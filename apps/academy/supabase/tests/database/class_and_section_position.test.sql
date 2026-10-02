-- pgTAP tests for FR-J05: class and section position.
--
--   AC1  section totals of 480, 472, 472 and 465 are positions 1, 2, 2 and 3,
--        and the "out of" figure is the number of RANKED candidates rather
--        than the section strength.
--   AC2  rank_policy 'exclude_absentees' plus a candidate absent in one paper
--        leaves that candidate with no position at all.
--   AC3  a class of three sections stores BOTH rank_in_section and
--        rank_in_class for every ranked candidate.
--   AC4  a mark change after ranking re-ranks the affected section AND the
--        class, and every report card in the class reads stale meanwhile.
--
-- Plus the properties the acceptance criteria do not state and the module
-- depends on:
--
--   * a class rank is refused until every section of the class is signed off,
--     naming the section it waits on — FR-I16 approves per section, and half a
--     cohort is not a class;
--   * a withheld (debarred) candidate is never ranked, under either policy;
--   * an EXEMPT candidate is ranked, out of the smaller total FR-I11 left them;
--   * 'include_all' ranks the absentee and moves the denominator with them;
--   * the policy that decided a row is frozen onto that row;
--   * recomputing positions cannot clear staleness the term result still has;
--   * a parent sees their own child's position and no classmate's total, and
--     nobody can type a position in by hand.
begin;
select plan(66);

select public.provision_tenant('test-rank-co', 'Rank Co', 'owner@rankco.test');
select id as tenant_id from public.tenant where slug = 'test-rank-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_id' \gset

select public.provision_tenant('test-rank-rival', 'Rank Rival', 'owner@rankrival.test');
select id as rival_id from public.tenant where slug = 'test-rank-rival' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@rankco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Rank Owner');

select gen_random_uuid() as ec_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ec_uid', 'controller@rankco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ec_uid', :'tenant_id', 'exam_controller', 'Shaista Kamal');

select gen_random_uuid() as principal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_uid', 'principal@rankco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_uid', :'tenant_id', 'principal', 'Tahira Aziz');

select gen_random_uuid() as clerk_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'clerk_uid', 'clerk@rankco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'clerk_uid', :'tenant_id', 'accountant', 'Accounts Clerk');

select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'rival_uid', 'owner@rankrival.test', 'x', now(), 'authenticated', 'authenticated');
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

-- Physics out of 300 and Maths out of 200 make a term total out of 500, so
-- AC1's four figures are sums of two papers rather than one paper renamed.
select public.create_subject('PHY', 'Physics', 'طبیعیات') as subj_phy \gset
select public.create_subject('MTH', 'Maths', 'ریاضی')     as subj_mth \gset

select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_phy', 6::smallint) as cs_phy \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_mth', 8::smallint) as cs_mth \gset

-- AC3's "class of three sections".
select public.create_section(:'campus_a', :'session_a', :'class9', 'A', 40) as sec_a \gset
select public.create_section(:'campus_a', :'session_a', :'class9', 'B', 40) as sec_b \gset
select public.create_section(:'campus_a', :'session_a', :'class9', 'C', 40) as sec_c \gset

select public.upsert_exam_term(:'campus_a', :'session_a', 'FINAL', 'Final Term', 1::smallint, 100.00) as term_f \gset
select public.activate_exam_terms(:'session_a'::uuid, :'campus_a'::uuid) as _act_terms \gset

select public.upsert_exam_subject(:'term_f', :'cs_phy', '[{"component":"theory","max_marks":300,"pass_marks":0}]'::jsonb) as es_phy \gset
select public.upsert_exam_subject(:'term_f', :'cs_mth', '[{"component":"theory","max_marks":200,"pass_marks":0}]'::jsonb) as es_mth \gset

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

-- ── The cohort ─────────────────────────────────────────────────────────
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);

select public.create_student(:'campus_a', 'Ayesha Noor',   '2011-01-01'::date, 'female') as st_ayesha \gset
select public.create_student(:'campus_a', 'Bilal Ahmed',   '2011-02-01'::date, 'male')   as st_bilal \gset
select public.create_student(:'campus_a', 'Chandni Rao',   '2011-03-01'::date, 'female') as st_chandni \gset
select public.create_student(:'campus_a', 'Danish Ali',    '2011-04-01'::date, 'male')   as st_danish \gset
select public.create_student(:'campus_a', 'Emaan Zafar',   '2011-05-01'::date, 'female') as st_emaan \gset
select public.create_student(:'campus_a', 'Farhan Iqbal',  '2011-06-01'::date, 'male')   as st_farhan \gset
select public.create_student(:'campus_a', 'Ghazala Riaz',  '2011-07-01'::date, 'female') as st_ghazala \gset
select public.create_student(:'campus_a', 'Hina Sattar',   '2011-08-01'::date, 'female') as st_hina \gset
select public.create_student(:'campus_a', 'Imran Baig',    '2011-09-01'::date, 'male')   as st_imran \gset
select public.create_student(:'campus_a', 'Junaid Sheikh', '2011-10-01'::date, 'male')   as st_junaid \gset

select public.enrol_student(:'sec_a', :'st_ayesha')  as enr_ayesha \gset
select public.enrol_student(:'sec_a', :'st_bilal')   as enr_bilal \gset
select public.enrol_student(:'sec_a', :'st_chandni') as enr_chandni \gset
select public.enrol_student(:'sec_a', :'st_danish')  as enr_danish \gset
select public.enrol_student(:'sec_a', :'st_emaan')   as enr_emaan \gset
select public.enrol_student(:'sec_b', :'st_farhan')  as enr_farhan \gset
select public.enrol_student(:'sec_b', :'st_ghazala') as enr_ghazala \gset
select public.enrol_student(:'sec_c', :'st_hina')    as enr_hina \gset
select public.enrol_student(:'sec_c', :'st_imran')   as enr_imran \gset
select public.enrol_student(:'sec_c', :'st_junaid')  as enr_junaid \gset

select public.fn_find_or_create_guardian(p_name_en => 'Ayesha Mother', p_phone_e164 => '+923005550051') as g_ayesha \gset
select public.link_guardian(:'st_ayesha'::uuid, :'g_ayesha'::uuid, 'mother'::public.guardian_relationship, true, true);
reset role;
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'parent_uid', 'mother@rankco.test', 'x', now(), 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'parent_uid'::uuid where id = :'g_ayesha'::uuid;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

select is(
  app.fn_rank_policy(:'campus_a'::uuid)::text,
  'exclude_absentees',
  'a campus that has never been configured excludes absentees — the case AC2 describes'
);

-- Emaan misses the Maths paper; Junaid is debarred from Physics; Ghazala is
-- exempt from Maths, which is an entitlement rather than a failure to appear.
select public.set_exam_attendance(:'es_mth', :'enr_emaan',   'absent', 'medical')          as _ab \gset
select public.set_exam_attendance(:'es_phy', :'enr_junaid',  'debarred', 'fee_default')    as _deb \gset
select public.set_exam_attendance(:'es_mth', :'enr_ghazala', 'exempt', 'board_exemption')  as _ex \gset

-- One batch covers exactly one section (FR-I12), so six calls: two papers
-- across three sections. Section A carries AC1's four figures: 480, 472, 472
-- and 465.
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_phy', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 300),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 290),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 280),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 270),
  jsonb_build_object('enrolment_id', :'enr_emaan',   'component', 'theory', 'marks_obtained', 250)
))) as _mpa \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_mth', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 180),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 182),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 192),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 195)
))) as _mma \gset

select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_phy', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_farhan',  'component', 'theory', 'marks_obtained', 295),
  jsonb_build_object('enrolment_id', :'enr_ghazala', 'component', 'theory', 'marks_obtained', 280)
))) as _mpb \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_mth', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_farhan',  'component', 'theory', 'marks_obtained', 195)
))) as _mmb \gset

select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_phy', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_hina',    'component', 'theory', 'marks_obtained', 285),
  jsonb_build_object('enrolment_id', :'enr_imran',   'component', 'theory', 'marks_obtained', 265)
))) as _mpc \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_mth', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_hina',    'component', 'theory', 'marks_obtained', 190),
  jsonb_build_object('enrolment_id', :'enr_imran',   'component', 'theory', 'marks_obtained', 190),
  jsonb_build_object('enrolment_id', :'enr_junaid',  'component', 'theory', 'marks_obtained', 190)
))) as _mmc \gset

-- ═══════════════════════════════════════════════════════════════════════
-- A class rank is the whole class or nothing
-- ═══════════════════════════════════════════════════════════════════════

select public.fn_approve_marks(:'es_phy', :'sec_a') as _a1 \gset
select public.fn_approve_marks(:'es_mth', :'sec_a') as _a2 \gset
select public.fn_approve_marks(:'es_phy', :'sec_b') as _b1 \gset
select public.fn_approve_marks(:'es_mth', :'sec_b') as _b2 \gset

select is(
  (select count(*)::int from public.result_position),
  0,
  'two sections of three signed off ranks nobody — FR-I16 approves per section, and half a cohort is not a class'
);
select is(
  ((public.fn_position_readiness(:'term_f', :'class9')) ->> 'ready')::boolean,
  false,
  'and the readiness answer says so'
);
select throws_ok(
  format($$select public.fn_compute_positions(%L, %L)$$, :'term_f', :'class9'),
  '23514',
  'positions wait on section C',
  'an explicit re-rank is refused and NAMES the section it waits on'
);

-- The last section is what fires it.
select public.fn_approve_marks(:'es_phy', :'sec_c') as _c1 \gset
select public.fn_approve_marks(:'es_mth', :'sec_c') as _c2 \gset

select is(
  (select count(*)::int from public.result_position),
  10,
  'the last section completes the class and every candidate gets a row, ranked or not'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: 480, 472, 472, 465 -> 1, 2, 2, 3
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select total_obtained from public.result_position where enrolment_id = :'enr_ayesha'),
  480.00::numeric(9,2),
  'AC1: Physics 300 and Maths 180 total 480'
);
select is(
  (select rank_in_section from public.result_position where enrolment_id = :'enr_ayesha'),
  1,
  'AC1: 480 is position 1'
);
select is(
  (select total_obtained from public.result_position where enrolment_id = :'enr_bilal'),
  472.00::numeric(9,2),
  'AC1: 290 + 182 is 472'
);
select is(
  (select total_obtained from public.result_position where enrolment_id = :'enr_chandni'),
  472.00::numeric(9,2),
  'AC1: and so is 280 + 192 — a tie on the total, not on a paper'
);
select is(
  (select rank_in_section from public.result_position where enrolment_id = :'enr_bilal'),
  2,
  'AC1: the first 472 is position 2'
);
select is(
  (select rank_in_section from public.result_position where enrolment_id = :'enr_chandni'),
  2,
  'AC1: the second 472 SHARES position 2 — ties are not broken'
);
select is(
  (select rank_in_section from public.result_position where enrolment_id = :'enr_danish'),
  3,
  'AC1: and 465 is position 3, NOT 4 — dense ranking, so the tie does not consume a position'
);
select is(
  (select ranked_out_of from public.result_position where enrolment_id = :'enr_ayesha'),
  4,
  'AC1: out of 4 — the number of RANKED candidates'
);
select is(
  (select count(*)::int from public.enrolment where section_id = :'sec_a' and status = 'active'),
  5,
  'AC1: while the section strength is 5 — the two figures are deliberately different'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: three sections, both ranks stored for every ranked candidate
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select count(*)::int from public.result_position
    where is_ranked and (rank_in_section is null or rank_in_class is null)),
  0,
  'AC3: every ranked candidate has BOTH a section position and a class one'
);
select is(
  (select count(distinct section_id)::int from public.result_position where exam_term_id = :'term_f'),
  3,
  'AC3: across all three sections of the class'
);
-- Class order: Farhan 490, Ayesha 480, Hina 475, Bilal/Chandni 472,
-- Danish 465, Ghazala 460, Imran 455.
select is(
  (select rank_in_class from public.result_position where enrolment_id = :'enr_farhan'),
  1,
  'AC3: the class topper is in section B, and the class rank knows it'
);
select is(
  (select rank_in_section from public.result_position where enrolment_id = :'enr_farhan'),
  1,
  'AC3: he tops his own section too, and the two numbers are computed separately'
);
select is(
  (select rank_in_class from public.result_position where enrolment_id = :'enr_ayesha'),
  2,
  'AC3: section A''s topper is second in the class'
);
select is(
  (select rank_in_class from public.result_position where enrolment_id = :'enr_hina'),
  3,
  'AC3: section C''s topper is third'
);
select is(
  (select rank_in_class from public.result_position where enrolment_id = :'enr_chandni'),
  4,
  'AC3: and the tie shares a class position exactly as it shares a section one'
);
select is(
  (select rank_in_class from public.result_position where enrolment_id = :'enr_danish'),
  5,
  'AC3: with the next class position not skipped either'
);
select is(
  (select ranked_out_of_class from public.result_position where enrolment_id = :'enr_ayesha'),
  8,
  'AC3: out of the 8 ranked candidates in the class, across all three sections'
);
select is(
  (select ranked_out_of from public.result_position where enrolment_id = :'enr_hina'),
  2,
  'AC3: while her section denominator is its own 2 — section C has a debarred candidate in it'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: the absentee has no position
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select is_ranked from public.result_position where enrolment_id = :'enr_emaan'),
  false,
  'AC2: a candidate absent in ONE paper is not ranked under exclude_absentees'
);
select ok(
  (select rank_in_section from public.result_position where enrolment_id = :'enr_emaan') is null,
  'AC2: with no section position — the report card prints a dash'
);
select ok(
  (select rank_in_class from public.result_position where enrolment_id = :'enr_emaan') is null,
  'AC2: and no class position either'
);
select is(
  (select exclusion_reason from public.result_position where enrolment_id = :'enr_emaan'),
  'absent',
  'AC2: the row says WHY, so "where is my daughter''s position" is answered off the row'
);
select is(
  (select rank_policy::text from public.result_position where enrolment_id = :'enr_emaan'),
  'exclude_absentees',
  'and the policy that decided it is frozen onto the row, not looked up again later'
);
select ok(
  (select total_obtained from public.result_position where enrolment_id = :'enr_emaan') > 0,
  'her marks are still stored — she is unranked, not unrecorded'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Withheld is never ranked, under either policy
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select is_ranked from public.result_position where enrolment_id = :'enr_junaid'),
  false,
  'a debarred candidate has no position — there is no released total to rank'
);
select is(
  (select exclusion_reason from public.result_position where enrolment_id = :'enr_junaid'),
  'withheld',
  'and the reason is withheld rather than absent'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Exempt is ranked — the policy names absentees and only absentees
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select is_ranked from public.result_position where enrolment_id = :'enr_ghazala'),
  true,
  'an exempt candidate IS ranked — an exemption is an entitlement, not a failure to appear'
);
select is(
  (select total_max from public.result_position where enrolment_id = :'enr_ghazala'),
  300,
  'out of the 300 FR-I11 left her rather than the 500 her classmates sat'
);
select is(
  (select total_obtained from public.result_position where enrolment_id = :'enr_ghazala'),
  280.00::numeric(9,2),
  'so the merit list orders her on a smaller total, and stores what it was out of rather than hiding it'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The policy is a setting, and changing it changes the cohort
-- ═══════════════════════════════════════════════════════════════════════

select public.set_rank_policy(:'campus_a', 'include_all'::public.rank_policy) as _sp \gset
select is(
  public.fn_compute_positions(:'term_f', :'class9'),
  10,
  'the Exam Controller re-ranks the class explicitly'
);
select is(
  (select is_ranked from public.result_position where enrolment_id = :'enr_emaan'),
  true,
  'under include_all the absentee IS ranked — her zeros simply count'
);
select is(
  (select rank_in_section from public.result_position where enrolment_id = :'enr_emaan'),
  4,
  'behind the four classmates who beat her'
);
select is(
  (select ranked_out_of from public.result_position where enrolment_id = :'enr_ayesha'),
  5,
  'and the section denominator moves with her — 5 ranked, not 4'
);
select is(
  (select is_ranked from public.result_position where enrolment_id = :'enr_junaid'),
  false,
  'while the debarred candidate is still not ranked — include_all is about absentees, not withheld results'
);
select is(
  (select ranked_out_of_class from public.result_position where enrolment_id = :'enr_ayesha'),
  9,
  'so the class ranks 9 of its 10 candidates'
);
select is(
  (select rank_in_section from public.result_position where enrolment_id = :'enr_ayesha'),
  1,
  'and nobody who was already ranked moves — adding a candidate below them changes no position'
);

select public.set_rank_policy(:'campus_a', 'exclude_absentees'::public.rank_policy) as _sp2 \gset
select is(
  public.fn_compute_positions(:'term_f', :'class9'),
  10,
  'and the policy is reversible'
);
select is(
  (select ranked_out_of from public.result_position where enrolment_id = :'enr_ayesha'),
  4,
  'putting the denominator back'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);
select throws_ok(
  format($$select public.set_rank_policy(%L, 'include_all'::public.rank_policy)$$, :'campus_a'),
  '42501',
  'FORBIDDEN',
  'an accountant does not decide who appears in the merit list'
);
select throws_ok(
  format($$select public.fn_compute_positions(%L, %L)$$, :'term_f', :'class9'),
  '42501',
  'FORBIDDEN',
  'nor re-ranks one'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: one mark in section C re-ranks section A
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select is(
  (select count(*)::int from public.v_result_position where is_stale),
  0,
  'a freshly ranked class is not stale'
);

select public.request_mark_unlock(:'es_phy', :'sec_c', 'Q9 total mis-added on Imran''s script') as unlock_req \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select public.fn_break_glass_unlock(:'unlock_req', 60) as _bg \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_phy', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_imran', 'component', 'theory', 'marks_obtained', 295)
))) as _fix \gset

select is(
  (select count(*)::int from public.v_result_position where is_stale),
  10,
  'AC4: a correction in section C marks EVERY report card in the class stale, section A''s included'
);
select throws_ok(
  format($$select public.fn_compute_positions(%L, %L)$$, :'term_f', :'class9'),
  '42501',
  'marks are open under a break-glass window on Physics — recompute when it closes',
  'and a merit list computed mid-window is refused, for FR-J02''s reason'
);
select is(
  public.fn_recompute_stale_positions(:'term_f'),
  10,
  'AC4: the nightly job finds the class and re-ranks it'
);
select is(
  (select count(*)::int from public.v_result_position where is_stale),
  10,
  'and it is STILL stale — re-ranking cannot paint over a mark nobody has corrected'
);

-- Only recomputing the term result clears it, and the whole class moves.
select public.fn_relock_expired_unlocks(clock_timestamp() + interval '5 hours') as _relock \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select is(
  public.fn_compute_subject_result(:'term_f', :'sec_c'),
  6,
  'once the window closes, section C''s term results recompute'
);
select is(
  (select count(*)::int from public.v_result_position where is_stale),
  0,
  'AC4: and the positions follow in the same transaction, so the staleness clears itself'
);
select is(
  (select total_obtained from public.result_position where enrolment_id = :'enr_imran'),
  485.00::numeric(9,2),
  'the corrected mark is in the total'
);
select is(
  (select rank_in_section from public.result_position where enrolment_id = :'enr_imran'),
  1,
  'AC4: which moves him to the top of section C'
);
select is(
  (select rank_in_class from public.result_position where enrolment_id = :'enr_imran'),
  2,
  'and to second in the class'
);
select is(
  (select rank_in_class from public.result_position where enrolment_id = :'enr_ayesha'),
  3,
  'AC4: pushing section A''s topper from second to third — a mark in another section re-ranks this one'
);
select is(
  (select rank_in_section from public.result_position where enrolment_id = :'enr_ayesha'),
  1,
  'while her SECTION position is untouched, because it is a different cohort'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The sheet
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (public.fn_position_sheet(:'term_f', :'class9') -> 'candidates' -> 0 ->> 'enrolment_id')::uuid,
  :'enr_farhan'::uuid,
  'the merit list opens on the class topper'
);
select is(
  public.fn_position_sheet(:'term_f', :'class9') ->> 'rank_policy',
  'exclude_absentees',
  'and quotes the policy in force rather than leaving it to be guessed'
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
  (select count(*)::int from public.result_position),
  0,
  'another tenant sees no positions at all'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'parent_uid')::text,
  true
);
select is(
  (select count(*)::int from public.result_position),
  1,
  'a parent sees exactly one position row'
);
select is(
  (select enrolment_id from public.result_position),
  :'enr_ayesha'::uuid,
  'their own child''s — not the classmate''s total it was measured against'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select throws_ok(
  format($$insert into public.result_position
             (tenant_id, campus_id, exam_term_id, class_level_id, section_id, enrolment_id,
              total_obtained, total_max, rank_in_section, rank_in_class, ranked_out_of,
              ranked_out_of_class, is_ranked, rank_policy)
           values (%L, %L, %L, %L, %L, %L, 999, 1000, 1, 1, 1, 1, true, 'exclude_absentees')$$,
         :'tenant_id', :'campus_a', :'term_f', :'class9', :'sec_a', :'enr_danish'),
  '42501',
  NULL,
  'a position is computed against a cohort, never typed in'
);
select lives_ok(
  format($$update public.result_position set rank_in_section = 1 where enrolment_id = %L$$, :'enr_danish'),
  'and with no UPDATE policy the statement reaches no row at all'
);
select is(
  (select rank_in_section from public.result_position where enrolment_id = :'enr_danish'),
  3,
  'so the position stands where the marks put it'
);

select * from finish();
rollback;
