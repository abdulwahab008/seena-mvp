begin;
select plan(17);

select public.provision_tenant('test-records-extra', 'Records Extra Co', 'owner@recordsextra.test') as tenant_id \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'NORTH', 'North Campus') returning id as campus_b \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class_id from public.class_level where tenant_id = :'tenant_id' and code = '5' \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
values (:'tenant_id', :'campus_a', :'session_id', :'class_id', '5-A', 30) returning id as section_a \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
values (:'tenant_id', :'campus_b', :'session_id', :'class_id', '5-N', 30) returning id as section_b \gset

insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender, status)
values (:'tenant_id', :'campus_a', 'GR-1', 'Zara Khan', '2015-01-01', 'female', 'active') returning id as zara \gset
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender, status)
values (:'tenant_id', :'campus_a', 'GR-1-DUP', 'Zara Khan', '2015-01-01', 'female', 'active') returning id as zara_dup \gset
insert into public.enrolment (tenant_id, campus_id, session_id, class_level_id, section_id, student_id)
values (:'tenant_id', :'campus_a', :'session_id', :'class_id', :'section_a', :'zara') returning id as zara_enrol \gset
insert into public.section_membership_history (enrolment_id, section_id, from_date) values (:'zara_enrol', :'section_a', current_date - 30);
insert into public.guardian (tenant_id, name_en, phone_e164) values (:'tenant_id', 'Mother of Zara', '+923004440000') returning id as mother \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id', :'zara_dup', :'mother', 'mother', true, true);

set local role authenticated;

-- Campus transfer: A asks, B decides.
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok(format($$ select public.request_campus_transfer(%L, %L, 'x') $$, :'zara_enrol', :'section_a'), '22023', 'SAME_CAMPUS', 'a move within the campus is not a transfer');
select public.request_campus_transfer(:'zara_enrol', :'section_b', 'Family moved to the north of the city') as transfer_id \gset
select throws_ok(format($$ select public.decide_campus_transfer(%L, true, null) $$, :'transfer_id'), '42501', 'FORBIDDEN', 'the sending campus cannot approve its own request');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_b'))::text, true);
select public.decide_campus_transfer(:'transfer_id', true, 'Welcome');
reset role;
select is((select campus_id from public.student where id = :'zara'), :'campus_b'::uuid, 'approval moves the student to the new campus');
select is((select section_id from public.enrolment where id = :'zara_enrol'), :'section_b'::uuid, 'and into the new section');
select is((select count(*)::int from public.section_membership_history where enrolment_id = :'zara_enrol' and to_date is null), 1, 'with one open section membership');
select is((select section_id from public.section_membership_history where enrolment_id = :'zara_enrol' and to_date is null), :'section_b'::uuid, 'which is the new one');
set local role authenticated;
select throws_ok(format($$ select public.decide_campus_transfer(%L, false, null) $$, :'transfer_id'), '55000', 'TRANSFER_DECIDED', 'a decided transfer is final');

-- Vaccinations.
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'nurse', 'campus_ids', json_build_array(:'campus_b'))::text, true);
select public.save_student_vaccination(:'zara', 'Typhoid', 1, current_date + 10, null, null);
select public.save_student_vaccination(:'zara', 'typhoid', 1, current_date + 10, current_date, 'Given at school');
select is((select count(*)::int || ' ' || (given_on is not null)::text from public.student_vaccination group by given_on), '1 true', 'the same dose is updated, not duplicated');
select throws_ok(format($$ select public.save_student_vaccination(%L, 'Polio', 1, null, current_date + 1, null) $$, :'zara'), '22023', 'DATE_INVALID', 'a dose cannot be given in the future');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_b'))::text, true);
select throws_ok(format($$ select public.save_student_vaccination(%L, 'Polio', 1, current_date, null, null) $$, :'zara'), '42501', 'FORBIDDEN', 'a subject teacher cannot record vaccinations');
select is((select count(*)::int from public.student_vaccination), 0, 'or read them');

-- Merge: the duplicate's guardian moves to the kept record.
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);
select is((select row_count from public.preview_student_merge(:'zara', :'zara_dup') where table_name = 'student_guardian'), 1::bigint, 'the preview shows what will move');
select ok(public.merge_students(:'zara', :'zara_dup') >= 1, 'the merge moves the rows');
reset role;
select is((select student_id from public.student_guardian where guardian_id = :'mother'), :'zara'::uuid, 'the guardian now belongs to the kept record');
select isnt((select deleted_at from public.student where id = :'zara_dup'), null, 'the duplicate goes to the recycle bin');

-- A merge that would create two enrolments in one session is refused whole.
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender, status)
values (:'tenant_id', :'campus_b', 'GR-2', 'Zara K', '2015-01-01', 'female', 'active') returning id as zara_dup2 \gset
insert into public.enrolment (tenant_id, campus_id, session_id, class_level_id, section_id, student_id)
values (:'tenant_id', :'campus_b', :'session_id', :'class_id', :'section_b', :'zara_dup2');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);
select throws_ok(format($$ select public.merge_students(%L, %L) $$, :'zara', :'zara_dup2'), '23505', 'MERGE_CONFLICT', 'two enrolments in one session block the merge');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_b'))::text, true);
select throws_ok(format($$ select public.merge_students(%L, %L) $$, :'zara', :'zara_dup2'), '42501', 'FORBIDDEN', 'only the owner or a principal can merge');

select * from finish();
rollback;
