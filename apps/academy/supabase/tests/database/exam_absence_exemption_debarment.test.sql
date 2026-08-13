-- pgTAP tests for FR-I11: absent, exempt and debarred handling.
--
--   AC1  A candidate marked Absent for Class 9 Maths Final: 45 marks are
--        refused with "candidate is marked Absent for this paper", from the
--        writer and from a raw INSERT as service_role.
--   AC2  A non-Muslim candidate Exempt from Islamiat and taking Ethics:
--        Islamiat contributes 0 obtained AND 0 to the maximum, so the
--        denominator SHRINKS — asserted as an actual percentage, computed
--        the way FR-J02 will compute it, against the same candidate's
--        classmate who sat the paper.
--   AC3  A candidate marked Absent: 0 obtained against the paper's FULL
--        maximum, and the report symbol is 'AB'.
--   AC4  Marks approved, then the status is changed: refused, and the
--        refusal names the break-glass path.
--
-- The point of this FR is that FR-J02 cannot get the arithmetic wrong, so
-- the arithmetic itself is asserted here rather than only the storage.
begin;
select plan(51);

select public.provision_tenant('test-exam-absence-co', 'Exam Absence Co', 'owner@examabsence.test');
select id as tenant_id from public.tenant where slug = 'test-exam-absence-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_id' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@examabsence.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Absence Owner');

select gen_random_uuid() as ec_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ec_uid', 'controller@examabsence.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ec_uid', :'tenant_id', 'exam_controller', 'Shaista Kamal');

select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_uid', 'maths@examabsence.test', 'x', now(), 'authenticated', 'authenticated');
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

-- Maths (AC1/AC3), Islamiat and Ethics (AC2 — the legal entitlement this
-- FR's Notes call not an edge case).
select public.create_subject('MTH', 'Mathematics', 'ریاضی') as subj_mth \gset
select public.create_subject('ISL', 'Islamiat', 'اسلامیات')  as subj_isl \gset
select public.create_subject('ETH', 'Ethics', 'اخلاقیات')    as subj_eth \gset

select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_mth', 6::smallint) as cs_mth \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_isl', 3::smallint) as cs_isl \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_eth', 3::smallint) as cs_eth \gset

select public.create_section(:'campus_a', :'session_a', :'class9', 'A', 40) as sec9 \gset
select public.assign_subject_teacher(:'sec9', :'subj_mth', :'teacher_uid', current_date - 30) as _t1 \gset
select public.assign_subject_teacher(:'sec9', :'subj_isl', :'teacher_uid', current_date - 30) as _t2 \gset

select public.upsert_exam_term(:'campus_a', :'session_a', 'FINAL', 'Final Term', 1::smallint, 100.00) as term_f \gset
select public.activate_exam_terms(:'session_a'::uuid, :'campus_a'::uuid) as _a \gset

-- Maths Final out of 100, Islamiat and Ethics out of 50 each.
select public.upsert_exam_subject(
  :'term_f', :'cs_mth', '[{"component":"theory","max_marks":100,"pass_marks":33}]'::jsonb
) as es_mth \gset
select public.upsert_exam_subject(
  :'term_f', :'cs_isl', '[{"component":"theory","max_marks":50,"pass_marks":17}]'::jsonb
) as es_isl \gset
select public.upsert_exam_subject(
  :'term_f', :'cs_eth', '[{"component":"theory","max_marks":50,"pass_marks":17}]'::jsonb
) as es_eth \gset

-- Three candidates: one absent from Maths, one exempt from Islamiat and
-- taking Ethics, one debarred.
reset role;
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender, religion)
values (:'tenant_id', :'campus_a', 'GR-0001', 'Absent Ali',  current_date - interval '14 years', 'male', 'Islam'),
       (:'tenant_id', :'campus_a', 'GR-0002', 'Exempt Emma', current_date - interval '14 years', 'female', 'Christianity'),
       (:'tenant_id', :'campus_a', 'GR-0003', 'Present Piya', current_date - interval '14 years', 'female', 'Islam'),
       (:'tenant_id', :'campus_a', 'GR-0004', 'Debarred Danish', current_date - interval '14 years', 'male', 'Islam');

insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, roll_no)
select :'tenant_id', :'campus_a', :'session_a', st.id, :'class9', :'sec9',
       row_number() over (order by st.gr_number)
  from public.student st where st.tenant_id = :'tenant_id' order by st.gr_number;

select id as enr_absent   from public.enrolment where section_id = :'sec9' and roll_no = 1 \gset
select id as enr_exempt   from public.enrolment where section_id = :'sec9' and roll_no = 2 \gset
select id as enr_present  from public.enrolment where section_id = :'sec9' and roll_no = 3 \gset
select id as enr_debarred from public.enrolment where section_id = :'sec9' and roll_no = 4 \gset

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: no mark for a candidate marked Absent
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'teacher_uid')::text,
  true
);

-- The teacher was in the hall; the empty chair is theirs to record.
select ok(
  public.set_exam_attendance(:'es_mth', :'enr_absent', 'absent', 'medical') is not null,
  'a teacher who teaches the paper may record an absence'
);
select is(
  (select status::text from public.exam_attendance
    where exam_subject_id = :'es_mth' and enrolment_id = :'enr_absent'),
  'absent',
  'and it is stored as a status, on its own table — never as a mark'
);
select is(
  (select reason::text from public.exam_attendance
    where exam_subject_id = :'es_mth' and enrolment_id = :'enr_absent'),
  'medical',
  'with the mandatory reason code'
);

select throws_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 45)))) $$,
         :'es_mth', :'enr_absent'),
  '23514',
  'candidate is marked Absent for this paper',
  'AC1: 45 marks for an Absent candidate is refused, in the acceptance criteria''s own words'
);
select is(
  (select count(*)::int from public.mark_entry
    where exam_subject_id = :'es_mth' and enrolment_id = :'enr_absent'),
  0,
  'AC1: and nothing is persisted for them'
);

-- Their classmate is unaffected: the refusal is per candidate, not per paper.
select lives_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 80)))) $$,
         :'es_mth', :'enr_present'),
  'AC1: the candidate who DID sit the paper is marked normally'
);

-- The trigger, not the function, is the boundary.
reset role;
select set_config('request.jwt.claims', '', true);
set local role service_role;
select throws_ok(
  format($$ insert into public.mark_entry
              (tenant_id, campus_id, exam_subject_id, enrolment_id, component_code, marks_obtained)
            values (%L, %L, %L, %L, 'theory', 45) $$,
         :'tenant_id', :'campus_a', :'es_mth', :'enr_absent'),
  '23514',
  'candidate is marked Absent for this paper',
  'AC1: trg_block_marks_when_not_present refuses it at the table too, whatever the caller'
);
reset role;

-- ═══════════════════════════════════════════════════════════════════════
-- Who may record what
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'teacher_uid')::text,
  true
);
select throws_ok(
  format($$ select public.set_exam_attendance(%L, %L, 'exempt', 'religious_exemption') $$,
         :'es_isl', :'enr_exempt'),
  '42501',
  'EXAM_STATUS_OFFICE_ONLY',
  'a teacher cannot grant an exemption — that is an entitlement decision, not an observation'
);
select throws_ok(
  format($$ select public.set_exam_attendance(%L, %L, 'debarred', 'fee_default') $$,
         :'es_mth', :'enr_debarred'),
  '42501',
  'EXAM_STATUS_OFFICE_ONLY',
  'nor debar anyone'
);
select throws_ok(
  format($$ select public.set_exam_attendance(%L, %L, 'absent', null) $$,
         :'es_mth', :'enr_debarred'),
  '23514',
  'ABSENCE_REASON_REQUIRED',
  'and an absence without a reason code is not a record of anything'
);
select throws_ok(
  format($$ select public.set_exam_attendance(%L, %L, 'present', 'medical') $$,
         :'es_mth', :'enr_present'),
  '23514',
  'REASON_NOT_APPLICABLE',
  'nor is "present, medical" — a candidate who sat the paper has no absence reason'
);
select throws_ok(
  format($$ select public.set_exam_attendance(%L, %L, 'absent', 'medical') $$,
         :'es_mth', :'enr_present'),
  '23514',
  'MARKS_ALREADY_ENTERED',
  'a candidate whose marks are in cannot be quietly turned into an absentee'
);
-- Ethics is not theirs to mark at all.
select throws_ok(
  format($$ select public.set_exam_attendance(%L, %L, 'absent', 'medical') $$,
         :'es_eth', :'enr_present'),
  '42501',
  'FORBIDDEN',
  'and a paper they do not teach is not theirs to record either'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: Exempt from Islamiat, taking Ethics
-- ═══════════════════════════════════════════════════════════════════════

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select ok(
  public.set_exam_attendance(:'es_isl', :'enr_exempt', 'exempt', 'religious_exemption') is not null,
  'AC2: the exam office records the religious exemption from Islamiat'
);
-- Both candidates sit Maths and Ethics; only Emma is exempt from Islamiat.
select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_mth',
  'marks', jsonb_build_array(jsonb_build_object(
    'enrolment_id', :'enr_exempt', 'component', 'theory', 'marks_obtained', 80)))) as _m1 \gset
select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_eth',
  'marks', jsonb_build_array(jsonb_build_object(
    'enrolment_id', :'enr_exempt', 'component', 'theory', 'marks_obtained', 40)))) as _m2 \gset
select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_isl',
  'marks', jsonb_build_array(jsonb_build_object(
    'enrolment_id', :'enr_present', 'component', 'theory', 'marks_obtained', 40)))) as _m3 \gset
select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_eth',
  'marks', jsonb_build_array(jsonb_build_object(
    'enrolment_id', :'enr_present', 'component', 'theory', 'marks_obtained', 40)))) as _m4 \gset

select is(
  (select obtained_marks from public.v_exam_result_input
    where exam_subject_id = :'es_isl' and enrolment_id = :'enr_exempt'),
  0::numeric,
  'AC2: Islamiat contributes 0 to obtained for the exempt candidate'
);
select is(
  (select denominator_marks from public.v_exam_result_input
    where exam_subject_id = :'es_isl' and enrolment_id = :'enr_exempt'),
  0,
  'AC2: and 0 to the maximum — the denominator SHRINKS'
);
select is(
  (select paper_max_marks from public.v_exam_result_input
    where exam_subject_id = :'es_isl' and enrolment_id = :'enr_exempt'),
  50,
  'AC2: the paper still has its own maximum of 50 — it is this candidate''s denominator that shrank, not the paper'
);
select is(
  (select report_symbol from public.v_exam_result_input
    where exam_subject_id = :'es_isl' and enrolment_id = :'enr_exempt'),
  'EX',
  'AC2: and the report card prints EX rather than a zero'
);
select is(
  (select attendance_status::text from public.v_exam_result_input
    where exam_subject_id = :'es_eth' and enrolment_id = :'enr_exempt'),
  'present',
  'AC2: Ethics, which they DID take, is an ordinary present paper'
);

-- The arithmetic itself, computed the way FR-J02 will compute it. Emma sat
-- Maths (80/100) and Ethics (40/50) and is exempt from Islamiat: 120 of 150,
-- 80.00%. Piya sat all three (80 was not hers; she has Islamiat 40/50 and
-- Ethics 40/50, and no Maths mark): the denominators differ, and that is the
-- entire point.
select is(
  (select round(sum(obtained_marks) * 100 / nullif(sum(denominator_marks), 0), 2)
     from public.v_exam_result_input
    where exam_term_id = :'term_f' and enrolment_id = :'enr_exempt'),
  80.00::numeric,
  'AC2: the exempt candidate''s percentage is 120 of 150 — Islamiat is out of the fraction entirely'
);
select is(
  (select sum(denominator_marks)::int from public.v_exam_result_input
    where exam_term_id = :'term_f' and enrolment_id = :'enr_exempt'),
  150,
  'AC2: 150, not 200 — the shrunk denominator is the whole difference'
);
select is(
  (select sum(denominator_marks)::int from public.v_exam_result_input
    where exam_term_id = :'term_f' and enrolment_id = :'enr_present'),
  200,
  'AC2: while the classmate who sat Islamiat is still out of the full 200'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: Absent is 0 against the FULL maximum, and prints 'AB'
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select obtained_marks from public.v_exam_result_input
    where exam_subject_id = :'es_mth' and enrolment_id = :'enr_absent'),
  0::numeric,
  'AC3: the absent candidate contributes 0 obtained'
);
select is(
  (select denominator_marks from public.v_exam_result_input
    where exam_subject_id = :'es_mth' and enrolment_id = :'enr_absent'),
  100,
  'AC3: against the paper''s FULL maximum — absent does NOT shrink the denominator'
);
select is(
  (select report_symbol from public.v_exam_result_input
    where exam_subject_id = :'es_mth' and enrolment_id = :'enr_absent'),
  'AB',
  'AC3: and the report card prints AB'
);
select ok(
  not (select blocks_result from public.v_exam_result_input
        where exam_subject_id = :'es_mth' and enrolment_id = :'enr_absent'),
  'AC3: an absence does not block the result — it scores zero, which is a result'
);
-- Absent and Exempt are genuinely different arithmetic, which is this FR's
-- entire reason for existing.
select isnt(
  (select denominator_marks from public.v_exam_result_input
    where exam_subject_id = :'es_mth' and enrolment_id = :'enr_absent'),
  (select denominator_marks from public.v_exam_result_input
    where exam_subject_id = :'es_isl' and enrolment_id = :'enr_exempt'),
  'Absent and Exempt do NOT compute the same way — 100 against 0'
);

-- Debarred: blocked, not merely zeroed.
select ok(
  public.set_exam_attendance(:'es_mth', :'enr_debarred', 'debarred', 'disciplinary') is not null,
  'the exam office debars a candidate from the Maths paper'
);
select ok(
  (select blocks_result from public.v_exam_result_input
    where exam_subject_id = :'es_mth' and enrolment_id = :'enr_debarred'),
  'a debarred candidate sets blocks_result — the result is not computed, not computed as zero'
);
select is(
  (select report_symbol from public.v_exam_result_input
    where exam_subject_id = :'es_mth' and enrolment_id = :'enr_debarred'),
  'DEB',
  'and prints DEB'
);
select ok(
  public.fn_exam_result_blocked(:'term_f', :'enr_debarred'),
  'fn_exam_result_blocked answers it once per candidate per term, whichever paper the debarment is on'
);
select ok(
  not public.fn_exam_result_blocked(:'term_f', :'enr_absent'),
  'and says no for a candidate who was merely absent'
);
select ok(
  not public.fn_exam_result_blocked(:'term_f', :'enr_exempt'),
  'and for one who was merely exempt'
);

-- Nothing in the view a computation can mistake for a mark.
select ok(
  (select bool_and(obtained_marks is not null and denominator_marks is not null)
     from public.v_exam_result_input where exam_term_id = :'term_f'),
  'every row carries real numbers in both arithmetic columns — no nulls for FR-J02 to coalesce'
);
select ok(
  (select bool_and(obtained_marks >= 0 and denominator_marks >= 0)
     from public.v_exam_result_input where exam_term_id = :'term_f'),
  'and no sentinel negatives standing in for a status'
);
select is(
  (select count(*)::int from public.v_exam_result_input
    where exam_term_id = :'term_f' and attendance_status = 'present' and report_symbol is not null),
  0,
  'a present candidate never carries a report symbol'
);
select is(
  (select count(*)::int from public.v_exam_result_input
    where exam_term_id = :'term_f' and attendance_status <> 'present' and report_symbol is null),
  0,
  'and a non-present one always does'
);

-- A candidate with no exam_attendance row at all is Present, without a row
-- having to exist to say so.
select is(
  (select attendance_status::text from public.v_exam_result_input
    where exam_subject_id = :'es_eth' and enrolment_id = :'enr_absent'),
  'present',
  'silence means Present — forty rows saying nothing happened is a cost with no reader'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: the status is locked once the marks are approved
-- ═══════════════════════════════════════════════════════════════════════

-- Piya's Ethics mark is approved. FR-I16 will do this; today it is the seam.
reset role;
set local role service_role;
update public.mark_entry set status = 'approved'
 where exam_subject_id = :'es_eth' and enrolment_id = :'enr_present';
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select throws_ok(
  format($$ select public.set_exam_attendance(%L, %L, 'absent', 'unauthorised') $$,
         :'es_eth', :'enr_present'),
  '42501',
  'candidate exam status is locked by approved marks — the break-glass path is a result-recompute request',
  'AC4: the status cannot be corrected once a result was computed from it, and the refusal names the way through'
);

-- The same refusal for an existing status row being edited, and for
-- service_role, because it is a trigger rather than a policy.
select ok(
  public.set_exam_attendance(:'es_isl', :'enr_present', 'present', null) is not null,
  'a status can still be corrected while the marks are open'
);
select lives_ok(
  format($$ select public.lock_exam_term(%L) $$, :'term_f'),
  'FR-I16 seam: the whole term is locked when its marks are approved'
);
select throws_ok(
  format($$ select public.set_exam_attendance(%L, %L, 'absent', 'medical') $$,
         :'es_isl', :'enr_debarred'),
  '42501',
  'candidate exam status is locked by approved marks — the break-glass path is a result-recompute request',
  'AC4: and a locked term shuts the whole thing, not just the candidates with approved marks'
);

reset role;
set local role service_role;
select throws_ok(
  format($$ update public.exam_attendance set status = 'present', reason = null
             where exam_subject_id = %L and enrolment_id = %L $$,
         :'es_mth', :'enr_absent'),
  '42501',
  'candidate exam status is locked by approved marks — the break-glass path is a result-recompute request',
  'AC4: the freeze is a TRIGGER, so service_role does not walk past it either'
);
select throws_ok(
  format($$ delete from public.exam_attendance
             where exam_subject_id = %L and enrolment_id = %L $$,
         :'es_mth', :'enr_absent'),
  '42501',
  'candidate exam status is locked by approved marks — the break-glass path is a result-recompute request',
  'AC4: nor can the record simply be deleted to get around it'
);
select is(
  (select status::text from public.exam_attendance
    where exam_subject_id = :'es_mth' and enrolment_id = :'enr_absent'),
  'absent',
  'AC4: so the recorded status stands'
);
reset role;

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'teacher_uid')::text,
  true
);
select ok(
  (select count(*)::int from public.exam_attendance) > 0,
  'RLS: the teacher of the paper reads its statuses'
);
select is(
  (select count(*)::int from public.exam_attendance where exam_subject_id = :'es_eth'),
  0,
  'RLS: but not those of a paper they do not teach'
);

reset role;
select public.provision_tenant('other-exam-absence-co', 'Other Co', 'owner@otherabsence.test');
select id as other_tenant from public.tenant where slug = 'other-exam-absence-co' \gset
select id as other_campus from public.campus where tenant_id = :'other_tenant' \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'other_campus'), 'sub', :'owner_uid')::text,
  true
);
select is((select count(*)::int from public.exam_attendance), 0, 'RLS: another tenant sees no exam statuses');
select is((select count(*)::int from public.v_exam_result_input), 0, 'RLS: nor anything through the result-input view');
select throws_ok(
  format($$ select public.set_exam_attendance(%L, %L, 'absent', 'medical') $$, :'es_mth', :'enr_present'),
  '42501',
  'FORBIDDEN',
  'RLS: and cannot record a status against another tenant''s paper, even holding its id'
);
select throws_ok(
  format($$ select public.fn_exam_result_blocked(%L, %L) $$, :'term_f', :'enr_debarred'),
  '42501',
  'FORBIDDEN',
  'RLS: nor ask whether another tenant''s candidate is debarred'
);

select * from finish();
rollback;
