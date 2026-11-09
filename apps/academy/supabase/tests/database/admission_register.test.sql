begin;
select plan(9);

select public.provision_tenant('test-adm-register', 'Register Co', 'owner@register.test') as tenant_id \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'NORTH', 'North Campus') returning id as campus_b \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class5 from public.class_level where tenant_id = :'tenant_id' and code = '5' \gset
select id as class6 from public.class_level where tenant_id = :'tenant_id' and code = '6' \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
values (:'tenant_id', :'campus_a', :'session_id', :'class5', '5-A', 30) returning id as sec5 \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
values (:'tenant_id', :'campus_a', :'session_id', :'class6', '6-A', 30) returning id as sec6 \gset

insert into public.student (tenant_id, campus_id, gr_number, name_en, father_name_en, dob, gender, status)
values (:'tenant_id', :'campus_a', 'GR-002', 'Bilal Shah', 'Kamran Shah', '2014-03-01', 'male', 'left') returning id as bilal \gset
insert into public.student (tenant_id, campus_id, gr_number, name_en, father_name_en, dob, gender, status)
values (:'tenant_id', :'campus_a', 'GR-001', 'Amna Iqbal', 'Javed Iqbal', '2015-01-01', 'female', 'active') returning id as amna \gset
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender, status)
values (:'tenant_id', :'campus_b', 'GR-900', 'North Kid', '2015-01-01', 'male', 'active');
insert into public.enrolment (tenant_id, campus_id, session_id, class_level_id, section_id, student_id, joined_on)
values (:'tenant_id', :'campus_a', :'session_id', :'class5', :'sec5', :'amna', '2025-08-01');
insert into public.enrolment (tenant_id, campus_id, session_id, class_level_id, section_id, student_id, joined_on, status, left_on)
values (:'tenant_id', :'campus_a', :'session_id', :'class6', :'sec6', :'bilal', '2025-08-05', 'left', '2025-12-20');
insert into public.student_status_history (student_id, from_status, to_status, reason_code, reason_note, effective_date)
values (:'bilal', 'active', 'left', 'relocation', 'Moved to Lahore', '2025-12-31');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_a'))::text, true);

select is((select array_agg(gr_number) from public.admission_register()), array['GR-001', 'GR-002'], 'the register lists the campus''s students in GR order');
select is((select admitted_on from public.admission_register() where gr_number = 'GR-001'), '2025-08-01'::date, 'the admission date is the first enrolment''s');
select is((select class_admitted || ' / ' || father_name_en from public.admission_register() where gr_number = 'GR-001'), (select name_en from public.class_level where id = :'class5') || ' / Javed Iqbal', 'with the class admitted to and the father''s name');
select is((select withdrawn_on from public.admission_register() where gr_number = 'GR-002'), '2025-12-31'::date, 'a student who left shows the leaving date');
select is((select withdrawal_reason from public.admission_register() where gr_number = 'GR-002'), 'Relocation: Moved to Lahore', 'and the reason');
select is((select withdrawn_on from public.admission_register() where gr_number = 'GR-001'), null, 'a current student has no leaving date');
select is((select array_agg(gr_number) from public.admission_register(:'session_id', :'class6')), array['GR-002'], 'the class filter keeps students admitted to that class');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);
select is((select count(*)::int from public.admission_register()), 3, 'the owner sees every campus');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok($$ select * from public.admission_register() $$, '42501', 'FORBIDDEN', 'a teacher cannot read the register');

select * from finish();
rollback;
