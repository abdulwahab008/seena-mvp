-- Office tools: a shared contact directory (vendors, doctors, the bank
-- branch, transport contractors, board offices) and a team task list.
-- Both are for staff only; parents and students never see them.

create table public.office_contact (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  name         text not null check (length(btrim(name)) between 1 and 150),
  organisation text check (organisation is null or length(organisation) <= 150),
  category     text not null default 'other' check (category in ('vendor', 'medical', 'bank', 'transport', 'government', 'parent_body', 'other')),
  phone        text check (phone is null or length(phone) <= 30),
  email        text check (email is null or length(email) <= 200),
  notes        text check (notes is null or length(notes) <= 500),
  created_by   uuid default auth.uid() references auth.users(id),
  created_at   timestamptz not null default now()
);
create index idx_office_contact_tenant on public.office_contact (tenant_id, category, name);

create table public.team_task (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  title        text not null check (length(btrim(title)) between 1 and 200),
  assigned_to  uuid references public.app_user(user_id),
  due_on       date,
  done_at      timestamptz,
  created_by   uuid default auth.uid() references auth.users(id),
  created_at   timestamptz not null default now()
);
create index idx_team_task_open on public.team_task (tenant_id, due_on) where done_at is null;
create index idx_team_task_assignee on public.team_task (assigned_to) where done_at is null;

alter table public.office_contact enable row level security;
alter table public.team_task enable row level security;
create policy office_contact_read on public.office_contact for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none'));
create policy team_task_read on public.team_task for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none'));
select app.fn_block_portal_roles('public.office_contact');
select app.fn_block_portal_roles('public.team_task');

create or replace function app.fn_assert_staff()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is null or app.auth_role() in ('parent', 'student', 'none') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function app.fn_assert_staff() from public, anon, authenticated;

create or replace function public.save_office_contact(p_name text, p_organisation text, p_category text, p_phone text, p_email text, p_notes text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_tenant_id() is null or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'admissions_officer', 'receptionist', 'accountant', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.office_contact (tenant_id, name, organisation, category, phone, email, notes)
  values (app.auth_tenant_id(), btrim(p_name), nullif(btrim(coalesce(p_organisation, '')), ''), p_category,
          nullif(btrim(coalesce(p_phone, '')), ''), nullif(btrim(coalesce(p_email, '')), ''), nullif(btrim(coalesce(p_notes, '')), ''))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.save_office_contact(text, text, text, text, text, text) from public, anon;
grant execute on function public.save_office_contact(text, text, text, text, text, text) to authenticated;

create or replace function public.add_team_task(p_title text, p_assigned_to uuid default null, p_due_on date default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.fn_assert_staff();
  if p_assigned_to is not null and not exists (select 1 from public.app_user where user_id = p_assigned_to and tenant_id = app.auth_tenant_id()) then
    raise exception 'USER_NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into public.team_task (tenant_id, title, assigned_to, due_on)
  values (app.auth_tenant_id(), btrim(p_title), p_assigned_to, p_due_on)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.add_team_task(text, uuid, date) from public, anon;
grant execute on function public.add_team_task(text, uuid, date) to authenticated;

-- The person it is assigned to, whoever added it, or leadership can tick it off.
create or replace function public.complete_team_task(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.team_task%rowtype;
begin
  perform app.fn_assert_staff();
  select * into t from public.team_task where id = p_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'TASK_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not (t.assigned_to = auth.uid() or t.created_by = auth.uid() or app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal')) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.team_task set done_at = now() where id = p_id and done_at is null;
end;
$$;
revoke execute on function public.complete_team_task(uuid) from public, anon;
grant execute on function public.complete_team_task(uuid) to authenticated;
