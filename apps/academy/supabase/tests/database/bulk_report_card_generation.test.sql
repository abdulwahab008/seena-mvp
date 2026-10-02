-- pgTAP tests for FR-J12: bulk report card generation.
--
--   AC1  starting a batch enumerates every candidate in scope and returns
--        immediately, with a progress row that renders nothing.
--   AC2  a batch does not abort on a candidate it cannot print: the ones that
--        can are produced, and every one that cannot is listed with its own
--        reason code.
--   AC3  the cards are ordered by section then roll number, frozen at
--        enumeration, and the merged manifest comes out in that order.
--   AC4  re-running renders only what was skipped — the cards that succeeded
--        keep their revision and are not rendered again — while the merged
--        file is rebuilt in full.
--
-- Plus the properties the acceptance criteria do not state and results day
-- depends on:
--
--   * the run is genuinely resumable: it is driven one item at a time, and
--     stopping halfway and continuing later reaches the same final count;
--   * a driver that dies mid-card is recovered — the item goes back in the
--     queue and the revision it had reserved is VOIDED, never reused;
--   * a withheld candidate whose remark is also missing is skipped for the
--     withhold, because that is the fact somebody has to act on;
--   * a 'class' scope does not reach into another campus, although class_level
--     is tenant-wide and a target alone would let it;
--   * batches are tenant-isolated, invisible to parents, and cannot be written
--     to directly or truncated.
begin;
select plan(50);

select public.provision_tenant('test-batch-co', 'Batch Co', 'owner@batchco.test');
select id as tenant_id from public.tenant where slug = 'test-batch-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_id' \gset

select public.provision_tenant('test-batch-rival', 'Batch Rival', 'owner@batchrival.test');
select id as rival_id from public.tenant where slug = 'test-batch-rival' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@batchco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Batch Owner');

select gen_random_uuid() as ec_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ec_uid', 'controller@batchco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ec_uid', :'tenant_id', 'exam_controller', 'Shaista Kamal');

select gen_random_uuid() as principal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_uid', 'principal@batchco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_uid', :'tenant_id', 'principal', 'Tahira Aziz');

select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'parent_uid', 'mother@batchco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'parent_uid', :'tenant_id', 'parent', 'A Mother');

select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'rival_uid', 'owner@batchrival.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'rival_uid', :'rival_id', 'owner', 'Rival Owner');

select id as class5 from public.class_level where tenant_id = :'tenant_id' and code = '5' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);

-- A second campus of the SAME tenant, teaching the SAME class level. Nothing
-- in this file matters more than the fact that a 'class' scope must not reach
-- into it: class_level is tenant-wide, so the target alone would.
select public.create_campus('SOUTH', 'Campus South', null) as campus_b \gset

select public.create_subject('ENG', 'English', 'انگریزی') as subj_eng \gset
select public.create_subject('URD', 'Urdu',    'اردو')    as subj_urd \gset
select public.create_subject('MTH', 'Maths',   'ریاضی')   as subj_mth \gset
select public.create_subject('SCI', 'Science', 'سائنس')   as subj_sci \gset

select public.upsert_class_subject(:'campus_a', :'session_a', :'class5', :'subj_eng', 6::smallint) as cs_eng \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class5', :'subj_urd', 6::smallint) as cs_urd \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class5', :'subj_mth', 6::smallint) as cs_mth \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class5', :'subj_sci', 6::smallint) as cs_sci \gset

select public.create_section(:'campus_a', :'session_a', :'class5', 'A', 40) as sec_a \gset
select public.create_section(:'campus_a', :'session_a', :'class5', 'B', 40) as sec_b \gset
select public.create_section(:'campus_b', :'session_a', :'class5', 'C', 40) as sec_c \gset

select public.upsert_exam_term(:'campus_a', :'session_a', 'FINAL', 'Final Term', 1::smallint, 100.00) as term_f \gset
select public.activate_exam_terms(:'session_a'::uuid, :'campus_a'::uuid) as _act_terms \gset

select public.upsert_exam_subject(:'term_f', :'cs_eng', '[{"component":"theory","max_marks":200,"pass_marks":0}]'::jsonb) as es_eng \gset
select public.upsert_exam_subject(:'term_f', :'cs_urd', '[{"component":"theory","max_marks":200,"pass_marks":0}]'::jsonb) as es_urd \gset
select public.upsert_exam_subject(:'term_f', :'cs_mth', '[{"component":"theory","max_marks":200,"pass_marks":0}]'::jsonb) as es_mth \gset
select public.upsert_exam_subject(:'term_f', :'cs_sci', '[{"component":"theory","max_marks":200,"pass_marks":0}]'::jsonb) as es_sci \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select public.save_grading_scheme(
  'FBISE'::public.board, 'FBISE 2025', date '2000-01-01',
  '[{"grade_label":"A1","min_pct":80,"max_pct":100,"gpa_point":4.00},
    {"grade_label":"A", "min_pct":70,"max_pct":79.99,"gpa_point":3.70},
    {"grade_label":"B", "min_pct":60,"max_pct":69.99,"gpa_point":3.30},
    {"grade_label":"C", "min_pct":50,"max_pct":59.99,"gpa_point":3.00},
    {"grade_label":"D", "min_pct":40,"max_pct":49.99,"gpa_point":2.50},
    {"grade_label":"E", "min_pct":33,"max_pct":39.99,"gpa_point":2.00},
    {"grade_label":"F", "min_pct":0, "max_pct":32.99,"gpa_point":0.00,"is_pass":false}]'::jsonb
) as fbise \gset
select public.activate_grading_scheme(:'fbise') as _act_scheme \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);
select public.create_student(:'campus_a', 'Ayesha Noor',  '2015-01-01'::date, 'female') as st_ayesha \gset
select public.create_student(:'campus_a', 'Bilal Ahmed',  '2015-02-01'::date, 'male')   as st_bilal \gset
select public.create_student(:'campus_a', 'Chandni Rao',  '2015-03-01'::date, 'female') as st_chandni \gset
select public.create_student(:'campus_a', 'Danish Ali',   '2015-04-01'::date, 'male')   as st_danish \gset
select public.create_student(:'campus_a', 'Erum Shah',    '2015-05-01'::date, 'female') as st_erum \gset
select public.create_student(:'campus_a', 'Farhan Iqbal', '2015-06-01'::date, 'male')   as st_farhan \gset
select public.create_student(:'campus_b', 'Ghazala Bibi', '2015-07-01'::date, 'female') as st_ghazala \gset

select public.enrol_student(:'sec_a', :'st_ayesha')  as enr_ayesha \gset
select public.enrol_student(:'sec_a', :'st_bilal')   as enr_bilal \gset
select public.enrol_student(:'sec_a', :'st_chandni') as enr_chandni \gset
select public.enrol_student(:'sec_a', :'st_danish')  as enr_danish \gset
select public.enrol_student(:'sec_b', :'st_erum')    as enr_erum \gset
select public.enrol_student(:'sec_b', :'st_farhan')  as enr_farhan \gset
select public.enrol_student(:'sec_c', :'st_ghazala') as enr_ghazala \gset

-- AC3's order is section then ROLL NUMBER, so the roll numbers have to exist
-- and must not agree with the alphabet, or the test would pass on the name.
reset role;
update public.enrolment set roll_no = 4 where id = :'enr_ayesha';
update public.enrolment set roll_no = 3 where id = :'enr_bilal';
update public.enrolment set roll_no = 2 where id = :'enr_chandni';
update public.enrolment set roll_no = 1 where id = :'enr_danish';
update public.enrolment set roll_no = 2 where id = :'enr_erum';
update public.enrolment set roll_no = 1 where id = :'enr_farhan';
set local role authenticated;

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

-- Section A is signed off completely. Section B is signed off on three papers
-- of four, so it stays provisional and its two candidates are AC2's "cannot be
-- printed" without any of them being at fault.
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_eng', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 160),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 180),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 170),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 150)
))) as _ma1 \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_eng', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_erum',    'component', 'theory', 'marks_obtained', 140),
  jsonb_build_object('enrolment_id', :'enr_farhan',  'component', 'theory', 'marks_obtained', 130)
))) as _mb1 \gset

select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_urd', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 150),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 175),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 165),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 145)
))) as _ma2 \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_urd', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_erum',    'component', 'theory', 'marks_obtained', 135),
  jsonb_build_object('enrolment_id', :'enr_farhan',  'component', 'theory', 'marks_obtained', 125)
))) as _mb2 \gset

select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_mth', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 152),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 178),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 168),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 148)
))) as _ma3 \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_mth', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_erum',    'component', 'theory', 'marks_obtained', 138),
  jsonb_build_object('enrolment_id', :'enr_farhan',  'component', 'theory', 'marks_obtained', 128)
))) as _mb3 \gset

select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_sci', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 150),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 177),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 167),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 147)
))) as _ma4 \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_sci', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_erum',    'component', 'theory', 'marks_obtained', 137),
  jsonb_build_object('enrolment_id', :'enr_farhan',  'component', 'theory', 'marks_obtained', 127)
))) as _mb4 \gset

select public.fn_approve_marks(:'es_eng', :'sec_a') as _a1 \gset
select public.fn_approve_marks(:'es_urd', :'sec_a') as _a2 \gset
select public.fn_approve_marks(:'es_mth', :'sec_a') as _a3 \gset
select public.fn_approve_marks(:'es_sci', :'sec_a') as _a4 \gset
select public.fn_approve_marks(:'es_eng', :'sec_b') as _b1 \gset
select public.fn_approve_marks(:'es_urd', :'sec_b') as _b2 \gset
select public.fn_approve_marks(:'es_mth', :'sec_b') as _b3 \gset

-- FR-J08's hold on Ayesha, opened by hand because the money is not the point
-- here: what matters is that the batch skips her for the WITHHOLD even though
-- she has no remark either.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select public.raise_result_withhold(
  :'enr_ayesha'::uuid, :'term_f'::uuid, 'discipline'::public.result_withhold_reason,
  'Library books outstanding since March.'
) as _wh \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: enumerate, in AC3's order, and return
-- ═══════════════════════════════════════════════════════════════════════

select public.start_report_card_batch(
  :'term_f'::uuid,
  'class'::public.report_card_batch_scope,
  :'class5'::uuid,
  jsonb_build_object(
    :'enr_bilal',  'A steady term. Reads widely.',
    :'enr_danish', 'Much improved in Science.'
  ),
  true
) as batch1 \gset
select (:'batch1'::jsonb ->> 'batch_id') as batch_id \gset

select is(
  (:'batch1'::jsonb ->> 'total')::int,
  6,
  'AC1: every candidate of the class in this campus is enumerated — and Campus South''s Class 5 is NOT, although class_level is tenant-wide'
);
select is(
  (:'batch1'::jsonb ->> 'status'),
  'queued',
  'AC1: the progress row exists before a single page is rendered'
);
select is(
  (select count(*)::int from public.report_card_batch_item where batch_id = :'batch_id'::uuid),
  6,
  'every enumerated candidate has a row, so the batch cannot silently omit one'
);
select is(
  (select array_agg(st.name_en order by i.seq)
     from public.report_card_batch_item i
     join public.enrolment e on e.id = i.enrolment_id
     join public.student st on st.id = e.student_id
    where i.batch_id = :'batch_id'::uuid),
  array['Danish Ali', 'Chandni Rao', 'Bilal Ahmed', 'Ayesha Noor', 'Farhan Iqbal', 'Erum Shah'],
  'AC3: section then ROLL NUMBER, frozen at enumeration — not alphabetical, and not the order they were enrolled'
);
select is(
  (select count(*)::int from public.report_card_batch_item where batch_id = :'batch_id'::uuid
    and enrolment_id = :'enr_ghazala'::uuid),
  0,
  'the campus guard is in the enumeration, not in the target: a class scope cannot reach another campus'
);

select public.start_report_card_batch(
  :'term_f'::uuid, 'class'::public.report_card_batch_scope, :'class5'::uuid, '{}'::jsonb, true
) as batch1b \gset
select is(
  (:'batch1b'::jsonb ->> 'batch_id'),
  :'batch_id',
  'pressing the button twice RESUMES the unfinished run rather than reserving a second revision for every child'
);
select is(
  (:'batch1b'::jsonb ->> 'resumed')::boolean,
  true,
  'and says so, so the screen does not report a fresh start it did not make'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: one item at a time, and nobody stops the run
-- ═══════════════════════════════════════════════════════════════════════

select public.claim_report_card_batch_item(:'batch_id'::uuid) as claim1 \gset
select is(
  (:'claim1'::jsonb ->> 'status'),
  'rendering',
  'the first candidate in print order has a remark and a signed-off term, so a revision is reserved for them'
);
select (:'claim1'::jsonb ->> 'item_id') as item_danish \gset
select (:'claim1'::jsonb -> 'reserved' ->> 'report_card_id') as card_danish \gset
select is(
  (:'claim1'::jsonb -> 'reserved' -> 'payload_snapshot' ->> 'remark'),
  'Much improved in Science.',
  'the remark the screen collected travels with the batch and is frozen onto the card'
);
select is(
  jsonb_array_length(:'claim1'::jsonb -> 'reserved' -> 'payload_snapshot' -> 'subjects'),
  4,
  'and the card is FR-J09''s payload, unchanged — the batch builds no second document'
);

select throws_ok(
  format($$select public.finish_report_card_batch_item(%L, true, null, 1)$$, :'item_danish'),
  '23514',
  'REPORT_CARD_NOT_ISSUED',
  'a card is only counted as produced once the register agrees it became a document'
);

select public.attach_report_card_pdf(:'card_danish'::uuid, repeat('a', 64));
select public.finish_report_card_batch_item(:'item_danish'::uuid, true, null, 1) as _f1 \gset

select public.claim_report_card_batch_item(:'batch_id'::uuid) as claim2 \gset
select is(
  (:'claim2'::jsonb ->> 'error_code'),
  'remark_missing',
  'AC2: a candidate with nothing in the remark box is skipped rather than handed a card with an empty one'
);

-- Halfway. The FR's per-item checkpointing is the whole point: this is a real
-- stopping place, not a moment inside one long transaction.
select public.fn_report_card_batch_status(:'batch_id'::uuid) as mid \gset
select is(
  jsonb_build_array(:'mid'::jsonb -> 'succeeded', :'mid'::jsonb -> 'skipped', :'mid'::jsonb -> 'pending'),
  '[1, 1, 4]'::jsonb,
  'stopping after two of six leaves one produced, one skipped and four still to do — counters derived from the items, never incremented'
);
select is(
  (:'mid'::jsonb ->> 'status'),
  'running',
  'and the batch says it is running'
);
select throws_ok(
  format($$select public.complete_report_card_batch(%L, %L, 1)$$, :'batch_id', repeat('b', 64)),
  '23514',
  'REPORT_CARD_BATCH_UNFINISHED',
  'the merged file cannot be sealed over a run that has not finished'
);

select public.claim_report_card_batch_item(:'batch_id'::uuid) as claim3 \gset
select (:'claim3'::jsonb ->> 'item_id') as item_bilal \gset
select (:'claim3'::jsonb -> 'reserved' ->> 'report_card_id') as card_bilal \gset
select public.attach_report_card_pdf(:'card_bilal'::uuid, repeat('c', 64));
select public.finish_report_card_batch_item(:'item_bilal'::uuid, true, null, 1) as _f2 \gset

select public.claim_report_card_batch_item(:'batch_id'::uuid) as claim4 \gset
select is(
  (:'claim4'::jsonb ->> 'error_code'),
  'result_withheld',
  'AC2: a withheld candidate is SKIPPED with FR-J08''s own reason, and her missing remark is not the answer given — the withhold is the fact somebody must act on'
);
select is(
  (select error_detail from public.report_card_batch_item where batch_id = :'batch_id'::uuid and enrolment_id = :'enr_ayesha'::uuid),
  (select app.fn_report_card_block_reason(:'enr_ayesha'::uuid, :'term_f'::uuid)),
  'and the sentence on the row is the gate''s own, so the batch and the print list cannot explain the same fact two ways'
);

select public.claim_report_card_batch_item(:'batch_id'::uuid) as claim5 \gset
select is(
  (:'claim5'::jsonb ->> 'error_code'),
  'term_provisional',
  'AC2: the section whose Science paper is still being marked is skipped for THAT, in FR-J03''s own words'
);
select public.claim_report_card_batch_item(:'batch_id'::uuid) as claim6 \gset
select public.claim_report_card_batch_item(:'batch_id'::uuid) as claim7 \gset

select is(
  (:'claim7'::jsonb ->> 'done')::boolean,
  true,
  'and the run ends by saying there is nothing left, rather than by raising'
);

select public.fn_report_card_batch_status(:'batch_id'::uuid) as after1 \gset
select is(
  jsonb_build_array(:'after1'::jsonb -> 'total', :'after1'::jsonb -> 'succeeded',
                    :'after1'::jsonb -> 'skipped', :'after1'::jsonb -> 'failed'),
  '[6, 2, 4, 0]'::jsonb,
  'AC2: resuming from the halfway stop reaches the same final count — two produced, four accounted for'
);
select is(
  (select count(*)::int from public.report_card_batch_item
    where batch_id = :'batch_id'::uuid and status = 'skipped' and error_code is null),
  0,
  'and not one of the four is skipped without a reason code'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the merged manifest
-- ═══════════════════════════════════════════════════════════════════════

select public.fn_report_card_batch_manifest(:'batch_id'::uuid) as manifest \gset
select is(
  jsonb_array_length(:'manifest'::jsonb -> 'cards'),
  2,
  'the merged file is built over the cards that succeeded and nothing else'
);
select is(
  (select array_agg(c ->> 'enrolment_id' order by (c ->> 'seq')::int)
     from jsonb_array_elements(:'manifest'::jsonb -> 'cards') c),
  array[:'enr_danish', :'enr_bilal'],
  'AC3: in the order frozen at enumeration — roll 1 before roll 3 — so a section renamed mid-run cannot reorder a half-printed document'
);
select ok(
  (select bool_and(c -> 'snapshot' ? 'subjects') from jsonb_array_elements(:'manifest'::jsonb -> 'cards') c),
  'and from each card''s FROZEN snapshot, so rebuilding the merge never re-reads today''s marks'
);
select is(
  (:'manifest'::jsonb ->> 'file_path'),
  :'tenant_id' || '/' || :'campus_a' || '/' || :'term_f' || '/batch-' || :'batch_id' || '.pdf',
  'at the path the requirement names'
);

select public.complete_report_card_batch(:'batch_id'::uuid, repeat('d', 64), 2) as done1 \gset
select is(
  jsonb_build_array(:'done1'::jsonb -> 'status', :'done1'::jsonb -> 'checksum', :'done1'::jsonb -> 'page_count'),
  jsonb_build_array('completed'::text, repeat('d', 64), 2),
  'sealing the merged file completes the batch and records the digest of what the bucket holds'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: re-run renders only what was skipped
-- ═══════════════════════════════════════════════════════════════════════

select public.retry_report_card_batch(
  :'batch_id'::uuid,
  jsonb_build_object(:'enr_chandni', 'A quiet term, but the work is there.')
) as retry1 \gset

select is(
  jsonb_build_array(:'retry1'::jsonb -> 'status', :'retry1'::jsonb -> 'checksum', :'retry1'::jsonb -> 'pending'),
  jsonb_build_array('queued'::text, 'null'::jsonb #> '{}', 4),
  'AC4: the four that were skipped go back in the queue and the merged file is cleared for a full rebuild'
);
select is(
  (select array_agg(status::text order by seq) from public.report_card_batch_item
    where batch_id = :'batch_id'::uuid and enrolment_id in (:'enr_danish', :'enr_bilal')),
  array['succeeded', 'succeeded'],
  'AC4: the two that succeeded are untouched — a re-run does not render them again'
);
select is(
  (select count(distinct revision_no)::int from public.report_card
    where enrolment_id = :'enr_bilal'::uuid and exam_term_id = :'term_f'::uuid),
  1,
  'and no second revision is reserved for a candidate whose card is already correct'
);

select public.claim_report_card_batch_item(:'batch_id'::uuid) as rclaim1 \gset
select is(
  (:'rclaim1'::jsonb ->> 'status'),
  'rendering',
  'the candidate whose remark was supplied on the re-run is now printable'
);
select (:'rclaim1'::jsonb -> 'reserved' ->> 'report_card_id') as card_chandni1 \gset

-- ═══════════════════════════════════════════════════════════════════════
-- A driver that dies mid-card
-- ═══════════════════════════════════════════════════════════════════════

reset role;
update public.report_card_batch_item
   set claimed_at = clock_timestamp() - interval '1 hour'
 where batch_id = :'batch_id'::uuid and enrolment_id = :'enr_chandni'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

select public.claim_report_card_batch_item(:'batch_id'::uuid) as rclaim2 \gset
select is(
  (select status::text from public.report_card where id = :'card_chandni1'::uuid),
  'void',
  'a revision reserved by a driver that never came back is VOIDED, so the number it consumed can never be reissued'
);
select is(
  (:'rclaim2'::jsonb -> 'reserved' ->> 'report_card_id') <> :'card_chandni1',
  true,
  'and the candidate is handed back out on a fresh revision rather than being lost from the run'
);
select is(
  (:'rclaim2'::jsonb -> 'reserved' ->> 'revision_no')::int,
  2,
  'which is revision 2: the voided one still counts, exactly as FR-T02 requires'
);

select (:'rclaim2'::jsonb ->> 'item_id') as item_chandni \gset
select (:'rclaim2'::jsonb -> 'reserved' ->> 'report_card_id') as card_chandni2 \gset
select public.attach_report_card_pdf(:'card_chandni2'::uuid, repeat('e', 64));
select public.finish_report_card_batch_item(:'item_chandni'::uuid, true, null, 1) as _f3 \gset

select public.claim_report_card_batch_item(:'batch_id'::uuid) as rclaim3 \gset
select is(
  (:'rclaim3'::jsonb ->> 'error_code'),
  'result_withheld',
  'the candidate whose withhold nobody released is skipped again, for the same reason'
);

select public.claim_report_card_batch_item(:'batch_id'::uuid) as rclaim4 \gset
select public.claim_report_card_batch_item(:'batch_id'::uuid) as rclaim5 \gset
select public.claim_report_card_batch_item(:'batch_id'::uuid) as rclaim6 \gset

select public.fn_report_card_batch_status(:'batch_id'::uuid) as after2 \gset
select is(
  jsonb_build_array(:'after2'::jsonb -> 'total', :'after2'::jsonb -> 'succeeded',
                    :'after2'::jsonb -> 'skipped', :'after2'::jsonb -> 'pending'),
  '[6, 3, 3, 0]'::jsonb,
  'AC4: the re-run produced exactly the one candidate that was fixed, and the three that are still blocked stay listed'
);
select is(
  jsonb_array_length(public.fn_report_card_batch_manifest(:'batch_id'::uuid) -> 'cards'),
  3,
  'and the merged file is rebuilt IN FULL — all three, not just the newly rendered one'
);
select is(
  (select attempts from public.report_card_batch_item
    where batch_id = :'batch_id'::uuid and enrolment_id = :'enr_bilal'::uuid),
  1,
  'the card that was already right was claimed exactly once across both runs'
);

-- A failure of the bytes is not a skip: the school has nothing to fix.
select public.complete_report_card_batch(:'batch_id'::uuid, repeat('f', 64), 3) as _done2 \gset
select public.fail_report_card_batch(:'batch_id'::uuid, 'RENDERER_UNAVAILABLE') as failed1 \gset
select is(
  (:'failed1'::jsonb ->> 'status'),
  'failed',
  'a merge that cannot be produced fails the BATCH, leaving the individually sealed cards downloadable'
);

-- ═══════════════════════════════════════════════════════════════════════
-- FR-I17's staleness, inherited rather than reinvented
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select public.request_mark_unlock(:'es_mth', :'sec_a', 'Q7 total mis-added on Bilal''s script') as unlock_req \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select public.fn_break_glass_unlock(:'unlock_req', 60) as _bg \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_mth', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_bilal', 'component', 'theory', 'marks_obtained', 188)
))) as _fix \gset

select public.start_report_card_batch(
  :'term_f'::uuid, 'section'::public.report_card_batch_scope, :'sec_a'::uuid,
  jsonb_build_object(:'enr_bilal', 'Re-marked.'), true
) as batch2 \gset
select (:'batch2'::jsonb ->> 'batch_id') as batch2_id \gset

select public.claim_report_card_batch_item(:'batch2_id'::uuid) as sclaim1 \gset
select public.claim_report_card_batch_item(:'batch2_id'::uuid) as sclaim2 \gset
select public.claim_report_card_batch_item(:'batch2_id'::uuid) as sclaim3 \gset
select is(
  (select error_code from public.report_card_batch_item
    where batch_id = :'batch2_id'::uuid and enrolment_id = :'enr_bilal'::uuid),
  'result_stale',
  'FR-I17''s stamp is the batch''s staleness too: a mark changed under a computed result and no card is produced from it'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Scope, campus and tenant
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$select public.start_report_card_batch(%L, 'section', %L)$$, :'term_f', :'sec_c'),
  '23514',
  'that section is not in this term''s campus and session',
  'a section of another campus cannot be batched against this campus''s term'
);
select throws_ok(
  format($$select public.start_report_card_batch(%L, 'campus', %L)$$, :'term_f', :'campus_b'),
  '23514',
  'that campus is not this term''s campus',
  'and neither can another campus outright'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_b'), 'sub', :'principal_uid')::text,
  true
);
select throws_ok(
  format($$select public.start_report_card_batch(%L, 'section', %L)$$, :'term_f', :'sec_a'),
  '42501',
  'FORBIDDEN',
  'a Principal of Campus South cannot start a run against a term that is not theirs'
);
select throws_ok(
  format($$select public.fn_report_card_batch_status(%L)$$, :'batch_id'),
  '42501',
  'FORBIDDEN',
  'and cannot read one either — the SECURITY DEFINER reader guards the campus explicitly, because RLS is not filtering it'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'rival_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(gen_random_uuid()), 'sub', :'rival_uid')::text,
  true
);
select is(
  (select count(*)::int from public.report_card_batch),
  0,
  'another tenant sees no batch of this one'
);
select is(
  (select count(*)::int from public.report_card_batch_item),
  0,
  'nor any of its candidates'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'parent_uid')::text,
  true
);
select is(
  (select count(*)::int from public.report_card_batch),
  0,
  'a parent sees no batch: which six of their child''s classmates were skipped is not theirs to read'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select is(
  (select count(*)::int from public.report_card_batch_item where batch_id = :'batch_id'::uuid),
  6,
  'while staff on the campus read every candidate of the run'
);
select throws_ok(
  format($$update public.report_card_batch set succeeded = 999 where id = %L$$, :'batch_id'),
  '42501',
  null,
  'the counters cannot be typed in: every write goes through the driver functions'
);
select throws_ok(
  format($$update public.report_card_batch_item set status = 'succeeded' where batch_id = %L$$, :'batch_id'),
  '42501',
  null,
  'and neither can an outcome'
);
select throws_ok(
  $$truncate public.report_card_batch$$,
  '42501',
  null,
  'a bulk run register is not derived — the bucket objects and the reasons would orphan'
);

select * from finish();
rollback;
