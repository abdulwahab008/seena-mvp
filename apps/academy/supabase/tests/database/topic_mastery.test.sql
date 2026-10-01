-- pgTAP tests for FR-J07: topic-wise mastery analytics.
--
--   AC1  a Physics paper whose questions carry chapter tags 1 to 4 and per-
--        question marks: a percentage per chapter, "Ch.3 Motion 42%, Ch.1
--        Measurements 88%".
--   AC2  a paper entered as a single total (no per-question marks): no topic
--        breakdown is generated and the sheet says per-question data was not
--        captured.
--   AC3  a section view: chapters where the section is below 50% are
--        re-teach candidates.
--   AC4  a topic covered by fewer than 3 questions carries a low-confidence
--        marker.
--
-- Plus: parents see only their own child, teachers only their sections (the
-- class teacher all subjects of theirs), the scheme cannot be changed once
-- marks hang off it, marks stay inside the question, OCR-reviewed marks are
-- lifted into the same table, and the view is materialised.
begin;
select plan(43);

select public.provision_tenant('test-topic-co', 'Topic Co', 'owner@topicco.test');
select id as tenant_id from public.tenant where slug = 'test-topic-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select public.provision_tenant('test-topic-rival', 'Topic Rival', 'owner@topicrival.test');
select id as rival_id from public.tenant where slug = 'test-topic-rival' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as teach_a_uid \gset
select gen_random_uuid() as teach_b_uid \gset
select gen_random_uuid() as classteach_uid \gset
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role) values
  (:'owner_uid', 'o@topicco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'ec_uid', 'e@topicco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'teach_a_uid', 'ta@topicco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'teach_b_uid', 'tb@topicco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'classteach_uid', 'ct@topicco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'parent_uid', 'p@topicco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'rival_uid', 'r@topicrival.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Shaista Kamal'),
  (:'teach_a_uid', :'tenant_id', 'subject_teacher', 'Physics Teacher A'), (:'teach_b_uid', :'tenant_id', 'subject_teacher', 'Physics Teacher B'),
  (:'classteach_uid', :'tenant_id', 'class_teacher', 'Class Teacher A'), (:'rival_uid', :'rival_id', 'owner', 'Rival');
insert into public.user_campus (user_id, tenant_id, campus_id)
select u, :'tenant_id', :'campus_id' from (values (:'ec_uid'::uuid), (:'teach_a_uid'::uuid), (:'teach_b_uid'::uuid), (:'classteach_uid'::uuid)) v(u);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text, true);
select public.create_subject('PHY', 'Physics', 'طبیعیات') as s_phy \gset
select public.create_subject('CHM', 'Chemistry', 'کیمیا') as s_chm \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_phy', 6::smallint) as cs_phy \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_chm', 6::smallint) as cs_chm \gset
select public.create_section(:'campus_id', :'session_id', :'class9', 'A', 40) as sec_a \gset
select public.create_section(:'campus_id', :'session_id', :'class9', 'B', 40) as sec_b \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'FINAL', 'Final Term', 1::smallint, 100.00) as term \gset
select public.activate_exam_terms(:'session_id'::uuid, :'campus_id'::uuid) as _act \gset
select public.upsert_exam_subject(:'term', :'cs_phy', '[{"component":"theory","max_marks":150,"pass_marks":0}]'::jsonb) as es_phy \gset
select public.upsert_exam_subject(:'term', :'cs_chm', '[{"component":"theory","max_marks":100,"pass_marks":0}]'::jsonb) as es_chm \gset
select public.create_student(:'campus_id', 'Ayesha Noor', '2011-01-01'::date, 'female') as st_ayesha \gset
select public.create_student(:'campus_id', 'Bilal Ahmed', '2011-02-01'::date, 'male') as st_bilal \gset
select public.create_student(:'campus_id', 'Chandni Rao', '2011-03-01'::date, 'female') as st_chandni \gset
select public.create_student(:'campus_id', 'Gul Naz', '2011-04-01'::date, 'female') as st_gul \gset
select public.enrol_student(:'sec_a', :'st_ayesha') as e_ayesha \gset
select public.enrol_student(:'sec_a', :'st_bilal') as e_bilal \gset
select public.enrol_student(:'sec_a', :'st_chandni') as e_chandni \gset
select public.enrol_student(:'sec_b', :'st_gul') as e_gul \gset
select public.fn_find_or_create_guardian(p_name_en => 'Ayesha Mother', p_phone_e164 => '+923005550081') as g \gset
select public.link_guardian(:'st_ayesha'::uuid, :'g'::uuid, 'mother'::public.guardian_relationship, true, true);
reset role;
update public.guardian set auth_user_id = :'parent_uid'::uuid where id = :'g'::uuid;
insert into public.section_subject_teacher (tenant_id, campus_id, session_id, section_id, subject_id, staff_id, effective_from) values
  (:'tenant_id', :'campus_id', :'session_id', :'sec_a', :'s_phy', :'teach_a_uid', current_date - 60),
  (:'tenant_id', :'campus_id', :'session_id', :'sec_b', :'s_phy', :'teach_b_uid', current_date - 60);
insert into public.section_class_teacher (tenant_id, campus_id, session_id, section_id, staff_id, effective_from)
values (:'tenant_id', :'campus_id', :'session_id', :'sec_a', :'classteach_uid', current_date - 60);
-- Chemistry was entered as a single total: a result exists, no per-question marks.
insert into public.subject_result (tenant_id, campus_id, exam_term_id, section_id, exam_subject_id, enrolment_id, subject_id, obtained, max_marks, pct, is_pass)
values (:'tenant_id', :'campus_id', :'term', :'sec_a', :'es_chm', :'e_ayesha', :'s_chm', 61, 100, 61, true);

-- ── the marking scheme: four chapters ─────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teach_a_uid')::text, true);
select throws_ok(format($$select public.save_exam_questions(%L, '[{"question_no":1,"max_marks":200,"chapter_no":1,"chapter_title":"Measurements"}]'::jsonb)$$, :'es_phy'), 'QUESTIONS_EXCEED_PAPER', 'a scheme cannot add up to more than the paper');
select throws_ok(format($$select public.save_exam_questions(%L, '[{"question_no":1,"max_marks":10}]'::jsonb)$$, :'es_phy'), 'QUESTION_TOPIC_REQUIRED', 'every question names its chapter');
select throws_ok(format($$select public.save_exam_questions(%L, '[{"question_no":1,"max_marks":10,"chapter_no":1,"chapter_title":"A"},{"question_no":1,"max_marks":10,"chapter_no":1,"chapter_title":"A"}]'::jsonb)$$, :'es_phy'), 'QUESTION_INVALID', 'question numbers are unique');
select is(public.save_exam_questions(:'es_phy'::uuid, $q$[
  {"question_no":1,"max_marks":20,"chapter_no":1,"chapter_title":"Measurements"},
  {"question_no":2,"max_marks":15,"chapter_no":1,"chapter_title":"Measurements"},
  {"question_no":3,"max_marks":15,"chapter_no":1,"chapter_title":"Measurements"},
  {"question_no":4,"max_marks":10,"chapter_no":2,"chapter_title":"Heat"},
  {"question_no":5,"max_marks":10,"chapter_no":2,"chapter_title":"Heat"},
  {"question_no":6,"max_marks":20,"chapter_no":3,"chapter_title":"Motion"},
  {"question_no":7,"max_marks":15,"chapter_no":3,"chapter_title":"Motion"},
  {"question_no":8,"max_marks":15,"chapter_no":3,"chapter_title":"Motion"},
  {"question_no":9,"max_marks":10,"chapter_no":4,"chapter_title":"Forces"},
  {"question_no":10,"max_marks":10,"chapter_no":4,"chapter_title":"Forces"},
  {"question_no":11,"max_marks":10,"chapter_no":4,"chapter_title":"Forces"}]$q$::jsonb), 11, 'the teacher defines eleven questions across four chapters');
select is((select topic_tag from public.exam_question where exam_subject_id = :'es_phy' and question_no = 6), 'Ch.3 Motion', 'a question''s tag reads "Ch.3 Motion"');

-- ── capturing per-question marks ──────────────────────────────────────────
select throws_ok(format($$select public.save_question_marks(%L, jsonb_build_array(jsonb_build_object('enrolment_id', %L, 'marks', jsonb_build_array(jsonb_build_object('question_no', 1, 'obtained', 21)))))$$, :'es_phy', :'e_ayesha'), '22003', null, 'marks above a question''s maximum are refused');
-- Ayesha: Ch.1 44/50, Ch.2 15/20, Ch.3 21/50, Ch.4 24/30.
select is(public.save_question_marks(:'es_phy'::uuid, jsonb_build_array(
  jsonb_build_object('enrolment_id', :'e_ayesha', 'marks', jsonb_build_array(
    jsonb_build_object('question_no', 1, 'obtained', 18), jsonb_build_object('question_no', 2, 'obtained', 13), jsonb_build_object('question_no', 3, 'obtained', 13),
    jsonb_build_object('question_no', 4, 'obtained', 10), jsonb_build_object('question_no', 5, 'obtained', 5),
    jsonb_build_object('question_no', 6, 'obtained', 8), jsonb_build_object('question_no', 7, 'obtained', 7), jsonb_build_object('question_no', 8, 'obtained', 6),
    jsonb_build_object('question_no', 9, 'obtained', 8), jsonb_build_object('question_no', 10, 'obtained', 8), jsonb_build_object('question_no', 11, 'obtained', 8))),
  jsonb_build_object('enrolment_id', :'e_bilal', 'marks', jsonb_build_array(
    jsonb_build_object('question_no', 1, 'obtained', 10), jsonb_build_object('question_no', 2, 'obtained', 10), jsonb_build_object('question_no', 3, 'obtained', 10),
    jsonb_build_object('question_no', 4, 'obtained', 5), jsonb_build_object('question_no', 5, 'obtained', 5),
    jsonb_build_object('question_no', 6, 'obtained', 5), jsonb_build_object('question_no', 7, 'obtained', 5), jsonb_build_object('question_no', 8, 'obtained', 5),
    jsonb_build_object('question_no', 9, 'obtained', 5), jsonb_build_object('question_no', 10, 'obtained', 5), jsonb_build_object('question_no', 11, 'obtained', 5)))
)), 22, 'two candidates'' marks are captured');
select is(public.save_question_marks(:'es_phy'::uuid, jsonb_build_array(
  jsonb_build_object('enrolment_id', :'e_chandni', 'marks', jsonb_build_array(
    jsonb_build_object('question_no', 1, 'obtained', 12), jsonb_build_object('question_no', 2, 'obtained', 9), jsonb_build_object('question_no', 3, 'obtained', 9),
    jsonb_build_object('question_no', 6, 'obtained', 6), jsonb_build_object('question_no', 7, 'obtained', 6), jsonb_build_object('question_no', 8, 'obtained', 6))))), 6,
  'a candidate''s partial paper is captured as far as it goes');
select throws_ok(format($$select public.save_exam_questions(%L, '[{"question_no":1,"max_marks":20,"chapter_no":1,"chapter_title":"Measurements"}]'::jsonb)$$, :'es_phy'), 'QUESTIONS_LOCKED', 'the scheme is locked once marks hang off it');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teach_b_uid')::text, true);
select throws_ok(format($$select public.save_question_marks(%L, jsonb_build_array(jsonb_build_object('enrolment_id', %L, 'marks', jsonb_build_array(jsonb_build_object('question_no', 1, 'obtained', 5)))))$$, :'es_phy', :'e_ayesha'), '42501', null, 'a teacher cannot enter marks for another teacher''s section');
select is(public.save_question_marks(:'es_phy'::uuid, jsonb_build_array(
  jsonb_build_object('enrolment_id', :'e_gul', 'marks', jsonb_build_array(
    jsonb_build_object('question_no', 1, 'obtained', 20), jsonb_build_object('question_no', 2, 'obtained', 15), jsonb_build_object('question_no', 3, 'obtained', 15),
    jsonb_build_object('question_no', 6, 'obtained', 20), jsonb_build_object('question_no', 7, 'obtained', 15), jsonb_build_object('question_no', 8, 'obtained', 15))))), 6,
  'but can for their own');

-- ── materialised: nothing until the refresh ───────────────────────────────
reset role;
select is((select count(*)::int from app.mv_topic_mastery), 0, 'the view is materialised: captured marks do not appear until it is refreshed');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'ec_uid')::text, true);
select is(public.fn_refresh_topic_mastery(:'term'::uuid) > 0, true, 'fn_refresh_topic_mastery brings it up to date');
select has_index('app', 'mv_topic_mastery', 'uq_mv_topic_mastery', array['enrolment_id', 'subject_id', 'topic_tag'], 'the unique index allows CONCURRENTLY refreshes');
select has_index('public', 'question_response_mark', 'uq_qrm', array['enrolment_id', 'exam_paper_question_id'], 'uq_qrm: one response per candidate per question');

-- ── AC1 ───────────────────────────────────────────────────────────────────
select is((select pct from public.v_topic_mastery where enrolment_id = :'e_ayesha' and topic_tag = 'Ch.3 Motion'), 42.00::numeric, 'AC1: Ch.3 Motion is 42%');
select is((select pct from public.v_topic_mastery where enrolment_id = :'e_ayesha' and topic_tag = 'Ch.1 Measurements'), 88.00::numeric, 'AC1: Ch.1 Measurements is 88%');
select is((select count(*)::int from public.v_topic_mastery where enrolment_id = :'e_ayesha'), 4, 'AC1: one line per chapter, all four');
select is((public.fn_topic_mastery_sheet(:'e_ayesha'::uuid) -> 'topics' -> 0 ->> 'topic_tag'), 'Ch.3 Motion', 'the sheet lists the weakest chapter first');
select is((select obtained from public.v_topic_mastery where enrolment_id = :'e_ayesha' and topic_tag = 'Ch.3 Motion'), 21.00::numeric, 'with the marks behind it');

-- ── AC4 ───────────────────────────────────────────────────────────────────
select is((select low_confidence from public.v_topic_mastery where enrolment_id = :'e_ayesha' and topic_tag = 'Ch.2 Heat'), true, 'AC4: a chapter covered by 2 questions carries the low-confidence marker');
select is((select low_confidence from public.v_topic_mastery where enrolment_id = :'e_ayesha' and topic_tag = 'Ch.1 Measurements'), false, 'AC4: and one covered by 3 does not');
select is((select question_count from public.v_topic_mastery where enrolment_id = :'e_ayesha' and topic_tag = 'Ch.2 Heat'), 2, 'the count is on the line');

-- ── AC2 ───────────────────────────────────────────────────────────────────
select is(public.fn_topic_mastery_sheet(:'e_ayesha'::uuid) -> 'uncaptured' -> 0 ->> 'subject_name', 'Chemistry', 'AC2: the total-only Chemistry paper is reported as not captured');
select is(public.fn_topic_mastery_sheet(:'e_ayesha'::uuid) -> 'uncaptured' -> 0 ->> 'reason', 'no_question_scheme', 'AC2: because the paper has no question scheme');
select is((select count(*)::int from public.v_topic_mastery where enrolment_id = :'e_ayesha' and subject_id = :'s_chm'), 0, 'AC2: and no Chemistry breakdown is generated');
select is((public.fn_topic_mastery_sheet(:'e_bilal'::uuid) ->> 'has_breakdown')::boolean, true, 'a candidate with per-question marks has a breakdown');

-- ── AC3 ───────────────────────────────────────────────────────────────────
select is((select pct from public.v_section_topic_mastery where section_id = :'sec_a' and topic_tag = 'Ch.3 Motion'), 36.00::numeric, 'section A pools Ch.3 Motion at 36% (21+15+18 of 50+50+50)');
select is((select reteach from public.v_section_topic_mastery where section_id = :'sec_a' and topic_tag = 'Ch.3 Motion'), true, 'AC3: below 50% -> a re-teach candidate');
select is((select reteach from public.v_section_topic_mastery where section_id = :'sec_a' and topic_tag = 'Ch.1 Measurements'), false, 'AC3: Ch.1 Measurements (70%) is not');
select is((select array_agg(topic_tag order by topic_tag) from public.v_section_topic_mastery where section_id = :'sec_a' and reteach), array['Ch.3 Motion'], 'AC3: Ch.3 Motion is the only highlighted chapter');
select is((select low_confidence from public.v_section_topic_mastery where section_id = :'sec_a' and topic_tag = 'Ch.2 Heat'), true, 'the section line also carries the low-confidence marker');

-- ── who sees what ─────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teach_b_uid')::text, true);
select is((select count(distinct section_id)::int from public.v_topic_mastery), 1, 'a teacher sees only the section they teach');
select is((select count(*)::int from public.v_topic_mastery where enrolment_id = :'e_ayesha'), 0, 'and not another teacher''s students');
select throws_ok(format($$select public.fn_topic_mastery_sheet(%L)$$, :'e_ayesha'), '42501', null, 'nor their sheet');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'classteach_uid')::text, true);
select is((select count(distinct enrolment_id)::int from public.v_topic_mastery), 3, 'the class teacher sees their whole section');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb, 'sub', :'parent_uid')::text, true);
select is((select count(distinct enrolment_id)::int from public.v_topic_mastery), 1, 'a parent sees only their own child');
select is((select count(*)::int from public.v_section_topic_mastery), 0, 'and no section view');
select is((select count(*)::int from public.question_response_mark), 11, 'the parent policy on the base table shows only their child''s responses');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'rival_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb, 'sub', :'rival_uid')::text, true);
select is((select count(*)::int from public.v_topic_mastery) + (select count(*)::int from public.question_response_mark), 0, 'another school sees none');

-- ── OCR-graded papers feed the same table ─────────────────────────────────
reset role;
insert into public.ocr_mark_job (tenant_id, campus_id, exam_term_id, exam_subject_id, section_id, component_code, status)
values (:'tenant_id', :'campus_id', :'term', :'es_phy', :'sec_a', 'theory', 'promoted') returning id as job \gset
insert into public.ocr_review_action (tenant_id, campus_id, job_id, enrolment_id, question_no, ocr_value, final_value)
values (:'tenant_id', :'campus_id', :'job', :'e_chandni', 4, 6, 7), (:'tenant_id', :'campus_id', :'job', :'e_chandni', 5, 8, 8), (:'tenant_id', :'campus_id', :'job', :'e_chandni', 99, 3, 3);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'ec_uid')::text, true);
select is(public.fn_import_ocr_question_marks(:'job'::uuid) ->> 'imported', '2', 'OCR-reviewed marks are imported against the scheme');
select is(public.fn_import_ocr_question_marks(:'job'::uuid) ->> 'skipped_no_scheme_row', '1', 'a question outside the scheme is counted, not guessed');
select is((select source from public.question_response_mark where enrolment_id = :'e_chandni' and obtained = 7), 'ocr', 'and they are marked as OCR-sourced');

select * from finish();
rollback;
