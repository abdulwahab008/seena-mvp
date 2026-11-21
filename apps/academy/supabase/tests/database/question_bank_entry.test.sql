-- pgTAP tests for typing questions into the bank, and building sets from them.
begin;
select plan(14);

select public.provision_tenant('test-bank-entry', 'Bank Entry Co', 'owner@bankentry.test');
select id as tenant_id from public.tenant where slug = 'test-bank-entry' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as other_uid \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@bankentry.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@bankentry.test', 'authenticated', 'authenticated', 'x'),
  (:'other_uid', 'x@bankentry.test', 'authenticated', 'authenticated', 'x'), (:'parent_uid', 'p@bankentry.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher'),
  (:'other_uid', :'tenant_id', 'subject_teacher', 'Other Teacher'), (:'parent_uid', :'tenant_id', 'parent', 'Parent');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_subject('PHY', 'Physics', 'طبیعیات') as s_phy \gset
select public.create_subject('CHE', 'Chemistry', 'کیمیا') as s_che \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_phy', 5::smallint) as cs_phy \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_che', 5::smallint) as cs_che \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class9'::uuid, 'A', 45) as sec9 \gset
select public.assign_subject_teacher(:'sec9', :'s_phy', :'teach_uid', current_date - 30) as _t \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T1', 'First Term', 1::smallint, 100.00) as term1 \gset
select public.activate_exam_terms(:'session_id'::uuid, :'campus_id'::uuid) as _a \gset
select public.upsert_exam_subject(:'term1', :'cs_phy', '[{"component":"theory","max_marks":65,"pass_marks":23}]'::jsonb) as es_phy \gset
select public.save_board_pattern('MINI', 'Two MCQs', 'FBISE'::public.board, '[{"no":1,"name":"A","type":"mcq","count":2,"marks_each":1}]'::jsonb) as pat \gset

-- The Physics teacher sees and writes Physics only.
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select array_agg(subject_name) from public.my_bank_class_subjects()), array['Physics'], 'a teacher is offered only the subject they teach');
select ok(public.add_bank_question(:'cs_phy', 'Ch.1', 'mcq', 1, 'What is the SI unit of force?', '["Newton","Joule","Watt","Pascal"]', 'A') is not null, 'the teacher adds an MCQ');
select public.add_bank_question(:'cs_phy', 'Ch.1', 'mcq', 1, 'What is the SI unit of energy?', '["Newton","Joule","Watt","Pascal"]', 'B');
select public.add_bank_question(:'cs_phy', 'Ch.1', 'mcq', 1, 'What is the SI unit of power?', '["Newton","Joule","Watt","Pascal"]', 'C');
select public.add_bank_question(:'cs_phy', 'Ch.1', 'mcq', 1, 'What is the SI unit of pressure?', '["Newton","Joule","Watt","Pascal"]', 'D') as q4 \gset
select ok(public.add_bank_question(:'cs_phy', 'Ch.2', 'short', 3, 'Define inertia.', null, 'Resistance to change in motion.') is not null, 'and a short question');
select throws_ok(format($$ select public.add_bank_question(%L, 'Ch.1', 'mcq', 1, '  what is the SI unit of FORCE? ', '["a","b","c","d"]', 'A') $$, :'cs_phy'), 'QUESTION_EXISTS', 'the same wording twice is refused');
select throws_ok(format($$ select public.add_bank_question(%L, 'Ch.1', 'mcq', 1, 'Three options?', '["a","b","c"]', 'A') $$, :'cs_phy'), 'MCQ_OPTIONS_INVALID', 'an MCQ needs four options');
select throws_ok(format($$ select public.add_bank_question(%L, 'Ch.1', 'mcq', 1, 'No answer?', '["a","b","c","d"]', null) $$, :'cs_phy'), 'MCQ_OPTIONS_INVALID', 'an MCQ needs an answer letter');
select throws_ok(format($$ select public.add_bank_question(%L, ' ', 'short', 2, 'No chapter?') $$, :'cs_phy'), 'CHAPTER_REQUIRED', 'a question needs a chapter');
select throws_ok(format($$ select public.add_bank_question(%L, 'Ch.1', 'short', 2, 'Not my subject?') $$, :'cs_che'), 'FORBIDDEN', 'not into a subject they do not teach');

-- Another teacher and a parent cannot write or retire.
select set_config('request.jwt.claims', json_build_object('sub', :'other_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.my_bank_class_subjects()), 0, 'a teacher with no subjects is offered nothing');
select throws_ok(format($$ select public.set_bank_question_active(%L, false) $$, :'q4'), 'FORBIDDEN', 'another teacher cannot retire the question');
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.add_bank_question(%L, 'Ch.1', 'short', 2, 'Parent question?') $$, :'cs_phy'), 'FORBIDDEN', 'a parent cannot add questions');

-- The typed questions are enough for two non-overlapping sets.
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(cardinality(public.build_paper_sets(:'es_phy'::uuid, :'pat'::uuid, array['Ch.1'], null, 2, 0)), 2, 'Set A and Set B are built from the typed questions');

-- Retired questions leave the pool: three active MCQs cannot fill two disjoint sets of two.
select public.set_bank_question_active(:'q4', false);
select is((select is_active from public.question_bank_item where id = :'q4'::uuid), false, 'the teacher retires a question');
select throws_ok(format($$ select public.build_paper_sets(%L, %L, array['Ch.1'], null, 2, 0, true) $$, :'es_phy', :'pat'), '22023', null, 'a retired question is no longer drawn');

select * from finish();
rollback;
