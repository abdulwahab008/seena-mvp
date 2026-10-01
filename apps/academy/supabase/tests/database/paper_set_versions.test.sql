-- pgTAP tests for FR-I07: Set A and Set B paper versions.
--
--   AC1  A 65-mark blueprint, 2 sets: each totals 65 with identical per-section
--        marks and identical per-(section, chapter) question counts.
--   AC2  Set B has 12 MCQs from Chapter 2, at most 2 identical to Set A.
--   AC3  Only 14 usable Chapter 2 MCQs for a 24-item requirement: it fails with
--        insufficient_pool: Ch.2 MCQ rather than near-duplicate sets.
--   AC4  The key is per set: the path (and so the filename) carries the set code.
-- Plus uq_paper_set, the same two checks on a worker-generated multi-set result,
-- and that a published paper is never replaced by a fresh generation.
begin;
select plan(43);

select public.provision_tenant('test-sets-co', 'Sets Co', 'owner@sets.test');
select id as tenant_id from public.tenant where slug = 'test-sets-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select id as class10 from public.class_level where tenant_id = :'tenant_id' and code = '10' \gset
select id as class8 from public.class_level where tenant_id = :'tenant_id' and code = '8' \gset
select id as class6 from public.class_level where tenant_id = :'tenant_id' and code = '6' \gset
select public.provision_tenant('test-sets-other', 'Other Sets Co', 'owner@othersets.test');
select id as other_tenant_id from public.tenant where slug = 'test-sets-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@sets.test', 'authenticated', 'authenticated', 'x'), (:'ec_uid', 'e@sets.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@sets.test', 'authenticated', 'authenticated', 'x'), (:'parent_uid', 'p@sets.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Exam Controller'),
  (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher'), (:'parent_uid', :'tenant_id', 'parent', 'Parent');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_subject('PHY', 'Physics', 'طبیعیات') as s_phy \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_phy', 5::smallint) as cs9 \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class10', :'s_phy', 5::smallint) as cs10 \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class8', :'s_phy', 5::smallint) as cs8 \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class6', :'s_phy', 5::smallint) as cs6 \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T1', 'First Term', 1::smallint, 100.00) as t1 \gset
select public.activate_exam_terms(:'session_id'::uuid, :'campus_id'::uuid) as _a \gset
select public.upsert_exam_subject(:'t1', :'cs9', '[{"component":"theory","max_marks":65,"pass_marks":23}]'::jsonb) as es9 \gset
select public.upsert_exam_subject(:'t1', :'cs10', '[{"component":"theory","max_marks":12,"pass_marks":4}]'::jsonb) as es10 \gset
select public.upsert_exam_subject(:'t1', :'cs8', '[{"component":"theory","max_marks":12,"pass_marks":4}]'::jsonb) as es8 \gset
select public.upsert_exam_subject(:'t1', :'cs6', '[{"component":"theory","max_marks":4,"pass_marks":1}]'::jsonb) as es6 \gset
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_board_pattern('FBISE-PHY-9', 'FBISE Physics IX', 'FBISE'::public.board,
  '[{"no":1,"name":"A","type":"mcq","count":24,"marks_each":1},{"no":2,"name":"B","type":"short","count":9,"marks_each":3},{"no":3,"name":"C","type":"long","count":1,"marks_each":14}]'::jsonb) as pat65 \gset
select public.save_board_pattern('MCQ12', 'Twelve MCQs', 'FBISE'::public.board, '[{"no":1,"name":"A","type":"mcq","count":12,"marks_each":1}]'::jsonb) as pat12 \gset
select public.save_board_pattern('MCQ4', 'Four MCQs', 'FBISE'::public.board, '[{"no":1,"name":"A","type":"mcq","count":4,"marks_each":1}]'::jsonb) as pat4 \gset

reset role;
-- The bank. Class 9: plenty. Class 10: 22 usable Ch.2 MCQs. Class 8: only 14.
insert into public.question_bank_item (tenant_id, campus_id, subject_id, class_level_id, chapter, marks, question_type, question_text)
select :'tenant_id', :'campus_id', :'s_phy', :'class9', c.chapter, c.marks, c.qt, 'C9 ' || c.qt || ' ' || c.chapter || ' #' || g
  from (values ('Ch.1', 1, 'mcq', 30), ('Ch.2', 1, 'mcq', 30), ('Ch.1', 3, 'short', 12), ('Ch.2', 3, 'short', 10), ('Ch.3', 14, 'long', 4)) c(chapter, marks, qt, n),
       lateral generate_series(1, c.n) g;
insert into public.question_bank_item (tenant_id, campus_id, subject_id, class_level_id, chapter, marks, question_type, question_text)
select :'tenant_id', :'campus_id', :'s_phy', :'class10', 'Ch.2', 1, 'mcq', 'C10 mcq Ch.2 #' || g from generate_series(1, 22) g;
insert into public.question_bank_item (tenant_id, campus_id, subject_id, class_level_id, chapter, marks, question_type, question_text)
select :'tenant_id', :'campus_id', :'s_phy', :'class8', 'Ch.2', 1, 'mcq', 'C8 mcq Ch.2 #' || g from generate_series(1, 14) g;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── AC1 / AC2: the 65-mark blueprint in two sets ──────────────────────────
select public.build_paper_sets(:'es9'::uuid, :'pat65'::uuid, null,
  '[{"section_no":1,"chapter":"Ch.1","count":12},{"section_no":1,"chapter":"Ch.2","count":12},{"section_no":2,"chapter":"Ch.1","count":5},{"section_no":2,"chapter":"Ch.2","count":4},{"section_no":3,"chapter":"Ch.3","count":1}]'::jsonb, 2) as sets \gset
select is(cardinality(:'sets'::uuid[]), 2, 'two set papers are built');
select (:'sets'::uuid[])[1] as paper_a, (:'sets'::uuid[])[2] as paper_b \gset
select is((select array_agg(set_code::text order by set_code) from public.exam_paper where id in (:'paper_a', :'paper_b')), array['A', 'B'], 'they are Set A and Set B');
select is((select sum(marks) from public.exam_paper_item where paper_id = :'paper_a'::uuid), 65::bigint, 'AC1: Set A totals 65 marks');
select is((select sum(marks) from public.exam_paper_item where paper_id = :'paper_b'::uuid), 65::bigint, 'AC1: Set B totals 65 marks');
select ok((select bool_and(marks_a = marks_b) from public.fn_paper_set_report(:'paper_a'::uuid, :'paper_b'::uuid)), 'AC1: identical marks per section');
select ok((select bool_and(count_a = count_b) from public.fn_paper_set_report(:'paper_a'::uuid, :'paper_b'::uuid)), 'AC1: identical question counts per (section, chapter)');
select is((select count(*) from public.fn_paper_set_report(:'paper_a'::uuid, :'paper_b'::uuid)), 5::bigint, 'AC1: across the five chapter groups');
select is((select count_b from public.fn_paper_set_report(:'paper_a'::uuid, :'paper_b'::uuid) where section_no = 1 and chapter = 'Ch.2'), 12, 'AC2: Set B has 12 MCQs from Chapter 2');
select ok((select identical <= 2 from public.fn_paper_set_report(:'paper_a'::uuid, :'paper_b'::uuid) where section_no = 1 and chapter = 'Ch.2'), 'AC2: at most 2 identical to Set A');
select is(public.fn_paper_set_divergence(:'paper_a'::uuid, :'paper_b'::uuid), 0::numeric, 'with a deep bank the two sets share no question at all');
select is((select count(distinct bank_item_id) from public.exam_paper_item where paper_id in (:'paper_a', :'paper_b')), 68::bigint, 'two sets of 34 questions use 68 different bank questions');
select is((select set_count from public.exam_paper_set_group where exam_subject_id = :'es9'::uuid), 2::smallint, 'the exam subject now records two sets (the seating plan alternates them)');
select is((select status from public.exam_paper where id = :'paper_b'::uuid), 'draft', 'the sets are drafts until published');

-- ── AC2: 22 usable questions -> exactly 2 shared ──────────────────────────
select public.build_paper_sets(:'es10'::uuid, :'pat12'::uuid, array['Ch.2'], null, 2) as sets10 \gset
select (:'sets10'::uuid[])[1] as p10a, (:'sets10'::uuid[])[2] as p10b \gset
select is((select identical from public.fn_paper_set_report(:'p10a'::uuid, :'p10b'::uuid) where chapter = 'Ch.2'), 2, 'AC2: with only 22 usable questions Set B shares exactly the 2 it must');
select is(public.fn_paper_set_divergence(:'p10a'::uuid, :'p10b'::uuid), round(2::numeric / 12, 4), 'fn_paper_set_divergence reports 2 of 12 questions shared');
select is((select count(*) from public.exam_paper_item where paper_id = :'p10b'::uuid), 12::bigint, 'and Set B is still a full 12 questions');

-- ── AC3: 14 usable for a 24-item requirement ──────────────────────────────
select throws_ok(format($$ select public.build_paper_sets(%L, %L, array['Ch.2'], null, 2) $$, :'es8', :'pat12'), 'insufficient_pool: Ch.2 MCQ', 'AC3: 14 usable Ch.2 MCQs for 2 x 12 fail with insufficient_pool: Ch.2 MCQ');
select is((select count(*) from public.exam_paper where exam_subject_id = :'es8'::uuid), 0::bigint, 'AC3: and no near-duplicate sets were emitted');
select is((select count(*) from public.paper_generation_job where exam_subject_id = :'es8'::uuid), 0::bigint, 'AC3: nor a job record');
select lives_ok(format($$ select public.build_paper_sets(%L, %L, array['Ch.2'], null, 1) $$, :'es8', :'pat12'), 'a single set from the same 14 questions is fine');

-- ── uq_paper_set and replacing drafts ─────────────────────────────────────
select throws_ok(format($$ select public.build_paper_sets(%L, %L, array['Ch.2'], null, 2) $$, :'es10', :'pat12'), 'PAPER_SET_EXISTS', 'building again without replace is refused');
select lives_ok(format($$ select public.build_paper_sets(%L, %L, array['Ch.2'], null, 2, 2, true) $$, :'es10', :'pat12'), 'with replace the old drafts are superseded');
select is((select count(*) from public.exam_paper where exam_subject_id = :'es10'::uuid and status = 'superseded'), 2::bigint, 'two superseded drafts remain on record');
select is((select count(*) from public.exam_paper where exam_subject_id = :'es10'::uuid and status = 'draft'), 2::bigint, 'and exactly one live paper per set code');
reset role;
select throws_ok(format($$ insert into public.exam_paper (tenant_id, campus_id, job_id, exam_subject_id, set_code, title, total_marks, pattern_snapshot, created_by)
  select tenant_id, campus_id, job_id, exam_subject_id, set_code, 'dup', total_marks, pattern_snapshot, created_by from public.exam_paper where id = %L $$, :'p10a'), '23505', null, 'uq_paper_set refuses a second live Set A for one exam subject');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── AC4: the key is bound to its set at the storage path ──────────────────
select is((select paper_path from public.fn_exam_paper_file_paths(:'paper_b'::uuid)), :'tenant_id' || '/' || :'es9' || '/set-B.pdf', 'AC4: Set B''s paper is stored under set-B.pdf');
select is((select key_path from public.fn_exam_paper_file_paths(:'paper_b'::uuid)), :'tenant_id' || '/' || :'es9' || '/key-B.pdf', 'AC4: and its answer key under key-B.pdf');
select is((select key_path from public.fn_exam_paper_file_paths(:'paper_a'::uuid)), :'tenant_id' || '/' || :'es9' || '/key-A.pdf', 'AC4: Set A''s key is key-A.pdf');
select isnt((select key_path from public.fn_exam_paper_file_paths(:'paper_a'::uuid)), (select key_path from public.fn_exam_paper_file_paths(:'paper_b'::uuid)), 'AC4: the two keys are different files');

-- ── worker-generated sets: the same checks at ingest ──────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
reset role;
-- Four MCQs per set: two from Ch.1 (texts a1,a2), two from Ch.2 (texts b1,b2), the texts prefixed per set.
create function pg_temp.mkset(p_code text, p_ch1 int, p_same_as_a int default 0) returns jsonb language sql as $$
  select jsonb_build_object('set_code', p_code, 'title', 'Set ' || p_code, 'questions',
    (select jsonb_agg(jsonb_build_object('section_no', 1, 'question_no', n, 'type', 'mcq', 'marks', 1,
        'text', case when p_code = 'A' or n <= p_same_as_a then 'Shared question ' || n else 'Set ' || p_code || ' question ' || n end,
        'chapter', case when n <= p_ch1 then 'Ch.1' else 'Ch.2' end, 'verbatim_ratio', 0) order by n) from generate_series(1, 4) n));
$$;
create function pg_temp.newjob() returns uuid language plpgsql as $$
declare v uuid;
begin
  select public.request_paper_generation(es.id, p.id, array['Ch.1', 'Ch.2'], 4, 2) into v
    from public.exam_subject es, public.board_pattern_ref p where es.id = current_setting('test.es6')::uuid and p.code = 'MCQ4' and p.tenant_id = es.tenant_id;
  return v;
end $$;
select set_config('test.es6', :'es6', false);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select pg_temp.newjob() as job1 \gset
reset role;
select (public.fn_ingest_generated_paper(:'job1'::uuid, jsonb_build_object('sets', jsonb_build_array(pg_temp.mkset('A', 2), pg_temp.mkset('B', 3))))) ->> 'detail' as d1 \gset
select is((select status from public.paper_generation_job where id = :'job1'::uuid), 'pattern_mismatch', 'a set B with a different chapter split is rejected');
select ok(:'d1'::text like 'set B has 3 questions of Ch.1 in section 1, set A has 2', 'naming the chapter and both counts');
select is((select count(*) from public.exam_paper where job_id = :'job1'::uuid), 0::bigint, 'and nothing is stored');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select pg_temp.newjob() as job2 \gset
reset role;
select (public.fn_ingest_generated_paper(:'job2'::uuid, jsonb_build_object('sets', jsonb_build_array(pg_temp.mkset('A', 2), pg_temp.mkset('B', 2, 4))))) ->> 'detail' as d2 \gset
select ok(:'d2'::text like 'set B repeats too many questions of set A%', 'a set B that repeats the same questions is rejected as near-duplicate');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select pg_temp.newjob() as job3 \gset
reset role;
select (public.fn_ingest_generated_paper(:'job3'::uuid, jsonb_build_object('sets', jsonb_build_array(pg_temp.mkset('A', 2), pg_temp.mkset('B', 2))))) ->> 'status' as s3 \gset
select is(:'s3'::text, 'completed', 'two sets with one blueprint and different questions are accepted');
select is((select count(*) from public.exam_paper where job_id = :'job3'::uuid and status = 'draft'), 2::bigint, 'as two drafts');
select is((select set_count from public.exam_paper_set_group where exam_subject_id = :'es6'::uuid), 2::smallint, 'and the exam subject records two sets');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select pg_temp.newjob() as job4 \gset
reset role;
select (public.fn_ingest_generated_paper(:'job4'::uuid, jsonb_build_object('sets', jsonb_build_array(pg_temp.mkset('A', 2), pg_temp.mkset('B', 2))))) ->> 'status' as s4 \gset
select is(:'s4'::text, 'completed', 'a fresh generation supersedes the earlier drafts');
select is((select count(*) from public.exam_paper where exam_subject_id = :'es6'::uuid and status = 'superseded'), 2::bigint, 'the old drafts are kept as superseded');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.publish_exam_paper(id) from public.exam_paper where exam_subject_id = :'es6'::uuid and status = 'draft' and set_code = 'A';
select pg_temp.newjob() as job5 \gset
reset role;
select (public.fn_ingest_generated_paper(:'job5'::uuid, jsonb_build_object('sets', jsonb_build_array(pg_temp.mkset('A', 2), pg_temp.mkset('B', 2))))) ->> 'status' as s5 \gset
select is(:'s5'::text, 'failed', 'a published paper is never replaced by a fresh generation');
select is((select count(*) from public.exam_paper where job_id = :'job5'::uuid), 0::bigint, 'and no second live paper appears');

-- ── roles ─────────────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.build_paper_sets(%L, %L, array['Ch.2'], null, 2) $$, :'es9', :'pat12'), 'FORBIDDEN', 'a teacher who does not teach the subject cannot build sets');
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select throws_ok(format($$ select public.fn_paper_set_divergence(%L, %L) $$, :'paper_a', :'paper_b'), 'FORBIDDEN', 'a parent cannot compare papers');
select throws_ok(format($$ select * from public.fn_exam_paper_file_paths(%L) $$, :'paper_a'), 'FORBIDDEN', 'or learn where they are stored');

select * from finish();
rollback;
