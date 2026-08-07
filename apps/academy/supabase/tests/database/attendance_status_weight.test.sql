-- pgTAP tests for FR-G06 (late and half-day status resolution).
--
-- AC1's math is exercised against the REAL current month (never a
-- hardcoded calendar month, the same working_days_between()-derived
-- convention monthly_attendance_summary.test.sql already established) —
-- N working days marked present, then 2 flipped to absent and 2 to
-- half_day, so present_days = N - 2 (the absences) - 1 (half_day's own
-- 0.5 discount on 2 days) = N - 3, generalising the FR's own
-- 18-present/2-half_day/2-absent-of-22 example to any real month length.
begin;
select plan(14);

select public.provision_tenant('test-att-weight-co', 'Attendance Weight Co', 'owner@attweightco.test');
select id as tenant_id from public.tenant where slug = 'test-att-weight-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Weighted Kid', '2015-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrol_id \gset

reset role;
update public.enrolment set joined_on = current_date - 400 where id = :'enrol_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── attendance_weight(): the unconfigured default matches FR-G14's own
--    original hardcoded weights exactly — nothing regresses for a tenant
--    that never touches this FR's new config at all ──────────────────
select is(public.attendance_weight('present'::public.student_attendance_status, :'campus_id'::uuid, :'session_id'::uuid), 1::numeric, 'default weight: present = 1');
select is(public.attendance_weight('late'::public.student_attendance_status, :'campus_id'::uuid, :'session_id'::uuid), 1::numeric, 'default weight: late = 1');
select is(public.attendance_weight('half_day'::public.student_attendance_status, :'campus_id'::uuid, :'session_id'::uuid), 0.5::numeric, 'default weight: half_day = 0.5');
select is(public.attendance_weight('absent'::public.student_attendance_status, :'campus_id'::uuid, :'session_id'::uuid), 0::numeric, 'default weight: absent = 0');

-- ── AC1: N working days, 2 absent + 2 half_day, rest present ──────────

select (date_trunc('month', current_date))::date as month_start \gset
select (date_trunc('month', current_date) + interval '1 month' - interval '1 day')::date as month_end \gset
select extract(year from current_date)::int as this_year \gset
select extract(month from current_date)::int as this_month \gset
select public.working_days_between(:'campus_id'::uuid, :'month_start'::date, :'month_end'::date)::int as n_working \gset

reset role;
insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, source)
select :'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_id'::uuid, :'enrol_id'::uuid, d::date, 'present', 'web'
  from generate_series(:'month_start'::date, :'month_end'::date, interval '1 day') as d
 where extract(dow from d) <> 0;

update public.attendance_day set status = 'absent'
 where enrolment_id = :'enrol_id'::uuid
   and attendance_date in (select attendance_date from public.attendance_day where enrolment_id = :'enrol_id'::uuid order by attendance_date limit 2);
update public.attendance_day set status = 'half_day'
 where enrolment_id = :'enrol_id'::uuid
   and attendance_date in (select attendance_date from public.attendance_day where enrolment_id = :'enrol_id'::uuid and status = 'present' order by attendance_date limit 2);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.compute_month_attendance(:'campus_id'::uuid, :'this_year'::int, :'this_month'::int);
select is(
  (select present_days from public.attendance_month_summary where enrolment_id = :'enrol_id'::uuid and year = :'this_year'::int and month = :'this_month'::int)::numeric,
  (:'n_working'::int - 3)::numeric,
  'AC1: present_days = N - 2 (absences) - 1 (2 half_days at 0.5 each) — generalises the FR''s 18/2/2-of-22 example'
);
select is(
  (select attendance_pct from public.attendance_month_summary where enrolment_id = :'enrol_id'::uuid and year = :'this_year'::int and month = :'this_month'::int),
  round((:'n_working'::int - 3)::numeric / :'n_working'::int * 100, 2),
  'AC1: attendance_pct reflects the weighted present_days over working_days'
);
select (select attendance_pct from public.attendance_month_summary where enrolment_id = :'enrol_id'::uuid and year = :'this_year'::int and month = :'this_month'::int) as pct_before_reweight \gset

-- ── AC3: changing the weight does NOT retroactively touch the row
--    already stored above — only a fresh recompute reflects it ────────

select public.set_attendance_status_weight(:'campus_id'::uuid, :'session_id'::uuid, 'half_day'::public.student_attendance_status, 0.0::numeric);
select is(
  (select attendance_pct from public.attendance_month_summary where enrolment_id = :'enrol_id'::uuid and year = :'this_year'::int and month = :'this_month'::int),
  :'pct_before_reweight'::numeric,
  'AC3: the already-stored summary row is untouched by arming a new weight — no auto-recompute'
);

select public.compute_month_attendance(:'campus_id'::uuid, :'this_year'::int, :'this_month'::int);
select is(
  (select present_days from public.attendance_month_summary where enrolment_id = :'enrol_id'::uuid and year = :'this_year'::int and month = :'this_month'::int)::numeric,
  (:'n_working'::int - 4)::numeric,
  'AC3: a fresh recompute after the reweight now counts half_day as 0 (N - 2 absent - 2 half_day at weight 0)'
);

-- ── FORBIDDEN: only principal-tier roles can arm a weight override ────

select gen_random_uuid() as teacher_user_id \gset
reset role;
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@attweightco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'subject_teacher', 'A Teacher');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select throws_ok(
  format('select public.set_attendance_status_weight(%L, %L, ''late''::public.student_attendance_status, 1.0::numeric)', :'campus_id', :'session_id'),
  'FORBIDDEN',
  'a subject teacher cannot arm an attendance status weight override'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── AC2/AC4: save_attendance_register() defaults arrival_time only for
--    'late' with none supplied; 'present' + a supplied arrival_time is
--    stored as-is and never touches the weight ─────────────────────────

select public.set_attendance_policy(:'campus_id'::uuid, :'session_id'::uuid);

select public.save_attendance_register(
  :'section_id'::uuid, current_date,
  jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol_id', 'status', 'late'))
);
select ok(
  (select arrival_time from public.attendance_day where enrolment_id = :'enrol_id'::uuid and attendance_date = current_date) is not null,
  'AC2: a "late" mark with no arrival_time supplied is defaulted to the campus''s current local time'
);

select public.save_attendance_register(
  :'section_id'::uuid, current_date,
  jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol_id', 'status', 'late', 'arrival_time', '09:15:00'))
);
select is(
  (select arrival_time::text from public.attendance_day where enrolment_id = :'enrol_id'::uuid and attendance_date = current_date),
  '09:15:00',
  'AC2: an explicitly supplied arrival_time is never overridden by the default'
);

select public.save_attendance_register(
  :'section_id'::uuid, current_date,
  jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol_id', 'status', 'present', 'arrival_time', '08:02:00'))
);
select is(
  (select arrival_time::text from public.attendance_day where enrolment_id = :'enrol_id'::uuid and attendance_date = current_date),
  '08:02:00',
  'AC4: a "present" mark with an arrival_time supplied stores it'
);
select is(
  public.attendance_weight('present'::public.student_attendance_status, :'campus_id'::uuid, :'session_id'::uuid),
  1::numeric,
  'AC4: storing an arrival_time on a present day never changes present''s own weight'
);

-- AC2, via the real register-form entry point (rpc_bulk_mark_attendance)
-- rather than save_attendance_register() directly — proves arrival_time
-- actually survives the exceptions round trip the UI itself uses.
select public.rpc_bulk_mark_attendance(
  :'section_id'::uuid, current_date + 1,
  jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol_id', 'status', 'late', 'arrival_time', '09:40:00'))
);
select is(
  (select arrival_time::text from public.attendance_day where enrolment_id = :'enrol_id'::uuid and attendance_date = current_date + 1),
  '09:40:00',
  'AC2: an arrival_time passed through rpc_bulk_mark_attendance''s own exceptions reaches attendance_day'
);

select * from finish();
rollback;
