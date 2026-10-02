-- pgTAP tests for FR-J02: subject term result computation.
--
--   AC1  theory 48 of 65 and practical 16 of 20 -> 64 of 85 at 75.29%, grade
--        A, subject flagged pass.
--   AC2  theory 20 of 65 against a theory pass mark of 22 with practical 19
--        of 20 -> 45.88% and FAIL, with the failed component NAMED.
--   AC3  Exempt contributes 0 obtained and 0 maximum, so the denominator
--        shrinks — asserted against a classmate who sat the paper.
--   AC4  Absent contributes 0 obtained against the paper's FULL maximum.
--
-- Plus the properties the acceptance criteria do not state and the module
-- depends on:
--
--   * a debarred candidate's result is BLOCKED rather than failed, for every
--     paper in the term, because FR-I11 answers debarment per term;
--   * grade-boundary determinism at the exact boundary — 65.99 of 200 is
--     32.995%, which is 33.00% and grade E, and 65.98 of 200 is not;
--   * a computed result goes stale when a break-glass window changes a mark
--     underneath it, using FR-I17's own result_stale_at and no second flag,
--     and clears when it is recomputed;
--   * FR-J01 AC4: the scheme a result was graded on is frozen onto the row;
--   * approval never fails because a grade scale has not been configured;
--   * a section whose papers are not all locked cannot be computed;
--   * the parent of a candidate sees their own child's results and no others.
begin;
select plan(68);

select public.provision_tenant('test-result-co', 'Result Co', 'owner@resultco.test');
select id as tenant_id from public.tenant where slug = 'test-result-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_id' \gset
select starts_on as sess_start from public.academic_session where id = :'session_a' \gset

select public.provision_tenant('test-result-rival', 'Result Rival', 'owner@resultrival.test');
select id as rival_id from public.tenant where slug = 'test-result-rival' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@resultco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Result Owner');

select gen_random_uuid() as ec_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ec_uid', 'controller@resultco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ec_uid', :'tenant_id', 'exam_controller', 'Shaista Kamal');

select gen_random_uuid() as principal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_uid', 'principal@resultco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_uid', :'tenant_id', 'principal', 'Tahira Aziz');

select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'rival_uid', 'owner@resultrival.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'rival_uid', :'rival_id', 'owner', 'Rival Owner');

select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);

-- Three papers. Physics carries AC1 and AC2 (two components, the practical
-- pass mark that AC2 turns on); Islamiat carries AC3's exemption; Statistics
-- is out of 200 with no component pass mark, which is what makes an exact
-- 32.995% reachable and leaves the grading BAND as the only pass signal.
select public.create_subject('PHY', 'Physics', 'طبیعیات')   as subj_phy \gset
select public.create_subject('ISL', 'Islamiat', 'اسلامیات')  as subj_isl \gset
select public.create_subject('STA', 'Statistics', 'شماریات') as subj_sta \gset

select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_phy', 6::smallint) as cs_phy \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_isl', 3::smallint) as cs_isl \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_sta', 4::smallint) as cs_sta \gset

select public.create_section(:'campus_a', :'session_a', :'class9', 'A', 40) as sec_a \gset
select public.create_section(:'campus_a', :'session_a', :'class9', 'B', 40) as sec_b \gset

-- 32.995% is only expressible if a mark can carry two decimals.
select public.set_mark_precision(:'campus_a', 2::smallint) as _mp \gset

select public.upsert_exam_term(:'campus_a', :'session_a', 'FINAL', 'Final Term', 1::smallint, 100.00) as term_f \gset
select public.activate_exam_terms(:'session_a'::uuid, :'campus_a'::uuid) as _a \gset

select public.upsert_exam_subject(
  :'term_f', :'cs_phy',
  '[{"component":"theory","max_marks":65,"pass_marks":22},
    {"component":"practical","max_marks":20,"pass_marks":7}]'::jsonb
) as es_phy \gset
select public.upsert_exam_subject(
  :'term_f', :'cs_isl', '[{"component":"theory","max_marks":50,"pass_marks":17}]'::jsonb
) as es_isl \gset
select public.upsert_exam_subject(
  :'term_f', :'cs_sta', '[{"component":"theory","max_marks":200,"pass_marks":0}]'::jsonb
) as es_sta \gset

-- The published FBISE scale (FR-J01).
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
select public.activate_grading_scheme(:'fbise') as _act \gset

-- ── Candidates ─────────────────────────────────────────────────────────
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);

select public.create_student(:'campus_a', 'Ayesha Noor',  '2011-01-01'::date, 'female') as st_ayesha \gset
select public.create_student(:'campus_a', 'Bilal Ahmed',  '2011-02-01'::date, 'male')   as st_bilal \gset
select public.create_student(:'campus_a', 'Chandni Rao',  '2011-03-01'::date, 'female') as st_chandni \gset
select public.create_student(:'campus_a', 'Danish Ali',   '2011-04-01'::date, 'male')   as st_danish \gset
select public.create_student(:'campus_a', 'Emaan Zafar',  '2011-05-01'::date, 'female') as st_emaan \gset
select public.create_student(:'campus_a', 'Sec B Sameer', '2011-06-01'::date, 'male')   as st_sameer \gset

select public.enrol_student(:'sec_a', :'st_ayesha')  as enr_ayesha \gset
select public.enrol_student(:'sec_a', :'st_bilal')   as enr_bilal \gset
select public.enrol_student(:'sec_a', :'st_chandni') as enr_chandni \gset
select public.enrol_student(:'sec_a', :'st_danish')  as enr_danish \gset
select public.enrol_student(:'sec_a', :'st_emaan')   as enr_emaan \gset
select public.enrol_student(:'sec_b', :'st_sameer')  as enr_sameer \gset

-- Ayesha's mother, for the parent policy at the end.
select public.fn_find_or_create_guardian(p_name_en => 'Ayesha Mother', p_phone_e164 => '+923005550001') as g_ayesha \gset
select public.link_guardian(:'st_ayesha'::uuid, :'g_ayesha'::uuid, 'mother'::public.guardian_relationship, true, true);
reset role;
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'parent_uid', 'mother@resultco.test', 'x', now(), 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'parent_uid'::uuid where id = :'g_ayesha'::uuid;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

-- Exam statuses first: a candidate who is not present may not carry a mark.
select public.set_exam_attendance(:'es_isl', :'enr_chandni', 'exempt', 'religious_exemption') as _x1 \gset
select public.set_exam_attendance(:'es_phy', :'enr_danish',  'absent', 'medical')             as _x2 \gset
select public.set_exam_attendance(:'es_phy', :'enr_emaan',   'debarred', 'fee_default')       as _x3 \gset

select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_phy',
  'marks', jsonb_build_array(
    -- AC1: 48 + 16 of 65 + 20.
    jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory',    'marks_obtained', 48),
    jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'practical', 'marks_obtained', 16),
    -- AC2: the aggregate clears, the theory pass mark of 22 does not.
    jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory',    'marks_obtained', 20),
    jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'practical', 'marks_obtained', 19),
    jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory',    'marks_obtained', 50),
    jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'practical', 'marks_obtained', 18)
  ))) as _m1 \gset

select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_isl',
  'marks', jsonb_build_array(
    jsonb_build_object('enrolment_id', :'enr_ayesha', 'component', 'theory', 'marks_obtained', 40),
    jsonb_build_object('enrolment_id', :'enr_bilal',  'component', 'theory', 'marks_obtained', 40),
    jsonb_build_object('enrolment_id', :'enr_danish', 'component', 'theory', 'marks_obtained', 40),
    jsonb_build_object('enrolment_id', :'enr_emaan',  'component', 'theory', 'marks_obtained', 40)
  ))) as _m2 \gset

select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_sta',
  'marks', jsonb_build_array(
    -- 65.99 of 200 is 32.995% exactly — the boundary case.
    jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 65.99),
    jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 65.98),
    jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 100),
    jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 100),
    jsonb_build_object('enrolment_id', :'enr_emaan',   'component', 'theory', 'marks_obtained', 100)
  ))) as _m3 \gset

-- ═══════════════════════════════════════════════════════════════════════
-- Nothing is computed until every paper is signed off
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$select public.fn_compute_subject_result(%L, %L)$$, :'term_f', :'sec_a'),
  '23514',
  NULL,
  'a section whose papers are not all locked cannot be computed'
);
select is(
  (select count(*)::int from public.subject_result),
  0,
  'and nothing was written'
);

select public.fn_approve_marks(:'es_phy', :'sec_a') as _ap1 \gset
select public.fn_approve_marks(:'es_isl', :'sec_a') as _ap2 \gset
select is(
  (select count(*)::int from public.subject_result where section_id = :'sec_a'),
  0,
  'two of three papers locked still computes nothing'
);

-- The last lock is what fires trg_enqueue_result_compute.
select public.fn_approve_marks(:'es_sta', :'sec_a') as _ap3 \gset
select is(
  (select count(*)::int from public.subject_result where section_id = :'sec_a'),
  15,
  'approving the last paper computes every candidate in the section, automatically'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select obtained from public.subject_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  64.00::numeric(7,2),
  'AC1: theory 48 and practical 16 sum to 64 obtained'
);
select is(
  (select max_marks from public.subject_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  85,
  'AC1: out of 85'
);
select is(
  (select pct from public.subject_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  75.29::numeric(5,2),
  'AC1: 75.29% to two decimal places'
);
select is(
  (select grade_label from public.subject_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  'A',
  'AC1: grade A'
);
select is(
  (select gpa_point from public.subject_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  3.70::numeric(3,2),
  'AC1: with the scheme''s GPA point for that band'
);
select is(
  (select is_pass from public.subject_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  true,
  'AC1: the subject is flagged pass'
);
select is(
  (select failed_components from public.subject_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  '[]'::jsonb,
  'AC1: with no failed components'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: the aggregate clears and the subject still fails
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select pct from public.subject_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  45.88::numeric(5,2),
  'AC2: theory 20 and practical 19 give an aggregate of 45.88%'
);
select is(
  (select is_pass from public.subject_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  false,
  'AC2: and the subject is flagged FAIL on the component pass mark'
);
select is(
  (select jsonb_array_length(failed_components) from public.subject_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  1,
  'AC2: exactly one component failed — the practical cleared its own pass mark'
);
select is(
  (select failed_components -> 0 ->> 'component' from public.subject_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  'theory',
  'AC2: and the failed component is NAMED'
);
select is(
  (select failed_components -> 0 ->> 'pass_marks' from public.subject_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  '22',
  'AC2: with the pass mark it missed'
);
select is(
  (select failed_components -> 0 ->> 'obtained' from public.subject_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  '20.00',
  'AC2: and what was actually scored on it, as the mark was stored'
);
select is(
  (select grade_label from public.subject_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  'D',
  'AC2: the grade still reflects the aggregate — failing is not the same as ungraded'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: Exempt shrinks the denominator
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select obtained from public.subject_result
    where enrolment_id = :'enr_chandni' and subject_id = :'subj_isl'),
  0.00::numeric(7,2),
  'AC3: an exempt subject contributes 0 obtained'
);
select is(
  (select max_marks from public.subject_result
    where enrolment_id = :'enr_chandni' and subject_id = :'subj_isl'),
  0,
  'AC3: and 0 maximum — the denominator shrinks'
);
select ok(
  (select pct from public.subject_result
    where enrolment_id = :'enr_chandni' and subject_id = :'subj_isl') is null,
  'AC3: there is no percentage of nothing'
);
select ok(
  (select grade_label from public.subject_result
    where enrolment_id = :'enr_chandni' and subject_id = :'subj_isl') is null,
  'AC3: and no grade — an exemption is not an F'
);
select ok(
  (select is_pass from public.subject_result
    where enrolment_id = :'enr_chandni' and subject_id = :'subj_isl') is null,
  'AC3: nor a pass or a fail'
);
select is(
  (select report_symbol from public.subject_result
    where enrolment_id = :'enr_chandni' and subject_id = :'subj_isl'),
  'EX',
  'AC3: the report card prints EX'
);
-- The denominator actually shrinking, as a term total: the classmate who sat
-- Islamiat carries its 50 marks and the exempt candidate does not.
select is(
  (select sum(max_marks)::int from public.subject_result where enrolment_id = :'enr_ayesha'),
  335,
  'AC3: a candidate who sat every paper is measured out of 85 + 50 + 200'
);
select is(
  (select sum(max_marks)::int from public.subject_result where enrolment_id = :'enr_chandni'),
  285,
  'AC3: the exempt candidate is measured out of 285 — Islamiat''s 50 left the denominator'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: Absent scores 0 against the full maximum
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select obtained from public.subject_result
    where enrolment_id = :'enr_danish' and subject_id = :'subj_phy'),
  0.00::numeric(7,2),
  'AC4: an absent candidate contributes 0 obtained'
);
select is(
  (select max_marks from public.subject_result
    where enrolment_id = :'enr_danish' and subject_id = :'subj_phy'),
  85,
  'AC4: against the paper''s FULL maximum — absence does not shrink the denominator'
);
select is(
  (select pct from public.subject_result
    where enrolment_id = :'enr_danish' and subject_id = :'subj_phy'),
  0.00::numeric(5,2),
  'AC4: which is 0.00%'
);
select is(
  (select grade_label from public.subject_result
    where enrolment_id = :'enr_danish' and subject_id = :'subj_phy'),
  'F',
  'AC4: graded F, unlike the exempt candidate'
);
select is(
  (select is_pass from public.subject_result
    where enrolment_id = :'enr_danish' and subject_id = :'subj_phy'),
  false,
  'AC4: and failed'
);
select is(
  (select report_symbol from public.subject_result
    where enrolment_id = :'enr_danish' and subject_id = :'subj_phy'),
  'AB',
  'AC4: the report card prints AB'
);
select is(
  (select is_blocked from public.subject_result
    where enrolment_id = :'enr_danish' and subject_id = :'subj_phy'),
  false,
  'AC4: an absence is not a withheld result'
);
-- Absence and exemption differ where it matters: the same 0 obtained, a
-- different denominator.
select is(
  (select sum(max_marks)::int from public.subject_result where enrolment_id = :'enr_danish'),
  335,
  'the absent candidate is still measured out of the full 335'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Debarred: withheld, not failed, and for the whole term
-- ═══════════════════════════════════════════════════════════════════════

select ok(
  public.fn_exam_result_blocked(:'term_f', :'enr_emaan'),
  'FR-I11 answers debarment once per candidate per term'
);
select is(
  (select count(*)::int from public.subject_result
    where enrolment_id = :'enr_emaan' and is_blocked),
  3,
  'a debarment on one paper withholds every subject in the term, not just that paper'
);
select ok(
  (select bool_and(grade_label is null and pct is null and is_pass is null)
     from public.subject_result where enrolment_id = :'enr_emaan'),
  'a withheld result carries no grade, no percentage and no pass/fail — it is not a fail'
);
select is(
  (select report_symbol from public.subject_result
    where enrolment_id = :'enr_emaan' and subject_id = :'subj_phy'),
  'DEB',
  'the paper they were debarred from still says so'
);
select is(
  (select count(*)::int from public.subject_result
    where enrolment_id = :'enr_ayesha' and is_blocked),
  0,
  'and no classmate is blocked by it'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Grade-boundary determinism
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select pct from public.subject_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_sta'),
  33.00::numeric(5,2),
  '65.99 of 200 is 32.995%, which is stored as the 33.00% a report card prints'
);
select is(
  (select grade_label from public.subject_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_sta'),
  'E',
  'and grades as E — the boundary is decided on the printed number, deterministically'
);
select is(
  (select pct from public.subject_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_sta'),
  32.99::numeric(5,2),
  '65.98 of 200 is 32.99% exactly'
);
select is(
  (select grade_label from public.subject_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_sta'),
  'F',
  'and grades as F — one paisa of a mark either side of the boundary, and never in between'
);
-- Statistics has no component pass mark, so the BAND is the only pass signal.
select is(
  (select is_pass from public.subject_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_sta'),
  false,
  'a paper with no component pass marks still fails on a failing band'
);
select is(
  (select is_pass from public.subject_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_sta'),
  true,
  'and passes on a passing one'
);

-- FR-J01 AC4: the scale is frozen onto the result.
select is(
  (select count(distinct grading_scheme_id)::int from public.subject_result
    where section_id = :'sec_a'),
  1,
  'every result records the grading scheme it was graded on'
);
select is(
  (select grading_scheme_id from public.subject_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  :'fbise'::uuid,
  'and it is the version that was effective for this session'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Staleness, from FR-I17's own stamp
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select count(*)::int from public.v_subject_result where section_id = :'sec_a' and is_stale),
  0,
  'a freshly computed section is not stale'
);

select public.request_mark_unlock(:'es_phy', :'sec_a', 'Q5 total mis-added on Ayesha''s script') as unlock_req \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select public.fn_break_glass_unlock(:'unlock_req', 60) as _bg \gset

select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_phy',
  'marks', jsonb_build_array(
    jsonb_build_object('enrolment_id', :'enr_ayesha', 'component', 'theory', 'marks_obtained', 50)
  ))) as _m4 \gset

select ok(
  (select result_stale_at from public.mark_lock
    where exam_subject_id = :'es_phy' and section_id = :'sec_a') is not null,
  'FR-I17 stamps result_stale_at when a mark changes inside the window'
);
select is(
  (select count(*)::int from public.v_subject_result
    where section_id = :'sec_a' and subject_id = :'subj_phy' and is_stale),
  5,
  'and every Physics result for the section reads stale — derived from that stamp, not a second flag'
);
select is(
  (select count(*)::int from public.v_subject_result
    where section_id = :'sec_a' and subject_id = :'subj_isl' and is_stale),
  0,
  'while the papers nobody touched are not'
);
select is(
  ((public.fn_term_result_ready(:'term_f', :'sec_a')) ->> 'stale')::boolean,
  true,
  'FR-I16''s readiness gate reports the same thing, from the same stamp'
);

select throws_ok(
  format($$select public.fn_compute_subject_result(%L, %L)$$, :'term_f', :'sec_a'),
  '42501',
  'marks are open under a break-glass window on Physics — recompute when it closes',
  'a recompute inside an open window is refused: FR-I17 stamps staleness once per window'
);

-- The clock closes the window (FR-I17 AC2), and only then may it recompute.
select public.fn_relock_expired_unlocks(clock_timestamp() + interval '5 hours') as _relock \gset
select is(
  public.fn_compute_subject_result(:'term_f', :'sec_a'),
  15,
  'once the window has closed the section recomputes'
);
select is(
  (select obtained from public.subject_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  66.00::numeric(7,2),
  'the corrected mark is in the result'
);
select is(
  (select pct from public.subject_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  77.65::numeric(5,2),
  '66 of 85 is 77.65%'
);
select is(
  (select count(*)::int from public.v_subject_result where section_id = :'sec_a' and is_stale),
  0,
  'and the staleness clears itself, because it was never stored'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Approval never waits on a grade scale being configured
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

-- Section B sits the same three papers. Point the campus at a board with no
-- configured scale, then sign the section off.
select public.set_campus_board(:'campus_a', 'SINDH'::public.board) as _cb \gset

select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_phy',
  'marks', jsonb_build_array(
    jsonb_build_object('enrolment_id', :'enr_sameer', 'component', 'theory',    'marks_obtained', 55),
    jsonb_build_object('enrolment_id', :'enr_sameer', 'component', 'practical', 'marks_obtained', 15)
  ))) as _m5 \gset
select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_isl',
  'marks', jsonb_build_array(
    jsonb_build_object('enrolment_id', :'enr_sameer', 'component', 'theory', 'marks_obtained', 30)
  ))) as _m6 \gset
select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_sta',
  'marks', jsonb_build_array(
    jsonb_build_object('enrolment_id', :'enr_sameer', 'component', 'theory', 'marks_obtained', 150)
  ))) as _m7 \gset

select lives_ok(
  format($$select public.fn_approve_marks(%L, %L)$$, :'es_phy', :'sec_b'),
  'a school with no grade scale for its board can still sign off marks'
);
select public.fn_approve_marks(:'es_isl', :'sec_b') as _ap5 \gset
select public.fn_approve_marks(:'es_sta', :'sec_b') as _ap6 \gset

select is(
  (select count(*)::int from public.subject_result where section_id = :'sec_b'),
  0,
  'the results simply wait — the approval was not held hostage to a scale nobody has chosen'
);
select throws_ok(
  format($$select public.fn_compute_subject_result(%L, %L)$$, :'term_f', :'sec_b'),
  '23514',
  format('no grading scheme is configured for SINDH as at %s', :'sess_start'),
  'and asking for them names the board that has no scale, and the date it was asked for'
);

select public.set_campus_board(:'campus_a', 'FBISE'::public.board) as _cb2 \gset
select is(
  public.fn_compute_subject_result(:'term_f', :'sec_b'),
  3,
  'once a scale exists for the board, the same call computes'
);
select is(
  (select grade_label from public.subject_result
    where enrolment_id = :'enr_sameer' and subject_id = :'subj_phy'),
  'A1',
  '70 of 85 is 82.35% and an A1'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Who may compute, and who may read
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'parent_uid')::text,
  true
);
select is(
  (select count(*)::int from public.subject_result),
  3,
  'subject_result_parent_own_child: a parent sees their own child''s three subjects'
);
select is(
  (select count(distinct enrolment_id)::int from public.subject_result),
  1,
  'and no other family''s child, even in the same section'
);
select throws_ok(
  format($$select public.fn_compute_subject_result(%L, %L)$$, :'term_f', :'sec_a'),
  '42501',
  NULL,
  'a parent cannot run a computation'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'rival_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(gen_random_uuid()), 'sub', :'rival_uid')::text,
  true
);
select is(
  (select count(*)::int from public.subject_result),
  0,
  'subject_result_campus_scope: another school sees none of these results'
);

-- A computed result is not a hand-edited one: there is no write policy at all.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select lives_ok(
  format($$update public.subject_result set grade_label = 'A1' where enrolment_id = %L$$, :'enr_bilal'),
  'an UPDATE from a client connection reaches no row rather than erroring'
);
select is(
  (select grade_label from public.subject_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  'D',
  'and the grade is unchanged — a correction is a recompute of the marks, not an edit of the number'
);

select * from finish();
rollback;
