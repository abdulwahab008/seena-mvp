-- Module E (Academic Setup) hardening — 23 confirmed findings from an
-- independent multi-pass adversarial review (4 review dimensions, every
-- finding separately re-verified by a skeptical second pass before being
-- accepted), the same rigor already applied to every other module this
-- session. This is the module with the most gaps found so far: the
-- tenant-isolation hardening migration (20260731040000) covered some but
-- not all of Module E's SECURITY DEFINER functions, and two functions
-- (copy_class_subject_map, set_section_stream/delete_stream,
-- delete_class_level, create_subject, swap_class_level_ordinals) were
-- never touched by it at all.
--
-- The 23 findings collapse into 10 distinct fixes below — several
-- findings independently rediscovered the same underlying bug from
-- different angles (e.g. copy_class_subject_map's missing tenant checks
-- were flagged by the tenant-isolation, business-rules AND ui-contract
-- passes). Each fix section names every finding id it closes.

-- ── 1. copy_class_subject_map(): zero tenant scoping on any of its 4 id
--    params, plus a TOCTOU duplicate-insert race ───────────────────────
--
-- Closes: copy-class-subject-map-no-tenant-scope (tenant-isolation),
-- copy-class-subject-map-no-tenant-scope (business-rules, same bug via a
-- second finder), copy-class-subject-map-no-tenant-check (ui-contract),
-- copy-class-subject-map-duplicate-toctou (concurrency-timestamps).
--
-- Unlike every sibling function in this file, this one had NO tenant
-- check anywhere: no campus_ids scoping, no campus/session/class_level
-- tenant check, and the source SELECT loop read whatever tenant's rows
-- matched the bare ids passed in — then inserted using the SOURCE row's
-- tenant_id/campus_id/session_id (not the caller's), so a caller who
-- supplied another tenant's class_level_id/session_id/campus_id could
-- both read that tenant's curriculum and write a forged row into it.
-- Also replaces the separate EXISTS-then-INSERT with a single atomic
-- INSERT ... ON CONFLICT DO NOTHING (mirroring upsert_class_subject's own
-- conflict target), closing the race where a concurrent copy/upsert could
-- make the bare INSERT throw an unhandled 23505 mid-loop.

create or replace function public.copy_class_subject_map(
  p_from_class_level_id uuid, p_to_class_level_id uuid, p_session_id uuid, p_campus_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_created int := 0;
  v_skipped int := 0;
  v_row     record;
  v_rows    int;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
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
  if not exists (select 1 from public.class_level where id = p_from_class_level_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.class_level where id = p_to_class_level_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;

  for v_row in
    select * from public.class_subject
     where class_level_id = p_from_class_level_id and session_id = p_session_id and campus_id = p_campus_id
       and tenant_id = app.auth_tenant_id()
  loop
    insert into public.class_subject (
      tenant_id, campus_id, session_id, class_level_id, stream_id, subject_id,
      is_compulsory, elective_bucket, choose_n, weekly_periods, max_marks
    ) values (
      app.auth_tenant_id(), p_campus_id, p_session_id, p_to_class_level_id, v_row.stream_id, v_row.subject_id,
      v_row.is_compulsory, v_row.elective_bucket, v_row.choose_n, v_row.weekly_periods, v_row.max_marks
    )
    on conflict (session_id, campus_id, class_level_id, (coalesce(stream_id, '00000000-0000-0000-0000-000000000000'::uuid)), subject_id)
    do nothing;

    get diagnostics v_rows = row_count;
    if v_rows > 0 then
      v_created := v_created + 1;
    else
      v_skipped := v_skipped + 1;
    end if;
  end loop;

  return jsonb_build_object('created', v_created, 'skipped', v_skipped);
end;
$$;

-- ── 2. create_section(): p_session_id and p_class_level_id were never
--    tenant-checked (only p_campus_id was), plus a TOCTOU on the
--    duplicate-name check ───────────────────────────────────────────────
--
-- Closes: create-section-missing-session-classlevel-tenant-check
-- (tenant-isolation), create-section-missing-class-level-session-tenant-
-- check (business-rules), create-section-unchecked-class-level-and-session
-- (ui-contract), create-section-duplicate-name-toctou
-- (concurrency-timestamps).

create or replace function public.create_section(
  p_campus_id         uuid,
  p_session_id        uuid,
  p_class_level_id    uuid,
  p_name              text,
  p_capacity          int,
  p_medium            public.section_medium default 'ENGLISH',
  p_shift             public.section_shift default 'MORNING',
  p_gender_restriction public.gender default null
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
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.class_level where id = p_class_level_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_capacity < 1 or p_capacity > 200 then
    raise exception 'CAPACITY_OUT_OF_RANGE' using errcode = '23514';
  end if;

  if exists (
    select 1 from public.class_section
     where campus_id = p_campus_id and session_id = p_session_id
       and class_level_id = p_class_level_id and name = p_name
  ) then
    raise exception 'SECTION_NAME_DUPLICATE' using errcode = '23505';
  end if;

  begin
    insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity, medium, shift, gender_restriction)
    values (app.auth_tenant_id(), p_campus_id, p_session_id, p_class_level_id, p_name, p_capacity, p_medium, p_shift, p_gender_restriction)
    returning id into v_id;
  exception
    when unique_violation then
      -- A genuinely concurrent call won the race and created the same
      -- (campus, session, class, name) row between our pre-check and this
      -- insert — same outcome as the pre-check path: the function's own
      -- named error, not a raw constraint-violation message.
      raise exception 'SECTION_NAME_DUPLICATE' using errcode = '23505';
  end;

  return v_id;
end;
$$;

-- ── 3. upsert_class_subject(): p_session_id, p_class_level_id,
--    p_subject_id and p_stream_id were never tenant-checked (only
--    p_campus_id was); also adds the missing WEEKLY_PERIODS_OUT_OF_RANGE
--    upper-bound check (previously only the CHECK constraint caught it,
--    with a raw message actions.ts can't recognize) ─────────────────────
--
-- Closes: upsert-class-subject-missing-fk-tenant-checks
-- (tenant-isolation), upsert-class-subject-missing-fk-tenant-checks
-- (business-rules), upsert-class-subject-unchecked-fk-ids (ui-contract),
-- and the WEEKLY_PERIODS_OUT_OF_RANGE half of
-- curriculum-mapper-silent-required-field-failure-and-range-mismatch.

create or replace function public.upsert_class_subject(
  p_campus_id       uuid,
  p_session_id      uuid,
  p_class_level_id  uuid,
  p_subject_id      uuid,
  p_weekly_periods  smallint,
  p_stream_id       uuid default null,
  p_is_compulsory   boolean default true,
  p_elective_bucket smallint default null,
  p_choose_n        smallint default null,
  p_max_marks       int default null
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
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.class_level where id = p_class_level_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.subject where id = p_subject_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_stream_id is not null and not exists (select 1 from public.stream where id = p_stream_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'STREAM_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_weekly_periods is null or p_weekly_periods < 1 then
    raise exception 'WEEKLY_PERIODS_REQUIRED' using errcode = '23514';
  end if;
  if p_weekly_periods > 12 then
    raise exception 'WEEKLY_PERIODS_OUT_OF_RANGE' using errcode = '23514';
  end if;
  if not p_is_compulsory and p_elective_bucket is null then
    raise exception 'ELECTIVE_BUCKET_REQUIRED' using errcode = '23514';
  end if;

  insert into public.class_subject (
    tenant_id, campus_id, session_id, class_level_id, stream_id, subject_id,
    is_compulsory, elective_bucket, choose_n, weekly_periods, max_marks
  ) values (
    app.auth_tenant_id(), p_campus_id, p_session_id, p_class_level_id, p_stream_id, p_subject_id,
    p_is_compulsory, p_elective_bucket, p_choose_n, p_weekly_periods, p_max_marks
  )
  on conflict (session_id, campus_id, class_level_id, (coalesce(stream_id, '00000000-0000-0000-0000-000000000000'::uuid)), subject_id)
  do update set
    is_compulsory   = excluded.is_compulsory,
    elective_bucket = excluded.elective_bucket,
    choose_n        = excluded.choose_n,
    weekly_periods  = excluded.weekly_periods,
    max_marks       = excluded.max_marks
  returning id into v_id;

  return v_id;
end;
$$;

-- ── 4/5. assign_class_teacher() / assign_subject_teacher(): p_staff_id
--    (both) and p_subject_id (assign_subject_teacher) were never
--    tenant-checked, only p_section_id was; assign_subject_teacher's
--    role='assistant' path also had no replace-or-reject semantics at
--    all, letting the same staff be inserted as assistant twice ────────
--
-- Closes: assign-teacher-functions-unchecked-staff-and-subject-id
-- (tenant-isolation), assign-teacher-missing-staff-and-subject-tenant-
-- checks (business-rules), teacher-allocation-unchecked-staff-and-
-- subject-ids (ui-contract), assistant-subject-teacher-duplicate-on-
-- resubmit (business-rules).
--
-- The new partial exclusion constraint mirrors ex_subject_teacher_no_
-- overlap's own mechanism (DB-level, race-safe — not a check-then-act
-- app check) but is scoped one column narrower (also by staff_id) so two
-- DIFFERENT assistants can still co-teach the same section+subject, only
-- the SAME staff can't hold two overlapping assistant rows.

create or replace function public.assign_class_teacher(p_section_id uuid, p_staff_id uuid, p_effective_from date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_section        public.class_section%rowtype;
  v_id             uuid;
  v_already_class_teacher boolean;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_section from public.class_section where id = p_section_id;
  if not found or v_section.tenant_id <> app.auth_tenant_id() then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.app_user where user_id = p_staff_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  select exists (
    select 1 from public.section_class_teacher sct
     where sct.staff_id = p_staff_id and sct.session_id = v_section.session_id
       and sct.section_id <> p_section_id and sct.effective_to is null
  ) into v_already_class_teacher;

  update public.section_class_teacher
     set effective_to = p_effective_from - 1
   where section_id = p_section_id and effective_to is null and effective_from < p_effective_from;

  insert into public.section_class_teacher (tenant_id, campus_id, session_id, section_id, staff_id, effective_from)
  values (app.auth_tenant_id(), v_section.campus_id, v_section.session_id, p_section_id, p_staff_id, p_effective_from)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'warning', case when v_already_class_teacher then 'DUAL_CLASS_TEACHER' else null end);
end;
$$;

alter table public.section_subject_teacher
  add constraint ex_subject_teacher_assistant_no_overlap
  exclude using gist (section_id with =, subject_id with =, staff_id with =, validity with &&) where (role = 'assistant');

create or replace function public.assign_subject_teacher(
  p_section_id uuid, p_subject_id uuid, p_staff_id uuid, p_effective_from date, p_role public.allocation_role default 'primary'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_section public.class_section%rowtype;
  v_id      uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_section from public.class_section where id = p_section_id;
  if not found or v_section.tenant_id <> app.auth_tenant_id() then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.subject where id = p_subject_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.app_user where user_id = p_staff_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_role = 'primary' then
    update public.section_subject_teacher
       set effective_to = p_effective_from - 1
     where section_id = p_section_id and subject_id = p_subject_id and role = 'primary'
       and effective_to is null and effective_from < p_effective_from;
  else
    -- Mirrors the primary branch's auto-close, scoped additionally to the
    -- SAME staff, so reassigning one assistant's range never touches a
    -- different, legitimately co-teaching assistant's row.
    update public.section_subject_teacher
       set effective_to = p_effective_from - 1
     where section_id = p_section_id and subject_id = p_subject_id and role = 'assistant' and staff_id = p_staff_id
       and effective_to is null and effective_from < p_effective_from;
  end if;

  begin
    insert into public.section_subject_teacher (tenant_id, campus_id, session_id, section_id, subject_id, staff_id, role, effective_from)
    values (app.auth_tenant_id(), v_section.campus_id, v_section.session_id, p_section_id, p_subject_id, p_staff_id, p_role, p_effective_from)
    returning id into v_id;
  exception
    when exclusion_violation then
      raise exception 'SUBJECT_TEACHER_ALREADY_ACTIVE' using errcode = '23505';
  end;

  return v_id;
end;
$$;

-- ── 6. set_section_stream(): p_stream_id was never tenant-checked (only
--    p_section_id was) ───────────────────────────────────────────────────
--
-- Closes: set-section-stream-unchecked-stream-id (tenant-isolation),
-- set-section-stream-missing-stream-tenant-check (business-rules, half —
-- the delete_stream half is fix #7 below).

create or replace function public.set_section_stream(p_section_id uuid, p_stream_id uuid)
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

  select tenant_id into v_tenant_id from public.class_section where id = p_section_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_stream_id is not null and not exists (select 1 from public.stream where id = p_stream_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'STREAM_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.class_section set stream_id = p_stream_id where id = p_section_id;
end;
$$;

-- ── 7. delete_stream(): the "in use" check queried class_section with no
--    tenant_id filter, so another tenant's dangling reference (created via
--    fix #6's now-closed hole) could permanently block the owning tenant
--    from deleting their own, genuinely-unused stream ─────────────────────
--
-- Closes: set-section-stream-missing-stream-tenant-check (business-rules,
-- the delete_stream half).
--
-- The tenant-scoped check alone isn't the whole fix: class_section.
-- stream_id has a real FK to stream(id) with no ON DELETE clause, so if a
-- FOREIGN tenant's row still references this stream (only reachable via
-- legacy data pre-dating fix #6, direct DB access, or a future bug
-- elsewhere — the app layer can no longer create one), the DELETE below
-- would still fail, just with a raw, unhandled foreign_key_violation
-- instead of the function's own named error. Caught and re-raised as the
-- same STREAM_IN_USE the caller already knows how to handle.

create or replace function public.delete_stream(p_id uuid)
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

  select tenant_id into v_tenant_id from public.stream where id = p_id;
  if v_tenant_id is null then
    raise exception 'STREAM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_tenant_id <> app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if exists (select 1 from public.class_section where stream_id = p_id and tenant_id = v_tenant_id) then
    raise exception 'STREAM_IN_USE' using errcode = '23503';
  end if;

  begin
    delete from public.stream where id = p_id;
  exception
    when foreign_key_violation then
      raise exception 'STREAM_IN_USE' using errcode = '23503';
  end;
end;
$$;

-- ── 8. delete_class_level(): same unfiltered "in use" check, same
--    cross-tenant denial-of-service shape as fix #7, same FK-violation
--    leak once the check itself is tenant-scoped ──────────────────────────
--
-- Closes: delete-class-level-in-use-check-unfiltered-by-tenant
-- (business-rules).

create or replace function public.delete_class_level(p_id uuid)
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

  select tenant_id into v_tenant_id from public.class_level where id = p_id;
  if v_tenant_id is null then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_tenant_id <> app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if exists (select 1 from public.class_section where class_level_id = p_id and tenant_id = v_tenant_id) then
    raise exception 'CLASS_LEVEL_IN_USE' using errcode = '23503';
  end if;

  begin
    delete from public.class_level where id = p_id;
  exception
    when foreign_key_violation then
      raise exception 'CLASS_LEVEL_IN_USE' using errcode = '23503';
  end;
end;
$$;

-- ── 9. create_subject(): p_alternate_of_subject_id was never
--    tenant-checked ───────────────────────────────────────────────────────
--
-- Closes: create-subject-unchecked-alternate-of-subject-id
-- (tenant-isolation), create-subject-unchecked-alternate-of (ui-contract).

create or replace function public.create_subject(
  p_code                    text,
  p_name_en                 text,
  p_name_ur                 text,
  p_subject_type            public.subject_type default 'CORE',
  p_is_examinable           boolean default true,
  p_default_max_marks       int default null,
  p_alternate_of_subject_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_name_ur is null or btrim(p_name_ur) = '' then
    raise exception 'URDU_NAME_REQUIRED' using errcode = '23514';
  end if;
  if p_alternate_of_subject_id is not null
     and not exists (select 1 from public.subject where id = p_alternate_of_subject_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'ALTERNATE_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.subject (
    tenant_id, code, name_en, name_ur, subject_type, is_examinable, default_max_marks, alternate_of_subject_id
  ) values (
    app.auth_tenant_id(), p_code, p_name_en, p_name_ur, p_subject_type, p_is_examinable, p_default_max_marks, p_alternate_of_subject_id
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- ── 10. swap_class_level_ordinals(): plain unlocked SELECTs followed by
--    two blind UPDATEs is a check-then-act race — two overlapping
--    concurrent swaps (e.g. swap(A,B) and swap(B,C)) can both read B's
--    ordinal before either writes, corrupting the result and surfacing a
--    raw unique-constraint-violation at commit instead of a clean error ──
--
-- Closes: class-level-ordinal-swap-toctou (concurrency-timestamps).
--
-- Fixed by taking row locks (SELECT ... FOR UPDATE) before reading,
-- ordered by id (not by parameter position) so two swaps sharing a row
-- can never deadlock against each other — the second call now blocks
-- until the first commits, then reads its fresh, already-updated
-- ordinal, instead of a stale pre-commit value.

create or replace function public.swap_class_level_ordinals(p_id_a uuid, p_id_b uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_a uuid;
  v_tenant_b uuid;
  v_ord_a    smallint;
  v_ord_b    smallint;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_id_a < p_id_b then
    select tenant_id, ordinal into v_tenant_a, v_ord_a from public.class_level where id = p_id_a for update;
    select tenant_id, ordinal into v_tenant_b, v_ord_b from public.class_level where id = p_id_b for update;
  else
    select tenant_id, ordinal into v_tenant_b, v_ord_b from public.class_level where id = p_id_b for update;
    select tenant_id, ordinal into v_tenant_a, v_ord_a from public.class_level where id = p_id_a for update;
  end if;

  if v_tenant_a is null or v_tenant_b is null or v_tenant_a <> v_tenant_b then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_tenant_a <> app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  set constraints public.uq_class_level_tenant_ordinal deferred;
  update public.class_level set ordinal = v_ord_b where id = p_id_a;
  update public.class_level set ordinal = v_ord_a where id = p_id_b;
end;
$$;
