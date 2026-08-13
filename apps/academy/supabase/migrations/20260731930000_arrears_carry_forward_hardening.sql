-- FR-K24 (continued): arrears carry-forward — soft-delete correctness,
-- one balance function instead of two, and the prior-session reference
-- the AC asks for.
--
-- FR-K24 already shipped (20260731260000_arrears_carry_forward.sql): the
-- arrears figure is a DISPLAY value stored on fee_challan.arrears_paisa
-- and folded into net_paisa, derived fresh from the ledger at generation
-- time, and never given its own fee_challan_line or fee_payment_allocation
-- row. That decision stands and is untouched here — the debt an arrears
-- figure displays already has a payable home in whichever older challan
-- is still unpaid, which the FR-K16 waterfall settles oldest-first. This
-- migration closes three gaps that three LATER FRs opened or exposed.
--
-- 1. Soft delete (FR-A15, 20260731780000). fee_challan gained deleted_at
--    AFTER FR-K24 shipped, and hid deleted rows via RLS only. Every
--    balance read here is SECURITY DEFINER and owned by postgres, so RLS
--    never applies to it — a soft-deleted challan's ledger entries kept
--    inflating the next challan's arrears with a debt no screen would
--    admit existed. outstanding_balance_as_of() now excludes them
--    explicitly. The join has to cover both shapes challan-linked ledger
--    rows come in: generate_challans posts charge/concession with
--    source_type='fee_challan'/source_id (fee_ledger.challan_id null),
--    while apply_late_fees (FR-K17) sets challan_id directly.
--    fn_arrears_breakdown likewise skips soft-deleted enrolments in the
--    promotion chain — soft-deleting last year's enrolment hides its
--    challans, so it must stop feeding this year's arrears too.
--
-- 2. Two balance functions. student_balance() (FR-K14) and
--    outstanding_balance_as_of() (FR-K24) were byte-for-byte the same sum
--    apart from the as-of filter, so the soft-delete fix above would have
--    landed on one and not the other — two numbers on two screens, which
--    is exactly the drift FR-K14's own header warns against. student_balance()
--    is now a thin call into outstanding_balance_as_of(): one definition,
--    one place to be right. Its behaviour is otherwise unchanged (ledger
--    rows are only ever inserted with posted_at defaulting to now(), so
--    "as of clock_timestamp()" is every row that exists).
--
-- 3. AC4's "references the prior session id". FR-K24 satisfied this only
--    implicitly, via the enrolment.previous_enrolment_id chain being
--    queryable. That is true but invisible: nothing on the challan a
--    parent (or an auditor) actually sees says WHICH session the carried
--    money came from. fee_challan.arrears_source is that reference,
--    snapshotted at generation time alongside arrears_paisa so the two
--    can never disagree, and surfaced through build_challan_render_payload
--    (which, separately, was omitting arrears entirely — printing a
--    net_paisa that its own line items could not add up to).
--
-- Note on FR-A06: the session rollover engine (20260731810000) now sets
-- enrolment.previous_enrolment_id itself when it promotes a student, so
-- cross-session carry-forward is automatic. link_enrolment_promotion()
-- stays as the manual primitive for enrolments created outside rollover.

alter table public.fee_challan add column arrears_source jsonb not null default '[]'::jsonb;

-- Signature is unchanged, so create-or-replace is unambiguous here (no
-- new defaulted argument to make the old and new forms both callable).
create or replace function public.outstanding_balance_as_of(p_enrolment_id uuid, p_as_of timestamptz default now())
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(case when l.direction = 'debit' then l.amount_paisa else -l.amount_paisa end), 0)::bigint
    from public.fee_ledger l
   where l.enrolment_id = p_enrolment_id
     and l.tenant_id = app.auth_tenant_id()
     and l.posted_at <= p_as_of
     and not exists (
       select 1 from public.fee_challan c
        where c.id = coalesce(l.challan_id, case when l.source_type = 'fee_challan' then l.source_id end)
          and c.deleted_at is not null
     );
$$;

revoke execute on function public.outstanding_balance_as_of(uuid, timestamptz) from public, anon;
grant execute on function public.outstanding_balance_as_of(uuid, timestamptz) to authenticated;

create or replace function public.student_balance(p_enrolment_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select public.outstanding_balance_as_of(p_enrolment_id, clock_timestamp());
$$;

revoke execute on function public.student_balance(uuid) from public, anon;
grant execute on function public.student_balance(uuid) to authenticated;

-- Internal: one row per link of the promotion chain that still owes
-- something, carrying the session that link belonged to. Each link is
-- floored at zero on its own — a credit sitting on one enrolment must
-- never silently net off a debt on another, matching what
-- apply_advance_credit (FR-K16) already does one enrolment at a time.
create or replace function app.fn_arrears_breakdown(p_enrolment_id uuid)
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
      select greatest(public.outstanding_balance_as_of(c.id, clock_timestamp()), 0)::bigint as amount
    ) owed
   where owed.amount > 0;
$$;

revoke execute on function app.fn_arrears_breakdown(uuid) from public, anon, authenticated;

create or replace function app.fn_arrears_including_promotions(p_enrolment_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(amount_paisa), 0)::bigint from app.fn_arrears_breakdown(p_enrolment_id);
$$;

revoke execute on function app.fn_arrears_including_promotions(uuid) from public, anon, authenticated;

-- Widened: arrears_source is snapshotted from the same single read that
-- produces arrears_paisa, so the total and its per-session breakdown can
-- never drift apart. Everything else is unchanged from the FR-A15 version.
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

    if v_gross = 0 then
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
    select coalesce(sum(b.amount_paisa), 0)::bigint,
           coalesce(jsonb_agg(jsonb_build_object(
             'enrolment_id', b.source_enrolment_id,
             'session_id', b.source_session_id,
             'amount_paisa', b.amount_paisa
           ) order by b.amount_paisa desc), '[]'::jsonb)
      into v_arrears, v_arrears_source
      from app.fn_arrears_breakdown(v_enrol.enrolment_id) b;

    v_challan_no := public.next_challan_no(v_tenant_id, p_campus_id, p_session_id);

    begin
      insert into public.fee_challan (
        tenant_id, campus_id, enrolment_id, session_id, billing_period, challan_no,
        due_date, gross_paisa, concession_paisa, arrears_paisa, arrears_source, net_paisa, batch_id
      ) values (
        v_tenant_id, p_campus_id, v_enrol.enrolment_id, p_session_id, v_period_start, v_challan_no,
        v_period_end + 10, v_gross, v_concession, v_arrears, v_arrears_source, v_gross - v_concession + v_arrears, v_batch_id
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

-- Widened: the printed challan now carries the arrears figure and where
-- it came from. Without this the payload advertised a net_paisa its own
-- 'lines' array could not add up to whenever a student owed anything.
-- Everything else is unchanged from the FR-A09 version.
create or replace function public.build_challan_render_payload(p_challan_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_challan  public.fee_challan%rowtype;
  v_template public.challan_template%rowtype;
  v_student  record;
  v_lines    jsonb;
  v_logo     jsonb;
  v_arrears  jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_challan from public.fee_challan where id = p_challan_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_template from public.challan_template where campus_id = v_challan.campus_id;
  if v_challan.logo_asset_id is not null then
    select jsonb_build_object('asset_id', id, 'storage_path', storage_path) into v_logo
      from public.branding_asset where id = v_challan.logo_asset_id;
  end if;

  select s.name_en, s.gr_number, cl.name_en as class_name, cs.name as section_name
    into v_student
    from public.enrolment e
    join public.student s on s.id = e.student_id
    join public.class_level cl on cl.id = e.class_level_id
    join public.class_section cs on cs.id = e.section_id
   where e.id = v_challan.enrolment_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'head_name', fh.name_en, 'amount_paisa', fcl.amount_paisa,
           'concession_paisa', fcl.concession_paisa, 'net_paisa', fcl.net_paisa, 'line_type', fcl.line_type
         ) order by fh.code), '[]'::jsonb)
    into v_lines
    from public.fee_challan_line fcl
    join public.fee_head fh on fh.id = fcl.fee_head_id
   where fcl.challan_id = p_challan_id;

  -- Resolved against academic_session for the session NAME, not just the
  -- id: "Arrears (2025-26)" is what makes the carried amount answerable
  -- at the counter without a second lookup.
  select coalesce(jsonb_agg(jsonb_build_object(
           'session_id', src ->> 'session_id',
           'session_name', ses.name,
           'amount_paisa', (src ->> 'amount_paisa')::bigint
         )), '[]'::jsonb)
    into v_arrears
    from jsonb_array_elements(v_challan.arrears_source) src
    left join public.academic_session ses on ses.id = (src ->> 'session_id')::uuid;

  return jsonb_build_object(
    'challan_no', v_challan.challan_no,
    'barcode_value', v_challan.challan_no,
    'billing_period', v_challan.billing_period,
    'issue_date', v_challan.issue_date,
    'due_date', v_challan.due_date,
    'student', jsonb_build_object(
      'name_en', v_student.name_en, 'gr_number', v_student.gr_number,
      'class_name', v_student.class_name, 'section_name', v_student.section_name
    ),
    'bank', jsonb_build_object(
      'bank_name', v_template.bank_name, 'bank_account_title', v_template.bank_account_title,
      'bank_account_no', v_template.bank_account_no, 'footer_note_en', v_template.footer_note_en,
      'footer_note_ur', v_template.footer_note_ur
    ),
    'logo', v_logo,
    'lines', v_lines,
    'gross_paisa', v_challan.gross_paisa,
    'concession_paisa', v_challan.concession_paisa,
    'arrears_paisa', v_challan.arrears_paisa,
    'arrears_source', v_arrears,
    'net_paisa', v_challan.net_paisa,
    'copies', jsonb_build_array('bank', 'school', 'student')
  );
end;
$$;

revoke execute on function public.build_challan_render_payload(uuid) from public, anon;
grant execute on function public.build_challan_render_payload(uuid) to authenticated;
