-- pgTAP tests for FR-G14: monthly attendance summary computation.
--
-- Every AC is exercised against the REAL current month/a real future
-- month, computed relative to current_date — never a hardcoded calendar
-- month. The K-module pgTAP suite already broke once this session when
-- a hardcoded "July 2026" assumption crossed a real wall-clock month
-- boundary; expected working-day counts here are derived by calling
-- working_days_between() itself, the same function compute_month_
-- attendance() uses internally, so this suite stays correct no matter
-- which real month it happens to run in.
begin;
select plan(15);

select public.provision_tenant('test-monthly-summary-co', 'Monthly Summary Co', 'owner@monthlysummaryco.test');
select id as tenant_id from public.tenant where slug = 'test-monthly-summary-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@monthlysummaryco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'class_teacher', 'Ms. Class Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.assign_class_teacher(:'section_id'::uuid, :'teacher_user_id'::uuid, current_date - 100);

select public.create_student(:'campus_id'::uuid, 'Full Month Kid', '2015-01-01'::date, 'male') as student1_id \gset
select public.enrol_student(:'section_id'::uuid, :'student1_id'::uuid) as enrol1_id \gset
select public.create_student(:'campus_id'::uuid, 'Mid Month Kid', '2015-01-01'::date, 'female') as student2_id \gset
select public.enrol_student(:'section_id'::uuid, :'student2_id'::uuid) as enrol2_id \gset
select public.create_student(:'campus_id'::uuid, 'Closed Month Kid', '2015-01-01'::date, 'male') as student3_id \gset
select public.enrol_student(:'section_id'::uuid, :'student3_id'::uuid) as enrol3_id \gset

-- enrol1/enrol2 both back-date joined_on so THIS month is fully covered
-- for enrol1, but enrol2's own joined_on is moved forward into the
-- middle of the month below (AC2) — enrol_student() itself always sets
-- joined_on = current_date, so it's backdated directly, table-owner
-- context, the same way every other FR in this session backdates a
-- validity/effective date that no RPC exposes a parameter for.
reset role;
update public.enrolment set joined_on = current_date - 400 where id = :'enrol1_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select (date_trunc('month', current_date))::date as month_start \gset
select (date_trunc('month', current_date) + interval '1 month' - interval '1 day')::date as month_end \gset
select extract(year from current_date)::int as this_year \gset
select extract(month from current_date)::int as this_month \gset
select public.working_days_between(:'campus_id'::uuid, :'month_start'::date, :'month_end'::date)::int as expected_working \gset

-- ── AC1: a full month, no clipping, 2 absences out of N working days ──

reset role;
insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, source)
select :'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_id'::uuid, :'enrol1_id'::uuid, d::date, 'present', 'web'
  from generate_series(:'month_start'::date, :'month_end'::date, interval '1 day') as d
 where extract(dow from d) <> 0;

update public.attendance_day
   set status = 'absent'
 where enrolment_id = :'enrol1_id'::uuid
   and attendance_date in (
     select attendance_date from public.attendance_day
      where enrolment_id = :'enrol1_id'::uuid
      order by attendance_date
      limit 2
   );
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.compute_month_attendance(:'campus_id'::uuid, :'this_year'::int, :'this_month'::int);

select is(
  (select working_days from public.attendance_month_summary where enrolment_id = :'enrol1_id'::uuid and year = :'this_year'::int and month = :'this_month'::int),
  :'expected_working'::int,
  'AC1: working_days matches working_days_between() over the full month'
);
select is(
  (select present_days from public.attendance_month_summary where enrolment_id = :'enrol1_id'::uuid and year = :'this_year'::int and month = :'this_month'::int)::numeric,
  (:'expected_working'::int - 2)::numeric,
  'AC1: present_days reflects the two absences'
);
select is(
  (select absent_days from public.attendance_month_summary where enrolment_id = :'enrol1_id'::uuid and year = :'this_year'::int and month = :'this_month'::int),
  2,
  'AC1: absent_days = 2'
);
select is(
  (select attendance_pct from public.attendance_month_summary where enrolment_id = :'enrol1_id'::uuid and year = :'this_year'::int and month = :'this_month'::int),
  round((:'expected_working'::int - 2)::numeric / :'expected_working'::int * 100, 2),
  'AC1: attendance_pct = present_days / working_days * 100, rounded to 2dp'
);
select isnt(
  (select computed_at from public.attendance_month_summary where enrolment_id = :'enrol1_id'::uuid and year = :'this_year'::int and month = :'this_month'::int),
  null,
  'AC1: computed_at is set on first computation'
);
select is(
  (select recomputed_at from public.attendance_month_summary where enrolment_id = :'enrol1_id'::uuid and year = :'this_year'::int and month = :'this_month'::int),
  null,
  'AC1: recomputed_at stays NULL until an actual recompute happens'
);

-- ── AC2: mid-month join clips the denominator, not just the numerator ─

select (:'month_start'::date + 10) as enrol2_joined \gset
reset role;
update public.enrolment set joined_on = :'enrol2_joined'::date where id = :'enrol2_id'::uuid;
select public.working_days_between(:'campus_id'::uuid, :'enrol2_joined'::date, :'month_end'::date)::int as expected_working_2 \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.compute_month_attendance(:'campus_id'::uuid, :'this_year'::int, :'this_month'::int);
select is(
  (select working_days from public.attendance_month_summary where enrolment_id = :'enrol2_id'::uuid and year = :'this_year'::int and month = :'this_month'::int),
  :'expected_working_2'::int,
  'AC2: working_days is clipped to [joined_on, month_end], not the full month'
);
select ok(
  :'expected_working_2'::int < :'expected_working'::int,
  'AC2 sanity: the mid-month join genuinely produced fewer working days than the full month'
);

-- ── AC3: a fully-closed future month stores NULL, not 0, for pct ──────

select (date_trunc('month', current_date + interval '2 months'))::date as future_start \gset
select (date_trunc('month', current_date + interval '2 months') + interval '1 month' - interval '1 day')::date as future_end \gset
select extract(year from :'future_start'::date)::int as future_year \gset
select extract(month from :'future_start'::date)::int as future_month \gset

reset role;
update public.enrolment set joined_on = current_date - 400 where id = :'enrol3_id'::uuid;
insert into public.holiday_calendar (tenant_id, campus_id, holiday_date, name)
select :'tenant_id'::uuid, :'campus_id'::uuid, d::date, 'Full closure test'
  from generate_series(:'future_start'::date, :'future_end'::date, interval '1 day') as d;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.compute_month_attendance(:'campus_id'::uuid, :'future_year'::int, :'future_month'::int);
select is(
  (select working_days from public.attendance_month_summary where enrolment_id = :'enrol3_id'::uuid and year = :'future_year'::int and month = :'future_month'::int),
  0,
  'AC3: zero working days in a fully-closed month'
);
select ok(
  (select attendance_pct from public.attendance_month_summary where enrolment_id = :'enrol3_id'::uuid and year = :'future_year'::int and month = :'future_month'::int) is null,
  'AC3: attendance_pct is stored as NULL, not 0, for a zero-working-day month'
);

-- ── AC4: an approved correction flags the month stale; recompute
--    updates the summary and advances recomputed_at ───────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select attendance_date from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and status = 'absent' order by attendance_date limit 1 \gset
select public.request_attendance_correction(:'enrol1_id'::uuid, :'attendance_date'::date, 'present'::public.student_attendance_status, 'Was marked absent by mistake, confirmed with parent') as correction1_id \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.approve_attendance_correction(:'correction1_id'::uuid, 'Confirmed with the parent, note is on file');

select ok(
  (select stale from public.attendance_month_summary where enrolment_id = :'enrol1_id'::uuid and year = :'this_year'::int and month = :'this_month'::int),
  'AC4: the approved correction flags this month''s summary stale'
);

select public.compute_month_attendance(:'campus_id'::uuid, :'this_year'::int, :'this_month'::int);

select is(
  (select present_days from public.attendance_month_summary where enrolment_id = :'enrol1_id'::uuid and year = :'this_year'::int and month = :'this_month'::int)::numeric,
  (:'expected_working'::int - 1)::numeric,
  'AC4: the recompute reflects the corrected day (only 1 absence remains)'
);
select isnt(
  (select recomputed_at from public.attendance_month_summary where enrolment_id = :'enrol1_id'::uuid and year = :'this_year'::int and month = :'this_month'::int),
  null,
  'AC4: recomputed_at is set after the recompute'
);
select ok(
  (select not stale from public.attendance_month_summary where enrolment_id = :'enrol1_id'::uuid and year = :'this_year'::int and month = :'this_month'::int),
  'AC4: the recompute clears the stale flag'
);

-- ── validation ──────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select throws_ok(
  format('select public.compute_month_attendance(%L, %L, %L)', :'campus_id', :'this_year', :'this_month'),
  'FORBIDDEN',
  'a class teacher cannot trigger a monthly recompute'
);

select * from finish();
rollback;
