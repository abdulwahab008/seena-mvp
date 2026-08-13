-- pgTAP tests for FR-I14: mandatory teacher override of OCR marks.
--
--   AC1  40 scripts with OCR suggestions and no review actions: submission is
--        refused with "0 of 40 scripts reviewed".
--   AC2  39 accepted unchanged and one amended from 52 to 55: mark_entry holds
--        40 rows, 39 'ocr_confirmed' and 1 'ocr_overridden', and the original
--        OCR value is preserved.
--   AC3  a bulk accept of a page of 10 writes TEN review rows with actor and
--        timestamp, not one row for the page.
--   AC4  six months later, the OCR value, the final value, the acting user and
--        the timestamp are all retrievable for that question.
--
-- Plus the properties the ACs rest on and which are the actual firewall:
--
--   * an unreviewed batch blocks FR-I16 approval, listing GR numbers the way
--     FR-I16 AC1 does, INCLUDING when every mark was keyed by hand — and
--     confirming the batch makes the set approvable;
--   * an OCR-sourced mark is structurally unreachable: no authenticated role,
--     no service_role key and not the table owner can write source='ocr_*'
--     outside fn_promote_ocr_marks();
--   * confidence buys nothing — a 0.999 suggestion blocks as hard as any;
--   * all three tables are append-only against authenticated, service_role, the
--     table owner AND truncate;
--   * typing over a promoted mark makes it manual again, and re-saving the same
--     number does not.
begin;
select plan(76);

select public.provision_tenant('test-ocr-co', 'OCR Co', 'owner@ocr.test');
select id as tenant_id from public.tenant where slug = 'test-ocr-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_id' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@ocr.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'OCR Owner');

select gen_random_uuid() as controller_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'controller_uid', 'controller@ocr.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'controller_uid', :'tenant_id', 'exam_controller', 'Rukhsana Bano');

select gen_random_uuid() as outsider_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'outsider_uid', 'teacher@ocr.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'outsider_uid', :'tenant_id', 'subject_teacher', 'Nadia Iqbal');

select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);

select public.create_subject('MTH', 'Maths', 'ریاضی') as subj_mth \gset
select public.create_subject('PHY', 'Physics', 'طبیعیات') as subj_phy \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_mth', 6::smallint) as cs_mth \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_phy', 5::smallint) as cs_phy \gset
select public.create_section(:'campus_a', :'session_a', :'class9', 'B', 40) as sec9b \gset

select public.upsert_exam_term(:'campus_a', :'session_a', 'T1', 'First Term', 1::smallint, 100.00) as term_t1 \gset
select public.activate_exam_terms(:'session_a'::uuid, :'campus_a'::uuid) as _a \gset
select public.upsert_exam_subject(
  :'term_t1', :'cs_mth', '[{"component":"theory","max_marks":100,"pass_marks":33}]'::jsonb
) as es_mth \gset
select public.upsert_exam_subject(
  :'term_t1', :'cs_phy', '[{"component":"theory","max_marks":100,"pass_marks":33}]'::jsonb
) as es_phy \gset

-- AC1's forty scripts.
reset role;
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', :'campus_a', 'GR-' || lpad(g::text, 4, '0'),
       'Candidate ' || lpad(g::text, 2, '0'), current_date - interval '14 years', 'male'
  from generate_series(1, 40) g;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, roll_no)
select :'tenant_id', :'campus_a', :'session_a', st.id, :'class9', :'sec9b', right(st.gr_number, 4)::int
  from public.student st where st.tenant_id = :'tenant_id';

select id as enr1 from public.enrolment where section_id = :'sec9b' and roll_no = 1 \gset
select id as enr40 from public.enrolment where section_id = :'sec9b' and roll_no = 40 \gset

-- ═══════════════════════════════════════════════════════════════════════
-- The batch arrives — FR-I13's seam, called the way FR-I13 will call it
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'controller_uid')::text,
  true
);

-- One question per script: the whole booklet marked as one total, which is the
-- shape AC2 describes ("edits one script from 52 to 55"). Roll 40 is the one
-- the machine read as 52. Roll 1 gets a confidence of 0.999 so the "high
-- confidence still needs a human" rule has something to bite on.
select (public.fn_open_ocr_job(
          :'es_mth', :'sec9b', 'theory',
          (select jsonb_agg(jsonb_build_object(
                    'enrolment_id', e.id,
                    'question_no',  1,
                    'ocr_value',    case when e.roll_no = 40 then 52 else 40 + e.roll_no end,
                    'confidence',   case when e.roll_no = 1 then 0.999 else 0.812 end))
             from public.enrolment e where e.section_id = :'sec9b'),
          'seena-ocr-v1') ->> 'job_id')::uuid as job1 \gset

select is(
  (select count(*)::int from public.ocr_mark_suggestion where job_id = :'job1'),
  40,
  'the batch lands as forty SUGGESTIONS'
);
select is(
  (select status::text from public.ocr_mark_job where id = :'job1'),
  'ready',
  'ready for a human, and nothing further'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: no review actions, no marks
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select count(*)::int from public.mark_entry where exam_subject_id = :'es_mth'),
  0,
  'AC1: forty machine-read scripts have produced exactly zero marks'
);
select throws_ok(
  format($$ select public.fn_promote_ocr_marks(%L) $$, :'job1'),
  '23514',
  '0 of 40 scripts reviewed',
  'AC1: and Submit marks is refused in the acceptance criterion''s own words'
);
select is(
  (select count(*)::int from public.mark_entry where exam_subject_id = :'es_mth'),
  0,
  'AC1: the refusal wrote nothing'
);

-- The FR's own token, carried where a caller can branch on it without parsing
-- English. See the migration header for why the sentence is the message.
select throws_like(
  format($$ select public.fn_promote_ocr_marks(%L) $$, :'job1'),
  '%0 of 40 scripts reviewed%',
  'AC1: the message is the sentence the teacher reads'
);
select is(
  (select count(*)::int from public.ocr_review_action where job_id = :'job1'),
  0,
  'AC1: because nobody has confirmed anything'
);

-- The gate is in the database, not in the screen: FR-I16's approval refuses
-- too, and it names the candidates the way FR-I16 AC1 does.
select throws_like(
  format($$ select public.fn_approve_marks(%L, %L) $$, :'es_mth', :'sec9b'),
  '%40 candidates have an OCR mark no teacher has confirmed: GR-0001%',
  'AC1: and the exam office cannot sign the set off either — with the GR numbers listed'
);
select is(
  (select jsonb_array_length(app.fn_mark_completeness(:'es_mth', :'sec9b') -> 'ocr_unreviewed')),
  40,
  'the approval queue shows the same forty BEFORE anyone clicks'
);
select is(
  (app.fn_mark_completeness(:'es_mth', :'sec9b') ->> 'complete')::boolean,
  false,
  'so the set is not complete, whatever else is in place'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: a bulk accept of a page of ten
-- ═══════════════════════════════════════════════════════════════════════

select (public.fn_record_ocr_review(
          :'job1',
          (select jsonb_agg(jsonb_build_object('enrolment_id', e.id, 'question_no', 1))
             from public.enrolment e
            where e.section_id = :'sec9b' and e.roll_no between 1 and 10))
        ->> 'actions_written')::int as bulk10 \gset

select is(
  :'bulk10'::int,
  10,
  'AC3: accepting a page of ten writes TEN rows, not one row for the page'
);
select is(
  (select count(*)::int from public.ocr_review_action where job_id = :'job1'),
  10,
  'AC3: ten individual review rows on the ledger'
);
select is(
  (select count(*)::int from public.ocr_review_action
    where job_id = :'job1' and actor_id = :'controller_uid'::uuid and acted_at is not null),
  10,
  'AC3: each carrying the actor and the timestamp'
);
select is(
  (select count(distinct enrolment_id)::int from public.ocr_review_action where job_id = :'job1'),
  10,
  'AC3: one per script — a page is not a unit anything here can record'
);
select is(
  (select count(*)::int from public.ocr_review_action
    where job_id = :'job1' and final_value = ocr_value),
  10,
  'AC3: accepted unchanged means final = what the machine said, stated rather than implied'
);

-- Ten of forty is still not forty, and 0.999 confidence on roll 1 changed
-- nothing about that.
select throws_ok(
  format($$ select public.fn_promote_ocr_marks(%L) $$, :'job1'),
  '23514',
  '10 of 40 scripts reviewed',
  'a partly-reviewed batch is refused, and the count is the honest one'
);
select is(
  (select confidence from public.ocr_mark_suggestion
    where job_id = :'job1' and enrolment_id = :'enr1'),
  0.999::numeric,
  'the machine was as certain as it gets about roll 1'
);
select is(
  (select count(*)::int from public.mark_entry where exam_subject_id = :'es_mth'),
  0,
  'and it bought that script no fast path whatsoever'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: 39 accepted, one amended from 52 to 55
-- ═══════════════════════════════════════════════════════════════════════

select public.fn_record_ocr_review(
  :'job1',
  (select jsonb_agg(jsonb_build_object('enrolment_id', e.id, 'question_no', 1))
     from public.enrolment e
    where e.section_id = :'sec9b' and e.roll_no between 11 and 39)) as _r2 \gset

select is(
  (select ocr_value from public.ocr_mark_suggestion
    where job_id = :'job1' and enrolment_id = :'enr40'),
  52.00::numeric,
  'AC2: the machine read the fortieth script as 52'
);

select public.fn_record_ocr_review(
  :'job1',
  jsonb_build_array(jsonb_build_object(
    'enrolment_id', :'enr40', 'question_no', 1, 'final_value', 55))) as _r3 \gset

select is(
  (select final_value from public.ocr_review_action
    where job_id = :'job1' and enrolment_id = :'enr40'),
  55.00::numeric,
  'AC2: the teacher amends it to 55'
);
select is(
  (select ocr_value from public.ocr_review_action
    where job_id = :'job1' and enrolment_id = :'enr40'),
  52.00::numeric,
  'AC2: and the review row keeps what was amended FROM — the caller never names it'
);

select (public.fn_promote_ocr_marks(:'job1')) as promo \gset

select is(
  (select count(*)::int from public.mark_entry where exam_subject_id = :'es_mth'),
  40,
  'AC2: promoted, mark_entry holds forty rows'
);
select is(
  (select count(*)::int from public.mark_entry
    where exam_subject_id = :'es_mth' and source = 'ocr_confirmed'),
  39,
  'AC2: thirty-nine of them source ''ocr_confirmed'''
);
select is(
  (select count(*)::int from public.mark_entry
    where exam_subject_id = :'es_mth' and source = 'ocr_overridden'),
  1,
  'AC2: and one ''ocr_overridden'''
);
select is(
  (select marks_obtained from public.mark_entry
    where exam_subject_id = :'es_mth' and enrolment_id = :'enr40'),
  55.00::numeric,
  'AC2: the amended script carries the teacher''s 55, not the machine''s 52'
);
select is(
  (select ocr_value from public.ocr_mark_suggestion
    where job_id = :'job1' and enrolment_id = :'enr40'),
  52.00::numeric,
  'AC2: "and the original OCR value is preserved"'
);
select is(
  (select count(*)::int from public.mark_entry
    where exam_subject_id = :'es_mth' and ocr_job_id = :'job1'),
  40,
  'every promoted row names the batch it came from — provenance is not a bare label'
);
select is(
  (select status::text from public.ocr_mark_job where id = :'job1'),
  'promoted',
  'and the batch is closed'
);
select is(
  (select count(*)::int from public.mark_entry
    where exam_subject_id = :'es_mth' and status = 'draft'),
  40,
  'promotion writes ''draft'': FR-I12 reserved ''submitted'' for FR-I13 and this does not spend it'
);
select throws_ok(
  format($$ select public.fn_promote_ocr_marks(%L) $$, :'job1'),
  '23514',
  'OCR_JOB_NOT_OPEN',
  'a batch is promoted once'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: the dispute, six months later
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select ocr_value from public.v_ocr_mark_audit
    where job_id = :'job1' and gr_number = 'GR-0040' and question_no = 1),
  52.00::numeric,
  'AC4: the OCR value for that question'
);
select is(
  (select final_value from public.v_ocr_mark_audit
    where job_id = :'job1' and gr_number = 'GR-0040' and question_no = 1),
  55.00::numeric,
  'AC4: the final value'
);
select is(
  (select actor_name from public.v_ocr_mark_audit
    where job_id = :'job1' and gr_number = 'GR-0040' and question_no = 1),
  'Rukhsana Bano',
  'AC4: the acting user, by name'
);
select ok(
  (select acted_at is not null from public.v_ocr_mark_audit
    where job_id = :'job1' and gr_number = 'GR-0040' and question_no = 1),
  'AC4: and the timestamp'
);
select ok(
  (select was_overridden from public.v_ocr_mark_audit
    where job_id = :'job1' and gr_number = 'GR-0040' and question_no = 1),
  'AC4: with "the software did not decide this" answerable in one column'
);
select is(
  (select count(*)::int from public.v_ocr_mark_audit where job_id = :'job1'),
  40,
  'AC4: for every script, not only the amended one'
);

-- Now that every script has a named human on it, the set signs off.
select is(
  (select jsonb_array_length(app.fn_mark_completeness(:'es_mth', :'sec9b') -> 'ocr_unreviewed')),
  0,
  'the approval block clears once the batch is confirmed'
);
select is(
  ((public.fn_approve_marks(:'es_mth', :'sec9b')) ->> 'marks_locked')::int,
  40,
  'and FR-I16 signs the forty off'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The case the ordering exists for: hand-keyed marks, unreviewed batch
-- ═══════════════════════════════════════════════════════════════════════

-- Physics: every mark typed by hand, and an OCR batch of the same scripts left
-- unreviewed. not_started and partial are both EMPTY, so without FR-I14 this
-- set would be signed off with a machine's unexamined opinion still on file.
select count(*)::int as _phy
  from public.enrolment e,
       lateral (
         select public.fn_upsert_marks(jsonb_build_object(
           'exam_subject_id', :'es_phy',
           'marks', jsonb_build_array(jsonb_build_object(
             'enrolment_id', e.id, 'component', 'theory', 'marks_obtained', 60))))
       ) s
 where e.section_id = :'sec9b' \gset

select is(
  (select jsonb_array_length(app.fn_mark_completeness(:'es_phy', :'sec9b') -> 'not_started')),
  0,
  'Physics: nobody is missing a mark'
);
select is(
  (app.fn_mark_completeness(:'es_phy', :'sec9b') ->> 'complete')::boolean,
  true,
  'and the set is complete — until a batch turns up'
);

select (public.fn_open_ocr_job(
          :'es_phy', :'sec9b', 'theory',
          jsonb_build_array(
            jsonb_build_object('enrolment_id', :'enr1', 'question_no', 1, 'ocr_value', 71),
            jsonb_build_object('enrolment_id', :'enr40', 'question_no', 1, 'ocr_value', 44))
        ) ->> 'job_id')::uuid as job2 \gset

select throws_like(
  format($$ select public.fn_approve_marks(%L, %L) $$, :'es_phy', :'sec9b'),
  '%2 candidates have an OCR mark no teacher has confirmed: GR-0001, GR-0040%',
  'a hand-keyed set with an unreviewed batch behind it is STILL refused, naming the two'
);

-- Cancelling the batch is the other way out: a scan that came back garbage must
-- not make a section permanently unapprovable.
select throws_ok(
  format($$ select public.fn_cancel_ocr_job(%L, 'bad') $$, :'job2'),
  '23514',
  'OCR_CANCEL_REASON_REQUIRED',
  'abandoning a machine''s reading of a pile of scripts needs a written reason'
);
select public.fn_cancel_ocr_job(:'job2', 'Scanner fed two scripts together — pages unusable') as _c2 \gset
select is(
  (select status::text from public.ocr_mark_job where id = :'job2'),
  'cancelled',
  'the batch is abandoned, on the record and with the reason attached'
);
select is(
  ((public.fn_approve_marks(:'es_phy', :'sec9b')) ->> 'marks_locked')::int,
  40,
  'and the hand-keyed set signs off'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The provenance guard: an OCR mark is not something anyone can claim
-- ═══════════════════════════════════════════════════════════════════════

-- A third paper on a fresh term, so nothing here is fighting a lock.
select public.upsert_exam_term(:'campus_a', :'session_a', 'T2', 'Second Term', 2::smallint, 0.00) as term_t2 \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);
select public.activate_exam_terms(:'session_a'::uuid, :'campus_a'::uuid) as _a2 \gset
select public.upsert_exam_subject(
  :'term_t2', :'cs_mth', '[{"component":"theory","max_marks":100,"pass_marks":33}]'::jsonb
) as es_t2 \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'controller_uid')::text,
  true
);
select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_t2',
  'marks', jsonb_build_array(jsonb_build_object(
    'enrolment_id', :'enr1', 'component', 'theory', 'marks_obtained', 70)))) as _t2m \gset

select is(
  (select source::text from public.mark_entry
    where exam_subject_id = :'es_t2' and enrolment_id = :'enr1'),
  'manual',
  'a typed mark says so — fn_upsert_marks is the hand-entry path and states it'
);
-- mark_entry carries a SELECT policy and no write policy (FR-I12), so an
-- authenticated caller's UPDATE qualifies no rows and never reaches the
-- trigger. The trigger is what holds for the two roles that DO get there.
select lives_ok(
  format($$ update public.mark_entry set source = 'ocr_confirmed', ocr_job_id = %L
             where exam_subject_id = %L and enrolment_id = %L $$,
         :'job1', :'es_t2', :'enr1'),
  'an authenticated Exam Controller''s relabelling UPDATE qualifies no rows at all'
);
select is(
  (select source::text from public.mark_entry
    where exam_subject_id = :'es_t2' and enrolment_id = :'enr1'),
  'manual',
  'so the typed mark is still a typed mark'
);

reset role;
select set_config('request.jwt.claims', '', true);
set local role service_role;
select throws_ok(
  format($$ update public.mark_entry set source = 'ocr_confirmed', ocr_job_id = %L
             where exam_subject_id = %L and enrolment_id = %L $$,
         :'job1', :'es_t2', :'enr1'),
  '42501',
  'a machine mark needs a named teacher',
  'nor a service_role key — which is precisely the role FR-I13''s pipeline runs as'
);
select throws_ok(
  format($$ insert into public.mark_entry
              (tenant_id, campus_id, exam_subject_id, enrolment_id, component_code,
               marks_obtained, source, ocr_job_id)
            values (%L, %L, %L, %L, 'theory', 88, 'ocr_confirmed', %L) $$,
         :'tenant_id', :'campus_a', :'es_t2', :'enr40', :'job1'),
  '42501',
  'a machine mark needs a named teacher',
  'and an INSERT is no way round it either — the pipeline cannot seed its own marks'
);
reset role;

-- The table owner, writing the statement by hand.
select throws_ok(
  format($$ update public.mark_entry set source = 'ocr_overridden', ocr_job_id = %L
             where exam_subject_id = %L and enrolment_id = %L $$,
         :'job1', :'es_t2', :'enr1'),
  '42501',
  'a machine mark needs a named teacher',
  'the table owner is held to it too — ownership buys no provenance'
);
-- A BEFORE ROW trigger runs ahead of the table's CHECK constraints, so the
-- trigger is what answers even for a source with no batch behind it.
select throws_ok(
  format($$ insert into public.mark_entry
              (tenant_id, campus_id, exam_subject_id, enrolment_id, component_code,
               marks_obtained, source)
            values (%L, %L, %L, %L, 'theory', 88, 'ocr_confirmed') $$,
         :'tenant_id', :'campus_a', :'es_t2', :'enr40'),
  '42501',
  'a machine mark needs a named teacher',
  'including a source with no batch behind it at all'
);
select ok(
  (select count(*) = 1 from pg_constraint
    where conname = 'chk_mark_entry_source_job'
      and conrelid = 'public.mark_entry'::regclass),
  'and chk_mark_entry_source_job keeps source and batch inseparable if that trigger is ever dropped'
);

-- Losing provenance is always allowed, because the number really is hand-typed
-- once a teacher retypes it.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'controller_uid')::text,
  true
);
select (public.fn_open_ocr_job(
          :'es_t2', :'sec9b', 'theory',
          jsonb_build_array(
            jsonb_build_object('enrolment_id', :'enr1', 'question_no', 1, 'ocr_value', 33))
        ) ->> 'job_id')::uuid as job3 \gset
select public.fn_record_ocr_review(
  :'job3', jsonb_build_array(jsonb_build_object('enrolment_id', :'enr1', 'question_no', 1))) as _r4 \gset
select public.fn_promote_ocr_marks(:'job3') as _p3 \gset

select is(
  (select source::text from public.mark_entry
    where exam_subject_id = :'es_t2' and enrolment_id = :'enr1'),
  'ocr_confirmed',
  'promotion overwrites a typed mark and claims the provenance'
);
select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_t2',
  'marks', jsonb_build_array(jsonb_build_object(
    'enrolment_id', :'enr1', 'component', 'theory', 'marks_obtained', 33)))) as _same \gset
select is(
  (select source::text from public.mark_entry
    where exam_subject_id = :'es_t2' and enrolment_id = :'enr1'),
  'ocr_confirmed',
  'an autosave that re-sends the SAME number does not quietly strip it'
);
select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_t2',
  'marks', jsonb_build_array(jsonb_build_object(
    'enrolment_id', :'enr1', 'component', 'theory', 'marks_obtained', 34)))) as _diff \gset
select is(
  (select source::text from public.mark_entry
    where exam_subject_id = :'es_t2' and enrolment_id = :'enr1'),
  'manual',
  'but typing a DIFFERENT number does: the value is the teacher''s now, and source says so'
);
select is(
  (select ocr_job_id from public.mark_entry
    where exam_subject_id = :'es_t2' and enrolment_id = :'enr1'),
  null::uuid,
  'and it no longer points at a batch it did not come from'
);
select is(
  (select count(*)::int from public.v_ocr_mark_audit where job_id = :'job3'),
  1,
  'nothing is lost by that — the machine''s reading and the human who confirmed it stay put'
);

-- ═══════════════════════════════════════════════════════════════════════
-- A signed-off set takes no new machine opinion
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ select public.fn_open_ocr_job(%L, %L, 'theory',
              jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'question_no', 1, 'ocr_value', 91))) $$,
         :'es_mth', :'sec9b', :'enr1'),
  '42501',
  'marks_locked',
  'a paper that was approved gets no re-scan — FR-I17''s window is the way back in'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Append-only, against every caller
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ update public.ocr_review_action set final_value = 99 where job_id = %L $$, :'job1'),
  '42501',
  'an OCR review action is append-only',
  'an authenticated Exam Controller cannot rewrite what they confirmed'
);
select throws_ok(
  format($$ update public.ocr_mark_suggestion set ocr_value = 55 where job_id = %L $$, :'job1'),
  '42501',
  'an OCR suggestion is append-only',
  'nor make the machine agree with them after the fact'
);

reset role;
select set_config('request.jwt.claims', '', true);
set local role service_role;
select throws_ok(
  format($$ delete from public.ocr_review_action where job_id = %L $$, :'job1'),
  '42501',
  'an OCR review action is append-only',
  'a service_role key cannot erase the named human either'
);
select throws_ok(
  format($$ update public.ocr_mark_job set status = 'ready' where id = %L $$, :'job1'),
  '42501',
  'an OCR batch is append-only',
  'nor reopen a promoted batch to promote it again'
);
reset role;

select throws_ok(
  format($$ update public.ocr_review_action set actor_id = %L where job_id = %L $$,
         :'owner_uid', :'job1'),
  '42501',
  'an OCR review action is append-only',
  'and the table owner cannot move the confirmation onto somebody else'
);
select throws_ok(
  format($$ delete from public.ocr_mark_suggestion where job_id = %L $$, :'job1'),
  '42501',
  'an OCR suggestion is append-only',
  'nor delete what the machine read'
);
select throws_ok(
  format($$ delete from public.ocr_mark_job where id = %L $$, :'job1'),
  '42501',
  'an OCR batch is append-only',
  'nor the batch itself'
);
-- TRUNCATE fires no row trigger and consults no RLS.
select throws_ok(
  $$ truncate table public.ocr_review_action cascade $$,
  '42501',
  'an OCR review action is append-only',
  'TRUNCATE, which no row trigger and no policy would have caught'
);
select throws_ok(
  $$ truncate table public.ocr_mark_suggestion cascade $$,
  '42501',
  'an OCR suggestion is append-only',
  'and the same on the suggestions'
);
select throws_ok(
  $$ truncate table public.ocr_mark_job cascade $$,
  '42501',
  'an OCR batch is append-only',
  'and on the batch'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Who may confirm, and tenant isolation
-- ═══════════════════════════════════════════════════════════════════════

-- A teacher who does not teach the class cannot confirm its machine marks: the
-- person affirming a mark is the person who could have entered it by hand.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'outsider_uid')::text,
  true
);
select throws_ok(
  format($$ select public.fn_record_ocr_review(%L,
              jsonb_build_array(jsonb_build_object('enrolment_id', %L, 'question_no', 1))) $$,
         :'job3', :'enr1'),
  '42501',
  'FORBIDDEN',
  'a teacher who does not teach the class cannot confirm its machine marks'
);
select is(
  (select count(*)::int from public.ocr_review_action),
  0,
  'RLS: nor read the ones somebody else confirmed'
);

reset role;
select public.provision_tenant('other-ocr-co', 'Other OCR Co', 'owner@otherocr.test');
select id as other_tenant from public.tenant where slug = 'other-ocr-co' \gset
select id as other_campus from public.campus where tenant_id = :'other_tenant' \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'other_campus'), 'sub', :'owner_uid')::text,
  true
);
select is((select count(*)::int from public.ocr_mark_job), 0, 'RLS: another tenant sees no batches');
select is((select count(*)::int from public.ocr_mark_suggestion), 0, 'RLS: nor what a machine read for them');
select is((select count(*)::int from public.ocr_review_action), 0, 'RLS: nor who confirmed it');
select is((select count(*)::int from public.v_ocr_mark_audit), 0, 'RLS: nor the six-months-later audit');
select throws_ok(
  format($$ select public.fn_promote_ocr_marks(%L) $$, :'job3'),
  '42501',
  'FORBIDDEN',
  'RLS: and cannot promote another school''s batch, even holding its id'
);
select throws_ok(
  format($$ select public.fn_cancel_ocr_job(%L, 'reaching into another school') $$, :'job3'),
  '42501',
  'FORBIDDEN',
  'RLS: nor cancel one'
);

select * from finish();
rollback;
