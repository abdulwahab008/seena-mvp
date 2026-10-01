-- pgTAP tests for FR-D20: teacher workload variance report.
begin;
select plan(20);

select public.provision_tenant('test-wl-co', 'Workload Co', 'owner@wl.test');
select id as tenant_id from public.tenant where slug = 'test-wl-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-wl-perf', 'Workload Perf Co', 'owner@wlperf.test');
select id as ptenant_id from public.tenant where slug = 'test-wl-perf' \gset
select id as pcampus_id from public.campus where tenant_id = :'ptenant_id' \gset
select id as psession_id from public.academic_session where tenant_id = :'ptenant_id' \gset
select id as pclass1_id from public.class_level where tenant_id = :'ptenant_id' and code = '1' \gset

select date_trunc('week', app.fn_karachi_today())::date as monday \gset
select to_char(:'monday'::date, 'IYYY-"W"IW') as iso \gset

select gen_random_uuid() as a_uid \gset
select gen_random_uuid() as b_uid \gset
select gen_random_uuid() as c_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'a_uid', 'a@wl.test', 'authenticated', 'authenticated', 'x'), (:'b_uid', 'b@wl.test', 'authenticated', 'authenticated', 'x'),
  (:'c_uid', 'c@wl.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@wl.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@wl.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'a_uid', :'tenant_id', 'subject_teacher', 'Teacher A'), (:'b_uid', :'tenant_id', 'subject_teacher', 'Teacher B'), (:'c_uid', :'tenant_id', 'subject_teacher', 'Teacher C'),
  (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Plain Teacher');
insert into public.staff (tenant_id, campus_id, user_id, employee_code, cnic, gender, doj, full_name) values
  (:'tenant_id', :'campus_id', :'a_uid', 'WL-A', '42101-5555555-1', 'female', '2020-01-01', 'Teacher A'),
  (:'tenant_id', :'campus_id', :'b_uid', 'WL-B', '42101-5555555-2', 'male', '2020-01-01', 'Teacher B'),
  (:'tenant_id', :'campus_id', :'c_uid', 'WL-C', '42101-5555555-3', 'female', '2020-01-01', 'Teacher C');
select id as sa from public.staff where employee_code = 'WL-A' and tenant_id = :'tenant_id' \gset
select id as sc from public.staff where employee_code = 'WL-C' and tenant_id = :'tenant_id' \gset
insert into public.staff_contract (tenant_id, staff_id, contract_type, start_date, contracted_periods_per_week) values (:'tenant_id', :'sa', 'permanent', :'monday'::date - 200, 30);

insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity) values
  (:'tenant_id', :'campus_id', :'session_id', :'class1_id', 'A', 30), (:'tenant_id', :'campus_id', :'session_id', :'class1_id', 'B', 30), (:'tenant_id', :'campus_id', :'session_id', :'class1_id', 'C', 30);
select id as sec_a from public.class_section where tenant_id = :'tenant_id' and name = 'A' \gset
select id as sec_b from public.class_section where tenant_id = :'tenant_id' and name = 'B' \gset
select id as sec_c from public.class_section where tenant_id = :'tenant_id' and name = 'C' \gset
insert into public.subject (tenant_id, code, name_en, name_ur) values (:'tenant_id', 'PHY', 'Physics', 'طبیعیات');
select id as phy from public.subject where tenant_id = :'tenant_id' and code = 'PHY' \gset
insert into public.timetable_version (tenant_id, campus_id, session_id, shift, name, status, version_no, effective_from, effective_to, published_at)
values (:'tenant_id', :'campus_id', :'session_id', 'MORNING', 'v1', 'PUBLISHED', 1, :'monday'::date - 60, :'monday'::date + 90, now());
select id as tv from public.timetable_version where tenant_id = :'tenant_id' \gset

-- Teacher A: 34 of 35 possible Mon-Fri periods; B: 5 Monday periods; C: 2 periods a day, all week
insert into public.timetable_slot (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, subject_id, staff_id)
select :'tenant_id', :'campus_id', :'tv', :'sec_a', d, p, :'phy', :'a_uid' from generate_series(1, 5) d, generate_series(1, 7) p where not (d = 5 and p = 7);
insert into public.timetable_slot (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, subject_id, staff_id)
select :'tenant_id', :'campus_id', :'tv', :'sec_b', 1, p, :'phy', :'b_uid' from generate_series(1, 5) p;
insert into public.timetable_slot (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, subject_id, staff_id)
select :'tenant_id', :'campus_id', :'tv', :'sec_c', d, p, :'phy', :'c_uid' from generate_series(1, 5) d, generate_series(1, 2) p;
-- A covers B's first three Monday periods
insert into public.timetable_substitution (tenant_id, campus_id, slot_id, sub_date, absent_staff_id, substitute_staff_id, reason, status)
select :'tenant_id', :'campus_id', id, :'monday'::date, :'b_uid', :'a_uid', 'other', 'active'
  from public.timetable_slot where section_id = :'sec_b' and period_no <= 3;
-- C is on approved leave for the whole week
insert into public.leave_type (tenant_id, code, name_en, entitlement_days) values (:'tenant_id', 'CASUAL', 'Casual', 10);
select id as lt from public.leave_type where tenant_id = :'tenant_id' \gset
insert into public.leave_application (tenant_id, campus_id, staff_id, leave_type_id, from_date, to_date, working_days, status)
values (:'tenant_id', :'campus_id', :'sc', :'lt', :'monday'::date, :'monday'::date + 6, 5, 'approved');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select lives_ok(format($$ select public.refresh_teacher_load(%L::uuid) $$, :'campus_id'), 'the Principal can refresh the report on demand');

-- ── AC1: contracted 30, timetabled 34 ────────────────────────────────────
select is((select timetabled_periods from public.get_teacher_workload(:'campus_id'::uuid, :'iso') where employee_code = 'WL-A'), 34, 'AC1: Teacher A is timetabled for 34 periods');
select is((select variance from public.get_teacher_workload(:'campus_id'::uuid, :'iso') where employee_code = 'WL-A'), 4, 'AC1: variance is +4 against the contracted 30');
select ok((select is_overloaded from public.get_teacher_workload(:'campus_id'::uuid, :'iso') where employee_code = 'WL-A'), 'AC1: and the row is flagged over-loaded');

-- ── AC2: substitution is reported separately ─────────────────────────────
select is((select substituted_periods from public.get_teacher_workload(:'campus_id'::uuid, :'iso') where employee_code = 'WL-A'), 3, 'AC2: the 3 periods Teacher A covered show in the substituted column');
select is((select timetabled_periods from public.get_teacher_workload(:'campus_id'::uuid, :'iso') where employee_code = 'WL-A'), 34, 'AC2: and are not merged into the 34 base periods');
select is((select delivered_periods from public.get_teacher_workload(:'campus_id'::uuid, :'iso') where employee_code = 'WL-A'), 34, 'AC2: nor into the delivered count');
select is((select delivered_periods from public.get_teacher_workload(:'campus_id'::uuid, :'iso') where employee_code = 'WL-B'), 2, 'the absent teacher delivered only the 2 periods nobody covered');
select is((select substituted_periods from public.get_teacher_workload(:'campus_id'::uuid, :'iso') where employee_code = 'WL-B'), 0, 'and covered none');

-- ── AC3: a whole week on approved leave ──────────────────────────────────
select is((select timetabled_periods from public.get_teacher_workload(:'campus_id'::uuid, :'iso') where employee_code = 'WL-C'), 10, 'AC3: timetabled periods still display for the teacher on leave');
select is((select delivered_periods from public.get_teacher_workload(:'campus_id'::uuid, :'iso') where employee_code = 'WL-C'), 0, 'AC3: delivered is 0');
select ok((select all_not_delivered and not_delivered_periods = 10 from public.get_teacher_workload(:'campus_id'::uuid, :'iso') where employee_code = 'WL-C'), 'AC3: all 10 are marked not delivered');
select ok((select variance is null and not is_overloaded from public.get_teacher_workload(:'campus_id'::uuid, :'iso') where employee_code = 'WL-C'), 'no contracted figure on file means no variance and no over-load flag');

-- ── campus isolation: the view itself is unreachable ─────────────────────
select throws_ok($$ select count(*) from public.mv_teacher_weekly_load $$, '42501', null, 'the materialized view cannot be read directly through the API');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', '[]'::jsonb)::text, true);
select throws_ok(format($$ select * from public.get_teacher_workload(%L::uuid, %L) $$, :'campus_id', :'iso'), 'FORBIDDEN', 'a Principal of another campus cannot read this campus''s staffing');
select throws_ok(format($$ select public.refresh_teacher_load(%L::uuid) $$, :'campus_id'), 'FORBIDDEN', 'nor refresh it');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select * from public.get_teacher_workload(%L::uuid, %L) $$, :'campus_id', :'iso'), 'FORBIDDEN', 'a teacher cannot read the workload report');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'ptenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select * from public.get_teacher_workload(%L::uuid, %L) $$, :'campus_id', :'iso'), 'CAMPUS_NOT_FOUND', 'another school''s campus does not exist for this caller');

-- ── AC4: a 40-teacher campus returns in under 3 seconds ──────────────────
reset role;
insert into auth.users (id, email, aud, role, encrypted_password) select gen_random_uuid(), 'pt' || n || '@wlperf.test', 'authenticated', 'authenticated', 'x' from generate_series(1, 40) n;
insert into public.app_user (user_id, tenant_id, app_role, full_name) select id, :'ptenant_id', 'subject_teacher', 'PT ' || email from auth.users where email like 'pt%@wlperf.test';
insert into public.staff (tenant_id, campus_id, user_id, employee_code, cnic, gender, doj, full_name)
select :'ptenant_id', :'pcampus_id', u.user_id, 'PT-' || row_number() over (order by u.full_name), '42101-' || lpad((row_number() over (order by u.full_name))::text, 7, '0') || '-1', 'male', '2020-01-01', u.full_name
  from public.app_user u where u.tenant_id = :'ptenant_id' and u.app_role = 'subject_teacher';
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity) select :'ptenant_id', :'pcampus_id', :'psession_id', :'pclass1_id', 'P' || n, 30 from generate_series(1, 40) n;
insert into public.subject (tenant_id, code, name_en, name_ur) values (:'ptenant_id', 'MTH', 'Maths', 'ریاضی');
select id as pmth from public.subject where tenant_id = :'ptenant_id' \gset
insert into public.timetable_version (tenant_id, campus_id, session_id, shift, name, status, version_no, effective_from, effective_to, published_at)
values (:'ptenant_id', :'pcampus_id', :'psession_id', 'MORNING', 'v1', 'PUBLISHED', 1, :'monday'::date - 60, :'monday'::date + 90, now());
select id as ptv from public.timetable_version where tenant_id = :'ptenant_id' \gset
insert into public.timetable_slot (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, subject_id, staff_id)
select :'ptenant_id', :'pcampus_id', :'ptv', cs.id, d, p, :'pmth', s.user_id
  from public.staff s
  join public.class_section cs on cs.tenant_id = s.tenant_id and cs.name = 'P' || substr(s.employee_code, 4)
  cross join generate_series(1, 5) d cross join generate_series(1, 6) p
 where s.tenant_id = :'ptenant_id';
select app.fn_refresh_teacher_load();
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'ptenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'pcampus_id'))::text, true);
select clock_timestamp() as t0 \gset
select count(*) as n_rows from public.get_teacher_workload(:'pcampus_id'::uuid, :'iso') \gset
select (extract(epoch from clock_timestamp() - :'t0'::timestamptz) < 3) as fast \gset
select is(:'n_rows'::int, 40, 'AC4: the 40-teacher campus returns one row per teacher');
select ok(:'fast'::boolean, 'AC4: and returns in under 3 seconds');

select * from finish();
rollback;
