-- Module K hardening — five bugs found by an independent second-pass
-- review of the whole Fees & Billing module before it merges, none of
-- them caught by this module's own (extensive) pgTAP suite. Each is a
-- real, concrete defect, not a style nit — see the per-function
-- comments below for the exact failure scenario each one closes.

-- ── 1. A negative concession value was never rejected ──────────────────
--
-- request_concession_award()/edit_concession_award() checked p_value
-- against an UPPER bound (100 for percentage, scheme.max_value) but
-- never checked p_value >= 0, and concession_award.value had no CHECK
-- constraint either (concession_scheme.value, the catalogue row, does —
-- the award row, the actual instance, didn't). A negative award value
-- flows straight into a negative concession_paisa inside
-- app.fn_plan_line_period_charges(), which then trips
-- fee_challan.concession_paisa/fee_challan_line.concession_paisa's own
-- `>= 0` CHECK as an uncaught exception *inside* generate_challans()'s
-- per-enrolment loop — aborting the entire monthly batch for every
-- other student, not just the one bad award. Fixed at both the two
-- write paths AND the table itself, the same "twice, on purpose"
-- defense-in-depth already used for the ledger and ck_challan_line_net_nonnegative.

alter table public.concession_award add constraint ck_concession_award_value_nonnegative check (value >= 0);

create or replace function public.request_concession_award(
  p_enrolment_id uuid, p_scheme_id uuid, p_value numeric, p_effective_from date, p_effective_to date,
  p_document_paths text[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enrolment public.enrolment%rowtype;
  v_scheme    public.concession_scheme%rowtype;
  v_award_id  uuid;
  v_path      text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_value < 0 then
    raise exception 'VALUE_MUST_BE_NONNEGATIVE' using errcode = '23514';
  end if;

  select * into v_enrolment from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_scheme from public.concession_scheme where id = p_scheme_id and tenant_id = app.auth_tenant_id() and is_active;
  if not found then
    raise exception 'CONCESSION_SCHEME_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_scheme.calc_type = 'percentage' and p_value > 100 then
    raise exception 'VALUE_EXCEEDS_MAXIMUM' using errcode = '23514';
  end if;
  if v_scheme.max_value is not null and p_value > v_scheme.max_value then
    raise exception 'VALUE_EXCEEDS_MAXIMUM' using errcode = '23514';
  end if;

  if v_scheme.requires_document and coalesce(array_length(p_document_paths, 1), 0) = 0 then
    raise exception 'DOCUMENT_REQUIRED' using errcode = '23514';
  end if;

  if p_effective_to <= p_effective_from then
    raise exception 'EFFECTIVE_TO_MUST_FOLLOW_FROM' using errcode = '23514';
  end if;

  insert into public.concession_award (
    tenant_id, campus_id, enrolment_id, scheme_id, calc_type, value, effective_from, effective_to, requested_by
  ) values (
    v_enrolment.tenant_id, v_enrolment.campus_id, p_enrolment_id, p_scheme_id, v_scheme.calc_type, p_value, p_effective_from, p_effective_to, auth.uid()
  )
  returning id into v_award_id;

  foreach v_path in array p_document_paths loop
    insert into public.concession_award_document (award_id, storage_path, uploaded_by) values (v_award_id, v_path, auth.uid());
  end loop;

  return v_award_id;
end;
$$;

create or replace function public.edit_concession_award(p_award_id uuid, p_new_value numeric)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_award  public.concession_award%rowtype;
  v_scheme public.concession_scheme%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_new_value < 0 then
    raise exception 'VALUE_MUST_BE_NONNEGATIVE' using errcode = '23514';
  end if;

  select * into v_award from public.concession_award where id = p_award_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CONCESSION_AWARD_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_scheme from public.concession_scheme where id = v_award.scheme_id;
  if v_award.calc_type = 'percentage' and p_new_value > 100 then
    raise exception 'VALUE_EXCEEDS_MAXIMUM' using errcode = '23514';
  end if;
  if v_scheme.max_value is not null and p_new_value > v_scheme.max_value then
    raise exception 'VALUE_EXCEEDS_MAXIMUM' using errcode = '23514';
  end if;

  update public.concession_award set value = p_new_value where id = p_award_id;
end;
$$;

-- ── 2. The regulator fee-increase cap was skippable ────────────────────
--
-- publish_fee_structure()'s Owner-approval/regulator_reference gate
-- (FR-K03) only ever fires when supersedes_id is not null. But
-- create_draft_structure() (FR-K02, never touched by FR-K03) will
-- happily create a SECOND, unrelated draft — supersedes_id null — for a
-- campus+session that already has a published structure. An Accountant
-- could publish an arbitrary increase through that second draft and
-- never hit the cap check at all, bypassing the entire regulator
-- workflow FR-K03 exists for. Not reachable through the shipped UI
-- (which only offers "create draft" when no structure exists yet), but
-- fully reachable by calling the RPC directly. Fixed by refusing to
-- create an unrelated draft once a structure is already published for
-- that campus+session — a revision must go through
-- create_next_structure_version(), which correctly sets supersedes_id.

create or replace function public.create_draft_structure(p_campus_id uuid, p_session_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if exists (
    select 1 from public.fee_structure
     where campus_id = p_campus_id and session_id = p_session_id and tenant_id = app.auth_tenant_id() and status = 'published'
  ) then
    raise exception 'PUBLISHED_STRUCTURE_EXISTS_USE_NEXT_VERSION' using errcode = '55000';
  end if;

  insert into public.fee_structure (tenant_id, campus_id, session_id, created_by)
  values (app.auth_tenant_id(), p_campus_id, p_session_id, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

-- ── 3. add_structure_line() never validated class_id/fee_head_id's tenant ──
--
-- Every sibling function that takes a client-supplied catalogue id
-- (create_concession_scheme() for applicable_head_ids, for one) checks
-- it belongs to the caller's tenant before using it. add_structure_line()
-- didn't for p_class_id or p_fee_head_id — not an actual cross-tenant
-- read/write (a foreign-tenant id just fails the FK or produces a
-- dangling reference), but a real gap in the pattern this module
-- otherwise holds to everywhere else.

create or replace function public.add_structure_line(
  p_structure_id uuid, p_class_id uuid, p_fee_head_id uuid, p_amount_paisa bigint, p_frequency public.fee_frequency,
  p_group_code text default null, p_billing_month_mask smallint default 4095
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.fee_structure_status;
  v_id     uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select status into v_status from public.fee_structure where id = p_structure_id and tenant_id = app.auth_tenant_id();
  if v_status is null then
    raise exception 'STRUCTURE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_status <> 'draft' then
    raise exception 'STRUCTURE_NOT_DRAFT' using errcode = '55000';
  end if;
  if not exists (select 1 from public.class_level where id = p_class_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.fee_head where id = p_fee_head_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'FEE_HEAD_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.fee_structure_line (structure_id, class_id, group_code, fee_head_id, amount_paisa, frequency, billing_month_mask)
  values (p_structure_id, p_class_id, p_group_code, p_fee_head_id, p_amount_paisa, p_frequency, p_billing_month_mask)
  returning id into v_id;

  return v_id;
end;
$$;

-- ── 4. generate_challans() could abort the whole batch on a race ───────
--
-- The idempotency guard was check-then-insert with no exception
-- handling: two genuinely concurrent invocations for the same period
-- could both pass the "does a challan already exist" check before
-- either commits, then the second INSERT hits fee_challan_period_uq as
-- an uncaught unique_violation — aborting generate_challans() entirely,
-- including every other enrolment already processed in that same call.
-- The documented, tested scenario (a sequential re-run) was never
-- actually affected by this — the pre-check already catches that case
-- — but a genuine race was one uncaught exception away from turning
-- "skip one enrolment" into "fail the whole campus's batch". Wrapped
-- the write in its own sub-block so a unique_violation here is treated
-- exactly like the pre-check path: skip, don't abort.

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

    v_challan_no := public.next_challan_no(v_tenant_id, p_campus_id, p_session_id);

    begin
      insert into public.fee_challan (
        tenant_id, campus_id, enrolment_id, session_id, billing_period, challan_no,
        due_date, gross_paisa, concession_paisa, net_paisa, batch_id
      ) values (
        v_tenant_id, p_campus_id, v_enrol.enrolment_id, p_session_id, v_period_start, v_challan_no,
        v_period_end + 10, v_gross, v_concession, v_gross - v_concession, v_batch_id
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
