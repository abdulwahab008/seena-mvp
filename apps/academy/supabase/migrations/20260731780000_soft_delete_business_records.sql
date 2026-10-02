-- FR-A15: soft delete of business records.
--
-- "As a Principal, I want deletions to be reversible, so that a clerk
-- deleting the wrong student on a Friday afternoon is a 10-second fix and
-- not a restore-from-backup incident."
--
-- Prior-art check (this migration's own required first step): grepped every
-- migration for deleted_at/is_active/is_deleted before writing anything.
-- Two near-misses, both left alone:
--   * public.campus already has a deleted_at column (foundation.sql), but
--     it's an archival timestamp paired with status='archived' — archived
--     campuses stay fully visible in the UI (campus-management.spec.ts
--     asserts the card "stays visible... doesn't vanish from the list").
--     That is not this FR's "invisible from every list" concept, so
--     campus/archive_campus is untouched.
--   * public.class_section.is_active is a deactivation flag (clone/rollover
--     churn) with its own semantics, not "someone deleted this section".
--     Untouched, per this FR's own instruction.
-- No existing hard-delete path for student or enrolment was found anywhere
-- (no delete/remove RPC, no delete button in the app) — there is nothing to
-- repoint onto the new mechanism.
--
-- Scope, deliberately narrow per this FR's own instruction rather than
-- retrofitting all ~100+ business tables:
--   * deleted_at/deleted_by land on student, enrolment, and fee_challan.
--     fee_challan is not a first-class soft_delete()/restore_record()
--     target on its own (p_table only accepts 'student'/'enrolment') — it's
--     a cascade dependent, pulled in specifically because AC4 requires an
--     enrolment's unpaid challans to disappear with it and come back intact
--     on restore, "no duplicate challan generated". Restoring a challan
--     only ever clears deleted_at — status/amounts are never touched, so
--     "pre-delete state" is trivially exact, and generate_challans()'s own
--     existing (enrolment_id, session_id, billing_period) existence check
--     already prevents a duplicate regardless.
--   * soft_delete()/restore_record() are generic, parametrized by table
--     name (p_table text), as asked — but only 'student' and 'enrolment'
--     are wired up. A third table joining this later is a new `elsif`
--     branch, not a new function.
--   * Every mutating RPC elsewhere (fn_change_student_status,
--     enrol_student, post_ledger_entry, ...) does NOT check deleted_at —
--     a soft-deleted row stays technically reachable by ID through those
--     other paths. Gating every existing mutation across the schema against
--     deleted_at is the "unbounded rewrite" this FR was explicitly scoped
--     away from; the Recycle Bin (view/restore) and the four tested ACs
--     (list/count invisibility, GR reuse, challan restore, purge hold) are
--     satisfied without it. Flagged here, not fixed.
--   * "result" records: no exam/result module exists yet in this schema
--     (grepped for it), so the purge hold's "financial/result" check below
--     only has financial tables to check today. The hold logic is written
--     to `raise` and get caught generically (see purge_soft_deleted_records
--     below), so a future result table starts protecting itself the moment
--     its own FK exists — no revisit needed here.
--
-- Campus-scope guard convention (per this session's b16ba25 fix, reapplied
-- to every new SECURITY DEFINER function here): every prior example in the
-- audit takes p_campus_id as a direct argument and checks it before doing
-- anything else. soft_delete/restore_record instead take a bare row id, so
-- the equivalent guard has to look the row's own campus_id up FIRST, then
-- apply the identical "owner/super_admin bypass, otherwise campus_id must
-- be in app.auth_campus_ids()" test before mutating it. restore_record
-- skips the campus half entirely: it is Owner/Super Admin-only start to
-- finish (AC2's own words — "When an Owner opens the Recycle Bin" — and
-- the same convention reverse_ledger_entry already uses for an "undo"
-- operation), and those two roles are tenant-wide by design everywhere
-- else in this schema, never campus-gated.
--
-- Delete-permission role list mirrors create_student's own
-- (super_admin/owner/principal/admissions_officer) — the roles who can
-- admit a student are the roles who can undo admitting one. Restore and
-- the Recycle Bin read are Owner/Super Admin only, on purpose: the person
-- who can silently fix a clerk's mistake is deliberately a narrower set
-- than the person who can make it.

-- ── schema: deleted_at / deleted_by ──────────────────────────────────────

alter table public.student add column deleted_at timestamptz;
alter table public.student add column deleted_by uuid references public.app_user(user_id);
alter table public.enrolment add column deleted_at timestamptz;
alter table public.enrolment add column deleted_by uuid references public.app_user(user_id);
alter table public.fee_challan add column deleted_at timestamptz;
alter table public.fee_challan add column deleted_by uuid references public.app_user(user_id);

create index idx_student_recycle_bin on public.student (tenant_id) where deleted_at is not null;
create index idx_enrolment_recycle_bin on public.enrolment (tenant_id) where deleted_at is not null;
create index idx_fee_challan_recycle_bin on public.fee_challan (tenant_id) where deleted_at is not null;

-- ── RLS: every SELECT policy on the three tables gains "and deleted_at is
--    null", plus a separate Owner/Super-Admin-only recycle-bin-read policy
--    on student and enrolment (two permissive SELECT policies on the same
--    table OR together, so a non-owner never matches the recycle-bin branch
--    and sees nothing extra) ─────────────────────────────────────────────

drop policy student_campus_scope on public.student;
create policy student_campus_scope on public.student
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() <> 'parent'
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    and deleted_at is null
  );

drop policy student_parent_read_own_children on public.student;
create policy student_parent_read_own_children on public.student
  for select to authenticated
  using (id = any(app.auth_guardian_student_ids()) and deleted_at is null);

create policy student_recycle_bin_read on public.student
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner')
    and deleted_at is not null
  );

drop policy enrolment_campus_scope on public.enrolment;
create policy enrolment_campus_scope on public.enrolment
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() <> 'parent'
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    and deleted_at is null
  );

drop policy enrolment_parent_read_own_children on public.enrolment;
create policy enrolment_parent_read_own_children on public.enrolment
  for select to authenticated
  using (student_id = any(app.auth_guardian_student_ids()) and deleted_at is null);

create policy enrolment_recycle_bin_read on public.enrolment
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner')
    and deleted_at is not null
  );

drop policy fee_challan_campus_scope on public.fee_challan;
create policy fee_challan_campus_scope on public.fee_challan
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() <> 'parent'
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    and deleted_at is null
  );

drop policy fee_challan_parent_read_own_children on public.fee_challan;
create policy fee_challan_parent_read_own_children on public.fee_challan
  for select to authenticated
  using (
    deleted_at is null
    and enrolment_id in (
      select id from public.enrolment where student_id = any(app.auth_guardian_student_ids())
    )
  );

-- ── direct dependents that compute "class strength" from enrolment.status
--    directly (bypassing RLS, as SECURITY DEFINER) — both widened so AC1
--    ("class strength drops by exactly 1") holds for them too ────────────

create or replace view public.v_section_seat_availability
with (security_invoker = true) as
select
  cs.id as section_id, cs.class_level_id, cs.campus_id, cs.session_id, cs.name, cs.capacity,
  coalesce(cnt.c, 0) as active_count,
  cs.capacity - coalesce(cnt.c, 0) as seats_free
from public.class_section cs
left join (
  select section_id, count(*) as c from public.enrolment where status = 'active' and deleted_at is null group by section_id
) cnt
  on cnt.section_id = cs.id
where cs.is_active;

-- Body otherwise unchanged from admission_waitlist.sql's version — the
-- true latest before this migration. (module_b_review_fixes.sql's own
-- version had already been superseded by it: campus_id-scoped rather
-- than tenant_id-scoped, plus an offer_pending-waitlist subquery, both
-- needed so the offer-lapse trigger's service_role/no-JWT cron path still
-- works and a promoted-but-not-yet-offered waitlist entry still holds its
-- seat.) The only actual change in this migration is "and e.deleted_at is
-- null" on the enrolment subquery.
create or replace function app.fn_available_seats(p_class_level_id uuid, p_session_id uuid, p_campus_id uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(cs.capacity), 0)::int - (
    select count(*)::int from public.enrolment e
     where e.class_level_id = p_class_level_id and e.session_id = p_session_id
       and e.campus_id = p_campus_id and e.status = 'active' and e.deleted_at is null
  ) - (
    select count(*)::int
      from public.admission_offer o
      join public.admission_application a on a.id = o.application_id
     where a.class_applied_id = p_class_level_id
       and a.session_id = p_session_id
       and a.campus_id = p_campus_id
       and ((o.status = 'issued' and o.expires_at > now()) or o.status = 'accepted')
  ) - (
    select count(*)::int from public.admission_waitlist w
     where w.class_level_id = p_class_level_id and w.session_id = p_session_id and w.campus_id = p_campus_id
       and w.status = 'offer_pending'
  )
  from public.class_section cs
 where cs.class_level_id = p_class_level_id and cs.session_id = p_session_id and cs.campus_id = p_campus_id
   and cs.is_active;
$$;

-- generate_challans: widened only enough that a soft-deleted student/
-- enrolment stops being picked up for a NEW billing period while gone (it
-- is, after all, not currently "in the system") — body otherwise unchanged
-- from the campus-scope-audit migration's version.
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

-- ── AC3: GR number stays reserved once used, even after the student
--    holding it is soft-deleted. uq_student_gr is a tenant-wide unique
--    index (not campus-scoped, unlike gr_ledger's own PK), so the check
--    below mirrors that exact scope. In normal operation
--    app.fn_allocate_gr_number's sequence is monotonic and this can never
--    fire — the only way to reach it is a deliberate set_gr_sequence()
--    rewind (the "migrating from a paper register" path that function's
--    own header already documents), which is exactly the scenario this AC
--    describes. Without this check the same rewind would still be blocked,
--    just by a raw "duplicate key value violates constraint uq_student_gr"
--    instead of the friendly code the AC asks for. ─────────────────────
create or replace function public.create_student(
  p_campus_id             uuid,
  p_name_en               text,
  p_dob                   date,
  p_gender                public.gender,
  p_name_ur               text default null,
  p_father_name_en        text default null,
  p_father_name_ur        text default null,
  p_religion              text default null,
  p_nationality           text default 'PK',
  p_b_form_no             text default null,
  p_blood_group           text default null,
  p_bform_override_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id                uuid;
  v_gr                text;
  v_normalized_bform  text;
  v_existing          record;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_b_form_no is not null and btrim(p_b_form_no) <> '' then
    v_normalized_bform := regexp_replace(p_b_form_no, '[^0-9]', '', 'g');
    if length(v_normalized_bform) <> 13 then
      raise exception 'BFORM_INVALID_FORMAT' using errcode = '23514';
    end if;
    v_normalized_bform :=
      substr(v_normalized_bform, 1, 5) || '-' || substr(v_normalized_bform, 6, 7) || '-' || substr(v_normalized_bform, 13, 1);

    select id, gr_number into v_existing
      from public.student
     where tenant_id = app.auth_tenant_id() and b_form_no = v_normalized_bform
     limit 1;

    if found and p_bform_override_reason is null then
      raise exception 'BFORM_DUPLICATE'
        using errcode = '23505', detail = format('existing_gr=%s existing_student_id=%s', v_existing.gr_number, v_existing.id);
    end if;
  end if;

  v_gr := app.fn_allocate_gr_number(p_campus_id);

  if exists (select 1 from public.student where tenant_id = app.auth_tenant_id() and gr_number = v_gr) then
    raise exception 'GR_NUMBER_IN_USE' using errcode = '23505', detail = format('gr_number=%s', v_gr);
  end if;

  insert into public.student (
    tenant_id, campus_id, gr_number, name_en, name_ur, father_name_en, father_name_ur,
    dob, gender, religion, nationality, b_form_no, blood_group, bform_override_reason
  ) values (
    app.auth_tenant_id(), p_campus_id, v_gr, p_name_en, p_name_ur, p_father_name_en, p_father_name_ur,
    p_dob, p_gender, p_religion, coalesce(p_nationality, 'PK'), v_normalized_bform, p_blood_group,
    p_bform_override_reason
  )
  returning id into v_id;

  insert into public.gr_ledger (campus_id, gr_number, student_id, allocated_by)
  values (p_campus_id, v_gr, v_id, auth.uid());

  return v_id;
end;
$$;

-- ── soft_delete / restore_record: generic, parametrized by table name ───

create or replace function public.soft_delete(p_table text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
  v_row       record;
begin
  if p_table not in ('student', 'enrolment') then
    raise exception 'UNSUPPORTED_TABLE' using errcode = '0A000', detail = format('table=%s', p_table);
  end if;

  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_table = 'student' then
    select tenant_id, campus_id into v_tenant_id, v_campus_id
      from public.student where id = p_id and deleted_at is null;
    if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
      raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
    end if;
  else
    select tenant_id, campus_id into v_tenant_id, v_campus_id
      from public.enrolment where id = p_id and deleted_at is null;
    if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
      raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;

  if app.auth_role() not in ('super_admin', 'owner') and not (v_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_table = 'student' then
    update public.student set deleted_at = now(), deleted_by = auth.uid() where id = p_id;

    -- Cascade to this student's own (still-live) enrolments, one at a
    -- time through the same function — each recursive call re-derives and
    -- re-checks its OWN campus_id (an enrolment's campus_id need not match
    -- its student's, e.g. after a cross-campus transfer), rather than
    -- inheriting the parent's already-passed check.
    for v_row in select id from public.enrolment where student_id = p_id and deleted_at is null loop
      perform public.soft_delete('enrolment', v_row.id);
    end loop;
  else
    update public.enrolment set deleted_at = now(), deleted_by = auth.uid() where id = p_id;

    -- AC4's direct dependent: challans hidden alongside their enrolment,
    -- restored to the exact pre-delete row (status/amounts untouched) by
    -- restore_record below.
    update public.fee_challan set deleted_at = now(), deleted_by = auth.uid()
     where enrolment_id = p_id and deleted_at is null;
  end if;
end;
$$;

revoke execute on function public.soft_delete(text, uuid) from public, anon;
grant execute on function public.soft_delete(text, uuid) to authenticated;

create or replace function public.restore_record(p_table text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_row       record;
begin
  if p_table not in ('student', 'enrolment') then
    raise exception 'UNSUPPORTED_TABLE' using errcode = '0A000', detail = format('table=%s', p_table);
  end if;

  -- Owner/Super Admin only (AC2), and both are tenant-wide by convention
  -- everywhere else in this schema — no campus-scope check here, unlike
  -- soft_delete above.
  if app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_table = 'student' then
    select tenant_id into v_tenant_id from public.student where id = p_id and deleted_at is not null;
    if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
      raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
    end if;

    update public.student set deleted_at = null, deleted_by = null where id = p_id;

    for v_row in select id from public.enrolment where student_id = p_id and deleted_at is not null loop
      perform public.restore_record('enrolment', v_row.id);
    end loop;
  else
    select tenant_id into v_tenant_id from public.enrolment where id = p_id and deleted_at is not null;
    if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
      raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
    end if;

    update public.enrolment set deleted_at = null, deleted_by = null where id = p_id;

    -- AC4: challans come back exactly as they were — this clears the one
    -- column soft_delete ever touched on them, nothing else.
    update public.fee_challan set deleted_at = null, deleted_by = null
     where enrolment_id = p_id and deleted_at is not null;
  end if;
end;
$$;

revoke execute on function public.restore_record(text, uuid) from public, anon;
grant execute on function public.restore_record(text, uuid) to authenticated;

-- ── purge_soft_deleted_records: the daily job, un-scheduled ────────────
--
-- Same convention as every other System-actor function this session has
-- built (compute_month_attendance, dispatch_absentee_notifications,
-- run_unmarked_attendance_check): a real, tested, service_role-grantable
-- function a pg_cron job WOULD call once one exists locally — not actually
-- scheduled. Callable by an authenticated Owner/Super Admin too, in which
-- case it is naturally tenant-scoped by the `tenant_id = app.auth_tenant_id()`
-- filter below (service_role/cron, with no JWT, sees every tenant).
--
-- AC5's "only if nothing financial/result references it" is enforced two
-- ways: (1) an explicit pre-check against the five tables that would
-- otherwise silently CASCADE away with the enrolment (fee_plan,
-- fee_challan, fee_ledger, fee_payment, concession_award all have
-- `on delete cascade` back to enrolment — losing money history as a side
-- effect of a delete statement is exactly what this AC forbids, and a
-- cascade never raises an error to catch), and (2) the actual DELETE is
-- still wrapped in `exception when foreign_key_violation` as a catch-all,
-- so any OTHER reference this migration didn't enumerate by hand
-- (fee_challan_batch_error, the admission-fee-token consumed_by_enrolment_id
-- columns, and any future "result" table with a plain FK back to
-- student/enrolment) also converts to a hold+flag instead of crashing the
-- whole run. gr_ledger is the one deliberate exception: it is student's
-- only remaining referrer once its enrolments are gone, and it exists
-- specifically to survive the student it was allocated to (nullable
-- student_id, no cascade, "cited in board correspondence and legal
-- disputes" per its own migration) — it is detached (student_id set null),
-- not treated as a hold reason, so the GR register itself is never purged.

create table public.purge_hold (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  table_name text not null,
  row_id     uuid not null,
  reason     text not null,
  flagged_at timestamptz not null default now(),
  unique (table_name, row_id)
);

alter table public.purge_hold enable row level security;

create policy purge_hold_owner_read on public.purge_hold
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner'));

create or replace function public.purge_soft_deleted_records(p_older_than_days int default 91)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cutoff            timestamptz := now() - make_interval(days => p_older_than_days);
  v_enrolment         record;
  v_student           record;
  v_has_financial_ref boolean;
  v_purged_enrolments int := 0;
  v_held_enrolments   int := 0;
  v_purged_students   int := 0;
  v_held_students     int := 0;
begin
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- ── enrolments ──────────────────────────────────────────────────────
  for v_enrolment in
    select id, tenant_id from public.enrolment
     where deleted_at is not null and deleted_at < v_cutoff
       and (app.auth_tenant_id() is null or tenant_id = app.auth_tenant_id())
  loop
    v_has_financial_ref :=
      exists (select 1 from public.fee_plan where enrolment_id = v_enrolment.id)
      or exists (select 1 from public.fee_challan where enrolment_id = v_enrolment.id)
      or exists (select 1 from public.fee_ledger where enrolment_id = v_enrolment.id)
      or exists (select 1 from public.fee_payment where enrolment_id = v_enrolment.id)
      or exists (select 1 from public.concession_award where enrolment_id = v_enrolment.id);

    if v_has_financial_ref then
      insert into public.purge_hold (tenant_id, table_name, row_id, reason)
      values (v_enrolment.tenant_id, 'enrolment', v_enrolment.id, 'financial records reference this enrolment')
      on conflict (table_name, row_id) do update set reason = excluded.reason, flagged_at = now();
      v_held_enrolments := v_held_enrolments + 1;
    else
      begin
        delete from public.enrolment where id = v_enrolment.id;
        delete from public.purge_hold where table_name = 'enrolment' and row_id = v_enrolment.id;
        v_purged_enrolments := v_purged_enrolments + 1;
      exception
        when foreign_key_violation then
          insert into public.purge_hold (tenant_id, table_name, row_id, reason)
          values (v_enrolment.tenant_id, 'enrolment', v_enrolment.id, 'referenced by other records (foreign_key_violation)')
          on conflict (table_name, row_id) do update set reason = excluded.reason, flagged_at = now();
          v_held_enrolments := v_held_enrolments + 1;
      end;
    end if;
  end loop;

  -- ── students (only once every enrolment they had is actually gone —
  --    enrolment.student_id has no ON DELETE clause, so a remaining row,
  --    held or simply not old enough yet, blocks this by design) ────────
  for v_student in
    select id, tenant_id from public.student
     where deleted_at is not null and deleted_at < v_cutoff
       and (app.auth_tenant_id() is null or tenant_id = app.auth_tenant_id())
  loop
    if exists (select 1 from public.enrolment where student_id = v_student.id) then
      insert into public.purge_hold (tenant_id, table_name, row_id, reason)
      values (v_student.tenant_id, 'student', v_student.id, 'has remaining enrolment record(s)')
      on conflict (table_name, row_id) do update set reason = excluded.reason, flagged_at = now();
      v_held_students := v_held_students + 1;
    else
      begin
        -- gr_ledger is the permanent GR register — detached, not deleted,
        -- so the number stays legible in board correspondence forever.
        update public.gr_ledger set student_id = null where student_id = v_student.id;
        delete from public.student where id = v_student.id;
        delete from public.purge_hold where table_name = 'student' and row_id = v_student.id;
        v_purged_students := v_purged_students + 1;
      exception
        when foreign_key_violation then
          insert into public.purge_hold (tenant_id, table_name, row_id, reason)
          values (v_student.tenant_id, 'student', v_student.id, 'referenced by other records (foreign_key_violation)')
          on conflict (table_name, row_id) do update set reason = excluded.reason, flagged_at = now();
          v_held_students := v_held_students + 1;
      end;
    end if;
  end loop;

  return jsonb_build_object(
    'enrolments_purged', v_purged_enrolments, 'enrolments_held', v_held_enrolments,
    'students_purged', v_purged_students, 'students_held', v_held_students
  );
end;
$$;

revoke execute on function public.purge_soft_deleted_records(int) from public, anon;
grant execute on function public.purge_soft_deleted_records(int) to authenticated, service_role;
