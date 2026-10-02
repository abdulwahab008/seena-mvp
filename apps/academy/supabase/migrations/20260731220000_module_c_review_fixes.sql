-- Module C hardening — four bugs found by an independent second-pass
-- review of the students/enrolment/guardians module (the direct upstream
-- of Module K: fee_plan, concession_award, fee_ledger, fee_challan all
-- key off enrolment_id/student_id/family_group_id), none caught by this
-- module's own pgTAP suite. Three are cross-tenant writes reachable
-- directly via supabase.rpc(), not gated by any UI.

-- ── 1. link_family_group()/fn_merge_family_groups() never tenant-checked
--    the student/group rows they write ─────────────────────────────────
--
-- link_family_group()'s reuse-lookup and its final UPDATE both matched
-- on `id = any(p_student_ids)` with no tenant filter — a caller could
-- pass a foreign tenant's student id, pick up that tenant's real
-- family_group_id, and repoint every id in p_student_ids (including
-- their own real students) onto it: a group their own tenant's RLS
-- (family_group_tenant_read) can't even see afterwards, and one that
-- now silently mixes two schools' siblings for FR-K07's discount scan.
-- fn_merge_family_groups()'s UPDATE had the same gap — its own very
-- next line (the DELETE) already filtered by tenant_id, showing the
-- idiom was known and just missed on the UPDATE.

create or replace function public.link_family_group(p_student_ids uuid[], p_father_cnic text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if exists (
    select 1 from unnest(p_student_ids) as sid
     where not exists (select 1 from public.student where id = sid and tenant_id = app.auth_tenant_id())
  ) then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Reuse an existing group if any of the given students already belongs
  -- to one, rather than always minting a fresh one.
  select family_group_id into v_group_id
    from public.student
   where id = any(p_student_ids) and tenant_id = app.auth_tenant_id() and family_group_id is not null
   limit 1;

  if v_group_id is null then
    insert into public.family_group (tenant_id, father_cnic)
    values (app.auth_tenant_id(), case when p_father_cnic is not null then app.fn_normalize_pk_id(p_father_cnic) end)
    returning id into v_group_id;
  end if;

  update public.student set family_group_id = v_group_id where id = any(p_student_ids) and tenant_id = app.auth_tenant_id();

  return v_group_id;
end;
$$;

create or replace function public.fn_merge_family_groups(p_keep_id uuid, p_merge_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.family_group where id = p_keep_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'FAMILY_GROUP_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.family_group where id = p_merge_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'FAMILY_GROUP_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- A single nullable FK on student means membership of two groups at once
  -- is structurally impossible — the merge is just a bulk repoint.
  update public.student set family_group_id = p_keep_id where family_group_id = p_merge_id and tenant_id = app.auth_tenant_id();
  delete from public.family_group where id = p_merge_id and tenant_id = app.auth_tenant_id();
end;
$$;

-- ── 2. create_student() never tenant-checked p_campus_id ───────────────
--
-- p_campus_id flowed straight into app.fn_allocate_gr_number(), which
-- itself has no tenant check (it's revoked from authenticated — every
-- caller was assumed to have already validated the campus). A caller
-- could supply a foreign tenant's campus id and burn/advance that
-- tenant's real gr_sequence, insert a dangling gr_ledger row under their
-- campus, and create a student row that (tenant_id = caller,
-- campus_id = foreign) is invisible to both tenants' own
-- student_campus_scope RLS policy forever. set_gr_sequence(), right
-- above this function in the same file, already shows the correct
-- pattern — create_student() just never applied it.

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

-- ── 3. fn_assign_section() never tenant-checked p_section_id ───────────
--
-- The enrolment lookup was tenant-checked, but the target section
-- wasn't: a caller could move their own enrolment onto a foreign
-- tenant's class_section id, which then makes trg_enrolment_capacity_check
-- count that phantom row against the foreign tenant's real seat capacity,
-- and leaves the enrolment's own campus_id/session_id pointing nowhere
-- near its new section's actual campus/session.

create or replace function public.fn_assign_section(
  p_enrolment_id uuid, p_section_id uuid, p_from_date date default current_date, p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid;
  v_old_section_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id, section_id into v_tenant_id, v_old_section_id from public.enrolment where id = p_enrolment_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.class_section where id = p_section_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- End-dated, not overwritten: a September attendance sheet must still
  -- resolve the section the student was actually in on that date.
  update public.section_membership_history
     set to_date = p_from_date - 1
   where enrolment_id = p_enrolment_id and section_id = v_old_section_id and to_date is null;

  update public.enrolment set section_id = p_section_id, override_reason = p_reason where id = p_enrolment_id;

  insert into public.section_membership_history (enrolment_id, section_id, from_date, moved_by, reason)
  values (p_enrolment_id, p_section_id, p_from_date, auth.uid(), p_reason);
end;
$$;

-- ── 4. fn_assign_next_roll_no() had no lock, unlike every other
--    counter/capacity function in this module ──────────────────────────
--
-- `select coalesce(max(roll_no),0)+1` was a bare read-then-write. Two
-- concurrent calls for two different enrolments in the same section can
-- both read the same max and both attempt the same roll_no —
-- uq_roll_no prevents silent corruption, but turns one of the two
-- legitimate concurrent enrolments into an unique-violation error
-- instead of a success. tg_enrolment_capacity_check (enrolment.sql) and
-- app.fn_allocate_gr_number (students.sql, `for update`) both already
-- serialise the equivalent race in this same module — this function
-- just missed the pattern.

create or replace function public.fn_assign_next_roll_no(p_enrolment_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid;
  v_section_id uuid;
  v_session_id uuid;
  v_class_level_id uuid;
  v_next       int;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'class_teacher', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id, section_id, session_id, class_level_id
    into v_tenant_id, v_section_id, v_session_id, v_class_level_id
    from public.enrolment where id = p_enrolment_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('roll:' || v_section_id::text || ':' || v_session_id::text, 0));

  select coalesce(max(roll_no), 0) + 1 into v_next
    from public.enrolment
   where section_id = v_section_id and session_id = v_session_id and status = 'active';

  update public.enrolment set roll_no = v_next where id = p_enrolment_id;

  return v_next;
end;
$$;
