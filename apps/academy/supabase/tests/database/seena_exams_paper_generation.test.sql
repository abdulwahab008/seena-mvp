-- pgTAP tests for FR-I05: Seena Exams paper generation.
--
--   AC1  A request for Class 9 Physics, an FBISE 65-mark pattern, chapters 1-4,
--        writes a paper_generation_job row 'queued' immediately.
--   AC2  The callback must match the pattern exactly (65 of 65): otherwise the
--        job is 'pattern_mismatch' and no paper is stored.
--   AC3  An unreachable worker is retried three times with exponential backoff,
--        then the job is 'failed' (with a retry action) and no partial paper exists.
--   AC4  The same callback delivered twice leaves exactly one exam_paper per job.
-- Plus the copyright guard (runs before anything is stored), role scoping and
-- the service-only worker functions.
begin;
select plan(50);

select public.provision_tenant('test-paperjob-co', 'Paper Job Co', 'owner@paperjob.test');
select id as tenant_id from public.tenant where slug = 'test-paperjob-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select public.provision_tenant('test-paperjob-other', 'Other Paper Job Co', 'owner@otherpaperjob.test');
select id as other_tenant_id from public.tenant where slug = 'test-paperjob-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as other_teach_uid \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@paperjob.test', 'authenticated', 'authenticated', 'x'), (:'ec_uid', 'e@paperjob.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@paperjob.test', 'authenticated', 'authenticated', 'x'), (:'other_teach_uid', 't2@paperjob.test', 'authenticated', 'authenticated', 'x'),
  (:'parent_uid', 'p@paperjob.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Exam Controller'),
  (:'teach_uid', :'tenant_id', 'subject_teacher', 'Physics Teacher'), (:'other_teach_uid', :'tenant_id', 'subject_teacher', 'Other Teacher'),
  (:'parent_uid', :'tenant_id', 'parent', 'Parent');

-- Builds a callback payload: 12 MCQs x 1, 9 short x 3, 2 long x p_long_marks (13 -> 65 marks).
create function pg_temp.mkpaper(p_set text default 'A', p_long_marks int default 13, p_ratio numeric default 0) returns jsonb language sql as $$
  select jsonb_build_object('set_code', p_set, 'title', 'Physics IX', 'questions',
    (select jsonb_agg(q order by (q ->> 'section_no')::int, (q ->> 'question_no')::int) from (
       select jsonb_build_object('section_no', 1, 'question_no', g, 'type', 'mcq', 'marks', 1, 'text', 'MCQ ' || g, 'options', '["a","b","c","d"]'::jsonb, 'answer', 'a',
                                 'chapter', 'Ch.1', 'topic_tag', 'motion', 'slo_code', 'P-09-' || g, 'source_pages', '[12,13]'::jsonb, 'verbatim_ratio', p_ratio) q from generate_series(1, 12) g
       union all select jsonb_build_object('section_no', 2, 'question_no', g, 'type', 'short', 'marks', 3, 'text', 'Short ' || g, 'chapter', 'Ch.2', 'verbatim_ratio', 0) from generate_series(1, 9) g
       union all select jsonb_build_object('section_no', 3, 'question_no', g, 'type', 'long', 'marks', p_long_marks, 'text', 'Long ' || g, 'chapter', 'Ch.3', 'verbatim_ratio', 0) from generate_series(1, 2) g
     ) x));
$$;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_subject('PHY', 'Physics', 'طبیعیات') as s_phy \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_phy', 5::smallint) as cs_phy \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class9'::uuid, 'A', 45) as sec9 \gset
select public.assign_subject_teacher(:'sec9', :'s_phy', :'teach_uid', current_date - 30) as _t \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T1', 'First Term', 1::smallint, 100.00) as term1 \gset
select public.activate_exam_terms(:'session_id'::uuid, :'campus_id'::uuid) as _a \gset
select public.upsert_exam_subject(:'term1', :'cs_phy', '[{"component":"theory","max_marks":65,"pass_marks":23}]'::jsonb) as es_phy \gset

select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_board_pattern('FBISE-PHY-9', 'FBISE Physics IX (65)', 'FBISE'::public.board,
  '[{"no":1,"name":"Section A","type":"mcq","count":12,"marks_each":1},{"no":2,"name":"Section B","type":"short","count":9,"marks_each":3},{"no":3,"name":"Section C","type":"long","count":2,"marks_each":13}]'::jsonb) as pat \gset
select is((select total_marks from public.board_pattern_ref where id = :'pat'::uuid), 65, 'the pattern totals 65 marks (12 + 27 + 26)');
select throws_ok($$ select public.save_board_pattern('BAD', 'Bad', 'FBISE', '[{"no":1,"type":"essay","count":1,"marks_each":1}]'::jsonb) $$, 'PATTERN_SECTIONS_INVALID', 'a section of an unknown type is refused');

-- ── AC1: the request is a row, queued ─────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.request_paper_generation(:'es_phy'::uuid, :'pat'::uuid, array['Ch.1', 'Ch.2', 'Ch.3', 'Ch.4'], 65) as job1 \gset
select is((select status from public.paper_generation_job where id = :'job1'::uuid), 'queued', 'AC1: the job is queued');
select ok((select created_at >= now() - interval '2 seconds' from public.paper_generation_job where id = :'job1'::uuid), 'AC1: created within 2 seconds of the request');
select is((select pattern_snapshot -> 'total_marks' from public.paper_generation_job where id = :'job1'::uuid), '65'::jsonb, 'the pattern is snapshotted onto the job');
select is((select cardinality(chapters) from public.paper_generation_job where id = :'job1'::uuid), 4, 'with the four chapters');
select throws_ok(format($$ select public.request_paper_generation(%L, %L, array['Ch.1'], 70) $$, :'es_phy', :'pat'), 'PATTERN_TOTAL_MISMATCH', 'a total other than the pattern''s 65 is refused');
select throws_ok(format($$ select public.request_paper_generation(%L, %L, '{}', 65) $$, :'es_phy', :'pat'), 'CHAPTERS_REQUIRED', 'a request needs chapters');
select set_config('request.jwt.claims', json_build_object('sub', :'other_teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.request_paper_generation(%L, %L, array['Ch.1'], 65) $$, :'es_phy', :'pat'), 'FORBIDDEN', 'a teacher of another subject cannot request this paper');

-- ── AC2: the callback must equal the pattern exactly ──────────────────────
reset role;
select (public.fn_ingest_generated_paper(:'job1'::uuid, jsonb_build_object('sets', jsonb_build_array(pg_temp.mkpaper('A'))))) ->> 'status' as ok_status \gset
select is(:'ok_status'::text, 'completed', 'AC2: an exact 65-of-65 paper completes the job');
select is((select count(*) from public.exam_paper where job_id = :'job1'::uuid), 1::bigint, 'AC2: one paper is stored');
select is((select count(*) from public.exam_paper_item where paper_id = (select id from public.exam_paper where job_id = :'job1'::uuid)), 23::bigint, 'AC2: with its 23 questions');
select is((select sum(marks) from public.exam_paper_item where paper_id = (select id from public.exam_paper where job_id = :'job1'::uuid)), 65::bigint, 'AC2: totalling 65 marks');
select is((select slo_code from public.exam_paper_item where paper_id = (select id from public.exam_paper where job_id = :'job1'::uuid) and section_no = 1 and question_no = 3), 'P-09-3', 'questions keep their SLO code, topic tag and source pages');
select is((select source_pages from public.exam_paper_item where paper_id = (select id from public.exam_paper where job_id = :'job1'::uuid) and section_no = 1 and question_no = 1), '[12,13]'::jsonb, 'source pages are stored as jsonb');

-- a paper of 64 marks (a long question one mark short)
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.request_paper_generation(:'es_phy'::uuid, :'pat'::uuid, array['Ch.1'], 65) as job2 \gset
reset role;
select (public.fn_ingest_generated_paper(:'job2'::uuid, jsonb_build_object('sets', jsonb_build_array(pg_temp.mkpaper('A', 12))))) ->> 'status' as bad_status \gset
select is(:'bad_status'::text, 'pattern_mismatch', 'AC2: marks that do not match the pattern end the job pattern_mismatch');
select is((select count(*) from public.exam_paper where job_id = :'job2'::uuid), 0::bigint, 'AC2: and no paper is stored');
select is((select count(*) from public.exam_paper_item i join public.exam_paper p on p.id = i.paper_id where p.job_id = :'job2'::uuid), 0::bigint, 'AC2: nor any question');
select ok((select last_error like '%carries 12 marks, expected 13%' from public.paper_generation_job where id = :'job2'::uuid), 'AC2: the job says which question deviates');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.request_paper_generation(:'es_phy'::uuid, :'pat'::uuid, array['Ch.1'], 65) as job3 \gset
reset role;
select (public.fn_ingest_generated_paper(:'job3'::uuid, jsonb_build_object('sets', jsonb_build_array(jsonb_set(pg_temp.mkpaper('A'), '{questions}', (pg_temp.mkpaper('A') -> 'questions') - 0))))) ->> 'status' as short_status \gset
select is(:'short_status'::text, 'pattern_mismatch', 'AC2: a missing question (section count short) ends the job pattern_mismatch');
select ok((select last_error like 'set A: section 1 has 11 questions, expected 12%' from public.paper_generation_job where id = :'job3'::uuid), 'AC2: naming the section and the counts');

-- ── the copyright guard runs before storage ───────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.request_paper_generation(:'es_phy'::uuid, :'pat'::uuid, array['Ch.1'], 65) as job4 \gset
reset role;
select (public.fn_ingest_generated_paper(:'job4'::uuid, jsonb_build_object('sets', jsonb_build_array(pg_temp.mkpaper('A', 13, 0.9))))) ->> 'status' as cr_status \gset
select is(:'cr_status'::text, 'copyright_blocked', 'a question that reproduces the textbook ends the job copyright_blocked');
select is((select count(*) from public.exam_paper where job_id = :'job4'::uuid), 0::bigint, 'and nothing is stored');

-- ── AC4: the same callback delivered twice ────────────────────────────────
select (public.fn_ingest_generated_paper(:'job1'::uuid, jsonb_build_object('sets', jsonb_build_array(pg_temp.mkpaper('A'))))) as again \gset
select is((:'again'::jsonb ->> 'duplicate')::boolean, true, 'AC4: the repeat delivery is recognised');
select is((select count(*) from public.exam_paper where job_id = :'job1'::uuid), 1::bigint, 'AC4: exactly one exam_paper row exists for the job id');
select is((select count(*) from public.exam_paper_item i join public.exam_paper p on p.id = i.paper_id where p.job_id = :'job1'::uuid), 23::bigint, 'AC4: and no duplicated questions');
select (public.fn_ingest_generated_paper(:'job2'::uuid, jsonb_build_object('sets', jsonb_build_array(pg_temp.mkpaper('A'))))) ->> 'status' as late_status \gset
select is(:'late_status'::text, 'pattern_mismatch', 'a late callback for a closed job changes nothing (it stays pattern_mismatch)');
select is((select count(*) from public.exam_paper where job_id = :'job2'::uuid), 0::bigint, 'and stores no paper');

-- ── AC3: unreachable worker -> three retries with backoff -> failed ───────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.request_paper_generation(:'es_phy'::uuid, :'pat'::uuid, array['Ch.1'], 65) as job5 \gset
reset role;
select is((select count(*) from public.fn_claim_paper_jobs(10) where id = :'job5'::uuid), 1::bigint, 'the dispatcher claims the due job');
select is((select status || ':' || attempts from public.paper_generation_job where id = :'job5'::uuid), 'running:1', 'it is running on attempt 1');
select is(public.fn_record_paper_job_failure(:'job5'::uuid, 'ECONNREFUSED'), 'queued', 'AC3: the first failure re-queues it');
select ok((select next_attempt_at between now() + interval '29 seconds' and now() + interval '31 seconds' from public.paper_generation_job where id = :'job5'::uuid), 'AC3: after 30 seconds');
select is((select count(*) from public.fn_claim_paper_jobs(10) where id = :'job5'::uuid), 0::bigint, 'it is not claimable before its backoff has passed');
update public.paper_generation_job set next_attempt_at = now() where id = :'job5'::uuid;
select count(*) as _c1 from public.fn_claim_paper_jobs(10) \gset
select is(public.fn_record_paper_job_failure(:'job5'::uuid, 'ECONNREFUSED'), 'queued', 'AC3: the second failure re-queues it');
select ok((select next_attempt_at between now() + interval '59 seconds' and now() + interval '61 seconds' from public.paper_generation_job where id = :'job5'::uuid), 'AC3: after 60 seconds (exponential)');
update public.paper_generation_job set next_attempt_at = now() where id = :'job5'::uuid;
select count(*) as _c2 from public.fn_claim_paper_jobs(10) \gset
select is(public.fn_record_paper_job_failure(:'job5'::uuid, 'ECONNREFUSED'), 'queued', 'AC3: the third failure re-queues it');
select ok((select next_attempt_at between now() + interval '119 seconds' and now() + interval '121 seconds' from public.paper_generation_job where id = :'job5'::uuid), 'AC3: after 120 seconds');
update public.paper_generation_job set next_attempt_at = now() where id = :'job5'::uuid;
select count(*) as _c3 from public.fn_claim_paper_jobs(10) \gset
select is(public.fn_record_paper_job_failure(:'job5'::uuid, 'ECONNREFUSED'), 'failed', 'AC3: the fourth failure (after three retries) ends the job failed');
select is((select count(*) from public.exam_paper where job_id = :'job5'::uuid), 0::bigint, 'AC3: no partial paper is left');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.retry_paper_job(:'job5'::uuid);
select is((select status || ':' || attempts from public.paper_generation_job where id = :'job5'::uuid), 'queued:0', 'AC3: the retry action re-queues it with a fresh budget');
select throws_ok(format($$ select public.retry_paper_job(%L) $$, :'job5'), 'JOB_NOT_FAILED', 'only a failed job can be retried');

-- ── stalled worker ────────────────────────────────────────────────────────
reset role;
select count(*) as _c4 from public.fn_claim_paper_jobs(10) \gset
update public.paper_generation_job set started_at = now() - interval '20 minutes' where id = :'job5'::uuid;
select is(public.fn_fail_stalled_paper_jobs(15), 1, 'a job whose worker never reported back counts as a failed attempt');
select is((select status from public.paper_generation_job where id = :'job5'::uuid), 'queued', 'and is re-queued with backoff');

-- ── scoping ───────────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok((select count(*) from public.paper_generation_job) >= 5 and (select count(*) from public.exam_paper) = 1, 'the requester sees their own jobs and paper');
select throws_ok(format($$ select public.fn_ingest_generated_paper(%L, '{}'::jsonb) $$, :'job5'), '42501', null, 'the callback function is not callable by a user');
select set_config('request.jwt.claims', json_build_object('sub', :'other_teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.paper_generation_job) + (select count(*) from public.exam_paper) + (select count(*) from public.exam_paper_item), 0::bigint, 'another teacher sees neither jobs nor papers');
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok((select count(*) from public.paper_generation_job) >= 5 and (select count(*) from public.exam_paper) = 1, 'the exam controller sees every job and paper of the campus');
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.paper_generation_job) + (select count(*) from public.exam_paper) + (select count(*) from public.board_pattern_ref), 0::bigint, 'a parent sees no job, paper or pattern');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.paper_generation_job) + (select count(*) from public.exam_paper) + (select count(*) from public.board_pattern_ref), 0::bigint, 'another school sees none of it');
reset role;
select is((select public from storage.buckets where id = 'exam-papers'), false, 'the exam-papers bucket is private');

select * from finish();
rollback;
