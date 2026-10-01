-- Gap closing: transport (FR-P04), hostel + mess (FR-Q06) and library recovery (FR-O08) fees
-- appear as their own lines on the generated fee challan.
--
-- Until now those fees were posted to fee_ledger as debits only. generate_challans() is plan-line
-- driven, so the challan never showed them: the money was owed on the ledger (and was even
-- swept into "arrears_paisa" by fn_arrears_breakdown) but the parent saw no bus / hostel / mess
-- line on the challan, the PDF payload or the portal.
--
-- Design (no ledger double counting):
--   * The ancillary ledger debits already exist, and fee_ledger is append-only, so they are never
--     re-posted and never updated. Instead each absorbed ledger row is recorded in
--     fee_challan_ledger_link (ledger row -> challan). A row is "unbilled" while it has no link to
--     a live (not cancelled, not soft-deleted) challan. A cancelled challan therefore releases
--     its rows to the next run.
--   * generate_challans() adds one fee_challan_line per fee head from the unbilled rows
--     (gross = debits less non-concession credits, concession = concession credits) for rows
--     whose value_date is on or before the billing month end, so a month posted late by the
--     cron is never lost: it rides the next challan. Heads whose net would be negative (a credit
--     note for an already-billed month) are left unbilled; the credit stays in the balance and
--     reduces arrears.
--   * Header totals include the lines; only the plan charge/concession is posted to the ledger,
--     exactly as before. The challan's arrears exclude the absorbed ancillary net (it is on
--     this challan's lines, not carried forward), so challan.net_paisa equals the ledger balance
--     after generation.
--   * Idempotent: the existing (enrolment, session, period) unique index still skips a re-run;
--     rows are linked inside the same sub-transaction as the challan insert; an advisory lock
--     per enrolment serialises two periods racing for the same unbilled rows. Challan numbers
--     are still taken only for a challan that will really be created (gap-free).
--   * The inventory charge-to-fee trigger (FR-R02) had the mirror problem: the sale debit was
--     already in the arrears the generator computed, then the trigger added a line on top. It now
--     takes the sale amount back out of arrears.

create table if not exists public.fee_challan_ledger_link (
  ledger_id    uuid not null references public.fee_ledger(id),
  challan_id   uuid not null references public.fee_challan(id) on delete cascade,
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  fee_head_id  uuid not null references public.fee_head(id),
  amount_paisa bigint not null check (amount_paisa > 0),
  direction    public.fee_ledger_direction not null,
  created_at   timestamptz not null default clock_timestamp(),
  primary key (ledger_id, challan_id)
);
create index if not exists idx_fee_challan_ledger_link_challan on public.fee_challan_ledger_link (challan_id);
create index if not exists idx_fee_challan_ledger_link_tenant on public.fee_challan_ledger_link (tenant_id);
create index if not exists idx_fee_challan_ledger_link_head on public.fee_challan_ledger_link (fee_head_id);

alter table public.fee_challan_ledger_link enable row level security;
revoke insert, update, delete, truncate on public.fee_challan_ledger_link from anon, authenticated;
drop policy if exists fee_challan_ledger_link_read on public.fee_challan_ledger_link;
create policy fee_challan_ledger_link_read on public.fee_challan_ledger_link
  for select to authenticated
  using (
    tenant_id = (select app.auth_tenant_id())
    and challan_id in (
      select c.id from public.fee_challan c
       where c.tenant_id = (select app.auth_tenant_id())
         and ((select app.auth_role()) in ('super_admin', 'owner') or c.campus_id = any (app.auth_campus_ids()))
    )
  );

-- Ledger source types that are billed on the challan by line rather than by the plan.
create or replace function app.fn_ancillary_source_types()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['transport_allocation', 'transport_allocation_adj', 'hostel_charge', 'hostel_concession',
               'hostel_adj', 'hostel_deposit', 'library_write_off']::text[];
$$;
revoke execute on function app.fn_ancillary_source_types() from public, anon, authenticated;

-- Per fee head, what the enrolment's unbilled ancillary ledger rows come to, through p_through.
create or replace function app.fn_ancillary_challan_lines(p_enrolment_id uuid, p_through date)
returns table (fee_head_id uuid, gross_paisa bigint, concession_paisa bigint, ledger_ids uuid[])
language sql
stable
security definer
set search_path = ''
as $$
  with u as (
    select l.id, l.fee_head_id, l.amount_paisa, l.direction, l.entry_type
      from public.fee_ledger l
     where l.enrolment_id = p_enrolment_id
       and l.tenant_id = app.auth_tenant_id()
       and l.value_date <= p_through
       and l.fee_head_id is not null
       and (
         l.source_type = any (app.fn_ancillary_source_types())
         or (l.source_type = 'reversal' and exists (
               select 1 from public.fee_ledger o
                where o.id = l.reversal_of_id and o.source_type = any (app.fn_ancillary_source_types())))
       )
       and not exists (
         select 1 from public.fee_challan_ledger_link k
           join public.fee_challan c on c.id = k.challan_id
          where k.ledger_id = l.id and c.status <> 'cancelled' and c.deleted_at is null
       )
  ), h as (
    select u.fee_head_id,
           sum(case when u.direction = 'debit' then u.amount_paisa else 0 end)
             - sum(case when u.direction = 'credit' and u.entry_type <> 'concession' then u.amount_paisa else 0 end) as gross,
           sum(case when u.direction = 'credit' and u.entry_type = 'concession' then u.amount_paisa else 0 end) as conc,
           array_agg(u.id order by u.id) as ids
      from u
     group by u.fee_head_id
  )
  select h.fee_head_id, h.gross::bigint, h.conc::bigint, h.ids
    from h
   where h.gross - h.conc >= 0;
$$;
revoke execute on function app.fn_ancillary_challan_lines(uuid, date) from public, anon, authenticated;

-- fn_arrears_breakdown, but the current enrolment's owed amount is first reduced by what this
-- challan bills on its own lines (p_excluded), so that amount is not also carried as arrears.
create or replace function app.fn_arrears_breakdown_excl(p_enrolment_id uuid, p_excluded bigint)
returns table (source_enrolment_id uuid, source_session_id uuid, amount_paisa bigint)
language sql
stable
set search_path = ''
as $$
  with recursive chain as (
    select e.id, e.previous_enrolment_id, e.session_id
      from public.enrolment e
     where e.id = p_enrolment_id and e.deleted_at is null
    union all
    select e.id, e.previous_enrolment_id, e.session_id
      from public.enrolment e
      join chain c on e.id = c.previous_enrolment_id
     where e.deleted_at is null
  )
  select c.id, c.session_id, owed.amount
    from chain c
    cross join lateral (
      select greatest(
               public.outstanding_balance_as_of(c.id, clock_timestamp())
               - case when c.id = p_enrolment_id then coalesce(p_excluded, 0) else 0 end, 0)::bigint as amount
    ) owed
   where owed.amount > 0;
$$;
revoke execute on function app.fn_arrears_breakdown_excl(uuid, bigint) from public, anon, authenticated;

create or replace function public.generate_challans(
  p_campus_id uuid, p_session_id uuid, p_period date, p_dry_run boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid := app.auth_tenant_id();
  v_batch_id       uuid;
  v_month          int := extract(month from p_period)::int;
  v_period_start   date := date_trunc('month', p_period)::date;
  v_period_end     date := (date_trunc('month', p_period) + interval '1 month - 1 day')::date;
  v_generated      int := 0;
  v_skipped        int := 0;
  v_failed         int := 0;
  v_enrol          record;
  v_gross          bigint;
  v_concession     bigint;
  v_anc_gross      bigint;
  v_anc_conc       bigint;
  v_arrears        bigint;
  v_arrears_source jsonb;
  v_gap_head       text;
  v_challan_id     uuid;
  v_challan_no     text;
  v_preview        jsonb := '{}'::jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
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
       and e.deleted_at is null and s.deleted_at is null
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

    -- Transport / hostel / mess / library recovery already on the ledger and not yet on a challan.
    if not p_dry_run then
      perform pg_advisory_xact_lock(hashtextextended('challan-ancillary:' || v_enrol.enrolment_id::text, 0));
    end if;
    select coalesce(sum(a.gross_paisa), 0), coalesce(sum(a.concession_paisa), 0)
      into v_anc_gross, v_anc_conc
      from app.fn_ancillary_challan_lines(v_enrol.enrolment_id, v_period_end) a;

    if v_gross + v_anc_gross = 0 then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    if p_dry_run then
      v_preview := jsonb_set(
        v_preview, array[v_enrol.class_name],
        to_jsonb(coalesce((v_preview ->> v_enrol.class_name)::bigint, 0) + (v_gross + v_anc_gross - v_concession - v_anc_conc))
      );
      v_generated := v_generated + 1;
      continue;
    end if;

    -- Read before any of this period's own charge/concession entries are posted below. What this
    -- challan bills on its own ancillary lines is excluded: it is not "carried forward".
    select coalesce(sum(b.amount_paisa), 0)::bigint,
           coalesce(jsonb_agg(jsonb_build_object(
             'enrolment_id', b.source_enrolment_id,
             'session_id', b.source_session_id,
             'amount_paisa', b.amount_paisa
           ) order by b.amount_paisa desc), '[]'::jsonb)
      into v_arrears, v_arrears_source
      from app.fn_arrears_breakdown_excl(v_enrol.enrolment_id, v_anc_gross - v_anc_conc) b;

    v_challan_no := public.next_challan_no(v_tenant_id, p_campus_id, p_session_id);

    begin
      insert into public.fee_challan (
        tenant_id, campus_id, enrolment_id, session_id, billing_period, challan_no,
        due_date, gross_paisa, concession_paisa, arrears_paisa, arrears_source, net_paisa, batch_id
      ) values (
        v_tenant_id, p_campus_id, v_enrol.enrolment_id, p_session_id, v_period_start, v_challan_no,
        v_period_end + 10, v_gross + v_anc_gross, v_concession + v_anc_conc, v_arrears, v_arrears_source,
        v_gross + v_anc_gross - v_concession - v_anc_conc + v_arrears, v_batch_id
      ) returning id into v_challan_id;

      insert into public.fee_challan_line (challan_id, fee_head_id, amount_paisa, concession_paisa, net_paisa, line_type, applied_award_ids)
      select v_challan_id, fee_head_id, amount_paisa, concession_paisa, amount_paisa - concession_paisa, 'charge', applied_award_ids
        from app.fn_plan_line_period_charges(v_enrol.plan_id, v_enrol.enrolment_id, v_tenant_id, v_period_start, v_period_end, v_month);

      insert into public.fee_challan_line (challan_id, fee_head_id, amount_paisa, concession_paisa, net_paisa, line_type)
      select v_challan_id, a.fee_head_id, a.gross_paisa, a.concession_paisa, a.gross_paisa - a.concession_paisa, 'charge'
        from app.fn_ancillary_challan_lines(v_enrol.enrolment_id, v_period_end) a
       where a.gross_paisa > 0;

      insert into public.fee_challan_ledger_link (ledger_id, challan_id, tenant_id, fee_head_id, amount_paisa, direction)
      select l.id, v_challan_id, v_tenant_id, l.fee_head_id, l.amount_paisa, l.direction
        from app.fn_ancillary_challan_lines(v_enrol.enrolment_id, v_period_end) a
        join public.fee_ledger l on l.id = any (a.ledger_ids);

      -- Only the plan charge is posted: the ancillary debits are already on the ledger.
      if v_gross > 0 then
        perform public.post_ledger_entry(
          v_enrol.enrolment_id, 'charge', v_gross, 'debit', null, v_period_start, 'fee_challan', v_challan_id
        );
      end if;
      if v_concession > 0 then
        perform public.post_ledger_entry(
          v_enrol.enrolment_id, 'concession', v_concession, 'credit', null, v_period_start, 'fee_challan', v_challan_id
        );
      end if;

      perform public.apply_advance_credit(v_enrol.enrolment_id, v_challan_id);

      v_generated := v_generated + 1;
    exception
      when unique_violation then
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

revoke execute on function public.generate_challans(uuid, uuid, date, boolean) from public, anon;
grant execute on function public.generate_challans(uuid, uuid, date, boolean) to authenticated;

-- FR-R02 charge-to-fee sales: the sale debit is already in the arrears computed at insert, so the
-- line the trigger adds must come out of arrears, or the challan bills the sale twice.
create or replace function app.tg_attach_sales_to_challan()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sale   record;
  v_line   uuid;
  v_head   uuid;
  v_sum    bigint := 0;
  v_adj    bigint := 0;
  v_cur    bigint := 0;
begin
  for v_sale in
    select s.id, s.total - coalesce((select sum(c.total) from public.inv_sale c where c.credit_note_of = s.id), 0) as due
      from public.inv_sale s
     where s.enrolment_id = new.enrolment_id and s.tenant_id = new.tenant_id
       and s.doc_type = 'sale' and s.settlement = 'fee_ledger'
       and not exists (select 1 from public.inv_sale_challan_link k where k.sale_id = s.id)
     order by s.sold_at
  loop
    if v_sale.due <= 0 then
      continue;
    end if;
    v_head := app.fn_uniform_books_head(new.tenant_id);
    insert into public.fee_challan_line (challan_id, fee_head_id, amount_paisa, concession_paisa, net_paisa, line_type)
    values (new.id, v_head, v_sale.due, 0, v_sale.due, 'charge')
    returning id into v_line;
    insert into public.inv_sale_challan_link (sale_id, challan_id, challan_line_id, amount_paisa) values (v_sale.id, new.id, v_line, v_sale.due);
    v_sum := v_sum + v_sale.due;
  end loop;
  if v_sum > 0 then
    select coalesce(sum((x ->> 'amount_paisa')::bigint), 0) into v_cur
      from jsonb_array_elements(new.arrears_source) x where (x ->> 'enrolment_id')::uuid = new.enrolment_id;
    v_adj := least(v_sum, new.arrears_paisa, v_cur);
    update public.fee_challan
       set gross_paisa = gross_paisa + v_sum,
           arrears_paisa = arrears_paisa - v_adj,
           net_paisa = net_paisa + v_sum - v_adj,
           arrears_source = case when v_adj = 0 then arrears_source else coalesce((
             select jsonb_agg(case when (x ->> 'enrolment_id')::uuid = new.enrolment_id
                                   then jsonb_set(x, '{amount_paisa}', to_jsonb((x ->> 'amount_paisa')::bigint - v_adj))
                                   else x end)
               from jsonb_array_elements(arrears_source) x
              where not ((x ->> 'enrolment_id')::uuid = new.enrolment_id and (x ->> 'amount_paisa')::bigint - v_adj <= 0)
           ), '[]'::jsonb) end
     where id = new.id;
  end if;
  return null;
end;
$$;
revoke execute on function app.tg_attach_sales_to_challan() from public, anon, authenticated;
