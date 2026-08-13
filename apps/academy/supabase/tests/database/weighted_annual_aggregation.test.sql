-- pgTAP tests for FR-J03: weighted aggregation across terms.
--
--   AC1  First 25% at 60%, Mid 15% at 70%, Final 60% at 80% -> 73.50%.
--   AC2  a counting term that is not fully signed off stores the aggregate
--        'provisional' and publication is refused.
--   AC3  a candidate admitted mid-session has the missing term's weight
--        redistributed pro rata and the row annotated
--        "pro-rated, 2 of 3 terms".
--   AC4  a break-glass correction makes the aggregate stale, the recompute
--        job updates it, and the report card is marked stale meanwhile.
--
-- Plus the properties the acceptance criteria do not state and the module
-- depends on:
--
--   * the arithmetic rounds exactly ONCE, at the end, on exact decimals —
--     asserted at a value that lands on a half (73.505 -> 73.51) and at one
--     that lands just below it (73.5025 -> 73.50);
--   * a non-counting term is on the report card and outside the total, both;
--   * an exemption shrinks the denominator at the term level and keeps
--     shrinking it at the annual level, through the same pro rata path;
--   * a debarred candidate's YEAR is withheld, not failed;
--   * recomputing an aggregate CANNOT clear staleness the term result still
--     has — only recomputing the term result can;
--   * the parent of a candidate sees their own child's annual results and no
--     others, and nobody can write one by hand.
begin;
select plan(61);

select public.provision_tenant('test-annual-co', 'Annual Co', 'owner@annualco.test');
select id as tenant_id from public.tenant where slug = 'test-annual-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_id' \gset

select public.provision_tenant('test-annual-rival', 'Annual Rival', 'owner@annualrival.test');
select id as rival_id from public.tenant where slug = 'test-annual-rival' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@annualco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Annual Owner');

select gen_random_uuid() as ec_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ec_uid', 'controller@annualco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ec_uid', :'tenant_id', 'exam_controller', 'Shaista Kamal');

select gen_random_uuid() as principal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_uid', 'principal@annualco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_uid', :'tenant_id', 'principal', 'Tahira Aziz');

select gen_random_uuid() as clerk_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'clerk_uid', 'clerk@annualco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'clerk_uid', :'tenant_id', 'accountant', 'Accounts Clerk');

select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'rival_uid', 'owner@annualrival.test', 'x', now(), 'authenticated', 'authenticated');
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

-- Physics out of 100 makes a mark and a percentage the same number, which is
-- what lets the weightage arithmetic be read straight off the marks. Maths
-- out of 200 is what makes 60.01% and 60.02% expressible, and those are the
-- two values that land either side of a rounding half.
select public.create_subject('PHY', 'Physics', 'طبیعیات')  as subj_phy \gset
select public.create_subject('ISL', 'Islamiat', 'اسلامیات') as subj_isl \gset
select public.create_subject('MTH', 'Maths', 'ریاضی')       as subj_mth \gset

select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_phy', 6::smallint) as cs_phy \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_isl', 3::smallint) as cs_isl \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_mth', 8::smallint) as cs_mth \gset

select public.create_section(:'campus_a', :'session_a', :'class9', 'A', 40) as sec_a \gset
select public.create_section(:'campus_a', :'session_a', :'class9', 'B', 40) as sec_b \gset

select public.set_mark_precision(:'campus_a', 2::smallint) as _mp \gset

-- ── The term set: three counting terms and one that is not ─────────────
--
-- FR-I01 AC4: WEEKLY carries a real 20% display weight and is excluded from
-- the 100% validation outright. Activation succeeding at all is the first
-- half of that assertion; the aggregate ignoring it is the second.
select public.upsert_exam_term(:'campus_a', :'session_a', 'FIRST',  'First Term',  1::smallint, 25.00)  as term_1 \gset
select public.upsert_exam_term(:'campus_a', :'session_a', 'MID',    'Mid Term',    2::smallint, 15.00)  as term_2 \gset
select public.upsert_exam_term(:'campus_a', :'session_a', 'FINAL',  'Final Term',  3::smallint, 60.00)  as term_3 \gset
select public.upsert_exam_term(:'campus_a', :'session_a', 'WEEKLY', 'Weekly Tests', 4::smallint, 20.00, false) as term_w \gset
select public.activate_exam_terms(:'session_a'::uuid, :'campus_a'::uuid) as _act_terms \gset

select is(
  (select sum(weight_bp)::int from public.exam_term
    where session_id = :'session_a' and counts_toward_annual),
  10000,
  'the counting terms total exactly 10000 basis points, and activation passed'
);
select is(
  (select weight_bp from public.exam_term where id = :'term_w'),
  2000,
  'while the non-counting term carries its own 20.00% and never entered that total'
);

-- ── The papers ─────────────────────────────────────────────────────────
select public.upsert_exam_subject(:'term_1', :'cs_phy', '[{"component":"theory","max_marks":100,"pass_marks":0}]'::jsonb) as es_phy_1 \gset
select public.upsert_exam_subject(:'term_1', :'cs_isl', '[{"component":"theory","max_marks":50,"pass_marks":0}]'::jsonb)  as es_isl_1 \gset
select public.upsert_exam_subject(:'term_1', :'cs_mth', '[{"component":"theory","max_marks":200,"pass_marks":0}]'::jsonb) as es_mth_1 \gset

select public.upsert_exam_subject(:'term_2', :'cs_phy', '[{"component":"theory","max_marks":100,"pass_marks":0}]'::jsonb) as es_phy_2 \gset
select public.upsert_exam_subject(:'term_2', :'cs_isl', '[{"component":"theory","max_marks":50,"pass_marks":0}]'::jsonb)  as es_isl_2 \gset
select public.upsert_exam_subject(:'term_2', :'cs_mth', '[{"component":"theory","max_marks":200,"pass_marks":0}]'::jsonb) as es_mth_2 \gset

select public.upsert_exam_subject(:'term_3', :'cs_phy', '[{"component":"theory","max_marks":100,"pass_marks":0}]'::jsonb) as es_phy_3 \gset
select public.upsert_exam_subject(:'term_3', :'cs_isl', '[{"component":"theory","max_marks":50,"pass_marks":0}]'::jsonb)  as es_isl_3 \gset
select public.upsert_exam_subject(:'term_3', :'cs_mth', '[{"component":"theory","max_marks":200,"pass_marks":0}]'::jsonb) as es_mth_3 \gset

-- The weekly test set is one paper, which is all a non-counting term needs to
-- be on a report card.
select public.upsert_exam_subject(:'term_w', :'cs_phy', '[{"component":"theory","max_marks":100,"pass_marks":0}]'::jsonb) as es_phy_w \gset

-- The published FBISE scale (FR-J01), effective long before this session.
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

-- ── Candidates ─────────────────────────────────────────────────────────
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);

select public.create_student(:'campus_a', 'Ayesha Noor', '2011-01-01'::date, 'female') as st_ayesha \gset
select public.create_student(:'campus_a', 'Bilal Ahmed', '2011-02-01'::date, 'male')   as st_bilal \gset
select public.create_student(:'campus_a', 'Chandni Rao', '2011-03-01'::date, 'female') as st_chandni \gset
select public.create_student(:'campus_a', 'Danish Ali',  '2011-04-01'::date, 'male')   as st_danish \gset
select public.create_student(:'campus_a', 'Emaan Zafar', '2011-05-01'::date, 'female') as st_emaan \gset

select public.enrol_student(:'sec_a', :'st_ayesha')  as enr_ayesha \gset
select public.enrol_student(:'sec_a', :'st_chandni') as enr_chandni \gset
select public.enrol_student(:'sec_a', :'st_danish')  as enr_danish \gset
select public.enrol_student(:'sec_a', :'st_emaan')   as enr_emaan \gset

select public.fn_find_or_create_guardian(p_name_en => 'Ayesha Mother', p_phone_e164 => '+923005550031') as g_ayesha \gset
select public.link_guardian(:'st_ayesha'::uuid, :'g_ayesha'::uuid, 'mother'::public.guardian_relationship, true, true);
reset role;
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'parent_uid', 'mother@annualco.test', 'x', now(), 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'parent_uid'::uuid where id = :'g_ayesha'::uuid;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

-- ═══════════════════════════════════════════════════════════════════════
-- First Term. Bilal is not here yet — he transfers in in January.
-- ═══════════════════════════════════════════════════════════════════════

select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_phy_1', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 60),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 60),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 60),
  jsonb_build_object('enrolment_id', :'enr_emaan',   'component', 'theory', 'marks_obtained', 60)
))) as _p1 \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_isl_1', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 25),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 25),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 25),
  jsonb_build_object('enrolment_id', :'enr_emaan',   'component', 'theory', 'marks_obtained', 25)
))) as _i1 \gset
-- 120 of 200 is 60.00%; 120.04 is 60.02%; 120.02 is 60.01%. Those last two
-- are the boundary pair.
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_mth_1', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 120),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 120.04),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 120.02),
  jsonb_build_object('enrolment_id', :'enr_emaan',   'component', 'theory', 'marks_obtained', 120)
))) as _m1 \gset

select public.fn_approve_marks(:'es_phy_1', :'sec_a') as _ap11 \gset
select public.fn_approve_marks(:'es_isl_1', :'sec_a') as _ap12 \gset
select public.fn_approve_marks(:'es_mth_1', :'sec_a') as _ap13 \gset

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: one term in, two still being marked
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select count(*)::int from public.annual_result where section_id = :'sec_a'),
  12,
  'the aggregate is computed off the first term alone — a Principal sees where the class stands'
);
select is(
  (select status::text from public.annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  'provisional',
  'AC2: with a counting term still being marked it is stored provisional'
);
select throws_ok(
  format($$select public.fn_assert_annual_result_publishable(%L, %L)$$, :'session_a', :'enr_ayesha'),
  '23514',
  'annual result is provisional — a term is still being marked',
  'AC2: and publication is refused, by name'
);
select is(
  (select weighted_pct from public.annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  60.00::numeric(5,2),
  'a provisional aggregate is still arithmetic: one term at 60%, pro-rated to itself, is 60.00%'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Mid Term. Bilal transfers in — his father was posted to another city.
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);
select public.enrol_student(:'sec_a', :'st_bilal') as enr_bilal \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

-- Danish is exempt from Islamiat this term. FR-I11 already removes its 50
-- marks from his term denominator; this test follows that shrink upward.
select public.set_exam_attendance(:'es_isl_2', :'enr_danish', 'exempt', 'religious_exemption') as _ex1 \gset

select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_phy_2', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 70),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 70),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 70),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 70),
  jsonb_build_object('enrolment_id', :'enr_emaan',   'component', 'theory', 'marks_obtained', 70)
))) as _p2 \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_isl_2', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 35),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 35),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 35),
  jsonb_build_object('enrolment_id', :'enr_emaan',   'component', 'theory', 'marks_obtained', 35)
))) as _i2 \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_mth_2', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 140),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 140),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 140),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 140),
  jsonb_build_object('enrolment_id', :'enr_emaan',   'component', 'theory', 'marks_obtained', 140)
))) as _m2 \gset

select public.fn_approve_marks(:'es_phy_2', :'sec_a') as _ap21 \gset
select public.fn_approve_marks(:'es_isl_2', :'sec_a') as _ap22 \gset
select public.fn_approve_marks(:'es_mth_2', :'sec_a') as _ap23 \gset

select is(
  (select terms_counted from public.annual_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  1,
  'the mid-session admission has one term of three so far'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Final Term. Emaan is debarred from the Physics paper.
-- ═══════════════════════════════════════════════════════════════════════

select public.set_exam_attendance(:'es_phy_3', :'enr_emaan', 'debarred', 'fee_default') as _deb \gset

select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_phy_3', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 80),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 80),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 80),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 80)
))) as _p3 \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_isl_3', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 30),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 30),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 30),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 30),
  jsonb_build_object('enrolment_id', :'enr_emaan',   'component', 'theory', 'marks_obtained', 30)
))) as _i3 \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_mth_3', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 160),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 160),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 160),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 160),
  jsonb_build_object('enrolment_id', :'enr_emaan',   'component', 'theory', 'marks_obtained', 160)
))) as _m3 \gset

select public.fn_approve_marks(:'es_phy_3', :'sec_a') as _ap31 \gset
select public.fn_approve_marks(:'es_isl_3', :'sec_a') as _ap32 \gset
select public.fn_approve_marks(:'es_mth_3', :'sec_a') as _ap33 \gset

-- ═══════════════════════════════════════════════════════════════════════
-- AC1
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select weighted_pct from public.annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  73.50::numeric(5,2),
  'AC1: 25% at 60, 15% at 70 and 60% at 80 weight to exactly 73.50%'
);
select is(
  (select status::text from public.annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  'final',
  'AC1: with every counting term signed off the aggregate is final'
);
select is(
  (select grade_label from public.annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  'A',
  'AC1: graded off the weighted percentage, on the scale the terms were graded on'
);
select is(
  (select gpa_point from public.annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  3.70::numeric(3,2),
  'AC1: carrying that band''s GPA point'
);
select is(
  (select is_pass from public.annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  true,
  'AC1: and the year is a pass'
);
select is(
  (select grading_scheme_id from public.annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  :'fbise'::uuid,
  'FR-J01 AC4: the scale is READ OFF the term results, never re-resolved for today'
);
select ok(
  (select proration_note from public.annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy') is null,
  'a candidate who sat every term carries no pro-rating annotation'
);
select lives_ok(
  format($$select public.fn_assert_annual_result_publishable(%L, %L)$$, :'session_a', :'enr_ayesha'),
  'AC2, the other way round: a final, fresh aggregate may be published'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the mid-session admission
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select count(*)::int from public.subject_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  2,
  'AC3: the January admission has no First Term Physics result at all'
);
select is(
  (select weighted_pct from public.annual_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  78.00::numeric(5,2),
  'AC3: the missing 25% is redistributed pro rata across 15 and 60 — 78.00%, not 58.50%'
);
select is(
  (select terms_counted from public.annual_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  2,
  'AC3: two terms counted'
);
select is(
  (select terms_total from public.annual_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  3,
  'AC3: out of the session''s three counting terms'
);
select is(
  (select prorated_terms from public.annual_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  1,
  'AC3: one of them pro-rated away'
);
select is(
  (select proration_note from public.annual_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  'pro-rated, 2 of 3 terms',
  'AC3: and the record is annotated in the words the report card prints'
);
select is(
  (select status::text from public.annual_result
    where enrolment_id = :'enr_bilal' and subject_id = :'subj_phy'),
  'final',
  'AC3: a candidate who was not there is not a term the school has not marked — this is final, not provisional'
);
select lives_ok(
  format($$select public.fn_assert_annual_result_publishable(%L, %L)$$, :'session_a', :'enr_bilal'),
  'AC3: so a pro-rated report card publishes'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Rounding: once, at the end, on exact decimals
-- ═══════════════════════════════════════════════════════════════════════

-- 2500*60.02 + 1500*70.00 + 6000*80.00 = 735050, and 735050/10000 is
-- 73.505 exactly — a half, decided by numeric's round-half-away-from-zero.
select is(
  (select weighted_pct from public.annual_result
    where enrolment_id = :'enr_chandni' and subject_id = :'subj_mth'),
  73.51::numeric(5,2),
  'a weighted total of exactly 73.505 rounds to 73.51 — one round(), at the end, deterministically'
);
-- 2500*60.01 + 1500*70.00 + 6000*80.00 = 735025, which is 73.5025.
select is(
  (select weighted_pct from public.annual_result
    where enrolment_id = :'enr_danish' and subject_id = :'subj_mth'),
  73.50::numeric(5,2),
  'and 73.5025 rounds to 73.50 — one paisa of a mark either side of the half, never in between'
);
select is(
  (select weighted_pct from public.annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_mth'),
  73.50::numeric(5,2),
  'while the candidate who scored exactly 60/70/80 lands on 73.50 with nothing to round'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Exemption: the denominator shrinks at the term, and keeps shrinking
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select max_marks from public.subject_result
    where enrolment_id = :'enr_danish' and subject_id = :'subj_isl' and exam_term_id = :'term_2'),
  0,
  'FR-I11/J02: the exempt term contributes a denominator of 0'
);
select ok(
  (select pct from public.subject_result
    where enrolment_id = :'enr_danish' and subject_id = :'subj_isl' and exam_term_id = :'term_2') is null,
  'so that term has no percentage to weight'
);
select is(
  (select terms_counted from public.annual_result
    where enrolment_id = :'enr_danish' and subject_id = :'subj_isl'),
  2,
  'and the annual denominator shrinks with it — 2 of 3 terms, through the same pro rata path'
);
-- (2500*50.00 + 6000*60.00) / 8500 = 485000/8500 = 57.0588...
select is(
  (select weighted_pct from public.annual_result
    where enrolment_id = :'enr_danish' and subject_id = :'subj_isl'),
  57.06::numeric(5,2),
  'the exempt term''s 15% is redistributed, not scored zero'
);
select is(
  (select proration_note from public.annual_result
    where enrolment_id = :'enr_danish' and subject_id = :'subj_isl'),
  'pro-rated, 2 of 3 terms',
  'and the report card says so'
);
-- The classmate who sat the same three papers is the control.
select is(
  (select weighted_pct from public.annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_isl'),
  59.00::numeric(5,2),
  'while the classmate who sat all three is weighted across all three'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Debarred: the YEAR is withheld, not failed
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select count(*)::int from public.annual_result
    where enrolment_id = :'enr_emaan' and is_blocked),
  3,
  'a debarment in one term withholds every subject''s annual result, as it withholds the term'
);
select ok(
  (select bool_and(weighted_pct is null and grade_label is null and is_pass is null)
     from public.annual_result where enrolment_id = :'enr_emaan'),
  'a withheld year carries no percentage, no grade and no pass/fail — it is not a fail'
);
select is(
  (select count(*)::int from public.annual_result
    where enrolment_id = :'enr_ayesha' and is_blocked),
  0,
  'and no classmate is withheld by it'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The non-counting term is on the card and outside the total
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select count(*)::int from public.exam_term
    where session_id = :'session_a' and not counts_toward_annual),
  1,
  'the weekly-test term exists in the session'
);
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_phy_w', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 10),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 10),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 10),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 10),
  jsonb_build_object('enrolment_id', :'enr_emaan',   'component', 'theory', 'marks_obtained', 10)
))) as _pw \gset
select public.fn_approve_marks(:'es_phy_w', :'sec_a') as _apw \gset

select is(
  (select count(*)::int from public.subject_result where exam_term_id = :'term_w'),
  5,
  'and its results are computed and printable — it belongs on the report card'
);
select is(
  (select weighted_pct from public.annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  73.50::numeric(5,2),
  'a weekly test scored 10% at a 20% display weight would drag 73.50 to 62.92 if it counted — it does not'
);
select is(
  (select terms_total from public.annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  3,
  'and the year is still three terms long, not four'
);
select is(
  (select status::text from public.annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  'final',
  'a non-counting term also cannot hold a result provisional'
);
select is(
  (select count(*)::int
     from jsonb_array_elements(public.fn_annual_result_sheet(:'session_a', :'sec_a') -> 'terms') t
    where not (t ->> 'counts_toward_annual')::boolean),
  1,
  'and the sheet still hands the report card that term, flagged as outside the total'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: staleness, inherited from FR-I17 and impossible to paint over
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select count(*)::int from public.v_annual_result where section_id = :'sec_a' and is_stale),
  0,
  'a freshly computed year is not stale'
);

select public.request_mark_unlock(:'es_phy_3', :'sec_a', 'Q7 total mis-added on Ayesha''s final script') as unlock_req \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select public.fn_break_glass_unlock(:'unlock_req', 60) as _bg \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_phy_3', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha', 'component', 'theory', 'marks_obtained', 90)
))) as _p4 \gset

select is(
  (select is_stale from public.v_annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  true,
  'AC4: a break-glass correction in ONE term marks the whole year stale'
);
select is(
  (select is_stale from public.v_annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_isl'),
  false,
  'while a subject nobody touched is not'
);
select throws_ok(
  format($$select public.fn_assert_annual_result_publishable(%L, %L)$$, :'session_a', :'enr_ayesha'),
  '23514',
  'annual result is stale — a mark changed after it was computed',
  'AC4: and the dependent report card cannot be published while it says so'
);
select throws_ok(
  format($$select public.fn_compute_annual_result(%L, %L)$$, :'session_a', :'class9'),
  '42501',
  'marks are open under a break-glass window on Physics — recompute when it closes',
  'an explicit recompute inside an open window is refused, for FR-J02''s reason'
);

-- The property the whole design turns on: the recompute job runs, and it
-- CANNOT clear a flag that belongs to the term result.
select is(
  public.fn_recompute_stale_annual_results(:'session_a'),
  15,
  'the 5-minute job finds the stale year and recomputes the class it belongs to'
);
select is(
  (select is_stale from public.v_annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  true,
  'and it is STILL stale — recomputing an aggregate cannot paint over an uncorrected mark'
);

-- Only recomputing the term result can, and that is the correct direction.
select public.fn_relock_expired_unlocks(clock_timestamp() + interval '5 hours') as _relock \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select is(
  public.fn_compute_subject_result(:'term_3', :'sec_a'),
  15,
  'once the window closes the term recomputes'
);
select is(
  (select weighted_pct from public.annual_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  79.50::numeric(5,2),
  'AC4: and the annual result follows it in the same transaction — 25%*60 + 15%*70 + 60%*90'
);
select is(
  (select count(*)::int from public.v_annual_result where section_id = :'sec_a' and is_stale),
  0,
  'AC4: the staleness clears itself, because it was never stored'
);
select lives_ok(
  format($$select public.fn_assert_annual_result_publishable(%L, %L)$$, :'session_a', :'enr_ayesha'),
  'and the report card publishes again'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The explicit class-level recompute
-- ═══════════════════════════════════════════════════════════════════════

select is(
  public.fn_compute_annual_result(:'session_a', :'class9'),
  15,
  'the FR''s fn_compute_annual_result(session, class) covers every candidate of the class'
);
select is(
  (select count(*)::int from public.annual_result where section_id = :'sec_b'),
  0,
  'and writes nothing for a section that has not marked anything'
);
select throws_ok(
  format($$select public.fn_compute_annual_result(%L, %L)$$, :'session_a', :'sec_a'),
  'P0002',
  'CLASS_LEVEL_NOT_FOUND',
  'a section id is not a class id, and saying so beats computing nothing quietly'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);
select throws_ok(
  format($$select public.fn_compute_annual_result(%L, %L)$$, :'session_a', :'class9'),
  '42501',
  'FORBIDDEN',
  'and an accountant does not compute results'
);

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'rival_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(), 'sub', :'rival_uid')::text,
  true
);
select is(
  (select count(*)::int from public.annual_result),
  0,
  'another tenant sees no annual results at all'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'parent_uid')::text,
  true
);
select is(
  (select count(distinct enrolment_id)::int from public.annual_result),
  1,
  'a parent sees exactly one candidate''s annual results'
);
select is(
  (select distinct enrolment_id from public.annual_result),
  :'enr_ayesha'::uuid,
  'and it is their own child'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select throws_ok(
  format($$insert into public.annual_result
             (tenant_id, campus_id, session_id, class_level_id, section_id, enrolment_id,
              subject_id, weighted_pct, status, terms_counted, terms_total, prorated_terms)
           values (%L, %L, %L, %L, %L, %L, %L, 99.00, 'final', 3, 3, 0)$$,
         :'tenant_id', :'campus_a', :'session_a', :'class9', :'sec_a', :'enr_ayesha', :'subj_phy'),
  '42501',
  NULL,
  'an aggregate has no write policy — a correction is a recompute, never an edit'
);

select is(
  (select count(*)::int from public.annual_result where weighted_pct = 99.00),
  0,
  'and nothing was written'
);

select * from finish();
rollback;
