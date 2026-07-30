-- FR-K24: arrears carry-forward.
--
-- Design decision, not in the FR's own Supabase Objects list verbatim:
-- arrears is computed and shown on the challan (arrears_paisa, and
-- net_paisa = gross - concession + arrears, matching the AC's own
-- "net payable" figure) but is NEVER given its own fee_challan_line or
-- fee_payment_allocation row. It doesn't need one — the debt it displays
-- already has a fully payable home: whichever OLDER challan(s) are still
-- sitting unpaid/part_paid, which allocate_payment already walks
-- oldest-period-first (FR-K16). Giving arrears its own payable line
-- would let a single large payment settle the SAME debt twice — once via
-- the old challan's own lines, once via the new challan's arrears line —
-- since nothing would ever mark the old challan "already accounted for
-- elsewhere". Keeping arrears purely a display/reporting figure, derived
-- fresh from the ledger every time, is what the AC's own words ask for
-- anyway ("a display line derived from balance, not a new charge entry").
--
-- The one place this decision has teeth: fee_challan.net_paisa is now
-- arrears-inflated for display, but a challan's real "is this one done"
-- collectibility must stay driven by what it can actually collect — the
-- sum of ITS OWN fee_challan_line rows. app.fn_allocate_to_challan() and
-- apply_advance_credit() (both FR-K16) read fee_challan.net_paisa
-- directly for exactly that collectibility check — both are widened here
-- to sum fee_challan_line instead, so an arrears-inflated header column
-- can never make a challan whose real charges are fully paid report
-- "still part_paid" forever.
--
-- Cross-session carry-forward: FR-A06 (session rollover/promotion
-- engine) doesn't exist yet, so nothing today auto-creates a new
-- enrolment row linked to an old one on promotion. link_enrolment_promotion()
-- is the real, callable primitive that engine will use once it exists —
-- today it's a manual Accountant/Owner action. "references the prior
-- session id" (the AC's own words) is satisfied by the queryable chain
-- itself (enrolment.previous_enrolment_id -> that row's session_id), not
-- a new stored column that would just duplicate it.

alter table public.enrolment add column previous_enrolment_id uuid references public.enrolment(id);

create or replace function public.outstanding_balance_as_of(p_enrolment_id uuid, p_as_of timestamptz default now())
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(case when direction = 'debit' then amount_paisa else -amount_paisa end), 0)::bigint
    from public.fee_ledger
   where enrolment_id = p_enrolment_id and tenant_id = app.auth_tenant_id() and posted_at <= p_as_of;
$$;

revoke execute on function public.outstanding_balance_as_of(uuid, timestamptz) from public, anon;
grant execute on function public.outstanding_balance_as_of(uuid, timestamptz) to authenticated;

-- Internal: walks the previous_enrolment_id chain (this enrolment, then
-- whichever one it was promoted from, and so on) and sums each link's
-- own outstanding balance, each floored at zero individually — a credit
-- sitting on one enrolment in the chain must never silently net off a
-- debt on another; that is what apply_advance_credit (FR-K16) already
-- does deliberately, one enrolment at a time.
create or replace function app.fn_arrears_including_promotions(p_enrolment_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  with recursive chain as (
    select id, previous_enrolment_id from public.enrolment where id = p_enrolment_id
    union all
    select e.id, e.previous_enrolment_id
      from public.enrolment e
      join chain c on e.id = c.previous_enrolment_id
  )
  select coalesce(sum(greatest(public.outstanding_balance_as_of(chain.id, clock_timestamp()), 0)), 0)::bigint
    from chain;
$$;

revoke execute on function app.fn_arrears_including_promotions(uuid) from public, anon, authenticated;

create or replace function public.link_enrolment_promotion(p_new_enrolment_id uuid, p_old_enrolment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new public.enrolment%rowtype;
  v_old public.enrolment%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_new from public.enrolment where id = p_new_enrolment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into v_old from public.enrolment where id = p_old_enrolment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_new.student_id <> v_old.student_id then
    raise exception 'STUDENT_MISMATCH' using errcode = '55000';
  end if;
  if v_new.id = v_old.id then
    raise exception 'CANNOT_LINK_TO_SELF' using errcode = '55000';
  end if;

  update public.enrolment set previous_enrolment_id = p_old_enrolment_id where id = p_new_enrolment_id;
end;
$$;

revoke execute on function public.link_enrolment_promotion(uuid, uuid) from public, anon;
grant execute on function public.link_enrolment_promotion(uuid, uuid) to authenticated;

-- Widened: the collectibility check now sums this challan's own lines
-- rather than trusting fee_challan.net_paisa, which FR-K24 makes
-- arrears-inflated for display. See the migration header for why.
create or replace function app.fn_allocate_to_challan(p_payment_id uuid, p_challan_id uuid, p_max_amount bigint)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_remaining   bigint := p_max_amount;
  v_allocated   bigint := 0;
  v_head        record;
  v_line_alloc  bigint;
  v_total_net   bigint;
  v_total_alloc bigint;
begin
  if v_remaining <= 0 then
    return 0;
  end if;

  for v_head in
    with head_totals as (
      select fcl.fee_head_id,
             sum(fcl.net_paisa) as head_net,
             coalesce((
               select sum(fpa.amount_paisa) from public.fee_payment_allocation fpa
                where fpa.challan_id = p_challan_id and fpa.fee_head_id = fcl.fee_head_id
             ), 0) as head_allocated
        from public.fee_challan_line fcl
       where fcl.challan_id = p_challan_id and fcl.line_type in ('charge', 'late_fee')
       group by fcl.fee_head_id
    )
    select ht.fee_head_id, ht.head_net, ht.head_allocated
      from head_totals ht
      left join public.fee_head_priority fhp on fhp.fee_head_id = ht.fee_head_id and fhp.tenant_id = app.auth_tenant_id()
     order by coalesce(fhp.priority, 999) asc, ht.fee_head_id asc
  loop
    exit when v_remaining <= 0;
    if v_head.head_net - v_head.head_allocated <= 0 then
      continue;
    end if;
    v_line_alloc := least(v_head.head_net - v_head.head_allocated, v_remaining);
    insert into public.fee_payment_allocation (payment_id, challan_id, fee_head_id, amount_paisa)
    values (p_payment_id, p_challan_id, v_head.fee_head_id, v_line_alloc);
    v_remaining := v_remaining - v_line_alloc;
    v_allocated := v_allocated + v_line_alloc;
  end loop;

  if v_allocated > 0 then
    select coalesce(sum(net_paisa), 0) into v_total_net
      from public.fee_challan_line where challan_id = p_challan_id and line_type in ('charge', 'late_fee');
    select coalesce(sum(amount_paisa), 0) into v_total_alloc from public.fee_payment_allocation where challan_id = p_challan_id;
    update public.fee_challan
       set status = case when v_total_alloc >= v_total_net then 'paid' else 'part_paid' end::public.fee_challan_status
     where id = p_challan_id;
  end if;

  return v_allocated;
end;
$$;

-- Widened: same reasoning — v_net_paisa (how much credit this challan
-- can still absorb) must come from its own lines, not the
-- arrears-inflated header column.
create or replace function public.apply_advance_credit(p_enrolment_id uuid, p_challan_id uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid;
  v_challan_tenant uuid;
  v_net_paisa      bigint;
  v_credit_pay     record;
  v_this_alloc     bigint;
  v_total_applied  bigint := 0;
  v_remaining_need bigint;
begin
  select tenant_id into v_tenant_id from public.enrolment where id = p_enrolment_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  select tenant_id into v_challan_tenant from public.fee_challan where id = p_challan_id;
  if v_challan_tenant is null or v_challan_tenant <> app.auth_tenant_id() then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  select coalesce(sum(net_paisa), 0) into v_net_paisa
    from public.fee_challan_line where challan_id = p_challan_id and line_type in ('charge', 'late_fee');

  perform pg_advisory_xact_lock(hashtextextended('payment-alloc:' || p_enrolment_id::text, 0));

  for v_credit_pay in
    select fp.id, fp.amount_paisa - coalesce(sum(fpa.amount_paisa), 0) as unallocated
      from public.fee_payment fp
      left join public.fee_payment_allocation fpa on fpa.payment_id = fp.id
     where fp.enrolment_id = p_enrolment_id
     group by fp.id, fp.amount_paisa, fp.received_at
    having fp.amount_paisa - coalesce(sum(fpa.amount_paisa), 0) > 0
     order by fp.received_at asc
  loop
    select coalesce(sum(amount_paisa), 0) into v_remaining_need from public.fee_payment_allocation where challan_id = p_challan_id;
    v_remaining_need := v_net_paisa - v_remaining_need;
    exit when v_remaining_need <= 0;

    v_this_alloc := app.fn_allocate_to_challan(v_credit_pay.id, p_challan_id, least(v_credit_pay.unallocated, v_remaining_need)::bigint);
    v_total_applied := v_total_applied + v_this_alloc;
  end loop;

  return v_total_applied;
end;
$$;

-- Widened: computes and stores arrears_paisa (via
-- app.fn_arrears_including_promotions, read BEFORE this period's own
-- charge/concession entries are posted, so it never picks up the very
-- bill it is about to create) and folds it into net_paisa for display.
-- Everything else is unchanged from the FR-K16 version.
create or replace function public.generate_challans(
  p_campus_id uuid, p_session_id uuid, p_period date, p_dry_run boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_batch_id      uuid;
  v_month         int := extract(month from p_period)::int;
  v_period_start  date := date_trunc('month', p_period)::date;
  v_period_end    date := (date_trunc('month', p_period) + interval '1 month - 1 day')::date;
  v_generated     int := 0;
  v_skipped       int := 0;
  v_failed        int := 0;
  v_enrol         record;
  v_gross         bigint;
  v_concession    bigint;
  v_arrears       bigint;
  v_gap_head      text;
  v_challan_id    uuid;
  v_challan_no    text;
  v_preview       jsonb := '{}'::jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = v_tenant_id) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if not p_dry_run then
    insert into public.fee_challan_batch (tenant_id, campus_id, session_id, billing_period, requested_by)
    values (v_tenant_id, p_campus_id, p_session_id, v_period_start, auth.uid())
    returning id into v_batch_id;
  end if;

  for v_enrol in
    select e.id as enrolment_id, e.class_level_id, fp.id as plan_id, cl.name_en as class_name
      from public.enrolment e
      join public.student s on s.id = e.student_id
      join public.class_level cl on cl.id = e.class_level_id
      left join public.fee_plan fp on fp.enrolment_id = e.id
     where e.tenant_id = v_tenant_id and e.campus_id = p_campus_id and e.session_id = p_session_id
       and e.status = 'active' and s.status = 'active'
  loop
    if exists (
      select 1 from public.fee_challan
       where enrolment_id = v_enrol.enrolment_id and session_id = p_session_id
         and billing_period = v_period_start and status <> 'cancelled'
    ) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    if v_enrol.plan_id is null then
      v_failed := v_failed + 1;
      if not p_dry_run then
        insert into public.fee_challan_batch_error (batch_id, enrolment_id, reason)
        values (v_batch_id, v_enrol.enrolment_id, 'NO_FEE_PLAN');
      end if;
      continue;
    end if;

    select fh.code into v_gap_head
      from public.fee_head fh
     where fh.tenant_id = v_tenant_id and fh.is_mandatory
       and not exists (
         select 1 from public.fee_plan_line fpl where fpl.plan_id = v_enrol.plan_id and fpl.fee_head_id = fh.id
       )
     limit 1;
    if v_gap_head is not null then
      v_failed := v_failed + 1;
      if not p_dry_run then
        insert into public.fee_challan_batch_error (batch_id, enrolment_id, reason)
        values (v_batch_id, v_enrol.enrolment_id, 'MANDATORY_HEAD_COVERAGE_GAP: ' || v_gap_head);
      end if;
      continue;
    end if;

    select coalesce(sum(amount_paisa), 0), coalesce(sum(concession_paisa), 0)
      into v_gross, v_concession
      from app.fn_plan_line_period_charges(v_enrol.plan_id, v_enrol.enrolment_id, v_tenant_id, v_period_start, v_period_end, v_month);

    if v_gross = 0 then
      -- Nothing applicable this billing month (e.g. a quarterly-only plan
      -- between its billing months) — not a failure, just nothing to bill.
      v_skipped := v_skipped + 1;
      continue;
    end if;

    if p_dry_run then
      v_preview := jsonb_set(
        v_preview, array[v_enrol.class_name],
        to_jsonb(coalesce((v_preview ->> v_enrol.class_name)::bigint, 0) + (v_gross - v_concession))
      );
      v_generated := v_generated + 1;
      continue;
    end if;

    -- Read before any of this period's own charge/concession entries are
    -- posted below, so it reflects only what was ALREADY outstanding
    -- coming into this billing period.
    v_arrears := app.fn_arrears_including_promotions(v_enrol.enrolment_id);

    v_challan_no := public.next_challan_no(v_tenant_id, p_campus_id, p_session_id);

    begin
      insert into public.fee_challan (
        tenant_id, campus_id, enrolment_id, session_id, billing_period, challan_no,
        due_date, gross_paisa, concession_paisa, arrears_paisa, net_paisa, batch_id
      ) values (
        v_tenant_id, p_campus_id, v_enrol.enrolment_id, p_session_id, v_period_start, v_challan_no,
        v_period_end + 10, v_gross, v_concession, v_arrears, v_gross - v_concession + v_arrears, v_batch_id
      ) returning id into v_challan_id;

      insert into public.fee_challan_line (challan_id, fee_head_id, amount_paisa, concession_paisa, net_paisa, line_type, applied_award_ids)
      select v_challan_id, fee_head_id, amount_paisa, concession_paisa, amount_paisa - concession_paisa, 'charge', applied_award_ids
        from app.fn_plan_line_period_charges(v_enrol.plan_id, v_enrol.enrolment_id, v_tenant_id, v_period_start, v_period_end, v_month);

      perform public.post_ledger_entry(
        v_enrol.enrolment_id, 'charge', v_gross, 'debit', null, v_period_start, 'fee_challan', v_challan_id
      );
      if v_concession > 0 then
        perform public.post_ledger_entry(
          v_enrol.enrolment_id, 'concession', v_concession, 'credit', null, v_period_start, 'fee_challan', v_challan_id
        );
      end if;

      perform public.apply_advance_credit(v_enrol.enrolment_id, v_challan_id);

      v_generated := v_generated + 1;
    exception
      when unique_violation then
        -- A genuinely concurrent invocation won the race and already
        -- created this challan between our existence check and this
        -- insert — same outcome as the pre-check path: skip, not abort.
        v_skipped := v_skipped + 1;
    end;
  end loop;

  if not p_dry_run then
    update public.fee_challan_batch
       set generated_count = v_generated, skipped_count = v_skipped, failed_count = v_failed, completed_at = now()
     where id = v_batch_id;
  end if;

  return jsonb_build_object(
    'batch_id', v_batch_id, 'generated', v_generated, 'skipped', v_skipped, 'failed', v_failed,
    'dry_run', p_dry_run, 'preview_by_class', v_preview
  );
end;
$$;

create view public.v_student_outstanding
with (security_invoker = true) as
select e.id as enrolment_id, e.tenant_id, e.campus_id, e.student_id, e.session_id,
       greatest(public.outstanding_balance_as_of(e.id, clock_timestamp()), 0) as outstanding_paisa
  from public.enrolment e
 where e.status = 'active';
