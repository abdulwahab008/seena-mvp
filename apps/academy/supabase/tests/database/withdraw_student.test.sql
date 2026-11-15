-- pgTAP: withdrawing a student closes the student record and the class enrolment together.
begin;
select plan(9);

select public.provision_tenant('test-withdraw', 'Withdraw Co', 'owner@withdraw.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class5 from public.class_level where tenant_id = :'tenant_id' and code = '5' \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
values (:'tenant_id', :'campus_id', :'session_id', :'class5', '5-A', 30) returning id as sec5 \gset
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender, status)
values (:'tenant_id', :'campus_id', 'GR-001', 'Amna Iqbal', '2015-01-01', 'female', 'active') returning id as amna \gset
insert into public.enrolment (tenant_id, campus_id, session_id, class_level_id, section_id, student_id, joined_on)
values (:'tenant_id', :'campus_id', :'session_id', :'class5', :'sec5', :'amna', current_date - 30) returning id as enrol_id \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format('select public.withdraw_student(%L, current_date, %L)', :'amna', 'relocation'), 'FORBIDDEN', 'an admissions officer cannot withdraw a student');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format('select public.withdraw_student(%L, current_date + 5, %L)', :'amna', 'relocation'), 'LEAVING_DATE_INVALID', 'the leaving date cannot be in the future');
select throws_ok(format('select public.withdraw_student(%L, current_date - 60, %L)', :'amna', 'relocation'), 'LEAVING_DATE_INVALID', 'nor before the student joined the class');
select throws_ok(format('select public.withdraw_student(%L, current_date, %L)', :'amna', 'promotion'), 'REASON_INVALID', 'promotion is not a reason to leave');

select lives_ok(format('select public.withdraw_student(%L, current_date - 1, %L, %L)', :'amna', 'relocation', 'Moved to Lahore'), 'a principal withdraws the student');
select is((select status::text from public.student where id = :'amna'::uuid), 'left', 'the student is marked left');
select is((select status::text || ' ' || left_on from public.enrolment where id = :'enrol_id'::uuid), 'left ' || (current_date - 1), 'the enrolment is closed on the leaving date');
select is((select reason_code::text || ' ' || reason_note from public.student_status_history where student_id = :'amna'::uuid), 'relocation Moved to Lahore', 'the reason is on the status history');
select throws_ok(format('select public.withdraw_student(%L, current_date, %L)', :'amna', 'relocation'), 'STUDENT_NOT_ACTIVE', 'a student who has left cannot be withdrawn again');

select * from finish();
rollback;
