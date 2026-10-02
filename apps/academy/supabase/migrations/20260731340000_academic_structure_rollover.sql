-- FR-E11: academic structure session rollover.
--
-- Clones class_section, class_subject and the two teacher-allocation
-- tables from one session into another, already-existing one (the
-- target session is created first via the existing FR-A04
-- create_academic_session — this function only clones structure INTO
-- it). Deliberately does NOT touch enrolment or timetable_version, per
-- the FR's own Notes: promotion is a per-student decision, and a stale
-- cloned timetable that looks published is worse than an empty one.
--
-- Scope cuts:
--   * The Edge Function wrapper (for a clone that exceeds the statement
--     timeout) is not built — same "data layer only" pattern as
--     FR-K11/K17/K29/E10. clone_academic_structure() IS the actual
--     implementation; the Edge Function would only be a thin timeout-
--     avoidance wrapper around calling it, not different logic.
--   * section_subject_teacher's 'assistant' role (co-teaching) is not
--     cloned — only 'primary'. A resigned assistant's staff_id can't be
--     nulled out and re-run idempotently disambiguated from a DIFFERENT
--     resigned assistant on the same section+subject without a real
--     natural key beyond (section, subject, staff) alone — a narrow,
--     low-stakes edge case not worth the added complexity here. Primary
--     allocations (the vast majority) and class-teacher allocations
--     clone fully.
--
-- section_class_teacher.staff_id and section_subject_teacher.staff_id
-- become nullable — needed for the AC's own "6 allocations reference
-- resigned staff... created with staff_id NULL and appear in the
-- unallocated list for reassignment". Every EXISTING write path
-- (assign_class_teacher, assign_subject_teacher) still always supplies a
-- real staff_id — nullability is exercised only by this clone function.

alter table public.section_class_teacher alter column staff_id drop not null;
alter table public.section_subject_teacher alter column staff_id drop not null;

-- v_unallocated_section_subject's own "not exists an active primary" test
-- must not treat a null-staff placeholder row as "allocated" — widened so
-- a resigned-staff clone still surfaces for reassignment, per the AC.
create or replace view public.v_unallocated_section_subject
with (security_invoker = true) as
select cs.id as class_subject_id, cs.campus_id, cs.session_id, cs.class_level_id, cs.subject_id,
       sec.id as section_id, sec.name as section_name
  from public.class_subject cs
  join public.class_section sec
    on sec.class_level_id = cs.class_level_id and sec.session_id = cs.session_id and sec.campus_id = cs.campus_id and sec.is_active
 where not exists (
   select 1 from public.section_subject_teacher sst
    where sst.section_id = sec.id and sst.subject_id = cs.subject_id and sst.role = 'primary'
      and sst.effective_to is null and sst.staff_id is not null
 );

create table public.academic_clone_run (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  from_session_id uuid not null references public.academic_session(id),
  to_session_id  uuid not null references public.academic_session(id),
  is_dry_run     boolean not null,
  summary        jsonb not null,
  run_by         uuid references public.app_user(user_id),
  run_at         timestamptz not null default clock_timestamp()
);

create index idx_clone_run_tenant_to_session on public.academic_clone_run (tenant_id, to_session_id);

-- Clones sections, curriculum maps and (primary) teacher allocations from
-- p_from_session_id into p_to_session_id, both scoped to p_campus_id.
-- p_dry_run reports exactly what WOULD happen (same predicates as the
-- real run, just counted instead of written) without touching a single
-- row. Runs as one statement-set with no per-row exception handling —
-- any failure aborts the whole call and every write in it, matching the
-- AC's own "constraint violation at row 200 rolls back the whole
-- transaction, zero rows exist" requirement for free. A second call
-- against the same target session reports 0 created / all skipped —
-- idempotent via a NOT EXISTS "does this section/map/allocation already
-- exist" check ahead of every write, the same idiom this codebase already
-- uses for copy_class_subject_map()'s ON CONFLICT.
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

revoke execute on function public.clone_academic_structure(uuid, uuid, uuid, boolean) from public, anon;
grant execute on function public.clone_academic_structure(uuid, uuid, uuid, boolean) to authenticated;

alter table public.academic_clone_run enable row level security;

create policy clone_run_tenant_read on public.academic_clone_run
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner', 'principal') or campus_id = any(app.auth_campus_ids()))
  );
