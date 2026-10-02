-- pgTAP tests for FR-I12: teacher mark entry with validation.
--
--   AC1  Physics theory maximum 65, 70 typed: refused with "max 65", and
--        nothing persisted — asserted through fn_upsert_marks and again
--        through a raw INSERT as service_role, where the trigger is what
--        answers.
--   AC2  mark_precision 0 (the default): 45.5 refused with "whole numbers
--        only". Raised to 1: 45.5 saves, 45.55 does not.
--   AC3  A section of 40, entered one cell at a time down a column the way
--        an autosaving grid does: 40 rows, every one of them 'draft'.
--   AC4  The same 40-cell batch flushed twice under one client_batch_id:
--        exactly one row per (exam_subject, enrolment, component), the
--        ORIGINAL response replayed, and no second batch ledger row.
--
-- Plus the two controls the acceptance criteria do not name but the FR's
-- Supabase objects do: teacher scoping (the grid is not "anyone in my
-- campus") and the FR-I16 freeze, reused from FR-I01 rather than reinvented.
begin;
select plan(56);

select public.provision_tenant('test-mark-entry-co', 'Mark Entry Co', 'owner@markentry.test');
select id as tenant_id from public.tenant where slug = 'test-mark-entry-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_id' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@markentry.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Mark Entry Owner');

-- The Physics teacher AC1 is written about, allocated to the section.
select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_uid', 'phy@markentry.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_uid', :'tenant_id', 'subject_teacher', 'Nadia Aslam');

-- A second teacher, of the same campus, who teaches this section nothing.
select gen_random_uuid() as other_teacher_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_teacher_uid', 'urdu@markentry.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_teacher_uid', :'tenant_id', 'subject_teacher', 'Imran Shah');

-- A third, assigned by a PUBLISHED timetable slot and by nothing else.
select gen_random_uuid() as tt_teacher_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'tt_teacher_uid', 'tt@markentry.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'tt_teacher_uid', :'tenant_id', 'subject_teacher', 'Sara Bilal');

select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);

select public.create_subject('PHY', 'Physics', 'طبیعیات') as subj_phy \gset
select public.create_subject('URD', 'Urdu', 'اردو')       as subj_urd \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_phy', 5::smallint) as cs_phy \gset
select public.create_section(:'campus_a', :'session_a', :'class9', 'A', 45) as sec9 \gset
select public.assign_subject_teacher(:'sec9', :'subj_phy', :'teacher_uid', current_date - 30) as _t \gset

select public.upsert_exam_term(:'campus_a', :'session_a', 'T1', 'First Term', 1::smallint, 100.00) as term_t1 \gset
select public.activate_exam_terms(:'session_a'::uuid, :'campus_a'::uuid) as _a \gset
-- AC1's paper: theory out of 65, plus a practical so the grid has two
-- columns and "max 65" is demonstrably the THEORY maximum, not the paper's.
select public.upsert_exam_subject(
  :'term_t1', :'cs_phy',
  '[{"component":"theory","max_marks":65,"pass_marks":23},
    {"component":"practical","max_marks":20,"pass_marks":7}]'::jsonb
) as es_phy \gset

-- AC3's section of 40.
reset role;
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', :'campus_a', 'GR-' || lpad(g::text, 4, '0'),
       'Candidate ' || lpad(g::text, 2, '0'), current_date - interval '14 years', 'male'
  from generate_series(1, 40) g;

insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, roll_no)
select :'tenant_id', :'campus_a', :'session_a', st.id, :'class9', :'sec9',
       row_number() over (order by st.gr_number)
  from public.student st
 where st.tenant_id = :'tenant_id'
 order by st.gr_number;

select id as enr1 from public.enrolment where section_id = :'sec9' and roll_no = 1 \gset
select id as enr2 from public.enrolment where section_id = :'sec9' and roll_no = 2 \gset

-- A PUBLISHED timetable version putting the third teacher on this paper.
insert into public.timetable_version (id, tenant_id, campus_id, session_id, shift, name, version_no, status, published_at)
values (gen_random_uuid(), :'tenant_id', :'campus_a', :'session_a', 'MORNING', 'Published TT', 1, 'PUBLISHED', now());
select id as tt_version from public.timetable_version where tenant_id = :'tenant_id' \gset
insert into public.timetable_slot (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, subject_id, staff_id)
values (:'tenant_id', :'campus_a', :'tt_version', :'sec9', 1, 1, :'subj_phy', :'tt_teacher_uid');

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: "max 65"
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'teacher_uid')::text,
  true
);

select throws_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 70)))) $$,
         :'es_phy', :'enr1'),
  '23514',
  'max 65',
  'AC1: 70 into a theory paper out of 65 is refused, in the acceptance criteria''s own words'
);
select is(
  (select count(*)::int from public.mark_entry where exam_subject_id = :'es_phy'),
  0,
  'AC1: and no value is persisted — not the 70, not a truncated 65'
);
select lives_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 65)))) $$,
         :'es_phy', :'enr1'),
  'AC1: 65 exactly is accepted — "max 65" means at most, not below'
);
select is(
  (select marks_obtained from public.mark_entry
    where exam_subject_id = :'es_phy' and enrolment_id = :'enr1' and component_code = 'theory'),
  65.00::numeric,
  'AC1: and it is stored as entered'
);
-- The practical's own maximum is its own: 20, not the paper's 85.
select throws_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'practical', 'marks_obtained', 21)))) $$,
         :'es_phy', :'enr1'),
  '23514',
  'max 20',
  'AC1: each component is bounded by its OWN maximum'
);
select throws_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', -1)))) $$,
         :'es_phy', :'enr1'),
  '23514',
  'marks cannot be negative',
  'a negative mark is refused too — the requirement names it alongside the maximum'
);
select throws_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'viva', 'marks_obtained', 5)))) $$,
         :'es_phy', :'enr1'),
  '23514',
  'MARK_COMPONENT_NOT_CONFIGURED',
  'and a component this paper does not have has no maximum to be inside'
);

-- The trigger, not the function, is the boundary: service_role has BYPASSRLS
-- and every table grant, and is still refused.
reset role;
select set_config('request.jwt.claims', '', true);
set local role service_role;
select throws_ok(
  format($$ insert into public.mark_entry
              (tenant_id, campus_id, exam_subject_id, enrolment_id, component_code, marks_obtained)
            values (%L, %L, %L, %L, 'theory', 70) $$,
         :'tenant_id', :'campus_a', :'es_phy', :'enr2'),
  '23514',
  'max 65',
  'AC1: trg_mark_range_check refuses it at the table too, whatever the caller'
);
reset role;

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: mark_precision
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'teacher_uid')::text,
  true
);

select is(
  app.fn_mark_precision(:'campus_a'::uuid),
  0::smallint,
  'AC2: a campus that never configured mark_precision awards whole marks'
);
select throws_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 45.5)))) $$,
         :'es_phy', :'enr2'),
  '23514',
  'whole numbers only',
  'AC2: 45.5 at precision 0 is refused, in the acceptance criteria''s own words'
);
select is(
  (select count(*)::int from public.mark_entry where enrolment_id = :'enr2'),
  0,
  'AC2: and nothing is persisted for that candidate'
);
select lives_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 45.00)))) $$,
         :'es_phy', :'enr2'),
  'AC2: 45.00 IS a whole number — the rule is about the value, not the typing'
);

-- A campus that awards half marks is a setting away, and only the Exam
-- office can move it.
select throws_ok(
  format($$ select public.set_mark_precision(%L, 1::smallint) $$, :'campus_a'),
  '42501',
  'FORBIDDEN',
  'a Subject Teacher cannot widen the precision to fit their own entry'
);
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);
select lives_ok(
  format($$ select public.set_mark_precision(%L, 1::smallint) $$, :'campus_a'),
  'the exam office can'
);
select throws_ok(
  format($$ select public.set_mark_precision(%L, 3::smallint) $$, :'campus_a'),
  '23514',
  'MARK_PRECISION_OUT_OF_RANGE',
  'but not past two decimal places — beyond that it stops being a mark'
);
select lives_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 45.5)))) $$,
         :'es_phy', :'enr2'),
  'AC2: at precision 1 the same 45.5 saves'
);
select is(
  (select marks_obtained from public.mark_entry
    where exam_subject_id = :'es_phy' and enrolment_id = :'enr2' and component_code = 'theory'),
  45.50::numeric,
  'AC2: as 45.5, exactly'
);
select throws_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 45.55)))) $$,
         :'es_phy', :'enr2'),
  '23514',
  'at most 1 decimal place',
  'AC2: and one decimal is one decimal'
);
select lives_ok(
  format($$ select public.set_mark_precision(%L, 0::smallint) $$, :'campus_a'),
  'precision back to whole marks for the rest of these tests'
);
-- The 45.5 already stored is left alone: tightening the rule is not a
-- retro-active refusal of marks entered under the old one.
select is(
  (select marks_obtained from public.mark_entry
    where exam_subject_id = :'es_phy' and enrolment_id = :'enr2' and component_code = 'theory'),
  45.50::numeric,
  'and the 45.5 already entered is not retro-actively refused'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: 40 candidates, one cell at a time, all draft
-- ═══════════════════════════════════════════════════════════════════════

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'teacher_uid')::text,
  true
);

-- Exactly what an autosaving column does: one call per cell, moving down.
select count(*)::int as autosaved
  from public.enrolment e,
       lateral (
         select public.fn_upsert_marks(jsonb_build_object(
           'exam_subject_id', :'es_phy',
           'marks', jsonb_build_array(jsonb_build_object(
             'enrolment_id', e.id, 'component', 'theory',
             'marks_obtained', 30 + (e.roll_no % 30)))))
       ) as saved
 where e.section_id = :'sec9' \gset

select is(:'autosaved'::int, 40, 'AC3: forty cells, forty autosaves, one round trip each');
select is(
  (select count(*)::int from public.mark_entry
    where exam_subject_id = :'es_phy' and component_code = 'theory'),
  40,
  'AC3: a section of 40 has 40 theory marks — one row per candidate'
);
select is(
  (select count(*)::int from public.mark_entry
    where exam_subject_id = :'es_phy' and component_code = 'theory' and status <> 'draft'),
  0,
  'AC3: and every one of them is a DRAFT — nothing is submitted by typing it'
);
select is(
  (select marks_obtained from public.mark_entry
    where exam_subject_id = :'es_phy' and enrolment_id = :'enr1' and component_code = 'theory'),
  31.00::numeric,
  'AC3: the autosave overwrote the earlier 65 for candidate 1 rather than adding a second row'
);
select ok(
  (select count(*)::int from public.mark_entry_batch) = 0,
  'AC3: an online autosave writes no batch ledger row — a null client_batch_id is the ordinary save'
);

-- The sheet a teacher reloads on: the roster, the columns and what is
-- already entered, in one call.
select is(
  jsonb_array_length(public.fn_mark_entry_sheet(:'term_t1', :'sec9', :'subj_phy') -> 'students'),
  40,
  'the sheet returns all forty candidates'
);
select is(
  (public.fn_mark_entry_sheet(:'term_t1', :'sec9', :'subj_phy') -> 'students' -> 0 -> 'marks' ->> 'theory')::numeric,
  31.00::numeric,
  'with the marks already entered, keyed by component'
);
select is(
  (public.fn_mark_entry_sheet(:'term_t1', :'sec9', :'subj_phy') ->> 'can_enter')::boolean,
  true,
  'and tells the assigned teacher they may write'
);
select is(
  (public.fn_mark_entry_sheet(:'term_t1', :'sec9', :'subj_phy') ->> 'mark_precision')::int,
  0,
  'and how many decimals this campus allows, so the grid can refuse before the round trip'
);
select is(
  (public.fn_mark_entry_sheet(:'term_t1', :'sec9', :'subj_phy') ->> 'total_max_marks')::int,
  85,
  'and carries FR-I02''s denominator through unchanged'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: one batch, flushed twice
-- ═══════════════════════════════════════════════════════════════════════

select gen_random_uuid() as batch_id \gset
select jsonb_build_object(
         'exam_subject_id', :'es_phy',
         'marks', jsonb_agg(jsonb_build_object(
                    'enrolment_id', e.id, 'component', 'practical',
                    'marks_obtained', 10 + (e.roll_no % 10)))
       )::text as queued_payload
  from public.enrolment e where e.section_id = :'sec9' \gset

select is(
  (public.fn_upsert_marks(:'queued_payload'::jsonb, :'batch_id') ->> 'saved')::int,
  40,
  'AC4: the queue flushes forty practical marks in ONE call'
);
select is(
  (select count(*)::int from public.mark_entry
    where exam_subject_id = :'es_phy' and component_code = 'practical'),
  40,
  'AC4: exactly one row per (exam_subject, enrolment, component)'
);

-- The connection dropped before the ack: the device sends it again.
select is(
  (public.fn_upsert_marks(:'queued_payload'::jsonb, :'batch_id') ->> 'saved')::int,
  40,
  'AC4: a replay returns the ORIGINAL result, not a fresh count'
);
select is(
  (public.fn_upsert_marks(:'queued_payload'::jsonb, :'batch_id') ->> 'replayed')::boolean,
  true,
  'AC4: and says so, rather than pretending it did the work twice'
);
select is(
  (select count(*)::int from public.mark_entry
    where exam_subject_id = :'es_phy' and component_code = 'practical'),
  40,
  'AC4: with NO duplicates — still forty rows after three flushes of one batch'
);
select is(
  (select count(*)::int from public.mark_entry_batch where client_batch_id = :'batch_id'),
  1,
  'AC4: and one ledger row for the batch, however many times it arrived'
);
select is(
  (select count(*)::int from public.mark_entry where exam_subject_id = :'es_phy'),
  80,
  'AC4: theory and practical are separate cells — 40 of each, not 40 in total'
);

-- A different batch id genuinely re-does the work: idempotency is per
-- submission, not a blanket "ignore repeats".
select gen_random_uuid() as batch_id2 \gset
select is(
  (public.fn_upsert_marks(
     jsonb_build_object('exam_subject_id', :'es_phy',
       'marks', jsonb_build_array(jsonb_build_object(
         'enrolment_id', :'enr1', 'component', 'practical', 'marks_obtained', 19))),
     :'batch_id2') ->> 'saved')::int,
  1,
  'a NEW batch id is new work — the correction lands'
);
select is(
  (select marks_obtained from public.mark_entry
    where exam_subject_id = :'es_phy' and enrolment_id = :'enr1' and component_code = 'practical'),
  19.00::numeric,
  'and overwrites the queued value rather than duplicating the cell'
);

-- Clearing a cell removes the row. There is no null mark and no zero
-- standing in for one — the distinction FR-I11 and FR-J02 depend on.
select is(
  (public.fn_upsert_marks(
     jsonb_build_object('exam_subject_id', :'es_phy',
       'marks', jsonb_build_array(jsonb_build_object(
         'enrolment_id', :'enr1', 'component', 'practical', 'marks_obtained', null)))) ->> 'saved')::int,
  0,
  'clearing a cell is a delete, not a write'
);
select is(
  (select count(*)::int from public.mark_entry
    where exam_subject_id = :'es_phy' and enrolment_id = :'enr1' and component_code = 'practical'),
  0,
  'and leaves NO row — never a null mark, never a zero standing in for one'
);
select ok(
  (select bool_and(marks_obtained is not null) from public.mark_entry),
  'marks_obtained is never null anywhere: a mark is always a number'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Teacher scoping
-- ═══════════════════════════════════════════════════════════════════════

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'other_teacher_uid')::text,
  true
);
select throws_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 60)))) $$,
         :'es_phy', :'enr1'),
  '42501',
  'FORBIDDEN',
  'a teacher of the same campus who does not teach this class-subject cannot enter its marks'
);
select is(
  (public.fn_mark_entry_sheet(:'term_t1', :'sec9', :'subj_phy') ->> 'can_enter')::boolean,
  false,
  'and the sheet tells them so before they type anything'
);
select is(
  (select count(*)::int from public.mark_entry),
  0,
  'RLS: nor can they read the marks — marks_teacher_own_section is not "anyone in my campus"'
);

-- The timetable path the FR names, on its own.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'tt_teacher_uid')::text,
  true
);
select lives_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 55)))) $$,
         :'es_phy', :'enr1'),
  'a teacher assigned by a PUBLISHED timetable slot may enter marks'
);
select ok(
  (select count(*)::int from public.mark_entry) > 0,
  'RLS: and read them back'
);

-- The Exam Controller keying in a paper the teacher never submitted is the
-- ordinary case, not an exception.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);
select lives_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 58)))) $$,
         :'es_phy', :'enr1'),
  'an Exam Controller in campus scope may enter marks for any section'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The FR-I16 freeze, reused from FR-I01
-- ═══════════════════════════════════════════════════════════════════════

select lives_ok(
  format($$ select public.lock_exam_term(%L) $$, :'term_t1'),
  'FR-I16 seam: the term is locked when its marks are approved'
);
select throws_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 61)))) $$,
         :'es_phy', :'enr1'),
  '42501',
  'marks are locked by approval — raise a result-recompute request',
  'and marks stop being editable the moment it is'
);
select is(
  (select marks_obtained from public.mark_entry
    where exam_subject_id = :'es_phy' and enrolment_id = :'enr1' and component_code = 'theory'),
  58.00::numeric,
  'the approved value stands'
);

reset role;
set local role service_role;
select throws_ok(
  format($$ update public.mark_entry set marks_obtained = 1
             where exam_subject_id = %L and enrolment_id = %L and component_code = 'theory' $$,
         :'es_phy', :'enr1'),
  '42501',
  'marks are locked by approval — raise a result-recompute request',
  'the freeze is a TRIGGER, so service_role does not walk past it either'
);
select throws_ok(
  format($$ delete from public.mark_entry
             where exam_subject_id = %L and enrolment_id = %L and component_code = 'theory' $$,
         :'es_phy', :'enr1'),
  '42501',
  'marks are locked by approval — raise a result-recompute request',
  'nor can a locked mark be deleted out from under the result'
);
reset role;

-- ═══════════════════════════════════════════════════════════════════════
-- Tenant isolation
-- ═══════════════════════════════════════════════════════════════════════

select public.provision_tenant('other-mark-entry-co', 'Other Co', 'owner@othermark.test');
select id as other_tenant from public.tenant where slug = 'other-mark-entry-co' \gset
select id as other_campus from public.campus where tenant_id = :'other_tenant' \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'other_campus'), 'sub', :'owner_uid')::text,
  true
);
select is((select count(*)::int from public.mark_entry), 0, 'RLS: another tenant sees no marks');
select is((select count(*)::int from public.mark_entry_batch), 0, 'RLS: nor any batch ledger rows');
select throws_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 10)))) $$,
         :'es_phy', :'enr1'),
  '42501',
  'FORBIDDEN',
  'RLS: and cannot write to another tenant''s paper, even holding its id'
);

select * from finish();
rollback;
