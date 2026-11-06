begin;
select plan(4);
select public.provision_tenant('test-edit-student-co', 'Edit Student Co', 'o@editstudent.test');
select id as tenant_id from public.tenant where slug = 'test-edit-student-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_student(:'campus_id'::uuid, 'Fatma Noor', '2018-07-20'::date, 'male') as sid \gset
select public.create_student(:'campus_id'::uuid, 'Other Kid', '2018-07-20'::date, 'male', p_b_form_no => '3520212345671') as other_id \gset

select lives_ok(format($$ select public.update_student_details(%L, 'Fatima Noor', '2018-07-21', 'female', p_b_form_no => '35202-7654321-1') $$, :'sid'),
  'an owner corrects a student''s name, date of birth, gender and B-Form');
select is((select name_en || ' ' || dob || ' ' || gender || ' ' || b_form_no from public.student where id = :'sid'::uuid),
  'Fatima Noor 2018-07-21 female 35202-7654321-1', 'the corrections are saved');
select throws_ok(format($$ select public.update_student_details(%L, 'Fatima Noor', '2018-07-21', 'female', p_b_form_no => '35202-1234567-1') $$, :'sid'),
  '23505', 'BFORM_DUPLICATE', 'another student''s B-Form is refused');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.update_student_details(%L, 'X', '2018-07-21', 'female') $$, :'sid'), '42501', 'FORBIDDEN', 'a teacher cannot edit student details');
select * from finish();
rollback;
