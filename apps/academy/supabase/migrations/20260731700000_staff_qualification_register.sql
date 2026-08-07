-- FR-D02: qualification and certification register.
--
-- staff_qualification.staff_id references app_user(user_id), matching
-- section_subject_teacher's own convention (not staff.id, which a
-- different earlier FR — teacher_subject_competency — used) since AC4
-- below has to join straight into section_subject_teacher.
--
-- staff_document here is a deliberately MINIMAL stand-in for FR-D05's
-- own future "private staff document vault" (storage bucket, signed-URL
-- Edge Function, document_type/expiry tracking — none of that is FR-D02's
-- job). It exists only so staff_qualification.document_id has a real FK
-- target and AC3's "delete the linked document, verification reverts to
-- pending" has something real to delete. FR-D05, when built, should
-- ALTER this table rather than replace it.
--
-- AC4's "non-blocking qualification warning" mirrors the same pattern
-- already used for FR-F06's timetable_room_capacity_warning: a small,
-- queryable table populated by the write path, never a blocking check.

create type public.qualification_level as enum (
  'matric', 'intermediate', 'diploma', 'certification', 'bachelor', 'master', 'mphil', 'phd'
);

create type public.qualification_verification_status as enum ('pending', 'verified', 'rejected');

create table public.staff_document (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  staff_id     uuid not null references public.app_user(user_id),
  label        text not null,
  storage_path text,
  uploaded_by  uuid references public.app_user(user_id),
  uploaded_at  timestamptz not null default clock_timestamp()
);

create index idx_staff_document_staff on public.staff_document (staff_id);

create trigger staff_document_audit after insert or update or delete on public.staff_document
  for each row execute function app.tg_audit_row();

alter table public.staff_document enable row level security;

create policy staff_document_read on public.staff_document
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager') or staff_id = auth.uid())
  );

create table public.staff_qualification (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  staff_id            uuid not null references public.app_user(user_id),
  level               public.qualification_level not null,
  discipline          text not null,
  institution         text not null,
  -- Year of completion only, deliberately — a full award date is often
  -- the one field a teacher genuinely cannot supply, and requiring it
  -- just gets every row entered as 1 January.
  year_completed      smallint not null,
  verification_status public.qualification_verification_status not null default 'pending',
  document_id         uuid references public.staff_document(id) on delete set null,
  verified_by         uuid references public.app_user(user_id),
  verified_at         timestamptz,
  created_at          timestamptz not null default now(),
  constraint chk_qualification_year_reasonable check (year_completed between 1960 and extract(year from current_date)::smallint)
);

create index idx_staff_qualification_staff on public.staff_qualification (staff_id);
create index idx_staff_qualification_discipline on public.staff_qualification (discipline);

create trigger staff_qualification_audit after insert or update or delete on public.staff_qualification
  for each row execute function app.tg_audit_row();

alter table public.staff_qualification enable row level security;

create policy qualification_self_read on public.staff_qualification
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() and staff_id = auth.uid());

create policy qualification_hr_read on public.staff_qualification
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager'));

-- AC1: highest_level ranks the qualification ladder — the array position
-- of `level` in this fixed, low-to-high list is its rank.
create or replace function public.staff_highest_qualification(p_staff_id uuid)
returns public.qualification_level
language sql
stable
security definer
set search_path = ''
as $$
  select level from public.staff_qualification
   where staff_id = p_staff_id and tenant_id = app.auth_tenant_id()
   order by array_position(
     array['matric', 'intermediate', 'diploma', 'certification', 'bachelor', 'master', 'mphil', 'phd']::public.qualification_level[],
     level
   ) desc
   limit 1;
$$;

revoke execute on function public.staff_highest_qualification(uuid) from public, anon;
grant execute on function public.staff_highest_qualification(uuid) to authenticated;

-- A teacher can record their own qualifications (always landing
-- 'pending' — see verify_staff_qualification() for the only way that
-- ever changes); HR-tier roles can record on behalf of anyone in tenant.
create or replace function public.add_staff_qualification(
  p_staff_id uuid, p_level public.qualification_level, p_discipline text, p_institution text,
  p_year_completed smallint, p_document_id uuid default null
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
  if not exists (select 1 from public.app_user where user_id = p_staff_id and tenant_id = v_tenant_id) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') and auth.uid() <> p_staff_id then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.staff_qualification (tenant_id, staff_id, level, discipline, institution, year_completed, document_id)
  values (v_tenant_id, p_staff_id, p_level, p_discipline, p_institution, p_year_completed, p_document_id)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.add_staff_qualification(uuid, public.qualification_level, text, text, smallint, uuid) from public, anon;
grant execute on function public.add_staff_qualification(uuid, public.qualification_level, text, text, smallint, uuid) to authenticated;

-- AC2: only an HR-tier role can decide verification, and never for their
-- own row — the audit trail this produces is app.tg_audit_row()'s own
-- generic UPDATE capture on staff_qualification, not a bespoke insert.
create or replace function public.verify_staff_qualification(p_qualification_id uuid, p_status public.qualification_verification_status)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_qual      public.staff_qualification%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_status not in ('verified', 'rejected') then
    raise exception 'INVALID_STATUS' using errcode = '23514';
  end if;

  select * into v_qual from public.staff_qualification where id = p_qualification_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'QUALIFICATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_qual.staff_id = auth.uid() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.staff_qualification
     set verification_status = p_status, verified_by = auth.uid(), verified_at = clock_timestamp()
   where id = p_qualification_id;
end;
$$;

revoke execute on function public.verify_staff_qualification(uuid, public.qualification_verification_status) from public, anon;
grant execute on function public.verify_staff_qualification(uuid, public.qualification_verification_status) to authenticated;

create or replace function public.add_staff_document(p_staff_id uuid, p_label text, p_storage_path text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.app_user where user_id = p_staff_id and tenant_id = v_tenant_id) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.staff_document (tenant_id, staff_id, label, storage_path, uploaded_by)
  values (v_tenant_id, p_staff_id, p_label, p_storage_path, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.add_staff_document(uuid, text, text) from public, anon;
grant execute on function public.add_staff_document(uuid, text, text) to authenticated;

create or replace function public.delete_staff_document(p_document_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.staff_document where id = p_document_id and tenant_id = v_tenant_id) then
    raise exception 'DOCUMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  delete from public.staff_document where id = p_document_id;
end;
$$;

revoke execute on function public.delete_staff_document(uuid) from public, anon;
grant execute on function public.delete_staff_document(uuid) to authenticated;

-- AC3: BEFORE DELETE, not AFTER — the FK's own ON DELETE SET NULL and
-- this trigger would otherwise race over which sees document_id first.
create or replace function app.tg_unverify_on_document_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  update public.staff_qualification
     set verification_status = 'pending', verified_by = null, verified_at = null
   where document_id = old.id and verification_status = 'verified';
  return old;
end;
$$;

create trigger staff_document_bd_unverify before delete on public.staff_document
  for each row execute function app.tg_unverify_on_document_delete();

-- ── AC4: a non-blocking warning when an unverified teacher is assigned ──
--
-- assign_subject_teacher() was already re-declared by FR-E07 (teacher_
-- competency_registry.sql) to return jsonb {id, warning} — a
-- NO_COMPETENCY_ON_RECORD warning when the assignee has no competency
-- row for the subject, never blocking the assignment itself. FR-D02's
-- own AC4 is the same shape of non-blocking check, on a different
-- signal (verified qualifications, not declared competency), so it's
-- added as a second key on that SAME jsonb result rather than a
-- parallel warning table — one write path, two independent flags.
create or replace function public.assign_subject_teacher(
  p_section_id uuid, p_subject_id uuid, p_staff_id uuid, p_effective_from date, p_role public.allocation_role default 'primary'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_section              public.class_section%rowtype;
  v_id                   uuid;
  v_has_competency       boolean;
  v_has_qualification    boolean;
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

  select exists (
    select 1 from public.staff_qualification
     where staff_id = p_staff_id and tenant_id = app.auth_tenant_id() and verification_status = 'verified'
  ) into v_has_qualification;

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

  return jsonb_build_object(
    'id', v_id,
    'warning', case when v_has_competency then null else 'NO_COMPETENCY_ON_RECORD' end,
    'qualification_warning', case when v_has_qualification then null else 'QUALIFICATION_UNVERIFIED' end
  );
end;
$$;

revoke execute on function public.assign_subject_teacher(uuid, uuid, uuid, date, public.allocation_role) from public, anon;
grant execute on function public.assign_subject_teacher(uuid, uuid, uuid, date, public.allocation_role) to authenticated;
