-- pgTAP tests for FR-E06: class-subject curriculum mapping, the weekly
-- period load view (with alternate-subject dedup), and copy_class_subject_map.
begin;
select plan(8);

select public.provision_tenant('test-curriculum-co', 'Curriculum Co', 'owner@curriculumco.test');
select id as tenant_id from public.tenant where slug = 'test-curriculum-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9_id from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select id as class10_id from public.class_level where tenant_id = :'tenant_id' and code = '10' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_subject('PHY', 'Physics', 'طبیعیات') as phy_id \gset
select public.create_subject('ENG', 'English', 'انگریزی') as eng_id \gset
select public.create_subject('ETH', 'Ethics', 'اخلاقیات') as ethics_id \gset
select public.create_subject('ISL', 'Islamiyat', 'اسلامیات', 'CORE', true, null, :'ethics_id'::uuid) as islamiyat_id \gset

-- ── weekly_periods validation ──────────────────────────────────────────

select throws_ok(
  format(
    $$ select public.upsert_class_subject(p_campus_id => %L, p_session_id => %L, p_class_level_id => %L, p_subject_id => %L, p_weekly_periods => 0::smallint) $$,
    :'campus_id', :'session_id', :'class9_id', :'phy_id'
  ),
  'WEEKLY_PERIODS_REQUIRED',
  'a weekly_periods of 0 for a compulsory subject is rejected'
);

select public.upsert_class_subject(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class9_id', p_subject_id => :'phy_id', p_weekly_periods => 6::smallint);
select public.upsert_class_subject(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class9_id', p_subject_id => :'eng_id', p_weekly_periods => 5::smallint);
select is(
  (select count(*)::int from public.class_subject where class_level_id = :'class9_id'),
  2,
  'two compulsory subjects are mapped to class 9'
);

-- ── elective bucket: a third subject can join an existing bucket ──────

select public.create_subject('CS', 'Computer Science', 'کمپیوٹر سائنس', 'ELECTIVE') as cs_id \gset
select public.create_subject('BIO', 'Biology', 'حیاتیات', 'ELECTIVE') as bio_id \gset
select public.create_subject('CHEM', 'Chemistry', 'کیمسٹری', 'ELECTIVE') as chem_id \gset
select public.upsert_class_subject(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class9_id', p_subject_id => :'cs_id', p_weekly_periods => 6::smallint, p_is_compulsory => false, p_elective_bucket => 1::smallint, p_choose_n => 1::smallint);
select public.upsert_class_subject(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class9_id', p_subject_id => :'bio_id', p_weekly_periods => 6::smallint, p_is_compulsory => false, p_elective_bucket => 1::smallint, p_choose_n => 1::smallint);
select public.upsert_class_subject(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class9_id', p_subject_id => :'chem_id', p_weekly_periods => 6::smallint, p_is_compulsory => false, p_elective_bucket => 1::smallint, p_choose_n => 1::smallint);
select is(
  (select choose_n from public.class_subject where class_level_id = :'class9_id' and subject_id = :'chem_id'),
  1::smallint,
  'a third subject added to bucket 1 saves and choose_n stays 1'
);
select is(
  (select count(*)::int from public.class_subject where class_level_id = :'class9_id' and elective_bucket = 1),
  3,
  'bucket 1 now holds all three elective subjects'
);

-- ── elective without a bucket is rejected ──────────────────────────────

select throws_ok(
  format(
    $$ select public.upsert_class_subject(p_campus_id => %L, p_session_id => %L, p_class_level_id => %L, p_subject_id => %L, p_weekly_periods => 4::smallint, p_is_compulsory => false) $$,
    :'campus_id', :'session_id', :'class9_id', :'eng_id'
  ),
  'ELECTIVE_BUCKET_REQUIRED',
  'a non-compulsory subject with no elective_bucket is rejected'
);

-- ── weekly period load, alternates counted once ────────────────────────

-- Rows so far: Physics 6, English 5 (both compulsory), CS 6 / Biology 6 /
-- Chemistry 6 (bucket 1 — the view sums every mapped row regardless of
-- bucket, since bucket exclusivity is a *choose_n at enrolment* concern,
-- not a *scheduled periods* one: a school still needs a teacher and a slot
-- for every option it offers). Naive sum so far: 6+5+6+6+6 = 29.
select public.upsert_class_subject(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class9_id', p_subject_id => :'islamiyat_id', p_weekly_periods => 3::smallint);
select public.upsert_class_subject(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class9_id', p_subject_id => :'ethics_id', p_weekly_periods => 3::smallint);
-- +3 (Islamiyat) +3 (Ethics) naively = 35, but the two are alternates and
-- collapse to one group, so only one 3 counts: 29 + 3 = 32.
select is(
  (select total_weekly_periods from public.v_class_weekly_period_load
    where class_level_id = :'class9_id' and stream_id is null),
  32,
  'Islamiyat and its alternate Ethics count once (3), not twice (6), toward the weekly total'
);

-- ── copy_class_subject_map ──────────────────────────────────────────────

-- 7 rows exist for class 9: Physics, English, CS, Biology, Chemistry,
-- Islamiyat, Ethics (the rejected 8th attempt above never became a row).
select public.copy_class_subject_map(:'class9_id'::uuid, :'class10_id'::uuid, :'session_id'::uuid, :'campus_id'::uuid) as copy_result \gset
select is(
  (:'copy_result')::jsonb,
  '{"created": 7, "skipped": 0}'::jsonb,
  'copying class 9''s map to class 10 reports 7 created, 0 skipped'
);
select is(
  (select count(*)::int from public.class_subject where class_level_id = :'class10_id'),
  7,
  'class 10 now has all 7 rows, each carrying class 10''s own class_level_id'
);

select * from finish();
rollback;
