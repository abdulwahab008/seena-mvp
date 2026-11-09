-- Lookup lists for the student record: categories (orphan, staff child,
-- hafiz), regions or areas, parent professions and nearby schools. One table
-- with a kind, because the four lists behave identically; the student and
-- guardian links are written only through the RPCs below, which check the
-- kind, since a plain foreign key cannot.
--
-- Entries are deactivated, never deleted: a student admitted under a
-- category keeps it after the school stops offering it.

create table public.student_lookup (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  kind       text not null check (kind in ('category', 'region', 'profession', 'school')),
  name       text not null check (length(btrim(name)) between 1 and 120),
  area       text check (area is null or length(area) <= 120),
  is_active  boolean not null default true,
  created_by uuid default auth.uid() references auth.users(id),
  created_at timestamptz not null default now()
);
create unique index uq_student_lookup_name on public.student_lookup (tenant_id, kind, lower(name));
create index idx_student_lookup_kind on public.student_lookup (tenant_id, kind, is_active);
create trigger student_lookup_audit after insert or update or delete on public.student_lookup
  for each row execute function app.tg_audit_row();
alter table public.student_lookup enable row level security;
create policy student_lookup_read on public.student_lookup for select to authenticated
  using (tenant_id = app.auth_tenant_id());
select app.fn_block_portal_roles('public.student_lookup');

alter table public.student
  add column category_id        uuid references public.student_lookup(id),
  add column region_id          uuid references public.student_lookup(id),
  add column previous_school_id uuid references public.student_lookup(id);
create index idx_student_category on public.student (category_id) where category_id is not null;
create index idx_student_region on public.student (region_id) where region_id is not null;
create index idx_student_previous_school on public.student (previous_school_id) where previous_school_id is not null;

alter table public.guardian add column profession_id uuid references public.student_lookup(id);
create index idx_guardian_profession on public.guardian (profession_id) where profession_id is not null;

create or replace function public.save_student_lookup(p_kind text, p_name text, p_area text default null, p_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_kind not in ('category', 'region', 'profession', 'school') then
    raise exception 'KIND_INVALID' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'NAME_REQUIRED' using errcode = '22023';
  end if;
  begin
    if p_id is null then
      insert into public.student_lookup (tenant_id, kind, name, area)
      values (app.auth_tenant_id(), p_kind, btrim(p_name), case when p_kind = 'school' then nullif(btrim(coalesce(p_area, '')), '') end)
      returning id into v_id;
    else
      update public.student_lookup
         set name = btrim(p_name), area = case when p_kind = 'school' then nullif(btrim(coalesce(p_area, '')), '') end
       where id = p_id and tenant_id = app.auth_tenant_id() and kind = p_kind
      returning id into v_id;
      if v_id is null then
        raise exception 'LOOKUP_NOT_FOUND' using errcode = 'P0002';
      end if;
    end if;
  exception
    when unique_violation then
      raise exception 'LOOKUP_DUPLICATE' using errcode = '23505';
  end;
  return v_id;
end;
$$;
revoke execute on function public.save_student_lookup(text, text, text, uuid) from public, anon;
grant execute on function public.save_student_lookup(text, text, text, uuid) to authenticated;

create or replace function public.set_student_lookup_active(p_id uuid, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.student_lookup set is_active = p_is_active where id = p_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'LOOKUP_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.set_student_lookup_active(uuid, boolean) from public, anon;
grant execute on function public.set_student_lookup_active(uuid, boolean) to authenticated;

-- Null when p_id is null; raises unless p_id is this tenant's entry of p_kind.
-- An inactive entry is still accepted so an existing link survives an edit.
create or replace function app.fn_assert_student_lookup(p_id uuid, p_kind text)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_id is not null and not exists (
    select 1 from public.student_lookup where id = p_id and tenant_id = app.auth_tenant_id() and kind = p_kind
  ) then
    raise exception 'LOOKUP_NOT_FOUND' using errcode = 'P0002', detail = p_kind;
  end if;
  return p_id;
end;
$$;
revoke execute on function app.fn_assert_student_lookup(uuid, text) from public, anon, authenticated;

create or replace function public.set_student_lookups(p_student_id uuid, p_category_id uuid, p_region_id uuid, p_previous_school_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campus uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select campus_id into v_campus from public.student where id = p_student_id and tenant_id = app.auth_tenant_id() and deleted_at is null;
  if v_campus is null then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_campus = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.student
     set category_id = app.fn_assert_student_lookup(p_category_id, 'category'),
         region_id = app.fn_assert_student_lookup(p_region_id, 'region'),
         previous_school_id = app.fn_assert_student_lookup(p_previous_school_id, 'school')
   where id = p_student_id;
end;
$$;
revoke execute on function public.set_student_lookups(uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.set_student_lookups(uuid, uuid, uuid, uuid) to authenticated;

create or replace function public.set_guardian_profession(p_guardian_id uuid, p_profession_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.guardian g
     where g.id = p_guardian_id and g.tenant_id = app.auth_tenant_id()
       and (app.auth_role() in ('super_admin', 'owner') or exists (
             select 1 from public.student_guardian sg join public.student s on s.id = sg.student_id
              where sg.guardian_id = g.id and s.campus_id = any (app.auth_campus_ids())))
  ) then
    raise exception 'GUARDIAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  update public.guardian set profession_id = app.fn_assert_student_lookup(p_profession_id, 'profession') where id = p_guardian_id;
end;
$$;
revoke execute on function public.set_guardian_profession(uuid, uuid) from public, anon;
grant execute on function public.set_guardian_profession(uuid, uuid) to authenticated;
