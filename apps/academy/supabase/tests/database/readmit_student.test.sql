-- pgTAP: a withdrawn student is readmitted in the same session by reopening that session's enrolment.
begin;
select plan(8);

select public.provision_tenant('test-readmit', 'Readmit Co', 'owner@readmit.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class5 from public.class_level where tenant_id = :'tenant_id' and code = '5' \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
values (:'tenant_id', :'campus_id', :'session_id', :'class5', '5-A', 30) returning id as sec_a \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
values (:'tenant_id', :'campus_id', :'session_id', :'class5', '5-B', 30) returning id as sec_b \gset
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender, status)
values (:'tenant_id', :'campus_id', 'GR-001', 'Amna Iqbal', '2015-01-01', 'female', 'active') returning id as amna \gset
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender, status, no_readmission_flag)
values (:'tenant_id', :'campus_id', 'GR-002', 'Bilal Shah', '2015-01-01', 'male', 'active', true) returning id as bilal \gset
insert into public.enrolment (tenant_id, campus_id, session_id, class_level_id, section_id, student_id, joined_on)
values (:'tenant_id', :'campus_id', :'session_id', :'class5', :'sec_a', :'amna', current_date - 30) returning id as amna_enrol \gset
insert into public.enrolment (tenant_id, campus_id, session_id, class_level_id, section_id, student_id, joined_on)
values (:'tenant_id', :'campus_id', :'session_id', :'class5', :'sec_a', :'bilal', current_date - 30);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.withdraw_student(:'amna'::uuid, current_date - 5, 'relocation');
select public.withdraw_student(:'bilal'::uuid, current_date - 5, 'disciplinary');

select is(public.fn_readmit_student(:'amna'::uuid, :'sec_b'::uuid), :'amna_enrol'::uuid, 'readmitting in the same session reopens that session''s enrolment');
select is((select status::text from public.student where id = :'amna'::uuid), 'active', 'the student is active again');
select is((select status::text || ' ' || coalesce(left_on::text, 'open') from public.enrolment where id = :'amna_enrol'::uuid), 'active open', 'the enrolment is open again');
select is((select section_id from public.enrolment where id = :'amna_enrol'::uuid), :'sec_b'::uuid, 'in the section chosen on return');
select is((select roll_no from public.enrolment where id = :'amna_enrol'::uuid), 1, 'with the next free roll number there');

select throws_ok(format('select public.fn_readmit_student(%L, %L)', :'bilal', :'sec_a'), 'READMISSION_BLOCKED', 'a principal cannot readmit a student flagged no readmission');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format('select public.fn_readmit_student(%L, %L)', :'bilal', :'sec_a'), 'OVERRIDE_REASON_REQUIRED', 'the owner must give a reason to override');
select lives_ok(format('select public.fn_readmit_student(%L, %L, %L)', :'bilal', :'sec_a', 'Apologised; parents met the principal'), 'and can then readmit');

select * from finish();
rollback;
