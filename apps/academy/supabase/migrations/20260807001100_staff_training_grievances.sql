-- Staff training (CPD) and staff grievances.
--
-- Training: HR records a program (workshop, course, in-service day) with its
-- hours and who attended. CPD hours per staff member per year are the sum of
-- completed attendances, and mandatory programs show who has not done them.
--
-- Grievances: any staff member with a login raises a grievance about pay,
-- workload, conduct, facilities... HR and the Owner see all of them; the person
-- who raised one sees their own and its outcome; nobody else does, so a
-- complaint about one's head of department never reaches that head.

create table public.training_program (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  title        text not null check (length(btrim(title)) between 1 and 200),
  provider     text check (provider is null or length(provider) <= 200),
  held_on      date not null,
  hours        numeric(5,1) not null check (hours > 0 and hours <= 500),
  is_mandatory boolean not null default false,
  created_by   uuid not null default auth.uid() references auth.users(id),
  created_at   timestamptz not null default now()
);
create index idx_training_program_scope on public.training_program (tenant_id, campus_id, held_on desc);

create table public.training_attendance (
  program_id uuid not null references public.training_program(id) on delete cascade,
  staff_id   uuid not null references public.staff(id) on delete cascade,
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  completed  boolean not null default true,
  primary key (program_id, staff_id)
);
create index idx_training_attendance_staff on public.training_attendance (staff_id);
create index idx_training_attendance_scope on public.training_attendance (tenant_id, campus_id);

create table public.staff_grievance (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  raised_by    uuid not null default auth.uid() references auth.users(id),
  category     text not null check (category in ('pay', 'workload', 'conduct', 'harassment', 'facilities', 'policy', 'other')),
  subject      text not null check (length(btrim(subject)) between 1 and 200),
  description  text not null check (length(btrim(description)) between 1 and 4000),
  status       text not null default 'open' check (status in ('open', 'in_review', 'resolved', 'dismissed')),
  resolution   text check (resolution is null or length(resolution) <= 2000),
  handled_by   uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz
);
create index idx_staff_grievance_tenant on public.staff_grievance (tenant_id, status, created_at desc);
create index idx_staff_grievance_raiser on public.staff_grievance (raised_by);

alter table public.training_program enable row level security;
alter table public.training_attendance enable row level security;
alter table public.staff_grievance enable row level security;

create or replace function app.fn_hr_lead()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager');
$$;

create policy training_program_read on public.training_program for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())));
create policy training_attendance_read on public.training_attendance for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and ((app.fn_hr_lead() and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())))
              or exists (select 1 from public.staff s where s.id = staff_id and s.user_id = (select auth.uid()))));
-- Principals are left out on purpose: a grievance may be about them.
create policy staff_grievance_read on public.staff_grievance for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (raised_by = (select auth.uid()) or app.auth_role() in ('super_admin', 'owner', 'hr_manager')));

select app.fn_block_portal_roles('public.training_program');
select app.fn_block_portal_roles('public.training_attendance');
select app.fn_block_portal_roles('public.staff_grievance');

create or replace function public.save_training_program(
  p_campus_id    uuid,
  p_title        text,
  p_provider     text,
  p_held_on      date,
  p_hours        numeric,
  p_is_mandatory boolean,
  p_staff_ids    uuid[]
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
  if v_tenant_id is null or not app.fn_hr_lead() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501', detail = 'campus outside your scope';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if exists (select 1 from unnest(coalesce(p_staff_ids, '{}')) x(id)
              where not exists (select 1 from public.staff s where s.id = x.id and s.tenant_id = v_tenant_id)) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.training_program (tenant_id, campus_id, title, provider, held_on, hours, is_mandatory)
  values (v_tenant_id, p_campus_id, btrim(p_title), nullif(btrim(p_provider), ''), p_held_on, p_hours, coalesce(p_is_mandatory, false))
  returning id into v_id;
  insert into public.training_attendance (program_id, staff_id, tenant_id, campus_id)
  select v_id, x.id, v_tenant_id, p_campus_id from unnest(coalesce(p_staff_ids, '{}')) x(id)
  on conflict do nothing;
  return v_id;
end;
$$;
revoke execute on function public.save_training_program(uuid, text, text, date, numeric, boolean, uuid[]) from public, anon;
grant execute on function public.save_training_program(uuid, text, text, date, numeric, boolean, uuid[]) to authenticated;

-- CPD hours per staff member in a calendar year. Invoker: RLS scopes it.
create or replace function public.staff_cpd_hours(p_campus_id uuid, p_year int)
returns table (staff_id uuid, full_name text, hours numeric, programs int, mandatory_missed int)
language sql
stable
set search_path = ''
as $$
  select s.id, s.full_name,
         coalesce(sum(p.hours) filter (where a.completed), 0),
         count(p.id) filter (where a.completed)::int,
         (select count(*)::int from public.training_program mp
           where mp.campus_id = p_campus_id and mp.is_mandatory and extract(year from mp.held_on) = p_year
             and not exists (select 1 from public.training_attendance ma where ma.program_id = mp.id and ma.staff_id = s.id and ma.completed))
    from public.staff s
    left join public.training_attendance a on a.staff_id = s.id
    left join public.training_program p on p.id = a.program_id and extract(year from p.held_on) = p_year
   where s.campus_id = p_campus_id and s.employment_status = 'active'
   group by s.id, s.full_name
   order by s.full_name;
$$;
revoke execute on function public.staff_cpd_hours(uuid, int) from public, anon;
grant execute on function public.staff_cpd_hours(uuid, int) to authenticated;

create or replace function public.raise_staff_grievance(p_category text, p_subject text, p_description text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_tenant_id() is null or app.auth_role() in ('parent', 'student', 'none') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.staff_grievance (tenant_id, category, subject, description)
  values (app.auth_tenant_id(), p_category, btrim(p_subject), btrim(p_description))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.raise_staff_grievance(text, text, text) from public, anon;
grant execute on function public.raise_staff_grievance(text, text, text) to authenticated;

create or replace function public.handle_staff_grievance(p_id uuid, p_status text, p_resolution text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is null or app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_status not in ('in_review', 'resolved', 'dismissed') then
    raise exception 'STATUS_INVALID' using errcode = '22023';
  end if;
  if p_status in ('resolved', 'dismissed') and nullif(btrim(coalesce(p_resolution, '')), '') is null then
    raise exception 'RESOLUTION_REQUIRED' using errcode = '22023';
  end if;
  update public.staff_grievance
     set status = p_status,
         resolution = coalesce(nullif(btrim(p_resolution), ''), resolution),
         handled_by = auth.uid(),
         resolved_at = case when p_status in ('resolved', 'dismissed') then now() end
   where id = p_id and tenant_id = app.auth_tenant_id() and status not in ('resolved', 'dismissed')
     and raised_by <> (select auth.uid());
  if not found then
    raise exception 'GRIEVANCE_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.handle_staff_grievance(uuid, text, text) from public, anon;
grant execute on function public.handle_staff_grievance(uuid, text, text) to authenticated;
