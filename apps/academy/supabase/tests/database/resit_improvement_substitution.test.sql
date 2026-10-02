-- pgTAP tests for FR-J14: re-sit and improvement result substitution.
--
--   AC1  original Maths 28/100 (fail), re-sit 61, policy capped_at_pass, pass
--        mark 33: the published subject mark is 33 annotated 'R', and 61 stays
--        visible in the internal record.
--   AC2  policy best_of, original 72, improvement 55: 72 is published and the
--        improvement attempt is retained.
--   AC3  a re-sit: the report card renders attempt_no 2 and the footnote
--        "Maths: result of re-sit dated 12-Aug-2026".
--   AC4  a candidate Absent in the original paper qualifies for a re-sit only
--        if the absence reason was medical or a Principal records an exception.
--
-- Plus: the 'latest' policy, improvement is for passed papers only, an
-- ineligible re-sit is refused, marks stay inside the paper, the downstream
-- aggregate and rank follow the published mark, and the raw attempts are
-- invisible to parents.
begin;
select plan(43);

select public.provision_tenant('test-resit-co', 'Resit Co', 'owner@resitco.test');
select id as tenant_id from public.tenant where slug = 'test-resit-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select public.provision_tenant('test-resit-rival', 'Resit Rival', 'owner@resitrival.test');
select id as rival_id from public.tenant where slug = 'test-resit-rival' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teacher_uid \gset
select gen_random_uuid() as other_teacher_uid \gset
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role) values
  (:'owner_uid', 'o@resitco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'ec_uid', 'e@resitco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'prin_uid', 'p@resitco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'teacher_uid', 't@resitco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'other_teacher_uid', 't2@resitco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'parent_uid', 'pa@resitco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'rival_uid', 'r@resitrival.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Shaista Kamal'),
  (:'prin_uid', :'tenant_id', 'principal', 'Tahira Aziz'), (:'teacher_uid', :'tenant_id', 'subject_teacher', 'Maths Teacher'),
  (:'other_teacher_uid', :'tenant_id', 'subject_teacher', 'Other Teacher'), (:'rival_uid', :'rival_id', 'owner', 'Rival');
insert into public.user_campus (user_id, tenant_id, campus_id) values
  (:'ec_uid', :'tenant_id', :'campus_id'), (:'prin_uid', :'tenant_id', :'campus_id'),
  (:'teacher_uid', :'tenant_id', :'campus_id'), (:'other_teacher_uid', :'tenant_id', :'campus_id');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text, true);
select public.create_subject('MTH', 'Maths', 'ریاضی') as s_mth \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_mth', 6::smallint) as cs_mth \gset
select public.create_section(:'campus_id', :'session_id', :'class9', 'A', 40) as sec_a \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'FINAL', 'Final Term', 1::smallint, 100.00) as term \gset
select public.activate_exam_terms(:'session_id'::uuid, :'campus_id'::uuid) as _act \gset
-- Pass mark 33 of 100: the component carries it.
select public.upsert_exam_subject(:'term', :'cs_mth', '[{"component":"theory","max_marks":100,"pass_marks":33}]'::jsonb) as es \gset

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'ec_uid')::text, true);
select public.activate_grading_scheme(public.save_grading_scheme('FBISE'::public.board, 'FBISE 2025', date '2000-01-01',
  '[{"grade_label":"A1","min_pct":80,"max_pct":100,"gpa_point":4.00},{"grade_label":"B","min_pct":50,"max_pct":79.99,"gpa_point":3.00},
    {"grade_label":"E","min_pct":33,"max_pct":49.99,"gpa_point":1.00},
    {"grade_label":"F","min_pct":0,"max_pct":32.99,"gpa_point":0.00,"is_pass":false}]'::jsonb)) as _scheme \gset

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text, true);
select public.create_student(:'campus_id', 'Ayesha Noor', '2011-01-01'::date, 'female') as st_ayesha \gset
select public.create_student(:'campus_id', 'Bilal Ahmed', '2011-02-01'::date, 'male') as st_bilal \gset
select public.create_student(:'campus_id', 'Chandni Rao', '2011-03-01'::date, 'female') as st_chandni \gset
select public.create_student(:'campus_id', 'Danish Ali', '2011-04-01'::date, 'male') as st_danish \gset
select public.create_student(:'campus_id', 'Emaan Zafar', '2011-05-01'::date, 'female') as st_emaan \gset
select public.create_student(:'campus_id', 'Farhan Qazi', '2011-06-01'::date, 'male') as st_farhan \gset
select public.enrol_student(:'sec_a', :'st_ayesha') as e_ayesha \gset
select public.enrol_student(:'sec_a', :'st_bilal') as e_bilal \gset
select public.enrol_student(:'sec_a', :'st_chandni') as e_chandni \gset
select public.enrol_student(:'sec_a', :'st_danish') as e_danish \gset
select public.enrol_student(:'sec_a', :'st_emaan') as e_emaan \gset
select public.enrol_student(:'sec_a', :'st_farhan') as e_farhan \gset
select public.fn_find_or_create_guardian(p_name_en => 'Ayesha Mother', p_phone_e164 => '+923005550071') as g \gset
select public.link_guardian(:'st_ayesha'::uuid, :'g'::uuid, 'mother'::public.guardian_relationship, true, true);
reset role;
update public.guardian set auth_user_id = :'parent_uid'::uuid where id = :'g'::uuid;
insert into public.section_subject_teacher (tenant_id, campus_id, session_id, section_id, subject_id, staff_id, effective_from)
values (:'tenant_id', :'campus_id', :'session_id', :'sec_a', :'s_mth', :'teacher_uid', current_date - 60);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'ec_uid')::text, true);
select public.set_exam_attendance(:'es', :'e_chandni', 'absent', 'medical') as _a1 \gset
select public.set_exam_attendance(:'es', :'e_danish', 'absent', 'unauthorised') as _a2 \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'e_ayesha', 'component', 'theory', 'marks_obtained', 28),
  jsonb_build_object('enrolment_id', :'e_bilal', 'component', 'theory', 'marks_obtained', 72),
  jsonb_build_object('enrolment_id', :'e_emaan', 'component', 'theory', 'marks_obtained', 30),
  jsonb_build_object('enrolment_id', :'e_farhan', 'component', 'theory', 'marks_obtained', 50)))) as _m \gset
select public.fn_approve_marks(:'es', :'sec_a') as _ap \gset

select is((select is_pass from public.subject_result where enrolment_id = :'e_ayesha'), false, 'baseline: 28 of 100 against a pass mark of 33 is a fail');

-- ── AC4: the eligibility list ─────────────────────────────────────────────
select is(public.fn_generate_resit_eligibility_list(:'term'::uuid), 4, 'the list covers the two failures and the two absentees (a pass is not on it)');
select is((select basis from public.resit_eligibility where enrolment_id = :'e_ayesha'), 'failed', 'a failed paper qualifies');
select is((select eligible from public.resit_eligibility where enrolment_id = :'e_chandni'), true, 'AC4: absent for a medical reason qualifies');
select is((select basis from public.resit_eligibility where enrolment_id = :'e_chandni'), 'absent_medical', 'AC4: and says why');
select is((select eligible from public.resit_eligibility where enrolment_id = :'e_danish'), false, 'AC4: absent without a medical reason does not qualify');
select is((select count(*)::int from public.resit_eligibility where enrolment_id in (:'e_bilal', :'e_farhan')), 0, 'a candidate who passed is not on the list');
select throws_ok(format($$select public.record_exam_attempt(%L, %L, 'resit', 40, date '2026-08-12')$$, :'e_danish', :'es'), 'RESIT_NOT_ELIGIBLE', 'AC4: a re-sit for the ineligible absentee is refused');
select throws_ok(format($$select public.grant_resit_exception(%L, %L, 'Bereavement')$$, :'e_danish', :'es'), '42501', null, 'AC4: only a Principal can grant the exception');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'prin_uid')::text, true);
select throws_ok(format($$select public.grant_resit_exception(%L, %L, '')$$, :'e_danish', :'es'), 'EXCEPTION_REASON_REQUIRED', 'the exception needs a reason');
select public.grant_resit_exception(:'e_danish'::uuid, :'es'::uuid, 'Family bereavement on the day') as _g \gset
select is((select basis from public.resit_eligibility where enrolment_id = :'e_danish'), 'principal_exception', 'AC4: with the exception recorded the candidate qualifies');
select is((select granted_by from public.resit_eligibility where enrolment_id = :'e_danish'), :'prin_uid'::uuid, 'AC4: the grantor is on the record');
select is(public.fn_generate_resit_eligibility_list(:'term'::uuid), 4, 're-generating the list');
select is((select eligible from public.resit_eligibility where enrolment_id = :'e_danish'), true, 'does not undo a Principal''s recorded exception');

-- ── AC1: capped_at_pass (the default) ─────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'ec_uid')::text, true);
-- A report card was already handed out for Ayesha.
reset role;
insert into public.report_card (tenant_id, campus_id, exam_term_id, section_id, enrolment_id, revision_no, storage_path, checksum, status, payload_snapshot)
values (:'tenant_id', :'campus_id', :'term', :'sec_a', :'e_ayesha', 1, 'x/y/z.pdf', repeat('c', 64), 'issued', '{}'::jsonb);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'ec_uid')::text, true);

select throws_ok(format($$select public.record_exam_attempt(%L, %L, 'resit', 101, date '2026-08-12')$$, :'e_ayesha', :'es'), '22003', null, 'a mark above the paper maximum is refused');
select throws_ok(format($$select public.record_exam_attempt(%L, %L, 'improvement', 90, date '2026-08-12')$$, :'e_ayesha', :'es'), 'IMPROVEMENT_REQUIRES_PASS', 'an improvement is for a passed paper, not a failed one');
select public.record_exam_attempt(:'e_ayesha'::uuid, :'es'::uuid, 'resit', 61, date '2026-08-12') as _r1 \gset

select is((select obtained from public.subject_result where enrolment_id = :'e_ayesha'), 33.00::numeric, 'AC1: the published subject mark is 33, the pass mark');
select is((select report_symbol from public.subject_result where enrolment_id = :'e_ayesha'), 'R', 'AC1: annotated R');
select is((select obtained from public.exam_attempt where enrolment_id = :'e_ayesha' and attempt_no = 2), 61.00::numeric, 'AC1: and 61 remains visible in the internal record');
select is((select is_pass from public.subject_result where enrolment_id = :'e_ayesha'), true, 'the capped mark is a pass');
select is((select grade_label from public.subject_result where enrolment_id = :'e_ayesha'), 'E', 'graded on the published 33, not the raw 61');
select is((select (public.fn_effective_attempt(:'e_ayesha'::uuid, :'es'::uuid)).attempt_no::int), 2, 'fn_effective_attempt names attempt 2');
select is((select (public.fn_effective_attempt(:'e_ayesha'::uuid, :'es'::uuid)).obtained), 33.00::numeric, 'and returns the published mark');
select is((select status::text from public.report_card where enrolment_id = :'e_ayesha'), 'stale', 'the card already handed out is marked stale so the next revision carries the new mark');
select is((select weighted_pct from public.annual_result where enrolment_id = :'e_ayesha'), 33.00::numeric, 'the annual aggregate follows the published mark');

-- ── AC3: the report card ──────────────────────────────────────────────────
reset role;
select app.fn_build_report_card_payload(:'e_ayesha'::uuid, :'term'::uuid, null)::text as card \gset
select is(:'card'::jsonb -> 'subjects' -> 0 ->> 'attempt_no', '2', 'AC3: the card shows attempt_no 2 for the re-sat subject');
select is(:'card'::jsonb -> 'attempt_notes' ->> 0, 'Maths: result of re-sit dated 12-Aug-2026', 'AC3: with the footnote "Maths: result of re-sit dated 12-Aug-2026"');
select is(:'card'::jsonb -> 'subjects' -> 0 ->> 'report_symbol', 'R', 'AC3: and the R annotation');
select is(app.fn_build_report_card_payload(:'e_bilal'::uuid, :'term'::uuid, null) -> 'subjects' -> 0 ->> 'attempt_no', '1', 'a subject that was not re-sat reads attempt 1');
select is(jsonb_array_length(app.fn_build_report_card_payload(:'e_bilal'::uuid, :'term'::uuid, null) -> 'attempt_notes'), 0, 'and carries no footnote');
set local role authenticated;

-- ── AC2: best_of ──────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'prin_uid')::text, true);
select public.set_resit_policy(:'campus_id'::uuid, 'best_of') as _p \gset
select throws_ok(format($$select public.set_resit_policy(%L, 'whatever')$$, :'campus_id'), 'POLICY_INVALID', 'an unknown policy is refused');
select public.record_exam_attempt(:'e_bilal'::uuid, :'es'::uuid, 'improvement', 55, date '2026-08-12') as _i1 \gset
select is((select obtained from public.subject_result where enrolment_id = :'e_bilal'), 72.00::numeric, 'AC2: 72 is published');
select is((select count(*)::int from public.exam_attempt where enrolment_id = :'e_bilal' and attempt_type = 'improvement'), 1, 'AC2: and the improvement attempt is retained');
select is((select report_symbol from public.subject_result where enrolment_id = :'e_bilal'), null, 'no R: the original is what publishes');
select is((select (public.fn_effective_attempt(:'e_bilal'::uuid, :'es'::uuid)).attempt_no::int), 1, 'the effective attempt is the original');
select public.record_exam_attempt(:'e_bilal'::uuid, :'es'::uuid, 'improvement', 80, date '2026-08-20') as _i2 \gset
select is((select obtained from public.subject_result where enrolment_id = :'e_bilal'), 80.00::numeric, 'a better improvement attempt is the one published');
select is((select attempt_no from public.exam_attempt where enrolment_id = :'e_bilal' and obtained = 80), 3::smallint, 'attempts are numbered in sequence');

-- ── latest ────────────────────────────────────────────────────────────────
select public.set_resit_policy(:'campus_id'::uuid, 'latest') as _p2 \gset
select public.record_exam_attempt(:'e_emaan'::uuid, :'es'::uuid, 'resit', 20, date '2026-08-12') as _r2 \gset
select is((select obtained from public.subject_result where enrolment_id = :'e_emaan'), 20.00::numeric, 'policy latest: the most recent attempt publishes even when it is lower');
select is((select is_pass from public.subject_result where enrolment_id = :'e_emaan'), false, 'and still fails');

-- ── who may record, and who sees ──────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'other_teacher_uid')::text, true);
select throws_ok(format($$select public.record_exam_attempt(%L, %L, 'improvement', 60, date '2026-08-12')$$, :'e_farhan', :'es'), '42501', null, 'a teacher not assigned to the section and subject cannot record an attempt');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_uid')::text, true);
select lives_ok(format($$select public.record_exam_attempt(%L, %L, 'improvement', 60, date '2026-08-12')$$, :'e_farhan', :'es'), 'the assigned teacher can');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb, 'sub', :'parent_uid')::text, true);
select is((select count(*)::int from public.exam_attempt), 0, 'a parent cannot read the raw attempts');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'rival_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb, 'sub', :'rival_uid')::text, true);
select is((select count(*)::int from public.exam_attempt) + (select count(*)::int from public.resit_eligibility), 0, 'another school sees none');

select * from finish();
rollback;
