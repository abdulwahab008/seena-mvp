-- FR-E07: teacher subject competency registry.
--
-- Design note from the FR's own Notes: no school has clean competency
-- data on day one, and demanding a complete matrix during onboarding
-- produces a matrix everyone ticks for everything. So there are three
-- ways a row gets created — HR declares it, a real allocation infers it,
-- HR later verifies it against a document — and none of them are
-- optional scaffolding; all three are load-bearing per the AC.
--
-- teacher_subject_competency.staff_id references the Module D `staff`
-- table (has employment_status, doj, ...), NOT app_user(user_id) the way
-- section_class_teacher/section_subject_teacher's staff_id does — that
-- earlier choice was itself a scope cut ("no separate Module D staff/HR
-- table yet", per 20260730180117_teacher_allocation.sql's own header),
-- and Module D has since been built with its own identity space. The
-- auto-infer trigger below resolves one to the other via
-- staff.user_id = section_subject_teacher.staff_id — an allocation whose
-- teacher has no linked staff record (see link_staff_user_account) simply
-- can't get an inferred competency row; there is no HR record to attach
-- it to.
--
-- Scope cut: verification evidence storage. document_path is modelled
-- (per the FR's own Supabase Objects) as a plain nullable text column —
-- the actual `staff-documents` private Storage bucket and its upload
-- flow are not built, same "data layer only" pattern as FR-K11/K17/K29.
--
-- Small enabling piece, not its own FR: AC4 needs to know WHEN a staff
-- record was deactivated ("excluded from suggestions dated after
-- 2026-11-30"), and nothing in Module D tracks that yet (FR-D16, staff
-- exit, is still not started). employment_status_changed_at is added
-- here — narrowly, just the timestamp this FR's own AC requires, not a
-- clearance-checklist/exit-flow implementation.

create type public.competency_source_enum as enum ('DECLARED', 'INFERRED', 'VERIFIED');

create table public.teacher_subject_competency (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  staff_id          uuid not null references public.staff(id) on delete cascade,
  subject_id        uuid not null references public.subject(id),
  min_class_ordinal smallint not null,
  max_class_ordinal smallint not null,
  source            public.competency_source_enum not null default 'DECLARED',
  verified_by       uuid references public.app_user(user_id),
  verified_at       timestamptz,
  document_path     text,
  created_at        timestamptz not null default now(),
  constraint chk_competency_ordinal_range check (min_class_ordinal <= max_class_ordinal)
);

create unique index uq_competency_staff_subject on public.teacher_subject_competency (staff_id, subject_id);
create index idx_competency_subject_source on public.teacher_subject_competency (subject_id, source);
create index idx_competency_staff on public.teacher_subject_competency (staff_id);

create trigger competency_audit after insert or update or delete on public.teacher_subject_competency
  for each row execute function app.tg_audit_row();

alter table public.staff add column employment_status_changed_at timestamptz;

create or replace function app.tg_staff_status_changed_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.employment_status is distinct from old.employment_status then
    new.employment_status_changed_at := clock_timestamp();
  end if;
  return new;
end;
$$;

create trigger trg_staff_status_changed_at before update on public.staff
  for each row execute function app.tg_staff_status_changed_at();

-- HR declares (or widens/narrows) a competency range. Never downgrades an
-- already-VERIFIED row's source on conflict — only the ordinal range is
-- ever touched by a re-declare; VERIFIED stays VERIFIED, INFERRED stays
-- INFERRED, until verify_competency() is called.
create or replace function public.declare_competency(
  p_staff_id uuid, p_subject_id uuid, p_min_class_ordinal smallint, p_max_class_ordinal smallint
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
  if not exists (select 1 from public.staff where id = p_staff_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.subject where id = p_subject_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_min_class_ordinal > p_max_class_ordinal then
    raise exception 'INVALID_ORDINAL_RANGE' using errcode = '23514';
  end if;

  insert into public.teacher_subject_competency (tenant_id, staff_id, subject_id, min_class_ordinal, max_class_ordinal, source)
  values (app.auth_tenant_id(), p_staff_id, p_subject_id, p_min_class_ordinal, p_max_class_ordinal, 'DECLARED')
  on conflict (staff_id, subject_id) do update set
    min_class_ordinal = excluded.min_class_ordinal,
    max_class_ordinal = excluded.max_class_ordinal
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.declare_competency(uuid, uuid, smallint, smallint) from public, anon;
grant execute on function public.declare_competency(uuid, uuid, smallint, smallint) to authenticated;

-- AC: HR marks a competency Verified against a degree document —
-- verified_by/verified_at are stamped and it outranks Inferred/Declared
-- in every suggestion. Requires an existing row (declared or inferred);
-- verifying is a confirmation step, not a way to create a fresh row.
create or replace function public.verify_competency(p_staff_id uuid, p_subject_id uuid, p_document_path text default null)
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
  if not exists (select 1 from public.staff where id = p_staff_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.teacher_subject_competency
     set source = 'VERIFIED', verified_by = auth.uid(), verified_at = clock_timestamp(),
         document_path = coalesce(p_document_path, document_path)
   where staff_id = p_staff_id and subject_id = p_subject_id and tenant_id = app.auth_tenant_id()
  returning id into v_id;

  if v_id is null then
    raise exception 'COMPETENCY_NOT_FOUND' using errcode = 'P0002';
  end if;

  return v_id;
end;
$$;

revoke execute on function public.verify_competency(uuid, uuid, text) from public, anon;
grant execute on function public.verify_competency(uuid, uuid, text) to authenticated;

-- AC: allocating a teacher with no competency row on a subject auto-
-- creates one, source='INFERRED', scoped to just the class being taught
-- today — a narrow starting point HR can widen later, not a guess at the
-- teacher's full range. Never overwrites an existing row of any source.
create or replace function app.tg_infer_competency_on_allocation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_staff_id uuid;
  v_ordinal  smallint;
begin
  select id into v_staff_id from public.staff where user_id = new.staff_id and tenant_id = new.tenant_id;
  if v_staff_id is null then
    return new;
  end if;

  select cl.ordinal into v_ordinal
    from public.class_section cs
    join public.class_level cl on cl.id = cs.class_level_id
   where cs.id = new.section_id;

  insert into public.teacher_subject_competency (tenant_id, staff_id, subject_id, min_class_ordinal, max_class_ordinal, source)
  values (new.tenant_id, v_staff_id, new.subject_id, v_ordinal, v_ordinal, 'INFERRED')
  on conflict (staff_id, subject_id) do nothing;

  return new;
end;
$$;

create trigger trg_infer_competency_on_allocation after insert on public.section_subject_teacher
  for each row execute function app.tg_infer_competency_on_allocation();

-- assign_subject_teacher's return type widens uuid -> jsonb (matching
-- assign_class_teacher's own {id, warning} shape) to surface
-- NO_COMPETENCY_ON_RECORD — computed from whether a competency row
-- existed for this staff+subject BEFORE this call, since the trigger
-- above only fires (and only ever fills the gap) AFTER the insert.
drop function if exists public.assign_subject_teacher(uuid, uuid, uuid, date, public.allocation_role);

create or replace function public.assign_subject_teacher(
  p_section_id uuid, p_subject_id uuid, p_staff_id uuid, p_effective_from date, p_role public.allocation_role default 'primary'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_section        public.class_section%rowtype;
  v_id             uuid;
  v_has_competency boolean;
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

  select exists (
    select 1 from public.teacher_subject_competency tc
    join public.staff s on s.id = tc.staff_id
     where s.user_id = p_staff_id and s.tenant_id = app.auth_tenant_id() and tc.subject_id = p_subject_id
  ) into v_has_competency;

  if p_role = 'primary' then
    update public.section_subject_teacher
       set effective_to = p_effective_from - 1
     where section_id = p_section_id and subject_id = p_subject_id and role = 'primary'
       and effective_to is null and effective_from < p_effective_from;
  else
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

  return jsonb_build_object('id', v_id, 'warning', case when v_has_competency then null else 'NO_COMPETENCY_ON_RECORD' end);
end;
$$;

revoke execute on function public.assign_subject_teacher(uuid, uuid, uuid, date, public.allocation_role) from public, anon;
grant execute on function public.assign_subject_teacher(uuid, uuid, uuid, date, public.allocation_role) to authenticated;

-- AC: an out-of-range candidate is returned BELOW every exact-match
-- candidate, flagged, never hidden. Verified outranks Declared outranks
-- Inferred within the same range tier. A staff member currently active,
-- or who was still active as of p_as_of_date, is included; one exited
-- with no recorded status-change date can't be proven to have been
-- active on any past date, so is conservatively excluded outright.
create or replace function public.suggest_substitute_teachers(
  p_subject_id uuid, p_class_level_id uuid, p_as_of_date date default current_date
)
returns table (
  staff_id uuid, full_name text, source public.competency_source_enum,
  min_class_ordinal smallint, max_class_ordinal smallint, out_of_range boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_class_ordinal smallint;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.subject where id = p_subject_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select ordinal into v_class_ordinal from public.class_level where id = p_class_level_id and tenant_id = app.auth_tenant_id();
  if v_class_ordinal is null then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;

  return query
    select
      tc.staff_id, s.full_name, tc.source, tc.min_class_ordinal, tc.max_class_ordinal,
      not (v_class_ordinal between tc.min_class_ordinal and tc.max_class_ordinal) as out_of_range
    from public.teacher_subject_competency tc
    join public.staff s on s.id = tc.staff_id
   where tc.tenant_id = app.auth_tenant_id() and tc.subject_id = p_subject_id
     and (
       s.employment_status = 'active'
       or (s.employment_status_changed_at is not null and p_as_of_date < s.employment_status_changed_at::date)
     )
   order by
     (v_class_ordinal between tc.min_class_ordinal and tc.max_class_ordinal) desc,
     case tc.source when 'VERIFIED' then 2 when 'DECLARED' then 1 else 0 end desc,
     s.full_name;
end;
$$;

revoke execute on function public.suggest_substitute_teachers(uuid, uuid, date) from public, anon;
grant execute on function public.suggest_substitute_teachers(uuid, uuid, date) to authenticated;

alter table public.teacher_subject_competency enable row level security;

create policy competency_tenant_read on public.teacher_subject_competency
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager')
      or staff_id in (select id from public.staff where user_id = auth.uid())
    )
  );
