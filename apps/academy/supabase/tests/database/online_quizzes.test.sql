begin;
select plan(11);

select public.provision_tenant('test-quiz-co', 'Quiz Co', 'owner@quiz.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select gen_random_uuid() as t_uid \gset
select gen_random_uuid() as s_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'t_uid', 't@quiz.test', 'authenticated', 'authenticated', 'x'), (:'s_uid', 's@quiz.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'t_uid', :'tenant_id', 'owner', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'t_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as sec \gset
select public.create_student(:'campus_id'::uuid, 'Quiz Kid', '2015-01-01'::date, 'male') as kid \gset
select public.enrol_student(:'sec'::uuid, :'kid'::uuid);

select set_config('request.jwt.claims', json_build_object('sub', :'t_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_quiz(:'sec', 'Fractions check', now() - interval '1 hour', now() + interval '1 day', 20::smallint) as quiz \gset
select public.add_quiz_question(:'quiz', '1/2 + 1/4 = ?', array['1/4', '3/4', '2/6'], 1::smallint, 2::smallint);
select public.add_quiz_question(:'quiz', 'Half of 10?', array['5', '2'], 0::smallint, 1::smallint);
select throws_ok(format($$ select public.add_quiz_question(%L, 'x', array['a'], 0::smallint) $$, :'quiz'), '23514', null, 'a question needs at least two options');
select public.publish_quiz(:'quiz');
select throws_ok(format($$ select public.add_quiz_question(%L, 'x', array['a','b'], 0::smallint) $$, :'quiz'), '22023', 'QUIZ_PUBLISHED', 'a published quiz cannot be changed');

reset role;
insert into public.student_portal_account (tenant_id, campus_id, student_id, user_id, must_change_password) values (:'tenant_id', :'campus_id', :'kid', :'s_uid', false);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'s_uid', 'tenant_id', :'tenant_id', 'app_role', 'student', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select is((select count(*)::int from public.my_quizzes()), 1, 'the student sees the published quiz for their section');
select public.start_quiz_attempt(:'quiz') as started \gset
select is(jsonb_array_length(:'started'::jsonb -> 'questions'), 2, 'starting returns the questions');
select ok(not (:'started'::jsonb -> 'questions' -> 0 ? 'correct_index'), 'without the correct answers');
select is((select count(*)::int from public.quiz_question), 0, 'and the student cannot read the question table');
select is(public.submit_quiz_attempt(:'quiz', array[1, 1]::smallint[]) ->> 'score', '2', 'the server marks the attempt');
select throws_ok(format($$ select public.submit_quiz_attempt(%L, array[1,0]::smallint[]) $$, :'quiz'), '22023', 'ALREADY_SUBMITTED', 'one attempt only');
select is((select score from public.my_quizzes()), 2, 'the student sees their score');

select set_config('request.jwt.claims', json_build_object('sub', :'t_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select max_score from public.quiz_attempt where quiz_id = :'quiz'), 3, 'the teacher sees the attempt out of the total marks');

select set_config('request.jwt.claims', json_build_object('sub', :'s_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.quiz), 0, 'parents cannot read quizzes directly');

select * from finish();
rollback;
