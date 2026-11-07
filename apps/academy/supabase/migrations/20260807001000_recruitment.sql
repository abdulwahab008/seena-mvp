-- HR recruitment: job openings and the applicants for each, moved through a
-- simple pipeline (applied -> shortlisted -> interview -> offered -> hired, or
-- rejected / withdrawn at any point) with a dated note on every move.
--
-- HR and leadership only; candidate CNICs and phone numbers are personal data,
-- so parents, students and teaching staff never read these tables.

create table public.job_opening (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  title         text not null check (length(btrim(title)) between 1 and 150),
  department_id uuid references public.department(id) on delete set null,
  positions     smallint not null default 1 check (positions between 1 and 100),
  salary_range  text check (salary_range is null or length(salary_range) <= 100),
  description   text check (description is null or length(description) <= 4000),
  closes_on     date,
  status        text not null default 'open' check (status in ('open', 'on_hold', 'closed')),
  created_by    uuid not null default auth.uid() references auth.users(id),
  created_at    timestamptz not null default now()
);
create index idx_job_opening_scope on public.job_opening (tenant_id, campus_id, status);
create index idx_job_opening_department on public.job_opening (department_id) where department_id is not null;

create table public.job_application (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  job_opening_id uuid not null references public.job_opening(id) on delete cascade,
  candidate_name text not null check (length(btrim(candidate_name)) between 1 and 200),
  phone          text check (phone is null or length(phone) <= 30),
  email          text check (email is null or length(email) <= 200),
  cnic           text check (cnic is null or cnic ~ '^[0-9]{5}-[0-9]{7}-[0-9]$'),
  qualification  text check (qualification is null or length(qualification) <= 300),
  experience_yrs numeric(4,1) check (experience_yrs is null or experience_yrs between 0 and 60),
  source         text check (source is null or length(source) <= 100),
  stage          text not null default 'applied' check (stage in ('applied', 'shortlisted', 'interview', 'offered', 'hired', 'rejected', 'withdrawn')),
  interview_at   timestamptz,
  rating         smallint check (rating between 1 and 5),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index idx_job_application_opening on public.job_application (job_opening_id, stage);
create index idx_job_application_scope on public.job_application (tenant_id, campus_id);
create unique index uq_job_application_cnic on public.job_application (job_opening_id, cnic) where cnic is not null;

create table public.job_application_event (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  application_id uuid not null references public.job_application(id) on delete cascade,
  from_stage     text,
  to_stage       text not null,
  note           text check (note is null or length(note) <= 1000),
  actor_id       uuid not null default auth.uid() references auth.users(id),
  created_at     timestamptz not null default now()
);
create index idx_job_application_event_app on public.job_application_event (application_id, created_at);
create index idx_job_application_event_scope on public.job_application_event (tenant_id, campus_id);

create or replace function app.fn_recruiter()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'hr_manager');
$$;

alter table public.job_opening enable row level security;
alter table public.job_application enable row level security;
alter table public.job_application_event enable row level security;

create policy job_opening_read on public.job_opening for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_recruiter()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())));
create policy job_application_read on public.job_application for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_recruiter()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())));
create policy job_application_event_read on public.job_application_event for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_recruiter()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())));

select app.fn_block_portal_roles('public.job_opening');
select app.fn_block_portal_roles('public.job_application');
select app.fn_block_portal_roles('public.job_application_event');

create or replace function app.fn_assert_recruiter(p_campus_id uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is null or not app.fn_recruiter() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501', detail = 'campus outside your scope';
  end if;
end;
$$;
revoke execute on function app.fn_assert_recruiter(uuid) from public, anon, authenticated;

create or replace function public.save_job_opening(
  p_campus_id     uuid,
  p_title         text,
  p_department_id uuid,
  p_positions     smallint,
  p_salary_range  text,
  p_description   text,
  p_closes_on     date,
  p_status        text default 'open',
  p_opening_id    uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.fn_assert_recruiter(p_campus_id);
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_opening_id is null then
    insert into public.job_opening (tenant_id, campus_id, title, department_id, positions, salary_range, description, closes_on, status)
    values (app.auth_tenant_id(), p_campus_id, btrim(p_title), p_department_id, coalesce(p_positions, 1), nullif(btrim(p_salary_range), ''),
            nullif(btrim(p_description), ''), p_closes_on, coalesce(p_status, 'open'))
    returning id into v_id;
  else
    update public.job_opening
       set title = btrim(p_title), department_id = p_department_id, positions = coalesce(p_positions, 1),
           salary_range = nullif(btrim(p_salary_range), ''), description = nullif(btrim(p_description), ''),
           closes_on = p_closes_on, status = coalesce(p_status, status)
     where id = p_opening_id and campus_id = p_campus_id and tenant_id = app.auth_tenant_id()
    returning id into v_id;
    if v_id is null then
      raise exception 'OPENING_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
end;
$$;
revoke execute on function public.save_job_opening(uuid, text, uuid, smallint, text, text, date, text, uuid) from public, anon;
grant execute on function public.save_job_opening(uuid, text, uuid, smallint, text, text, date, text, uuid) to authenticated;

create or replace function public.add_job_application(
  p_job_opening_id uuid,
  p_candidate_name text,
  p_phone          text,
  p_email          text,
  p_cnic           text,
  p_qualification  text,
  p_experience_yrs numeric,
  p_source         text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.job_opening%rowtype;
  v_id  uuid;
begin
  select * into v_job from public.job_opening where id = p_job_opening_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'OPENING_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_recruiter(v_job.campus_id);
  if v_job.status = 'closed' then
    raise exception 'OPENING_CLOSED' using errcode = '22023';
  end if;

  insert into public.job_application (tenant_id, campus_id, job_opening_id, candidate_name, phone, email, cnic, qualification, experience_yrs, source)
  values (v_job.tenant_id, v_job.campus_id, v_job.id, btrim(p_candidate_name), nullif(btrim(p_phone), ''), nullif(btrim(p_email), ''),
          case when length(app.digits(coalesce(p_cnic, ''))) = 13 then app.fn_normalize_pk_id(p_cnic) end,
          nullif(btrim(p_qualification), ''), p_experience_yrs, nullif(btrim(p_source), ''))
  returning id into v_id;
  insert into public.job_application_event (tenant_id, campus_id, application_id, from_stage, to_stage)
  values (v_job.tenant_id, v_job.campus_id, v_id, null, 'applied');
  return v_id;
end;
$$;
revoke execute on function public.add_job_application(uuid, text, text, text, text, text, numeric, text) from public, anon;
grant execute on function public.add_job_application(uuid, text, text, text, text, text, numeric, text) to authenticated;

create or replace function public.move_job_application(
  p_application_id uuid,
  p_stage          text,
  p_note           text default null,
  p_interview_at   timestamptz default null,
  p_rating         smallint default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app public.job_application%rowtype;
begin
  select * into v_app from public.job_application where id = p_application_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'APPLICATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_recruiter(v_app.campus_id);
  if v_app.stage in ('hired', 'rejected', 'withdrawn') then
    raise exception 'APPLICATION_CLOSED' using errcode = '22023', hint = 'This application is already finished.';
  end if;
  if p_stage not in ('shortlisted', 'interview', 'offered', 'hired', 'rejected', 'withdrawn') then
    raise exception 'STAGE_INVALID' using errcode = '22023';
  end if;
  if p_stage = 'interview' and p_interview_at is null then
    raise exception 'INTERVIEW_TIME_REQUIRED' using errcode = '22023';
  end if;

  update public.job_application
     set stage = p_stage,
         interview_at = coalesce(p_interview_at, interview_at),
         rating = coalesce(p_rating, rating),
         updated_at = now()
   where id = p_application_id;
  insert into public.job_application_event (tenant_id, campus_id, application_id, from_stage, to_stage, note)
  values (v_app.tenant_id, v_app.campus_id, v_app.id, v_app.stage, p_stage, nullif(btrim(p_note), ''));
end;
$$;
revoke execute on function public.move_job_application(uuid, text, text, timestamptz, smallint) from public, anon;
grant execute on function public.move_job_application(uuid, text, text, timestamptz, smallint) to authenticated;
