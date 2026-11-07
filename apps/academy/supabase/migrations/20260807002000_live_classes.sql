-- Live classes: a teacher schedules a session for a section with a meeting
-- link (Zoom, Google Meet, Teams: any https link, typed in; no provider keys).
-- Students join from the student portal; joining is their attendance, one
-- row per student per class.

create table public.live_class (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  section_id   uuid not null references public.class_section(id) on delete cascade,
  subject_id   uuid references public.subject(id),
  title        text not null check (length(btrim(title)) between 1 and 150),
  starts_at    timestamptz not null,
  duration_min smallint not null check (duration_min between 5 and 240),
  meeting_url  text not null check (meeting_url ~ '^https://[^\s]+$' and length(meeting_url) <= 500),
  cancelled_at timestamptz,
  created_by   uuid default auth.uid() references auth.users(id),
  created_at   timestamptz not null default now()
);
create index idx_live_class_section on public.live_class (section_id, starts_at desc);
create index idx_live_class_campus on public.live_class (tenant_id, campus_id, starts_at desc);

create table public.live_class_attendance (
  live_class_id uuid not null references public.live_class(id) on delete cascade,
  student_id    uuid not null references public.student(id) on delete cascade,
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  joined_at     timestamptz not null default now(),
  primary key (live_class_id, student_id)
);
create index idx_live_class_attendance_campus on public.live_class_attendance (tenant_id, campus_id);

alter table public.live_class enable row level security;
alter table public.live_class_attendance enable row level security;
create policy live_class_staff_read on public.live_class for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
create policy live_class_attendance_staff_read on public.live_class_attendance for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
select app.fn_block_portal_roles('public.live_class');
select app.fn_block_portal_roles('public.live_class_attendance');

create or replace function public.schedule_live_class(p_section_id uuid, p_title text, p_starts_at timestamptz, p_duration_min smallint, p_meeting_url text, p_subject_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campus uuid;
  v_id     uuid;
begin
  if app.auth_tenant_id() is null or app.auth_role() in ('parent', 'student', 'none') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select campus_id into v_campus from public.class_section where id = p_section_id and tenant_id = app.auth_tenant_id();
  if v_campus is null then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_campus = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.live_class (tenant_id, campus_id, section_id, subject_id, title, starts_at, duration_min, meeting_url)
  values (app.auth_tenant_id(), v_campus, p_section_id, p_subject_id, btrim(p_title), p_starts_at, p_duration_min, btrim(p_meeting_url))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.schedule_live_class(uuid, text, timestamptz, smallint, text, uuid) from public, anon;
grant execute on function public.schedule_live_class(uuid, text, timestamptz, smallint, text, uuid) to authenticated;

create or replace function public.cancel_live_class(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.live_class%rowtype;
begin
  select * into c from public.live_class where id = p_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CLASS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not (c.created_by = (select auth.uid())
          or (app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'head_of_department')
              and (app.auth_role() in ('super_admin', 'owner') or c.campus_id = any (app.auth_campus_ids())))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.live_class set cancelled_at = now() where id = p_id and cancelled_at is null;
end;
$$;
revoke execute on function public.cancel_live_class(uuid) from public, anon;
grant execute on function public.cancel_live_class(uuid) to authenticated;

-- The student's classes from yesterday onwards, with whether they joined.
create or replace function public.my_live_classes()
returns table (id uuid, title text, subject text, starts_at timestamptz, duration_min smallint, joined boolean, cancelled boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id, c.title, s.name_en, c.starts_at, c.duration_min,
         exists (select 1 from public.live_class_attendance a where a.live_class_id = c.id and a.student_id = e.student_id),
         c.cancelled_at is not null
    from public.live_class c
    join public.enrolment e on e.section_id = c.section_id and e.status = 'active'
    left join public.subject s on s.id = c.subject_id
   where e.student_id = public.my_student_id() and c.starts_at + make_interval(mins => c.duration_min) > now() - interval '1 day'
   order by c.starts_at;
$$;
revoke execute on function public.my_live_classes() from public, anon;
grant execute on function public.my_live_classes() to authenticated;

-- Joining records attendance and hands back the link. Open from 15 minutes
-- before the start until the class ends.
create or replace function public.join_live_class(p_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.live_class%rowtype;
  v_student uuid := public.my_student_id();
begin
  select l.* into c from public.live_class l
    join public.enrolment e on e.section_id = l.section_id and e.status = 'active' and e.student_id = v_student
   where l.id = p_id;
  if not found or v_student is null then
    raise exception 'CLASS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if c.cancelled_at is not null then
    raise exception 'CLASS_CANCELLED' using errcode = '55000';
  end if;
  if now() < c.starts_at - interval '15 minutes' or now() > c.starts_at + make_interval(mins => c.duration_min) then
    raise exception 'CLASS_NOT_OPEN' using errcode = '55000', hint = 'A class opens 15 minutes before it starts and closes when it ends.';
  end if;
  insert into public.live_class_attendance (live_class_id, student_id, tenant_id, campus_id)
  values (c.id, v_student, c.tenant_id, c.campus_id)
  on conflict do nothing;
  return c.meeting_url;
end;
$$;
revoke execute on function public.join_live_class(uuid) from public, anon;
grant execute on function public.join_live_class(uuid) to authenticated;
