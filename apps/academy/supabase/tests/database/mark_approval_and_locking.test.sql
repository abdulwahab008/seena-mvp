-- pgTAP tests for FR-I16: mark approval and locking.
--
--   AC1  40 candidates, 2 with neither a mark nor an exam status: approval is
--        refused and the 2 GR numbers are listed — in the refusal AND in the
--        queue the controller reads before clicking.
--   AC2  All 40 complete: mark_entry.status becomes 'locked', a mark_lock row
--        records approver and timestamp, and the teacher's sheet comes back
--        read-only on the next load.
--   AC3  A locked subject refuses every write — through fn_upsert_marks, by a
--        raw statement as service_role, and by the table owner — with
--        'marks_locked' from a TRIGGER, not from a policy.
--   AC4  Every subject in the term locked for a class makes term result
--        computation available FOR THAT CLASS while another class is still
--        marking; the term itself locks only when nothing is left anywhere.
--
-- Plus the append-only guard on mark_lock (authenticated, service_role, the
-- table owner and TRUNCATE, per the FR-T02/T08 precedent) and tenant
-- isolation.
begin;
select plan(53);

select public.provision_tenant('test-mark-approval-co', 'Mark Approval Co', 'owner@markapproval.test');
select id as tenant_id from public.tenant where slug = 'test-mark-approval-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_id' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@markapproval.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Mark Approval Owner');

-- The Exam Controller the user story is written about.
select gen_random_uuid() as controller_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'controller_uid', 'controller@markapproval.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'controller_uid', :'tenant_id', 'exam_controller', 'Rukhsana Bano');

-- The Physics teacher whose grid must come back read-only.
select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_uid', 'phy@markapproval.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_uid', :'tenant_id', 'subject_teacher', 'Nadia Aslam');

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
select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_urd', 4::smallint) as cs_urd \gset
-- Two sections of one class: exam_subject is per CLASS, approval is per
-- SECTION, and AC4's "for that class" has to be demonstrably narrower than
-- "for the term".
select public.create_section(:'campus_a', :'session_a', :'class9', 'A', 45) as sec9a \gset
select public.create_section(:'campus_a', :'session_a', :'class9', 'B', 45) as sec9b \gset
select public.assign_subject_teacher(:'sec9a', :'subj_phy', :'teacher_uid', current_date - 30) as _t \gset

select public.upsert_exam_term(:'campus_a', :'session_a', 'T1', 'First Term', 1::smallint, 100.00) as term_t1 \gset
select public.activate_exam_terms(:'session_a'::uuid, :'campus_a'::uuid) as _a \gset
select public.upsert_exam_subject(
  :'term_t1', :'cs_phy',
  '[{"component":"theory","max_marks":65,"pass_marks":23},
    {"component":"practical","max_marks":20,"pass_marks":7}]'::jsonb
) as es_phy \gset
select public.upsert_exam_subject(
  :'term_t1', :'cs_urd',
  '[{"component":"theory","max_marks":100,"pass_marks":33}]'::jsonb
) as es_urd \gset

-- AC1's forty, plus two in the other section.
reset role;
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', :'campus_a', 'GR-' || lpad(g::text, 4, '0'),
       'Candidate ' || lpad(g::text, 2, '0'), current_date - interval '14 years', 'male'
  from generate_series(1, 42) g;

insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, roll_no)
select :'tenant_id', :'campus_a', :'session_a', st.id, :'class9',
       case when st.gr_number <= 'GR-0040' then :'sec9a'::uuid else :'sec9b'::uuid end,
       case when st.gr_number <= 'GR-0040'
            then right(st.gr_number, 4)::int
            else right(st.gr_number, 4)::int - 40 end
  from public.student st
 where st.tenant_id = :'tenant_id';

select id as enr39 from public.enrolment where section_id = :'sec9a' and roll_no = 39 \gset
select id as enr40 from public.enrolment where section_id = :'sec9a' and roll_no = 40 \gset

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: two candidates with neither a mark nor an exam status
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'controller_uid')::text,
  true
);

-- Thirty-eight complete candidates. Rolls 39 and 40 are left with nothing at
-- all — no mark, and no exam status either.
select count(*)::int as seeded_phy
  from public.enrolment e,
       lateral (
         select public.fn_upsert_marks(jsonb_build_object(
           'exam_subject_id', :'es_phy',
           'marks', jsonb_build_array(
             jsonb_build_object('enrolment_id', e.id, 'component', 'theory',
                                'marks_obtained', 30 + (e.roll_no % 30)),
             jsonb_build_object('enrolment_id', e.id, 'component', 'practical',
                                'marks_obtained', 10 + (e.roll_no % 10)))))
       ) s
 where e.section_id = :'sec9a' and e.roll_no <= 38 \gset

select is(:'seeded_phy'::int, 38, 'thirty-eight of the forty are fully marked');

select throws_ok(
  format($$ select public.fn_approve_marks(%L, %L) $$, :'es_phy', :'sec9a'),
  '23514',
  '2 candidates have neither a mark nor an exam status: GR-0039, GR-0040',
  'AC1: approval is refused and the two GR numbers are listed, in the message itself'
);
select is(
  (select count(*)::int from public.mark_lock),
  0,
  'AC1: and no lock row is written by a refused approval'
);
select is(
  (select count(*)::int from public.mark_entry where exam_subject_id = :'es_phy' and status <> 'draft'),
  0,
  'AC1: nor does any mark leave draft'
);

-- The controller sees the same two names BEFORE clicking, which is the point
-- of the queue: a refusal is a bad way to learn who is missing.
select is(
  (select jsonb_array_length(sub -> 'completeness' -> 'not_started')
     from jsonb_array_elements(public.fn_mark_approval_queue(:'term_t1', :'sec9a') -> 'subjects') sub
    where (sub ->> 'exam_subject_id')::uuid = :'es_phy'),
  2,
  'AC1: the approval queue names them before anything is attempted'
);
select is(
  (select sub -> 'completeness' -> 'not_started' -> 0 ->> 'gr_number'
     from jsonb_array_elements(public.fn_mark_approval_queue(:'term_t1', :'sec9a') -> 'subjects') sub
    where (sub ->> 'exam_subject_id')::uuid = :'es_phy'),
  'GR-0039',
  'AC1: with their GR numbers, in roll order'
);

-- A candidate who did not sit the paper is COMPLETE — there is nothing to
-- enter for them, and trg_block_marks_when_not_present would refuse it.
select public.set_exam_attendance(:'es_phy', :'enr40', 'absent', 'medical') as _abs \gset
select throws_ok(
  format($$ select public.fn_approve_marks(%L, %L) $$, :'es_phy', :'sec9a'),
  '23514',
  '1 candidate has neither a mark nor an exam status: GR-0039',
  'recording one of them absent settles that candidate — only the other is still missing'
);

-- Half a paper is not a marked paper: theory in, practical still blank.
select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_phy',
  'marks', jsonb_build_array(jsonb_build_object(
    'enrolment_id', :'enr39', 'component', 'theory', 'marks_obtained', 44)))) as _p \gset
select throws_ok(
  format($$ select public.fn_approve_marks(%L, %L) $$, :'es_phy', :'sec9a'),
  '23514',
  '1 candidate is missing a component mark: GR-0039 (practical)',
  'a candidate marked for one component of two is refused separately, naming the component'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: the approval
-- ═══════════════════════════════════════════════════════════════════════

select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_phy',
  'marks', jsonb_build_array(jsonb_build_object(
    'enrolment_id', :'enr39', 'component', 'practical', 'marks_obtained', 15)))) as _q \gset

select is(
  (public.fn_approve_marks(:'es_phy', :'sec9a') ->> 'marks_locked')::int,
  78,
  'AC2: the complete set approves — 39 sitting candidates x 2 components'
);
select is(
  (select count(*)::int from public.mark_entry m
     join public.enrolment e on e.id = m.enrolment_id
    where m.exam_subject_id = :'es_phy' and e.section_id = :'sec9a' and m.status <> 'locked'),
  0,
  'AC2: every mark in the set is now ''locked'''
);
select is(
  (select count(*)::int from public.mark_lock
    where exam_subject_id = :'es_phy' and section_id = :'sec9a'),
  1,
  'AC2: with exactly one lock row for the (paper, section)'
);
select is(
  (select locked_by from public.mark_lock where exam_subject_id = :'es_phy' and section_id = :'sec9a'),
  :'controller_uid'::uuid,
  'AC2: the lock row records who approved it'
);
select ok(
  (select locked_at is not null and locked_at <= clock_timestamp()
     from public.mark_lock where exam_subject_id = :'es_phy' and section_id = :'sec9a'),
  'AC2: and when'
);
select is(
  (select candidate_count from public.mark_lock
    where exam_subject_id = :'es_phy' and section_id = :'sec9a'),
  40,
  'AC2: and what was signed off — all forty candidates, absentee included'
);
select throws_ok(
  format($$ select public.fn_approve_marks(%L, %L) $$, :'es_phy', :'sec9a'),
  '23505',
  'MARKS_ALREADY_APPROVED',
  'AC2: a set is signed off once'
);

-- "the teacher's grid renders read-only on the next load"
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'teacher_uid')::text,
  true
);
select is(
  (public.fn_mark_entry_sheet(:'term_t1', :'sec9a', :'subj_phy') ->> 'is_locked')::boolean,
  true,
  'AC2: the sheet says the set is locked'
);
select is(
  (public.fn_mark_entry_sheet(:'term_t1', :'sec9a', :'subj_phy') ->> 'can_enter')::boolean,
  false,
  'AC2: and that the teacher who entered them may no longer write'
);
select is(
  public.fn_mark_entry_sheet(:'term_t1', :'sec9a', :'subj_phy') -> 'lock' ->> 'locked_by_name',
  'Rukhsana Bano',
  'AC2: naming the controller who signed it off, so the grid can say why'
);

-- Read-only for the approver too: an approval is not a private key.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'controller_uid')::text,
  true
);
select is(
  (public.fn_mark_entry_sheet(:'term_t1', :'sec9a', :'subj_phy') ->> 'can_enter')::boolean,
  false,
  'AC2: and not for the Exam Controller who approved it either'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: 'marks_locked', from a trigger, for every caller
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 60)))) $$,
         :'es_phy', :'enr39'),
  '42501',
  'marks_locked',
  'AC3: the ordinary write path is refused'
);
select is(
  (select marks_obtained from public.mark_entry
    where exam_subject_id = :'es_phy' and enrolment_id = :'enr39' and component_code = 'theory'),
  44.00::numeric,
  'AC3: and the approved value stands'
);

reset role;
select set_config('request.jwt.claims', '', true);
set local role service_role;
select throws_ok(
  format($$ update public.mark_entry m set marks_obtained = 1
             from public.enrolment e
            where e.id = m.enrolment_id and m.exam_subject_id = %L and e.section_id = %L $$,
         :'es_phy', :'sec9a'),
  '42501',
  'marks_locked',
  'AC3: a service-role job has BYPASSRLS and every grant, and is still refused'
);
select throws_ok(
  format($$ delete from public.mark_entry m
            using public.enrolment e
            where e.id = m.enrolment_id and m.exam_subject_id = %L and e.section_id = %L $$,
         :'es_phy', :'sec9a'),
  '42501',
  'marks_locked',
  'AC3: nor may it delete a signed-off mark'
);
-- A new row in a signed-off set is an edit to that set.
select throws_ok(
  format($$ insert into public.mark_entry
              (tenant_id, campus_id, exam_subject_id, enrolment_id, component_code, marks_obtained)
            values (%L, %L, %L, %L, 'internal', 5) $$,
         :'tenant_id', :'campus_a', :'es_phy', :'enr39'),
  '42501',
  'marks_locked',
  'AC3: and an OCR promoter cannot ADD a mark to the locked set either'
);
reset role;

-- The table owner, writing the statement by hand.
select throws_ok(
  format($$ update public.mark_entry m set marks_obtained = 1
             from public.enrolment e
            where e.id = m.enrolment_id and m.exam_subject_id = %L and e.section_id = %L $$,
         :'es_phy', :'sec9a'),
  '42501',
  'marks_locked',
  'AC3: it is a trigger, so the table owner is held to it too'
);

-- Another section of the same paper is untouched: the lock is per section.
select id as enr9b1 from public.enrolment where section_id = :'sec9b' and roll_no = 1 \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'controller_uid')::text,
  true
);
select lives_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 50)))) $$,
         :'es_phy', :'enr9b1'),
  'AC3: 9-B''s Physics marks are unaffected — the lock is per (paper, section)'
);

-- ═══════════════════════════════════════════════════════════════════════
-- mark_lock is append-only
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ update public.mark_lock set unlock_state = 'unlocked' where exam_subject_id = %L $$, :'es_phy'),
  '42501',
  'mark approval is append-only',
  'an authenticated Exam Controller cannot reach in and unlock the row'
);
-- DELETE keeps USING false, so an authenticated caller's statement qualifies
-- zero rows and the lock survives silently rather than loudly.
select lives_ok(
  format($$ delete from public.mark_lock where exam_subject_id = %L $$, :'es_phy'),
  'and their DELETE qualifies no rows at all'
);
select is(
  (select count(*)::int from public.mark_lock where exam_subject_id = :'es_phy'),
  1,
  'so the lock row is still there afterwards'
);

reset role;
select set_config('request.jwt.claims', '', true);
set local role service_role;
select throws_ok(
  format($$ update public.mark_lock set locked_by = null where exam_subject_id = %L $$, :'es_phy'),
  '42501',
  'mark approval is append-only',
  'a leaked service_role key cannot rewrite the approver either'
);
select throws_ok(
  format($$ delete from public.mark_lock where exam_subject_id = %L $$, :'es_phy'),
  '42501',
  'mark approval is append-only',
  'nor delete the lock out from under the marks'
);
reset role;
select throws_ok(
  format($$ update public.mark_lock set locked_at = now() where exam_subject_id = %L $$, :'es_phy'),
  '42501',
  'mark approval is append-only',
  'and neither can the table owner'
);
select throws_ok(
  format($$ delete from public.mark_lock where exam_subject_id = %L $$, :'es_phy'),
  '42501',
  'mark approval is append-only',
  'in either direction'
);
-- TRUNCATE fires no row trigger and consults no RLS — FR-T08's hole, closed.
select throws_ok(
  $$ truncate table public.mark_lock cascade $$,
  '42501',
  'mark approval is append-only',
  'and TRUNCATE, which no row trigger and no policy would have caught'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: result computation becomes available, per class
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'controller_uid')::text,
  true
);

select is(
  (public.fn_term_result_ready(:'term_t1', :'sec9a') ->> 'ready')::boolean,
  false,
  'AC4: one of two subjects locked is not a computable term'
);
select is(
  public.fn_term_result_ready(:'term_t1', :'sec9a') -> 'pending_subjects' ->> 0,
  'Urdu',
  'AC4: and the gate names what is still open'
);

-- 9-A's Urdu, marked and approved.
select count(*)::int as seeded_urd
  from public.enrolment e,
       lateral (
         select public.fn_upsert_marks(jsonb_build_object(
           'exam_subject_id', :'es_urd',
           'marks', jsonb_build_array(jsonb_build_object(
             'enrolment_id', e.id, 'component', 'theory',
             'marks_obtained', 40 + (e.roll_no % 40)))))
       ) s
 where e.section_id = :'sec9a' \gset

select is(
  (public.fn_approve_marks(:'es_urd', :'sec9a') ->> 'term_locked')::boolean,
  false,
  'AC4: 9-A finishing does NOT freeze the term — 9-B has not marked anything'
);
select is(
  (public.fn_term_result_ready(:'term_t1', :'sec9a') ->> 'ready')::boolean,
  true,
  'AC4: but 9-A''s term result computation is available the moment 9-A''s last subject locks'
);
select is(
  (public.fn_term_result_ready(:'term_t1', :'sec9b') ->> 'ready')::boolean,
  false,
  'AC4: and 9-B''s is not, which is what "for that class" means'
);
select is(
  (select status::text from public.exam_term where id = :'term_t1'),
  'active',
  'AC4: the exam term is still active — FR-I01''s term-wide freeze has not been called'
);

-- 9-B, both papers.
select count(*)::int as seeded_b
  from public.enrolment e,
       lateral (
         select public.fn_upsert_marks(jsonb_build_object(
           'exam_subject_id', :'es_phy',
           'marks', jsonb_build_array(
             jsonb_build_object('enrolment_id', e.id, 'component', 'theory', 'marks_obtained', 40),
             jsonb_build_object('enrolment_id', e.id, 'component', 'practical', 'marks_obtained', 12))))
       ) s
 where e.section_id = :'sec9b' \gset
select count(*)::int as seeded_b2
  from public.enrolment e,
       lateral (
         select public.fn_upsert_marks(jsonb_build_object(
           'exam_subject_id', :'es_urd',
           'marks', jsonb_build_array(jsonb_build_object(
             'enrolment_id', e.id, 'component', 'theory', 'marks_obtained', 55))))
       ) s
 where e.section_id = :'sec9b' \gset

select is(
  (public.fn_approve_marks(:'es_phy', :'sec9b') ->> 'term_locked')::boolean,
  false,
  'AC4: three of four (paper, section) pairs is still not the whole term'
);
select is(
  (public.fn_approve_marks(:'es_urd', :'sec9b') ->> 'term_locked')::boolean,
  true,
  'AC4: the LAST approval in the term calls FR-I01''s lock_exam_term() — the seam it was built for'
);
select is(
  (select status::text from public.exam_term where id = :'term_t1'),
  'locked',
  'AC4: and the term is locked, so weightage and component setup close with it'
);
select throws_ok(
  format($$ select public.set_exam_term_weight(%L, 50.00) $$, :'term_t1'),
  '42501',
  'exam term weightage is locked by approved marks — raise a result-recompute request',
  'AC4: FR-I01''s AC3 freeze is now biting for the reason it was written'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Who may approve
-- ═══════════════════════════════════════════════════════════════════════

select public.upsert_exam_term(:'campus_a', :'session_a', 'T2', 'Second Term', 2::smallint, 0.00) as term_t2 \gset
select public.activate_exam_terms(:'session_a'::uuid, :'campus_a'::uuid) as _a2 \gset
select public.upsert_exam_subject(
  :'term_t2', :'cs_urd', '[{"component":"theory","max_marks":50,"pass_marks":17}]'::jsonb
) as es_urd2 \gset

-- A section of a different class, so "this section does not sit this paper"
-- can be asked at all.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);
select id as class10 from public.class_level where tenant_id = :'tenant_id' and code = '10' \gset
select public.create_section(:'campus_a', :'session_a', :'class10', 'A', 40) as sec10a \gset

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'teacher_uid')::text,
  true
);
select throws_ok(
  format($$ select public.fn_approve_marks(%L, %L) $$, :'es_urd2', :'sec9a'),
  '42501',
  'FORBIDDEN',
  'the teacher who enters the marks is not the person who signs them off'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'controller_uid')::text,
  true
);
select throws_ok(
  format($$ select public.fn_approve_marks(%L, %L) $$, :'es_urd2', :'sec10a'),
  '23514',
  'SECTION_NOT_IN_EXAM_SUBJECT',
  'and a paper cannot be approved against a section that never sat it'
);

-- ═══════════════════════════════════════════════════════════════════════
-- A mark is not re-judged by a rule that changed after it was entered
-- ═══════════════════════════════════════════════════════════════════════

-- FR-I12 stores marks at the campus's precision AT ENTRY, and its own tests
-- assert a stored 45.5 is "not retro-actively refused" when the campus later
-- goes back to whole marks. Approval moves a status and touches no number, so
-- the same has to hold there — otherwise a campus that tightened its precision
-- would find a section permanently unapprovable, pointed at a mark nobody is
-- editing.
select public.set_mark_precision(:'campus_a', 1::smallint) as _p1 \gset
select count(*)::int as seeded_half
  from public.enrolment e,
       lateral (
         select public.fn_upsert_marks(jsonb_build_object(
           'exam_subject_id', :'es_urd2',
           'marks', jsonb_build_array(jsonb_build_object(
             'enrolment_id', e.id, 'component', 'theory', 'marks_obtained', 45.5))))
       ) s
 where e.section_id = :'sec9b' \gset
select public.set_mark_precision(:'campus_a', 0::smallint) as _p0 \gset

select throws_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 45.5)))) $$,
         :'es_urd2', :'enr9b1'),
  '23514',
  'whole numbers only',
  'the tightened precision still refuses a NEW half mark'
);
select lives_ok(
  format($$ select public.fn_approve_marks(%L, %L) $$, :'es_urd2', :'sec9b'),
  'but approving the marks already entered under the old rule is not a re-judgement'
);
select is(
  (select count(*)::int from public.mark_entry m
     join public.enrolment e on e.id = m.enrolment_id
    where m.exam_subject_id = :'es_urd2' and e.section_id = :'sec9b' and m.marks_obtained = 45.5),
  2,
  'and the half marks are still exactly what was entered'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Tenant isolation
-- ═══════════════════════════════════════════════════════════════════════

reset role;
select public.provision_tenant('other-mark-approval-co', 'Other Co', 'owner@othermarkapproval.test');
select id as other_tenant from public.tenant where slug = 'other-mark-approval-co' \gset
select id as other_campus from public.campus where tenant_id = :'other_tenant' \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'other_campus'), 'sub', :'owner_uid')::text,
  true
);
select is((select count(*)::int from public.mark_lock), 0, 'RLS: another tenant sees no approvals');
select throws_ok(
  format($$ select public.fn_approve_marks(%L, %L) $$, :'es_urd2', :'sec9a'),
  'P0002',
  'EXAM_SUBJECT_NOT_FOUND',
  'RLS: and cannot approve another tenant''s paper, even holding its id'
);
select throws_ok(
  format($$ select public.fn_mark_approval_queue(%L, %L) $$, :'term_t1', :'sec9a'),
  '42501',
  'FORBIDDEN',
  'RLS: nor read its approval queue'
);
select throws_ok(
  format($$ select public.fn_term_result_ready(%L, %L) $$, :'term_t1', :'sec9a'),
  '42501',
  'FORBIDDEN',
  'RLS: nor whether its results are computable'
);

select * from finish();
rollback;
