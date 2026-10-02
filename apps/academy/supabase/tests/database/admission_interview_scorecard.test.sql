-- pgTAP tests for FR-B14: interview scorecard and recommendation.
begin;
select plan(17);

select public.provision_tenant('test-scorecard-co', 'Scorecard Co', 'owner@scorecardco.test');
select id as tenant_id from public.tenant where slug = 'test-scorecard-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select public.provision_tenant('test-scorecard-other-co', 'Scorecard Other Co', 'owner@scorecardotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-scorecard-other-co' \gset

-- Two real panel identities — AC3's "two panel members" needs a second
-- distinct interviewer, and panel_user_id is a not-null FK to app_user,
-- so (unlike the simulated-claims "owner" persona used elsewhere) each
-- one needs a real backing row.
select gen_random_uuid() as panel1_user_id \gset
select gen_random_uuid() as panel2_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'panel1_user_id', 'panel1@scorecardco.test', 'x', now(), 'authenticated', 'authenticated'),
       (:'panel2_user_id', 'panel2@scorecardco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'panel1_user_id', :'tenant_id', 'admissions_officer', 'Mr. Panel One'),
       (:'panel2_user_id', :'tenant_id', 'principal', 'Ms. Panel Two');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- One 2-seat section — the AC's own "N of 60 for 40 seats" denominator.
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 2) as section_id \gset

select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate One', p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent One', p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry1_id \gset
select public.fn_submit_application(:'enquiry1_id'::uuid) as app1_id \gset
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate Two', p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Two', p_phone => '03002222222', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry2_id \gset
select public.fn_submit_application(:'enquiry2_id'::uuid) as app2_id \gset
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate Three', p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Three', p_phone => '03003333333', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry3_id \gset
select public.fn_submit_application(:'enquiry3_id'::uuid) as app3_id \gset

select public.create_test_sitting(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, '2026-08-10 09:00:00+05'::timestamptz, 3) as sitting_id \gset
select public.fn_allocate_test_seat(:'sitting_id'::uuid, :'app1_id'::uuid);
select public.fn_allocate_test_seat(:'sitting_id'::uuid, :'app2_id'::uuid);
select public.fn_allocate_test_seat(:'sitting_id'::uuid, :'app3_id'::uuid);
select id as candidate1_id from public.admission_test_candidate where sitting_id = :'sitting_id'::uuid and application_id = :'app1_id'::uuid \gset
select id as candidate2_id from public.admission_test_candidate where sitting_id = :'sitting_id'::uuid and application_id = :'app2_id'::uuid \gset
select id as candidate3_id from public.admission_test_candidate where sitting_id = :'sitting_id'::uuid and application_id = :'app3_id'::uuid \gset

-- Distinct percentages so ranks are unambiguous: app1=1st, app2=2nd (both
-- within the 2 seats), app3=3rd (outside them).
select public.set_test_score(:'candidate1_id'::uuid, 'total', 90, 100);
select public.set_test_score(:'candidate2_id'::uuid, 'total', 70, 100);
select public.set_test_score(:'candidate3_id'::uuid, 'total', 50, 100);

select public.book_interview(:'app1_id'::uuid, :'panel1_user_id'::uuid, '2026-08-15 09:00:00+05'::timestamptz, '2026-08-15 09:20:00+05'::timestamptz) as interview1_id \gset
select public.book_interview(:'app1_id'::uuid, :'panel2_user_id'::uuid, '2026-08-15 10:00:00+05'::timestamptz, '2026-08-15 10:20:00+05'::timestamptz) as interview1b_id \gset
select public.book_interview(:'app3_id'::uuid, :'panel1_user_id'::uuid, '2026-08-15 11:00:00+05'::timestamptz, '2026-08-15 11:20:00+05'::timestamptz) as interview3_id \gset

-- ── AC1: a recommendation that overrides merit needs a >=20-char
--    justification ────────────────────────────────────────────────────

select throws_ok(
  format(
    'select public.submit_interview_scorecard(%L, %L::jsonb, %L)',
    :'interview1_id',
    '[{"criterion":"communication","score":4},{"criterion":"confidence","score":4},{"criterion":"academic_readiness","score":3},{"criterion":"parental_engagement","score":4},{"criterion":"overall_impression","score":3}]',
    'reject'
  ),
  'JUSTIFICATION_REQUIRED',
  'AC: candidate one ranks 1st of 3 for 2 seats — rejecting them without a justification is refused'
);
select is(
  (select count(*)::int from public.admission_interview_score where interview_id = :'interview1_id'::uuid),
  0,
  'the refused submission wrote no scores — the whole call rolled back together'
);

select throws_ok(
  format(
    'select public.submit_interview_scorecard(%L, %L::jsonb, %L, %L)',
    :'interview1_id',
    '[{"criterion":"communication","score":4},{"criterion":"confidence","score":4},{"criterion":"academic_readiness","score":3},{"criterion":"parental_engagement","score":4},{"criterion":"overall_impression","score":3}]',
    'reject', 'too short'
  ),
  'JUSTIFICATION_REQUIRED',
  'a justification under 20 characters is treated the same as no justification'
);

select public.submit_interview_scorecard(
  :'interview1_id'::uuid,
  '[{"criterion":"communication","score":4},{"criterion":"confidence","score":4},{"criterion":"academic_readiness","score":3},{"criterion":"parental_engagement","score":4},{"criterion":"overall_impression","score":3}]'::jsonb,
  'reject',
  'The child was disruptive throughout and could not answer basic questions.'
) as outcome1_id \gset
select ok(:'outcome1_id' is not null, 'a sufficiently justified override submission succeeds');
select is(
  (select recommendation from public.admission_interview_outcome where interview_id = :'interview1_id'::uuid)::text,
  'reject',
  'the outcome records the reject recommendation'
);

-- ── AC4: a criterion left unscored is rejected, listing what's missing ─

select throws_ok(
  format(
    'select public.submit_interview_scorecard(%L, %L::jsonb, %L, %L)',
    :'interview3_id',
    '[{"criterion":"communication","score":3},{"criterion":"confidence","score":3},{"criterion":"academic_readiness","score":3},{"criterion":"parental_engagement","score":3}]',
    'accept', 'Exceptional potential despite a lower written test score this round.'
  ),
  'MISSING_CRITERIA',
  'AC: leaving overall_impression unscored is rejected'
);
select is(
  (select count(*)::int from public.admission_interview_score where interview_id = :'interview3_id'::uuid),
  0,
  'the incomplete submission wrote no scores'
);

select public.submit_interview_scorecard(
  :'interview3_id'::uuid,
  '[{"criterion":"communication","score":5},{"criterion":"confidence","score":5},{"criterion":"academic_readiness","score":4},{"criterion":"parental_engagement","score":5},{"criterion":"overall_impression","score":5}]'::jsonb,
  'accept',
  'Exceptional potential despite a lower written test score this round.'
) as outcome3_id \gset
select ok(:'outcome3_id' is not null, 'AC: candidate three ranks 3rd for 2 seats — accepting them with a justification succeeds');

-- ── AC2: read-only to the submitter, editable only by a Principal ──────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format(
    'select public.submit_interview_scorecard(%L, %L::jsonb, %L)',
    :'interview1_id',
    '[{"criterion":"communication","score":4},{"criterion":"confidence","score":4},{"criterion":"academic_readiness","score":3},{"criterion":"parental_engagement","score":4},{"criterion":"overall_impression","score":3}]',
    'waitlist'
  ),
  'SCORECARD_LOCKED',
  'a non-Principal cannot reopen an already-submitted scorecard'
);
select is(
  (select recommendation from public.admission_interview_outcome where interview_id = :'interview1_id'::uuid)::text,
  'reject',
  'the blocked edit attempt left the outcome unchanged'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.submit_interview_scorecard(
  :'interview1_id'::uuid,
  '[{"criterion":"communication","score":4},{"criterion":"confidence","score":4},{"criterion":"academic_readiness","score":3},{"criterion":"parental_engagement","score":4},{"criterion":"overall_impression","score":3}]'::jsonb,
  'waitlist'
);
select is(
  (select recommendation from public.admission_interview_outcome where interview_id = :'interview1_id'::uuid)::text,
  'waitlist',
  'AC: a Principal can edit an already-submitted scorecard'
);

-- ── AC3: both scorecards for the same applicant, plus the per-criterion
--    mean, are displayed together ──────────────────────────────────────

select public.submit_interview_scorecard(
  :'interview1b_id'::uuid,
  '[{"criterion":"communication","score":2},{"criterion":"confidence","score":3},{"criterion":"academic_readiness","score":4},{"criterion":"parental_engagement","score":2},{"criterion":"overall_impression","score":5}]'::jsonb,
  'accept'
);
select (public.fn_scorecard_summary(:'app1_id'::uuid)) as summary1 \gset
select is(
  jsonb_array_length((:'summary1')::jsonb -> 'scorecards'),
  2,
  'AC: candidate one, seen by two panel members, has both scorecards listed'
);
select is(
  (((:'summary1')::jsonb -> 'mean_by_criterion' ->> 'communication')::numeric),
  3.00,
  'AC: the mean communication score across both panel members is displayed'
);

-- ── validation and tenant isolation ─────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.submit_interview_scorecard(%L, %L::jsonb, %L)', :'interview3_id', '[]', 'accept'),
  'FORBIDDEN',
  'a role with no admissions access cannot submit a scorecard'
);

reset role;
select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'owner@scorecardotherco2.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json, 'sub', :'other_user_id')::text,
  true
);
select throws_ok(
  format('select public.submit_interview_scorecard(%L, %L::jsonb, %L)', :'interview1_id', '[]', 'accept'),
  'INTERVIEW_NOT_FOUND',
  'submit_interview_scorecard refuses a foreign-tenant interview id'
);
select is(
  (select count(*)::int from public.admission_interview_score),
  0,
  'AC/defense-in-depth: another tenant''s owner sees zero interview scores via RLS'
);
select is(
  (select count(*)::int from public.admission_interview_outcome),
  0,
  'another tenant''s owner sees zero interview outcomes via RLS'
);

select * from finish();
rollback;
