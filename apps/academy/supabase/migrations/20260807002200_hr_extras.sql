-- HR extras: interview scorecards, job offers, turning a hire into a staff
-- record, CNIC expiry, and an HR dashboard.
--
-- Staff CNIC and date of birth are not readable column by column (they are
-- personal data), so the dashboard is a SECURITY DEFINER function that only
-- HR roles may call, and it returns birthdays as day and month only.

create or replace function app.fn_assert_hr(p_campus_id uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'hr_manager')
     or (p_campus_id is not null and app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function app.fn_assert_hr(uuid) from public, anon, authenticated;

-- ── interview scorecards ──────────────────────────────────────────────────

create table public.interview_score (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  application_id    uuid not null references public.job_application(id) on delete cascade,
  interviewer_id    uuid not null default auth.uid() references auth.users(id),
  subject_knowledge smallint not null check (subject_knowledge between 1 and 5),
  communication     smallint not null check (communication between 1 and 5),
  teaching_demo     smallint not null check (teaching_demo between 1 and 5),
  attitude          smallint not null check (attitude between 1 and 5),
  recommendation    text not null check (recommendation in ('hire', 'hold', 'reject')),
  comment           text check (comment is null or length(comment) <= 1000),
  scored_at         timestamptz not null default now(),
  unique (application_id, interviewer_id)
);
create index idx_interview_score_campus on public.interview_score (tenant_id, campus_id);
alter table public.interview_score enable row level security;
create policy interview_score_read on public.interview_score for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'hr_manager')
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
select app.fn_block_portal_roles('public.interview_score');

create or replace function public.save_interview_score(p_application_id uuid, p_subject_knowledge smallint, p_communication smallint,
  p_teaching_demo smallint, p_attitude smallint, p_recommendation text, p_comment text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.job_application%rowtype;
  v_id uuid;
begin
  select * into a from public.job_application where id = p_application_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'APPLICATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_hr(a.campus_id);
  insert into public.interview_score (tenant_id, campus_id, application_id, subject_knowledge, communication, teaching_demo, attitude, recommendation, comment)
  values (a.tenant_id, a.campus_id, a.id, p_subject_knowledge, p_communication, p_teaching_demo, p_attitude, p_recommendation, nullif(btrim(coalesce(p_comment, '')), ''))
  on conflict (application_id, interviewer_id) do update
     set subject_knowledge = excluded.subject_knowledge, communication = excluded.communication, teaching_demo = excluded.teaching_demo,
         attitude = excluded.attitude, recommendation = excluded.recommendation, comment = excluded.comment, scored_at = now()
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.save_interview_score(uuid, smallint, smallint, smallint, smallint, text, text) from public, anon;
grant execute on function public.save_interview_score(uuid, smallint, smallint, smallint, smallint, text, text) to authenticated;

-- ── offers and hiring ─────────────────────────────────────────────────────

alter table public.job_application
  add column offer_salary_paisa bigint check (offer_salary_paisa is null or offer_salary_paisa > 0),
  add column offer_joining_on   date,
  add column staff_id           uuid references public.staff(id);

create or replace function public.make_job_offer(p_application_id uuid, p_salary_paisa bigint, p_joining_on date, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.job_application%rowtype;
begin
  select * into a from public.job_application where id = p_application_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'APPLICATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_hr(a.campus_id);
  if a.stage in ('hired', 'rejected', 'withdrawn') then
    raise exception 'APPLICATION_CLOSED' using errcode = '55000';
  end if;
  update public.job_application
     set stage = 'offered', offer_salary_paisa = p_salary_paisa, offer_joining_on = p_joining_on, updated_at = now()
   where id = a.id;
  insert into public.job_application_event (tenant_id, campus_id, application_id, from_stage, to_stage, note)
  values (a.tenant_id, a.campus_id, a.id, a.stage, 'offered',
          coalesce(nullif(btrim(coalesce(p_note, '')), ''), format('Offer: PKR %s a month from %s', to_char(p_salary_paisa / 100.0, 'FM999,999,990'), p_joining_on)));
end;
$$;
revoke execute on function public.make_job_offer(uuid, bigint, date, text) from public, anon;
grant execute on function public.make_job_offer(uuid, bigint, date, text) to authenticated;

-- An accepted offer becomes a staff record on the opening's campus and
-- department, joining on the offered date.
create or replace function public.hire_applicant(p_application_id uuid, p_employee_code text, p_gender public.gender, p_cnic text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.job_application%rowtype;
  j public.job_opening%rowtype;
  v_staff uuid;
  v_cnic  text;
begin
  select * into a from public.job_application where id = p_application_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'APPLICATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_hr(a.campus_id);
  if a.stage <> 'offered' then
    raise exception 'NOT_OFFERED' using errcode = '55000', hint = 'Make an offer before hiring.';
  end if;
  v_cnic := coalesce(a.cnic, nullif(btrim(coalesce(p_cnic, '')), ''));
  if v_cnic is null then
    raise exception 'CNIC_REQUIRED' using errcode = '22023', hint = 'A staff record needs the CNIC.';
  end if;
  select * into j from public.job_opening where id = a.job_opening_id;
  insert into public.staff (tenant_id, campus_id, employee_code, cnic, id_document_type, gender, full_name, doj, department_id)
  values (a.tenant_id, a.campus_id, btrim(p_employee_code), v_cnic, 'cnic', p_gender, a.candidate_name,
          coalesce(a.offer_joining_on, current_date), j.department_id)
  returning id into v_staff;
  update public.job_application set stage = 'hired', staff_id = v_staff, updated_at = now() where id = a.id;
  insert into public.job_application_event (tenant_id, campus_id, application_id, from_stage, to_stage, note)
  values (a.tenant_id, a.campus_id, a.id, 'offered', 'hired', 'Staff record created: ' || btrim(p_employee_code));
  return v_staff;
end;
$$;
revoke execute on function public.hire_applicant(uuid, text, public.gender, text) from public, anon;
grant execute on function public.hire_applicant(uuid, text, public.gender, text) to authenticated;

-- ── CNIC expiry ───────────────────────────────────────────────────────────

alter table public.staff add column cnic_expires_on date;
grant select (cnic_expires_on), update (cnic_expires_on) on public.staff to authenticated;

create or replace function public.set_staff_cnic_expiry(p_staff_id uuid, p_expires_on date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campus uuid;
begin
  select campus_id into v_campus from public.staff where id = p_staff_id and tenant_id = app.auth_tenant_id();
  if v_campus is null then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_hr(v_campus);
  update public.staff set cnic_expires_on = p_expires_on where id = p_staff_id;
end;
$$;
revoke execute on function public.set_staff_cnic_expiry(uuid, date) from public, anon;
grant execute on function public.set_staff_cnic_expiry(uuid, date) to authenticated;

-- ── dashboard ─────────────────────────────────────────────────────────────

create or replace function public.hr_dashboard(p_campus_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
begin
  perform app.fn_assert_hr(p_campus_id);
  return (
    with s as (
      select st.* from public.staff st
       where st.tenant_id = v_tenant
         and (p_campus_id is null or st.campus_id = p_campus_id)
         and (app.auth_role() in ('super_admin', 'owner') or st.campus_id = any (app.auth_campus_ids()))
    )
    select jsonb_build_object(
      'headcount', (select count(*) from s where employment_status <> 'exited'),
      'by_department', coalesce((select jsonb_agg(jsonb_build_object('department', coalesce(d.name_en, 'No department'), 'count', x.n) order by x.n desc)
                                   from (select department_id, count(*) n from s where employment_status <> 'exited' group by department_id) x
                                   left join public.department d on d.id = x.department_id), '[]'::jsonb),
      'joiners_90d', (select count(*) from s where doj > current_date - 90),
      'leavers_90d', (select count(*) from s where employment_status = 'exited' and employment_status_changed_at > now() - interval '90 days'),
      'birthdays', coalesce((select jsonb_agg(jsonb_build_object('name', full_name, 'day', extract(day from dob)::int) order by extract(day from dob))
                               from s where employment_status <> 'exited' and dob is not null and extract(month from dob) = extract(month from current_date)), '[]'::jsonb),
      'cnic_expiring', coalesce((select jsonb_agg(jsonb_build_object('name', full_name, 'expires_on', cnic_expires_on) order by cnic_expires_on)
                                   from s where employment_status <> 'exited' and cnic_expires_on is not null and cnic_expires_on <= current_date + 60), '[]'::jsonb)
    )
  );
end;
$$;
revoke execute on function public.hr_dashboard(uuid) from public, anon;
grant execute on function public.hr_dashboard(uuid) to authenticated;
