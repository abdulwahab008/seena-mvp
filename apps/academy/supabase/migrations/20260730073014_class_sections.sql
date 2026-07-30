-- FR-E02 (section creation with capacity). Also resolves the class_level
-- DELETE scope cut noted in the E01 migration ("no DELETE path at all...
-- swap the trigger for a real usage check once E02 ships") — class_section
-- now exists to check against, so class_level gets a real delete_class_level
-- function instead of no delete path at all.

create type public.section_medium as enum ('ENGLISH', 'URDU');
create type public.section_shift as enum ('MORNING', 'AFTERNOON');

create table public.class_section (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  session_id     uuid not null references public.academic_session(id) on delete cascade,
  class_level_id uuid not null references public.class_level(id),
  name           text not null,
  capacity       int not null,
  medium         public.section_medium not null default 'ENGLISH',
  shift          public.section_shift not null default 'MORNING',
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  constraint chk_section_capacity check (capacity between 1 and 200)
);

-- Scoped to campus, not tenant — the same section name legitimately repeats
-- across campuses and across sessions.
create unique index uq_section_campus_session_class_name
  on public.class_section (campus_id, session_id, class_level_id, name);
create index idx_class_section_session_class on public.class_section (session_id, class_level_id);
create index idx_class_section_campus_status on public.class_section (campus_id, is_active);

create trigger class_section_audit after insert or update or delete on public.class_section
  for each row execute function app.tg_audit_row();

create or replace function public.create_section(
  p_campus_id      uuid,
  p_session_id     uuid,
  p_class_level_id uuid,
  p_name           text,
  p_capacity       int,
  p_medium         public.section_medium default 'ENGLISH',
  p_shift          public.section_shift default 'MORNING'
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

  -- Checked explicitly (not just left to the CHECK constraint) so the
  -- caller gets the FR's own named error rather than a raw constraint
  -- violation message.
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

  insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity, medium, shift)
  values (app.auth_tenant_id(), p_campus_id, p_session_id, p_class_level_id, p_name, p_capacity, p_medium, p_shift)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_section(
  uuid, uuid, uuid, text, int, public.section_medium, public.section_shift
) from public, anon;
grant execute on function public.create_section(
  uuid, uuid, uuid, text, int, public.section_medium, public.section_shift
) to authenticated;

alter table public.class_section enable row level security;

create policy class_section_campus_scope on public.class_section
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- ── class_level delete, now that class_section exists to check against ──

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

  if exists (select 1 from public.class_section where class_level_id = p_id) then
    raise exception 'CLASS_LEVEL_IN_USE' using errcode = '23503';
  end if;

  delete from public.class_level where id = p_id;
end;
$$;

revoke execute on function public.delete_class_level(uuid) from public, anon;
grant execute on function public.delete_class_level(uuid) to authenticated;
