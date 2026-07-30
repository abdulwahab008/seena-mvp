-- pgTAP tests for FR-B01: enquiry capture (referral validation, phone
-- normalization, enquiry_no generation/immutability, campus scope, and the
-- Nursery-only age gate). Uses named-parameter call notation throughout —
-- create_enquiry has several optional trailing params, and positional calls
-- silently break the moment the function's parameter order changes.
begin;
select plan(11);

select public.provision_tenant('test-enquiry-co', 'Enquiry Co', 'owner@enquiryco.test');
select id as tenant_id from public.tenant where slug = 'test-enquiry-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as nursery_id from public.class_level where tenant_id = :'tenant_id' and code = 'NUR' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── referral validation ───────────────────────────────────────────────

select throws_ok(
  format(
    $$ select public.create_enquiry(
         p_campus_id => %L, p_session_id => %L, p_child_name => 'Ali Khan', p_dob => '2020-01-01',
         p_class_applied_id => %L, p_parent_name => 'Ahmed Khan', p_phone => '03001234567',
         p_whatsapp_opt_in => false, p_source => 'referral'::public.enquiry_source
       ) $$,
    :'campus_id', :'session_id', :'class1_id'
  ),
  'Referrer required for referral enquiries',
  'a referral enquiry with no referrer name is rejected'
);

-- ── phone normalization ───────────────────────────────────────────────

select public.create_enquiry(
  p_campus_id => :'campus_id'::uuid, p_session_id => :'session_id'::uuid, p_child_name => 'Sara Ahmed',
  p_dob => '2020-01-01', p_class_applied_id => :'class1_id'::uuid, p_parent_name => 'Bilal Ahmed',
  p_phone => '0300-1234567', p_whatsapp_opt_in => true, p_source => 'phone'
) as enquiry1_id \gset
select is(
  (select phone_e164 from public.admission_enquiry where id = :'enquiry1_id'),
  '+923001234567',
  'a phone typed as 0300-1234567 normalizes to +923001234567'
);

select throws_ok(
  format(
    $$ select public.create_enquiry(
         p_campus_id => %L, p_session_id => %L, p_child_name => 'Bad Phone', p_dob => '2020-01-01',
         p_class_applied_id => %L, p_parent_name => 'Parent', p_phone => '12345',
         p_whatsapp_opt_in => false, p_source => 'walk_in'::public.enquiry_source
       ) $$,
    :'campus_id', :'session_id', :'class1_id'
  ),
  'PHONE_INVALID',
  'a number without a valid Pakistani prefix is rejected'
);

-- ── enquiry_no: per-campus-per-session, sequential, immutable ─────────

select enquiry_no from public.admission_enquiry where id = :'enquiry1_id' \gset
select ok(:'enquiry_no' ~ '^MAIN-\d{4}-\d{5}$', 'enquiry_no matches the CAMPUSCODE-YYYY-NNNNN shape');

select public.create_enquiry(
  p_campus_id => :'campus_id'::uuid, p_session_id => :'session_id'::uuid, p_child_name => 'Second Child',
  p_dob => '2020-01-01', p_class_applied_id => :'class1_id'::uuid, p_parent_name => 'Another Parent',
  p_phone => '03011234567', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry2_id \gset
select isnt(
  (select enquiry_no from public.admission_enquiry where id = :'enquiry2_id'),
  :'enquiry_no',
  'a second enquiry in the same campus/session gets a different (sequential) enquiry_no'
);

-- No authenticated role has an UPDATE policy on admission_enquiry at all
-- (every mutation funnels through create_enquiry) — RLS alone would make
-- this update a silent no-op rather than exercising the trigger's own
-- guard, so this specific check runs as superuser to reach it.
reset role;
select throws_ok(
  format($$ update public.admission_enquiry set enquiry_no = 'HACKED-0000-00000' where id = %L $$, :'enquiry1_id'),
  'ENQUIRY_NO_IMMUTABLE',
  'enquiry_no cannot be changed once assigned'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── Nursery-only age gate (2y6m by 1 April of the session year) ───────

-- Session starts_on is date_trunc('year', current_date), so the reference
-- date is 1 April of *this* year. A child born 1 year ago is well under
-- 2y6m; a child born 4 years ago is well over it — both margins wide enough
-- to not depend on today's exact date within the year.
select throws_ok(
  format(
    $$ select public.create_enquiry(
         p_campus_id => %L, p_session_id => %L, p_child_name => 'Too Young',
         p_dob => (current_date - interval '1 year')::date, p_class_applied_id => %L, p_parent_name => 'Parent',
         p_phone => '03021234567', p_whatsapp_opt_in => false, p_source => 'walk_in'::public.enquiry_source
       ) $$,
    :'campus_id', :'session_id', :'nursery_id'
  ),
  'AGE_BELOW_MINIMUM_NEEDS_OVERRIDE',
  'a Nursery applicant under 2y6m by 1 April is rejected without an override reason'
);
select lives_ok(
  format(
    $$ select public.create_enquiry(
         p_campus_id => %L, p_session_id => %L, p_child_name => 'Too Young',
         p_dob => (current_date - interval '1 year')::date, p_class_applied_id => %L, p_parent_name => 'Parent',
         p_phone => '03021234567', p_whatsapp_opt_in => false, p_source => 'walk_in'::public.enquiry_source,
         p_age_override_reason => 'Principal-approved early admission'
       ) $$,
    :'campus_id', :'session_id', :'nursery_id'
  ),
  'the same under-age Nursery applicant succeeds once an override reason is supplied'
);
select lives_ok(
  format(
    $$ select public.create_enquiry(
         p_campus_id => %L, p_session_id => %L, p_child_name => 'Old Enough',
         p_dob => (current_date - interval '4 years')::date, p_class_applied_id => %L, p_parent_name => 'Parent',
         p_phone => '03031234567', p_whatsapp_opt_in => false, p_source => 'walk_in'::public.enquiry_source
       ) $$,
    :'campus_id', :'session_id', :'nursery_id'
  ),
  'a Nursery applicant well over 2y6m needs no override'
);
select lives_ok(
  format(
    $$ select public.create_enquiry(
         p_campus_id => %L, p_session_id => %L, p_child_name => 'No Gate Here',
         p_dob => (current_date - interval '1 year')::date, p_class_applied_id => %L, p_parent_name => 'Parent',
         p_phone => '03041234567', p_whatsapp_opt_in => false, p_source => 'walk_in'::public.enquiry_source
       ) $$,
    :'campus_id', :'session_id', :'class1_id'
  ),
  'the age gate does not apply outside Nursery (ordinal 0), regardless of age'
);

-- ── campus scope enforcement on create ────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(gen_random_uuid()))::text,
  true
);
select throws_ok(
  format(
    $$ select public.create_enquiry(
         p_campus_id => %L, p_session_id => %L, p_child_name => 'Wrong Campus', p_dob => '2020-01-01',
         p_class_applied_id => %L, p_parent_name => 'Parent', p_phone => '03051234567',
         p_whatsapp_opt_in => false, p_source => 'walk_in'::public.enquiry_source
       ) $$,
    :'campus_id', :'session_id', :'class1_id'
  ),
  'FORBIDDEN',
  'an admissions officer cannot create an enquiry for a campus outside their JWT campus_ids'
);

select * from finish();
rollback;
