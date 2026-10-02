-- Follow-up to FR-A12 (20260731760000_per_campus_role_scoping.sql): that
-- migration fixed 3 SECURITY DEFINER functions (daily_collection_report,
-- build_collection_report_payload, finalise_cash_book_day) that took a
-- p_campus_id argument with no check that it was in the caller's own
-- app.auth_campus_ids() scope, and flagged "several dozen more" similar
-- functions across the schema as unaudited. This migration is that audit.
--
-- Method: every SECURITY DEFINER function taking a p_campus_id-style
-- parameter (56 distinct functions, by latest definition) was read in
-- full and classified:
--
--   SAFE, no change — already checks app.auth_campus_ids() directly:
--   absentees_for_date, check_unmarked_attendance, copy_class_subject_map,
--   create_bell_calendar_rule, create_bell_template, create_enquiry,
--   create_room, create_section, create_timetable_version,
--   fn_student_medical_flags, sections_not_marked, upsert_class_subject.
--
--   SAFE, no change — role check already restricts callers to
--   owner/super_admin only, who are exempt from the scope check anyway:
--   archive_campus, create_late_fee_rule, set_challan_template.
--
--   SAFE, no change — EXECUTE is revoked from authenticated (granted only
--   to service_role), so an untrusted caller cannot reach it directly;
--   its only callers are other SECURITY DEFINER functions that already
--   validate the campus themselves before calling in:
--   fn_next_enquiry_no (called by create_enquiry), next_challan_no
--   (called by generate_challans, fixed below).
--
--   SAFE, no change — covered transitively: resolve_attendance_status
--   does no campus-scoped table access of its own, it only reads through
--   resolve_attendance_policy (fixed below), so fixing the latter closes
--   the gap for both without a redundant second guard.
--
--   REAL GAP, fixed below (35 functions) — SECURITY DEFINER, GRANTed to
--   authenticated, takes p_campus_id, and had no app.auth_campus_ids()
--   check anywhere in its own body or call path: add_holiday,
--   apply_class_preset, attach_staff_campus, attendance_weight,
--   available_seats, clone_academic_structure, compute_month_attendance,
--   create_academic_session, create_branding_asset, create_draft_structure,
--   create_staff, create_student, create_test_sitting,
--   detect_sibling_groups, dispatch_absentee_notifications,
--   fn_preview_checklist, fn_promote_waitlist, generate_challans,
--   mark_staff_attendance_bulk, resolve_attendance_holiday,
--   resolve_attendance_policy, resolve_bell_template,
--   resolve_bell_template_for_weekday, resolve_branding,
--   resolve_fee_structure, resolve_timetable_version,
--   run_unmarked_attendance_check, set_attendance_policy,
--   set_attendance_status_weight, set_document_requirement,
--   set_gr_sequence, set_homework_load_policy,
--   set_leave_approval_chain_step, suggest_rooms_for_type,
--   working_days_between. create_staff and create_student were the two
--   examples named in FR-A12's own header as suspected real holes.
--   apply_class_preset's only campus-scoped write went through
--   create_section, which DOES check scope — but that call is
--   conditional (skipped when the section already exists), and the
--   preceding class_level upsert/deactivation is unconditional, so the
--   guard was not "unambiguous" per this audit's own bar and gets its
--   own explicit check rather than relying on the nested call.
--
-- Fix shape: identical to FR-A12's own fix — for everyone except
-- owner/super_admin, require p_campus_id = any(app.auth_campus_ids()),
-- raising FORBIDDEN (42501) for writes and interactive-only reads, same
-- as every pre-existing example of this guard in the schema. Three write
-- functions (add_holiday, create_branding_asset, create_academic_session)
-- accept a NULL p_campus_id to mean "tenant-wide"; for those, NULL now
-- additionally requires owner/super_admin (a non-owner could otherwise
-- pass NULL to bypass the scope check entirely, since `NULL = any(...)`
-- is NULL, not TRUE — plpgsql's `if NULL` does not raise). Three
-- functions (compute_month_attendance, dispatch_absentee_notifications,
-- run_unmarked_attendance_check) already had a pre-existing
-- `app.auth_tenant_id() is not null` guard around their role/existence
-- checks, to stay callable by service_role/cron with no JWT — the new
-- scope check for those three is nested inside that same guard, matching
-- the existing convention, so a cron invocation with no session claims is
-- still unaffected. The read-only `language sql` helpers
-- (attendance_weight, available_seats, resolve_attendance_holiday,
-- resolve_attendance_policy, resolve_bell_template,
-- resolve_bell_template_for_weekday, resolve_fee_structure,
-- resolve_timetable_version, suggest_rooms_for_type,
-- working_days_between) follow the pre-existing silent-empty-result
-- convention used by absentees_for_date/check_unmarked_attendance/
-- sections_not_marked (an out-of-scope campus gets NULL/no rows back, not
-- an exception) rather than raising, and use the same
-- `app.auth_tenant_id() is null or ...` escape those functions use, since
-- several of them (attendance_weight, working_days_between,
-- resolve_attendance_holiday via run_unmarked_attendance_check) are
-- called internally from functions that are themselves callable by
-- service_role/cron with no JWT — without that escape, a legitimate
-- scheduled run would have started silently computing nulls instead of
-- real attendance data. resolve_branding (a plpgsql read, not `language
-- sql`) gets the equivalent `return null` form instead of raising, to
-- match its own existing "not found → null" behaviour used elsewhere in
-- its body.
--
-- public.campus itself (flagged, not fixed, by the FR-A12 migration) is
-- addressed below too: its SELECT policy was tenant-wide only, so every
-- campus-picker in the app (new-student-form, staff invite, room
-- creation, branding, session rollover, ...) listed every campus in the
-- tenant regardless of the viewer's own scope. A codebase search turned
-- up exactly one legitimate tenant-wide read need (owner/super_admin,
-- already exempt below) and one page — app/(app)/campuses/page.tsx,
-- FR-A02's admin campus list/create/archive screen — that intentionally
-- shows every campus, which is itself an owner/super_admin operation
-- (archive_campus is already owner/super_admin-gated); no page or RPC
-- depends on a campus-scoped role (Principal, Accountant, Teacher, ...)
-- seeing a peer campus's row. The fee dashboard (fees/reports/page.tsx,
-- FR-A12 AC2) already does its own app-layer scoping via
-- lib/campus-scope.ts, so tightening this policy is redundant
-- defense-in-depth there, not a behaviour change. Fixed by adding the
-- same owner/super_admin exemption used everywhere else.

drop policy if exists campus_tenant_scope on public.campus;

create policy campus_tenant_scope on public.campus
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or id = any(app.auth_campus_ids()))
  );

create or replace function public.add_holiday(p_holiday_date date, p_name text, p_campus_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_campus_id is null then
    if app.auth_role() not in ('super_admin', 'owner') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  elsif app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.holiday_calendar (tenant_id, campus_id, holiday_date, name)
  values (app.auth_tenant_id(), p_campus_id, p_holiday_date, p_name)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.apply_class_preset(p_tenant_id uuid, p_campus_id uuid, p_session_id uuid, p_preset_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_class_rows  jsonb;
  v_preset_codes text[];
  v_row          jsonb;
  v_class_id     uuid;
  v_class_count  int := 0;
  v_section_count int := 0;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_tenant_id <> app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = p_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = p_tenant_id) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  select class_rows into v_class_rows from public.class_structure_preset where code = p_preset_code;
  if v_class_rows is null then
    raise exception 'PRESET_NOT_FOUND' using errcode = 'P0002';
  end if;

  select array_agg(r ->> 'code') into v_preset_codes from jsonb_array_elements(v_class_rows) as r;

  for v_row in select * from jsonb_array_elements(v_class_rows)
  loop
    insert into public.class_level (tenant_id, code, name_en, ordinal, board_stage, is_active)
    values (
      p_tenant_id,
      v_row ->> 'code',
      v_row ->> 'name_en',
      coalesce((select max(ordinal) + 1 from public.class_level where tenant_id = p_tenant_id), 0),
      v_row ->> 'board_stage',
      true
    )
    on conflict (tenant_id, code) do update
      set name_en = excluded.name_en, board_stage = excluded.board_stage, is_active = true
    returning id into v_class_id;

    v_class_count := v_class_count + 1;

    if not exists (
      select 1 from public.class_section
       where campus_id = p_campus_id and session_id = p_session_id
         and class_level_id = v_class_id and name = 'A'
    ) then
      perform public.create_section(p_campus_id, p_session_id, v_class_id, 'A', 40);
      v_section_count := v_section_count + 1;
    end if;
  end loop;

  update public.class_level
     set is_active = false
   where tenant_id = p_tenant_id
     and is_active = true
     and code <> all (v_preset_codes);

  return jsonb_build_object('class_count', v_class_count, 'sections_created', v_section_count);
end;
$$;

create or replace function public.attach_staff_campus(p_staff_id uuid, p_campus_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id into v_tenant_id from public.staff where id = p_staff_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.staff_campus (staff_id, campus_id) values (p_staff_id, p_campus_id) on conflict do nothing;
end;
$$;

create or replace function public.attendance_weight(p_status public.student_attendance_status, p_campus_id uuid, p_session_id uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select weight from public.attendance_status_weight
      where campus_id = p_campus_id and session_id = p_session_id and status = p_status
        and (app.auth_tenant_id() is null or app.auth_role() in ('super_admin', 'owner') or p_campus_id = any(app.auth_campus_ids()))),
    case p_status when 'present' then 1 when 'late' then 1 when 'half_day' then 0.5 else 0 end
  );
$$;

create or replace function public.available_seats(p_class_level_id uuid, p_session_id uuid, p_campus_id uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when app.auth_tenant_id() is null or app.auth_role() in ('super_admin', 'owner') or p_campus_id = any(app.auth_campus_ids())
      then app.fn_available_seats(p_class_level_id, p_session_id, p_campus_id)
    else null
  end;
$$;

create or replace function public.clone_academic_structure(
  p_from_session_id uuid, p_to_session_id uuid, p_campus_id uuid, p_dry_run boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id            uuid := app.auth_tenant_id();
  v_section              public.class_section%rowtype;
  v_alloc                record;
  v_new_section_id       uuid;
  v_already_allocated    boolean;
  v_staff_id             uuid;
  v_staff_full_name      text;
  v_staff_employment_status public.employment_status;
  v_is_resigned          boolean;
  v_sections_created     int := 0;
  v_sections_skipped     int := 0;
  v_maps_created         int := 0;
  v_maps_skipped         int := 0;
  v_class_alloc_created  int := 0;
  v_class_alloc_skipped  int := 0;
  v_subject_alloc_created int := 0;
  v_subject_alloc_skipped int := 0;
  v_resigned             jsonb := '[]'::jsonb;
  v_summary              jsonb;
  v_run_id               uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_from_session_id and tenant_id = v_tenant_id) then
    raise exception 'FROM_SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_to_session_id and tenant_id = v_tenant_id) then
    raise exception 'TO_SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_from_session_id = p_to_session_id then
    raise exception 'SAME_SESSION' using errcode = '22023';
  end if;

  -- Not ON COMMIT DROP: a caller (or a pgTAP test file) commonly makes
  -- several calls within one transaction (dry run, then the real run,
  -- then a re-run to prove idempotency) — ON COMMIT DROP would only
  -- clear it after the LAST one, so the second call would hit "relation
  -- already exists". Drop-then-recreate each call instead; an ordinary
  -- transaction rollback still undoes the CREATE TEMP TABLE itself, same
  -- as any other DDL.
  drop table if exists tmp_clone_section_map;
  create temporary table tmp_clone_section_map (
    old_section_id uuid primary key,
    new_section_id uuid
  );

  -- ── sections ────────────────────────────────────────────────────────
  for v_section in
    select * from public.class_section
     where campus_id = p_campus_id and session_id = p_from_session_id and is_active
  loop
    select id into v_new_section_id from public.class_section
     where campus_id = p_campus_id and session_id = p_to_session_id
       and class_level_id = v_section.class_level_id and name = v_section.name;

    if v_new_section_id is not null then
      v_sections_skipped := v_sections_skipped + 1;
    else
      v_sections_created := v_sections_created + 1;
      if not p_dry_run then
        insert into public.class_section (
          tenant_id, campus_id, session_id, class_level_id, name, capacity, medium, shift, gender_restriction, stream_id
        ) values (
          v_tenant_id, p_campus_id, p_to_session_id, v_section.class_level_id, v_section.name,
          v_section.capacity, v_section.medium, v_section.shift, v_section.gender_restriction, v_section.stream_id
        )
        returning id into v_new_section_id;
      end if;
    end if;

    insert into tmp_clone_section_map (old_section_id, new_section_id) values (v_section.id, v_new_section_id);
  end loop;

  -- ── curriculum maps (session-scoped, not section-scoped — no mapping
  --    table needed) ───────────────────────────────────────────────────
  if p_dry_run then
    select count(*) into v_maps_created
      from public.class_subject src
     where src.campus_id = p_campus_id and src.session_id = p_from_session_id
       and not exists (
         select 1 from public.class_subject tgt
          where tgt.campus_id = p_campus_id and tgt.session_id = p_to_session_id
            and tgt.class_level_id = src.class_level_id and tgt.subject_id = src.subject_id
            and coalesce(tgt.stream_id, '00000000-0000-0000-0000-000000000000'::uuid)
                = coalesce(src.stream_id, '00000000-0000-0000-0000-000000000000'::uuid)
       );
    select count(*) into v_maps_skipped
      from public.class_subject src
     where src.campus_id = p_campus_id and src.session_id = p_from_session_id
       and exists (
         select 1 from public.class_subject tgt
          where tgt.campus_id = p_campus_id and tgt.session_id = p_to_session_id
            and tgt.class_level_id = src.class_level_id and tgt.subject_id = src.subject_id
            and coalesce(tgt.stream_id, '00000000-0000-0000-0000-000000000000'::uuid)
                = coalesce(src.stream_id, '00000000-0000-0000-0000-000000000000'::uuid)
       );
  else
    insert into public.class_subject (
      tenant_id, campus_id, session_id, class_level_id, stream_id, subject_id,
      is_compulsory, elective_bucket, choose_n, weekly_periods, max_marks
    )
    select tenant_id, campus_id, p_to_session_id, class_level_id, stream_id, subject_id,
           is_compulsory, elective_bucket, choose_n, weekly_periods, max_marks
      from public.class_subject src
     where src.campus_id = p_campus_id and src.session_id = p_from_session_id
    on conflict (session_id, campus_id, class_level_id, (coalesce(stream_id, '00000000-0000-0000-0000-000000000000'::uuid)), subject_id)
    do nothing;
    get diagnostics v_maps_created = row_count;

    select count(*) into v_maps_skipped from public.class_subject where campus_id = p_campus_id and session_id = p_from_session_id;
    v_maps_skipped := v_maps_skipped - v_maps_created;
  end if;

  -- ── class-teacher allocations (E08) ────────────────────────────────
  for v_alloc in
    select sct.*, os.name as section_name
      from public.section_class_teacher sct
      join public.class_section os on os.id = sct.section_id
     where os.campus_id = p_campus_id and os.session_id = p_from_session_id and os.is_active
       and sct.effective_to is null
  loop
    select new_section_id into v_new_section_id from tmp_clone_section_map where old_section_id = v_alloc.section_id;

    v_already_allocated := false;
    if v_new_section_id is not null then
      select exists (
        select 1 from public.section_class_teacher where section_id = v_new_section_id and effective_to is null
      ) into v_already_allocated;
    end if;

    if v_already_allocated then
      v_class_alloc_skipped := v_class_alloc_skipped + 1;
      continue;
    end if;

    select id, full_name, employment_status into v_staff_id, v_staff_full_name, v_staff_employment_status
      from public.staff where user_id = v_alloc.staff_id and tenant_id = v_tenant_id;
    v_is_resigned := v_staff_id is not null and v_staff_employment_status <> 'active';

    v_class_alloc_created := v_class_alloc_created + 1;
    if v_is_resigned then
      v_resigned := v_resigned || jsonb_build_object('role', 'class_teacher', 'section_name', v_alloc.section_name, 'staff_name', v_staff_full_name);
    end if;

    if not p_dry_run then
      insert into public.section_class_teacher (tenant_id, campus_id, session_id, section_id, staff_id, effective_from)
      values (v_tenant_id, p_campus_id, p_to_session_id, v_new_section_id, case when v_is_resigned then null else v_alloc.staff_id end, current_date);
    end if;
  end loop;

  -- ── subject-teacher allocations (E09, primary role only — see header) ─
  for v_alloc in
    select sst.*, os.name as section_name, sub.name_en as subject_name
      from public.section_subject_teacher sst
      join public.class_section os on os.id = sst.section_id
      join public.subject sub on sub.id = sst.subject_id
     where os.campus_id = p_campus_id and os.session_id = p_from_session_id and os.is_active
       and sst.effective_to is null and sst.role = 'primary'
  loop
    select new_section_id into v_new_section_id from tmp_clone_section_map where old_section_id = v_alloc.section_id;

    v_already_allocated := false;
    if v_new_section_id is not null then
      select exists (
        select 1 from public.section_subject_teacher
         where section_id = v_new_section_id and subject_id = v_alloc.subject_id and role = 'primary' and effective_to is null
      ) into v_already_allocated;
    end if;

    if v_already_allocated then
      v_subject_alloc_skipped := v_subject_alloc_skipped + 1;
      continue;
    end if;

    select id, full_name, employment_status into v_staff_id, v_staff_full_name, v_staff_employment_status
      from public.staff where user_id = v_alloc.staff_id and tenant_id = v_tenant_id;
    v_is_resigned := v_staff_id is not null and v_staff_employment_status <> 'active';

    v_subject_alloc_created := v_subject_alloc_created + 1;
    if v_is_resigned then
      v_resigned := v_resigned || jsonb_build_object(
        'role', 'subject_teacher', 'section_name', v_alloc.section_name, 'subject_name', v_alloc.subject_name, 'staff_name', v_staff_full_name
      );
    end if;

    if not p_dry_run then
      insert into public.section_subject_teacher (tenant_id, campus_id, session_id, section_id, subject_id, staff_id, role, effective_from)
      values (
        v_tenant_id, p_campus_id, p_to_session_id, v_new_section_id, v_alloc.subject_id,
        case when v_is_resigned then null else v_alloc.staff_id end, 'primary', current_date
      );
    end if;
  end loop;

  v_summary := jsonb_build_object(
    'sections', jsonb_build_object('created', v_sections_created, 'skipped', v_sections_skipped),
    'class_subject_maps', jsonb_build_object('created', v_maps_created, 'skipped', v_maps_skipped),
    'allocations', jsonb_build_object(
      'created', v_class_alloc_created + v_subject_alloc_created,
      'skipped', v_class_alloc_skipped + v_subject_alloc_skipped
    ),
    'resigned_staff_allocations', v_resigned
  );

  insert into public.academic_clone_run (tenant_id, campus_id, from_session_id, to_session_id, is_dry_run, summary, run_by)
  values (v_tenant_id, p_campus_id, p_from_session_id, p_to_session_id, p_dry_run, v_summary, auth.uid())
  returning id into v_run_id;

  return v_summary || jsonb_build_object('run_id', v_run_id);
end;
$$;

create or replace function public.compute_month_attendance(p_campus_id uuid, p_year int, p_month int)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_month_start date := make_date(p_year, p_month, 1);
  v_month_end   date := (v_month_start + interval '1 month' - interval '1 day')::date;
  v_row         record;
  v_from        date;
  v_to          date;
  v_working     int;
  v_present     numeric(5, 2);
  v_absent      int;
  v_late        int;
  v_half        int;
  v_leave       int;
  v_count       int := 0;
begin
  if app.auth_tenant_id() is not null then
    if app.auth_role() not in ('super_admin', 'owner', 'principal') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
      raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;

  for v_row in
    select e.id as enrolment_id, e.tenant_id, e.campus_id, e.session_id, e.joined_on, e.left_on
      from public.enrolment e
     where e.campus_id = p_campus_id
       and e.joined_on <= v_month_end
       and (e.left_on is null or e.left_on >= v_month_start)
  loop
    v_from := greatest(v_month_start, v_row.joined_on);
    v_to   := least(v_month_end, coalesce(v_row.left_on, v_month_end));

    if v_from > v_to then
      v_working := 0;
    else
      v_working := public.working_days_between(p_campus_id, v_from, v_to)::int;
    end if;

    select
      coalesce(sum(public.attendance_weight(status, p_campus_id, v_row.session_id)), 0),
      count(*) filter (where status = 'absent'),
      count(*) filter (where status = 'late'),
      count(*) filter (where status = 'half_day'),
      count(*) filter (where status = 'excused')
      into v_present, v_absent, v_late, v_half, v_leave
      from public.attendance_day
     where enrolment_id = v_row.enrolment_id
       and attendance_date between v_from and v_to;

    insert into public.attendance_month_summary (
      tenant_id, campus_id, session_id, enrolment_id, year, month,
      working_days, present_days, absent_days, late_count, half_day_count, leave_days,
      attendance_pct, computed_at
    ) values (
      v_row.tenant_id, v_row.campus_id, v_row.session_id, v_row.enrolment_id, p_year, p_month,
      v_working, v_present, v_absent, v_late, v_half, v_leave,
      case when v_working = 0 then null else round(v_present / v_working * 100, 2) end,
      clock_timestamp()
    )
    on conflict (enrolment_id, year, month) do update
       set working_days   = excluded.working_days,
           present_days   = excluded.present_days,
           absent_days    = excluded.absent_days,
           late_count     = excluded.late_count,
           half_day_count = excluded.half_day_count,
           leave_days     = excluded.leave_days,
           attendance_pct = excluded.attendance_pct,
           recomputed_at  = clock_timestamp(),
           stale          = false;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function public.create_academic_session(
  p_campus_id uuid,
  p_name      text,
  p_starts_on date,
  p_ends_on   date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_session_id uuid;
begin
  if v_tenant_id is null or app.auth_role() not in ('owner', 'principal', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_campus_id is null then
    if app.auth_role() not in ('super_admin', 'owner') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  elsif app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_campus_id is not null and not exists (
    select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id
  ) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on)
  values (v_tenant_id, p_campus_id, p_name, p_starts_on, p_ends_on)
  returning id into v_session_id;

  return v_session_id;
end;
$$;

create or replace function public.create_branding_asset(
  p_asset_type public.branding_asset_type, p_width_px int, p_height_px int, p_bytes int, p_mime_type text, p_file_ext text,
  p_campus_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_min_width  int;
  v_version    int;
  v_id         uuid := gen_random_uuid();
  v_path       text;
  v_scope      text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_campus_id is null then
    if app.auth_role() not in ('super_admin', 'owner') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  elsif app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_campus_id is not null and not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_mime_type not in ('image/jpeg', 'image/png') then
    raise exception 'UNSUPPORTED_FILE_TYPE' using errcode = '22023';
  end if;
  if p_bytes > 3145728 then
    raise exception 'ASSET_TOO_LARGE' using errcode = '23514', detail = 'max_bytes=3145728';
  end if;

  v_min_width := case p_asset_type when 'logo' then 600 when 'letterhead' then 1000 else 200 end;
  if p_width_px < v_min_width then
    raise exception 'ASSET_RESOLUTION_TOO_LOW' using errcode = '23514', detail = format('min_width_px=%s', v_min_width);
  end if;

  select coalesce(max(version), 0) + 1 into v_version
    from public.branding_asset
   where tenant_id = v_tenant_id and campus_id is not distinct from p_campus_id and asset_type = p_asset_type;

  v_scope := coalesce(p_campus_id::text, 'tenant');
  v_path := v_tenant_id::text || '/' || v_scope || '/' || p_asset_type::text || '/' || v_version::text || '.' || p_file_ext;

  insert into public.branding_asset (id, tenant_id, campus_id, asset_type, storage_path, width_px, height_px, bytes, version, uploaded_by)
  values (v_id, v_tenant_id, p_campus_id, p_asset_type, v_path, p_width_px, p_height_px, p_bytes, v_version, auth.uid());

  return jsonb_build_object('asset_id', v_id, 'storage_path', v_path);
end;
$$;

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
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
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

create or replace function public.create_staff(
  p_campus_id        uuid,
  p_full_name        text,
  p_gender           public.gender,
  p_id_document_type public.id_document_type default 'cnic',
  p_cnic             text default null,
  p_passport_no      text default null,
  p_full_name_ur     text default null,
  p_contract_type    text default 'permanent',
  p_dob              date default null,
  p_doj              date default current_date,
  p_designation_id   uuid default null,
  p_department_id    uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_normalized_cnic  text;
  v_existing_code    text;
  v_employee_code    text;
  v_id               uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_id_document_type = 'cnic' then
    if p_cnic is null then
      raise exception 'CNIC_REQUIRED' using errcode = '23514';
    end if;
    v_normalized_cnic := app.fn_normalize_pk_id(p_cnic);

    select employee_code into v_existing_code
      from public.staff
     where tenant_id = app.auth_tenant_id() and cnic = v_normalized_cnic and employment_status = 'active'
     limit 1;
    if found then
      raise exception 'CNIC_CONFLICT' using errcode = '23505', detail = format('conflicting_employee_code=%s', v_existing_code);
    end if;
  elsif p_passport_no is null then
    raise exception 'PASSPORT_REQUIRED' using errcode = '23514';
  end if;

  v_employee_code := app.fn_next_employee_code(p_campus_id);

  insert into public.staff (
    tenant_id, campus_id, employee_code, id_document_type, cnic, passport_no, gender, contract_type,
    dob, doj, designation_id, department_id, full_name, full_name_ur
  ) values (
    app.auth_tenant_id(), p_campus_id, v_employee_code, p_id_document_type, v_normalized_cnic, p_passport_no, p_gender, p_contract_type,
    p_dob, p_doj, p_designation_id, p_department_id, p_full_name, p_full_name_ur
  )
  returning id into v_id;

  insert into public.staff_campus (staff_id, campus_id) values (v_id, p_campus_id);

  return v_id;
end;
$$;

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

create or replace function public.create_test_sitting(
  p_campus_id uuid, p_session_id uuid, p_class_level_id uuid, p_starts_at timestamptz, p_capacity int, p_venue text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer', 'exam_controller') then
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
  if not exists (select 1 from public.class_level where id = p_class_level_id and tenant_id = v_tenant_id) then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_capacity < 1 then
    raise exception 'CAPACITY_MUST_BE_POSITIVE' using errcode = '23514';
  end if;

  insert into public.admission_test_sitting (tenant_id, campus_id, session_id, class_level_id, starts_at, capacity, venue)
  values (v_tenant_id, p_campus_id, p_session_id, p_class_level_id, p_starts_at, p_capacity, p_venue)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.detect_sibling_groups(p_campus_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid := app.auth_tenant_id();
  v_max_rank       smallint;
  v_group          record;
  v_member         record;
  v_rank           int;
  v_scheme_id      uuid;
  v_groups_found   int := 0;
  v_proposals      int := 0;
  v_needs_review   jsonb := '[]'::jsonb;
  v_existing_award public.concession_award%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  select max(sibling_rank) into v_max_rank from public.sibling_discount_scheme_rank where tenant_id = v_tenant_id;

  for v_group in
    select app.fn_normalize_pk_id(g.cnic) as cnic_norm, array_agg(e.id order by s.created_at) as enrolment_ids
      from public.enrolment e
      join public.student s on s.id = e.student_id
      join public.student_guardian sg on sg.student_id = s.id and sg.to_date is null and sg.relationship = 'father'
      join public.guardian g on g.id = sg.guardian_id and g.cnic is not null
     where e.tenant_id = v_tenant_id and e.campus_id = p_campus_id and e.session_id = p_session_id
       and e.status = 'active' and s.status = 'active'
     group by app.fn_normalize_pk_id(g.cnic)
    having count(*) >= 2
  loop
    v_groups_found := v_groups_found + 1;

    insert into public.sibling_group (tenant_id, campus_id, session_id, guardian_cnic_norm, member_enrolment_ids)
    values (v_tenant_id, p_campus_id, p_session_id, v_group.cnic_norm, v_group.enrolment_ids)
    on conflict (tenant_id, campus_id, session_id, guardian_cnic_norm)
      do update set member_enrolment_ids = excluded.member_enrolment_ids, last_scanned_at = clock_timestamp();

    v_rank := 0;
    for v_member in select unnest(v_group.enrolment_ids) as enrolment_id loop
      v_rank := v_rank + 1;

      -- The scheme this member's CURRENT rank is entitled to — null for
      -- the eldest (rank 1) or if no scheme is configured that high.
      -- Checked for every member, rank 1 included: a member whose rank
      -- just dropped to 1 (an elder sibling left) still needs their old
      -- award inspected, not silently skipped.
      v_scheme_id := null;
      if v_rank >= 2 and v_max_rank is not null then
        select scheme_id into v_scheme_id
          from public.sibling_discount_scheme_rank
         where tenant_id = v_tenant_id and sibling_rank = least(v_rank, v_max_rank)::smallint;
      end if;

      select * into v_existing_award
        from public.concession_award
       where enrolment_id = v_member.enrolment_id
         and scheme_id in (select scheme_id from public.sibling_discount_scheme_rank where tenant_id = v_tenant_id)
         and status in ('pending', 'approved')
       limit 1;

      if found then
        if v_existing_award.scheme_id <> v_scheme_id or v_scheme_id is null then
          -- Existing award's scheme no longer matches this rank (or this
          -- rank no longer qualifies at all) — the rank shifted. Flagged
          -- for a human, not silently changed.
          v_needs_review := v_needs_review || jsonb_build_object(
            'enrolment_id', v_member.enrolment_id, 'current_rank', v_rank, 'existing_award_id', v_existing_award.id
          );
        end if;
        -- Correct scheme already pending/approved: nothing to do.
        continue;
      end if;

      if v_scheme_id is null then
        continue;
      end if;

      perform public.request_concession_award(
        v_member.enrolment_id, v_scheme_id,
        (select value from public.concession_scheme where id = v_scheme_id),
        current_date, (current_date + interval '1 year')::date
      );
      v_proposals := v_proposals + 1;
    end loop;
  end loop;

  return jsonb_build_object(
    'groups_found', v_groups_found, 'proposals_created', v_proposals, 'needs_review', v_needs_review
  );
end;
$$;

create or replace function public.dispatch_absentee_notifications(p_campus_id uuid, p_date date default current_date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row          record;
  v_queued       int := 0;
  v_skipped      int := 0;
  v_body_len     int;
  v_segment_len  int;
  v_cost         int;
  v_spent_today  int;
  v_cap          int;
  v_name         text;
  c_paisa_per_segment constant int := 100;
begin
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_tenant_id() is not null and not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Serializes the whole read-spend/check-cap/insert sequence per
  -- campus+date, the same class of race FR-B05's fn_queue_appointment_
  -- reminders() already locks against.
  perform pg_advisory_xact_lock(hashtextextended('absentee-sms-cap:' || p_campus_id::text || ':' || p_date::text, 0));

  select daily_sms_cap_paisa into v_cap from public.campus where id = p_campus_id;
  select coalesce(sum(cost_paisa), 0) into v_spent_today
    from public.attendance_notification
   where campus_id = p_campus_id and notification_date = p_date;

  for v_row in select * from public.absentees_for_date(p_campus_id, p_date) loop
    -- Already handled by an earlier run today — skip before touching
    -- cost/cap accounting at all, so a re-run's own already-queued
    -- candidates can never inflate v_spent_today or trip the cap early.
    if exists (
      select 1 from public.attendance_notification
       where enrolment_id = v_row.enrolment_id and notification_date = p_date and channel = 'sms'
    ) then
      continue;
    end if;

    if v_row.guardian_id is null or v_row.phone_e164 is null then
      insert into public.attendance_notification (
        tenant_id, campus_id, enrolment_id, notification_date, channel, template_code, language, recipient_msisdn, status, cost_paisa
      )
      select tenant_id, p_campus_id, v_row.enrolment_id, p_date, 'sms', 'absentee_daily_' || v_row.language::text, v_row.language, null, 'skipped_no_contact', 0
        from public.enrolment where id = v_row.enrolment_id
      on conflict (enrolment_id, notification_date, channel) do nothing;
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_name := case when v_row.language = 'ur' then coalesce(v_row.student_name_ur, v_row.student_name) else v_row.student_name end;
    v_body_len := length(
      case v_row.language
        when 'ur' then v_name || ' (GR ' || v_row.gr_number || ') ' || v_row.section_label || ' ' || p_date::text || ' غیر حاضر'
        else v_name || ' (GR ' || v_row.gr_number || ') was absent from ' || v_row.section_label || ' on ' || p_date::text || '.'
      end
    );
    v_segment_len := case v_row.language when 'ur' then 70 else 160 end;
    v_cost := ceil(v_body_len::numeric / v_segment_len) * c_paisa_per_segment;

    if v_cap is not null and v_spent_today + v_cost > v_cap then
      exit; -- daily budget reached; the rest are picked up by a later re-run
    end if;

    insert into public.attendance_notification (
      tenant_id, campus_id, enrolment_id, notification_date, channel, template_code, language, recipient_msisdn, status, cost_paisa
    )
    select tenant_id, p_campus_id, v_row.enrolment_id, p_date, 'sms', 'absentee_daily_' || v_row.language::text, v_row.language, v_row.phone_e164, 'queued', v_cost
      from public.enrolment where id = v_row.enrolment_id
    on conflict (enrolment_id, notification_date, channel) do nothing;
    v_queued := v_queued + 1;
    v_spent_today := v_spent_today + v_cost;
  end loop;

  return jsonb_build_object(
    'queued', v_queued,
    'skipped_no_contact', v_skipped,
    'sections_not_marked', (select count(*) from public.sections_not_marked(p_campus_id, p_date))
  );
end;
$$;

create or replace function public.fn_preview_checklist(p_campus_id uuid, p_class_level_id uuid, p_board public.board default null)
returns setof public.admission_document_requirement
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_ordinal   smallint;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  select ordinal into v_ordinal from public.class_level where id = p_class_level_id and tenant_id = v_tenant_id;
  if v_ordinal is null then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;

  return query select * from app.fn_active_checklist(p_campus_id, v_ordinal, p_board, current_date);
end;
$$;

create or replace function public.fn_promote_waitlist(p_campus_id uuid, p_session_id uuid, p_class_level_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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

  return app.fn_promote_waitlist_internal(p_campus_id, p_session_id, p_class_level_id);
end;
$$;

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

create or replace function public.mark_staff_attendance_bulk(p_campus_id uuid, p_date date, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row              jsonb;
  v_staff_id         uuid;
  v_status           public.attendance_status;
  v_remarks          text;
  v_existing_source  public.attendance_source;
  v_written_count    int := 0;
  v_locked_staff_ids uuid[] := '{}';
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- A 7-day correction window for HR Manager; Principal/Owner/Super Admin
  -- are not bound by it. Every write either way lands in audit_log via
  -- the trigger above.
  if app.auth_role() = 'hr_manager' and p_date < current_date - 7 then
    raise exception 'CORRECTION_WINDOW_EXPIRED' using errcode = '23514';
  end if;

  -- One transaction, one RPC call for the whole campus — never one row
  -- per tap, or a flaky mobile connection leaves the register half
  -- written.
  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    v_staff_id := (v_row ->> 'staff_id')::uuid;
    v_status   := (v_row ->> 'status')::public.attendance_status;
    v_remarks  := v_row ->> 'remarks';

    if not exists (select 1 from public.staff where id = v_staff_id and tenant_id = app.auth_tenant_id()) then
      raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
    end if;

    select source into v_existing_source
      from public.staff_attendance
     where staff_id = v_staff_id and att_date = p_date;

    -- Source precedence: leave > biometric > manual. A clerk cannot mark
    -- an approved-leave teacher absent and trigger a wrong pay deduction
    -- — the row is skipped (not written), not silently overwritten, and
    -- reported back so the sheet UI can show which rows were locked.
    if v_existing_source = 'leave' and v_status not in ('on_leave', 'half_day') then
      v_locked_staff_ids := v_locked_staff_ids || v_staff_id;
      continue;
    end if;

    insert into public.staff_attendance (tenant_id, campus_id, staff_id, att_date, status, source, marked_by, remarks)
    values (app.auth_tenant_id(), p_campus_id, v_staff_id, p_date, v_status, 'manual', auth.uid(), v_remarks)
    on conflict (staff_id, att_date) do update
       set status = excluded.status, source = 'manual', marked_by = excluded.marked_by, remarks = excluded.remarks, marked_at = now()
     where public.staff_attendance.source <> 'leave';

    v_written_count := v_written_count + 1;
  end loop;

  return jsonb_build_object('written', v_written_count, 'locked_staff_ids', to_jsonb(v_locked_staff_ids));
end;
$$;

create or replace function public.resolve_attendance_holiday(p_campus_id uuid, p_date date)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select name from public.holiday_calendar
   where tenant_id = app.auth_tenant_id() and (campus_id is null or campus_id = p_campus_id) and holiday_date = p_date
     and (app.auth_tenant_id() is null or app.auth_role() in ('super_admin', 'owner') or p_campus_id = any(app.auth_campus_ids()))
   order by campus_id nulls last
   limit 1;
$$;

create or replace function public.resolve_attendance_policy(p_campus_id uuid, p_session_id uuid, p_as_of timestamptz default clock_timestamp())
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', id, 'mode', mode, 'start_time', start_time, 'late_threshold_minutes', late_threshold_minutes,
    'half_day_cutoff_time', half_day_cutoff_time, 'lock_window_hours', lock_window_hours,
    'min_attendance_pct', min_attendance_pct, 'saturday_working', saturday_working, 'effective_from', effective_from
  )
    from public.attendance_policy
   where tenant_id = app.auth_tenant_id() and campus_id = p_campus_id and session_id = p_session_id
     and effective_from <= p_as_of
     and (app.auth_tenant_id() is null or app.auth_role() in ('super_admin', 'owner') or p_campus_id = any(app.auth_campus_ids()))
   order by effective_from desc
   limit 1;
$$;

create or replace function public.resolve_bell_template(p_campus_id uuid, p_shift public.section_shift, p_date date)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then null
    else coalesce(
      (
        select bell_template_id
          from public.bell_calendar_rule
         where campus_id = p_campus_id
           and shift = p_shift
           and tenant_id = app.auth_tenant_id()
           and (
             (date_from is not null and p_date between date_from and coalesce(date_to, date_from))
             or (weekday is not null and date_from is null and extract(dow from p_date)::smallint = weekday)
           )
         order by precedence desc, (date_from is not null) desc
         limit 1
      ),
      (
        select id from public.bell_template
         where campus_id = p_campus_id and shift = p_shift and tenant_id = app.auth_tenant_id() and is_default
      )
    )
  end;
$$;

create or replace function public.resolve_bell_template_for_weekday(p_campus_id uuid, p_shift public.section_shift, p_weekday smallint)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then null
    else coalesce(
      (
        select bell_template_id
          from public.bell_calendar_rule
         where campus_id = p_campus_id
           and shift = p_shift
           and tenant_id = app.auth_tenant_id()
           and weekday = p_weekday
           and date_from is null
         order by precedence desc
         limit 1
      ),
      (
        select id from public.bell_template
         where campus_id = p_campus_id and shift = p_shift and tenant_id = app.auth_tenant_id() and is_default
      )
    )
  end;
$$;

create or replace function public.resolve_branding(p_campus_id uuid, p_asset_type public.branding_asset_type)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_asset     public.branding_asset%rowtype;
begin
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    return null;
  end if;

  select * into v_asset from public.branding_asset
   where tenant_id = v_tenant_id and campus_id = p_campus_id and asset_type = p_asset_type and is_current;
  if not found then
    select * into v_asset from public.branding_asset
     where tenant_id = v_tenant_id and campus_id is null and asset_type = p_asset_type and is_current;
  end if;
  if not found then
    return null;
  end if;
  return jsonb_build_object('asset_id', v_asset.id, 'storage_path', v_asset.storage_path);
end;
$$;

create or replace function public.resolve_fee_structure(p_campus_id uuid, p_session_id uuid, p_period_start date)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.fee_structure
   where campus_id = p_campus_id and session_id = p_session_id
     and tenant_id = app.auth_tenant_id()
     and status in ('published', 'superseded')
     and effective_from <= p_period_start
     and (app.auth_tenant_id() is null or app.auth_role() in ('super_admin', 'owner') or p_campus_id = any(app.auth_campus_ids()))
   order by effective_from desc, version_no desc
   limit 1;
$$;

create or replace function public.resolve_timetable_version(p_campus_id uuid, p_session_id uuid, p_date date)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.timetable_version
   where campus_id = p_campus_id and session_id = p_session_id and tenant_id = app.auth_tenant_id()
     and status in ('PUBLISHED', 'SUPERSEDED') and validity @> p_date
     and (app.auth_tenant_id() is null or app.auth_role() in ('super_admin', 'owner') or p_campus_id = any(app.auth_campus_ids()))
   limit 1;
$$;

create or replace function public.run_unmarked_attendance_check(p_campus_id uuid, p_date date default current_date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_holiday   text;
  v_row       record;
  v_sections  jsonb := '[]'::jsonb;
begin
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id into v_tenant_id from public.campus where id = p_campus_id;
  if v_tenant_id is null or (app.auth_tenant_id() is not null and v_tenant_id <> app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- AC2: a declared holiday skips the check entirely — no rows logged,
  -- no notification content produced.
  v_holiday := public.resolve_attendance_holiday(p_campus_id, p_date);
  if v_holiday is not null then
    return jsonb_build_object('skipped', true, 'reason', v_holiday, 'sections', '[]'::jsonb);
  end if;

  for v_row in
    select u.* from public.check_unmarked_attendance(p_campus_id, p_date) u
     where not exists (
       select 1 from public.attendance_gap_log g
        where g.section_id = u.section_id and g.attendance_date = p_date
     )
  loop
    insert into public.attendance_gap_log (tenant_id, campus_id, section_id, attendance_date, enrolled_count, marked_count)
    values (v_tenant_id, p_campus_id, v_row.section_id, p_date, v_row.enrolled_count, v_row.marked_count)
    on conflict (section_id, attendance_date) do nothing;

    v_sections := v_sections || jsonb_build_array(jsonb_build_object(
      'section_id', v_row.section_id,
      'section_label', v_row.section_label,
      'class_teacher_name', v_row.class_teacher_name,
      'enrolled_count', v_row.enrolled_count,
      'marked_count', v_row.marked_count,
      'status', case when v_row.marked_count = 0 then 'unmarked' else format('partially marked (%s/%s)', v_row.marked_count, v_row.enrolled_count) end
    ));
  end loop;

  return jsonb_build_object('skipped', false, 'sections', v_sections);
end;
$$;

create or replace function public.set_attendance_policy(
  p_campus_id uuid, p_session_id uuid,
  p_mode text default 'daily', p_start_time time default '08:00', p_late_threshold_minutes int default 15,
  p_half_day_cutoff_time time default null, p_lock_window_hours int default 24,
  p_min_attendance_pct numeric default null, p_saturday_working boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
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

  insert into public.attendance_policy (
    tenant_id, campus_id, session_id, mode, start_time, late_threshold_minutes,
    half_day_cutoff_time, lock_window_hours, min_attendance_pct, saturday_working, updated_by
  ) values (
    v_tenant_id, p_campus_id, p_session_id, p_mode, p_start_time, p_late_threshold_minutes,
    p_half_day_cutoff_time, p_lock_window_hours, p_min_attendance_pct, p_saturday_working, auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.set_attendance_status_weight(
  p_campus_id uuid, p_session_id uuid, p_status public.student_attendance_status, p_weight numeric
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_weight < 0 or p_weight > 1 then
    raise exception 'WEIGHT_OUT_OF_RANGE' using errcode = '23514';
  end if;

  insert into public.attendance_status_weight (tenant_id, campus_id, session_id, status, weight)
  values (app.auth_tenant_id(), p_campus_id, p_session_id, p_status, p_weight)
  on conflict (campus_id, session_id, status) do update set weight = excluded.weight;
end;
$$;

create or replace function public.set_document_requirement(
  p_campus_id uuid, p_min_class_ordinal smallint, p_max_class_ordinal smallint, p_doc_type public.document_type,
  p_is_mandatory boolean default true, p_min_count smallint default 1, p_board public.board default null,
  p_effective_from date default current_date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_min_class_ordinal > p_max_class_ordinal then
    raise exception 'INVALID_ORDINAL_RANGE' using errcode = '23514';
  end if;
  if p_min_count < 1 then
    raise exception 'MIN_COUNT_MUST_BE_POSITIVE' using errcode = '23514';
  end if;

  update public.admission_document_requirement
     set effective_to = p_effective_from
   where tenant_id = v_tenant_id and campus_id = p_campus_id and doc_type = p_doc_type
     and board is not distinct from p_board and effective_to is null and effective_from < p_effective_from;

  insert into public.admission_document_requirement (
    tenant_id, campus_id, min_class_ordinal, max_class_ordinal, board, doc_type, is_mandatory, min_count, effective_from
  ) values (
    v_tenant_id, p_campus_id, p_min_class_ordinal, p_max_class_ordinal, p_board, p_doc_type, p_is_mandatory, p_min_count, p_effective_from
  )
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.set_gr_sequence(
  p_campus_id uuid, p_prefix text, p_next_value bigint, p_pad_width smallint default 6
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select tenant_id into v_tenant_id from public.campus where id = p_campus_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.gr_sequence
     set prefix = p_prefix, next_value = p_next_value, pad_width = p_pad_width
   where campus_id = p_campus_id;
end;
$$;

create or replace function public.set_homework_load_policy(
  p_campus_id uuid, p_session_id uuid, p_max_assignments_per_day int default null, p_max_minutes_per_day int default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_max_assignments_per_day is null and p_max_minutes_per_day is null then
    raise exception 'AT_LEAST_ONE_CAP_REQUIRED' using errcode = '23514';
  end if;

  insert into public.homework_load_policy (tenant_id, campus_id, session_id, max_assignments_per_day, max_minutes_per_day)
  values (app.auth_tenant_id(), p_campus_id, p_session_id, p_max_assignments_per_day, p_max_minutes_per_day)
  on conflict (campus_id, session_id) do update set
    max_assignments_per_day = excluded.max_assignments_per_day,
    max_minutes_per_day = excluded.max_minutes_per_day
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.set_leave_approval_chain_step(
  p_campus_id uuid, p_leave_type_id uuid, p_step_no smallint, p_approver_role public.app_role, p_sla_hours smallint default 24
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.leave_type where id = p_leave_type_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'LEAVE_TYPE_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.leave_approval_chain (tenant_id, campus_id, leave_type_id, step_no, approver_role, sla_hours)
  values (app.auth_tenant_id(), p_campus_id, p_leave_type_id, p_step_no, p_approver_role, p_sla_hours)
  on conflict (campus_id, leave_type_id, step_no) do update set approver_role = excluded.approver_role, sla_hours = excluded.sla_hours
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.suggest_rooms_for_type(p_campus_id uuid, p_preferred_room_type public.room_type_enum)
returns setof public.room
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.room
   where tenant_id = app.auth_tenant_id() and campus_id = p_campus_id and is_active
     and (app.auth_tenant_id() is null or app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
   order by (room_type = p_preferred_room_type) desc, code;
$$;

create or replace function public.working_days_between(p_campus_id uuid, p_from date, p_to date)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then null
    else (
      select count(*)::numeric
        from generate_series(p_from, p_to, interval '1 day') as d(day)
       where extract(dow from d.day) <> 0 -- Sunday is the weekly off day
         and not exists (
           select 1 from public.holiday_calendar h
            where h.holiday_date = d.day::date
              and h.tenant_id = app.auth_tenant_id()
              and (h.campus_id = p_campus_id or h.campus_id is null)
         )
    )
  end;
$$;
