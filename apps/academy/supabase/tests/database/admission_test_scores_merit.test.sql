-- pgTAP tests for FR-B12: record admission test scores and merit rank.
--
-- "the merit list opens in under 2 seconds for 60 candidates x 3
-- subjects" is a performance AC, not asserted here — see the migration
-- header for why.
begin;
select plan(21);

select public.provision_tenant('test-merit-co', 'Merit Co', 'owner@meritco.test');
select id as tenant_id from public.tenant where slug = 'test-merit-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select public.provision_tenant('test-merit-other-co', 'Merit Other Co', 'owner@meritotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-merit-other-co' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_test_sitting(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, '2026-08-10 09:00:00+05'::timestamptz, 3) as sitting_id \gset

-- Candidate two is the oldest (earliest dob) — the tie-break AC hinges on
-- this ordering.
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate One', p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent One', p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry1_id \gset
select public.fn_submit_application(:'enquiry1_id'::uuid) as app1_id \gset
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate Two', p_dob => '2019-06-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Two', p_phone => '03002222222', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry2_id \gset
select public.fn_submit_application(:'enquiry2_id'::uuid) as app2_id \gset
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate Three', p_dob => '2021-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Three', p_phone => '03003333333', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry3_id \gset
select public.fn_submit_application(:'enquiry3_id'::uuid) as app3_id \gset

select public.fn_allocate_test_seat(:'sitting_id'::uuid, :'app1_id'::uuid) as candidate1_seat \gset
select public.fn_allocate_test_seat(:'sitting_id'::uuid, :'app2_id'::uuid) as candidate2_seat \gset
select public.fn_allocate_test_seat(:'sitting_id'::uuid, :'app3_id'::uuid) as candidate3_seat \gset
select id as candidate1_id from public.admission_test_candidate where sitting_id = :'sitting_id'::uuid and application_id = :'app1_id'::uuid \gset
select id as candidate2_id from public.admission_test_candidate where sitting_id = :'sitting_id'::uuid and application_id = :'app2_id'::uuid \gset
select id as candidate3_id from public.admission_test_candidate where sitting_id = :'sitting_id'::uuid and application_id = :'app3_id'::uuid \gset

-- ── AC1: obtained cannot exceed total ────────────────────────────────

select throws_ok(
  format('select public.set_test_score(%L, %L, 45, 40)', :'candidate1_id', 'math'),
  'new row for relation "admission_test_score" violates check constraint "chk_score_range"',
  'AC: obtained 45 against total 40 is rejected by the check constraint'
);

-- ── scores: candidate one and two tie at 85%, candidate three at 50% ──

select public.set_test_score(:'candidate1_id'::uuid, 'math', 40, 50);
select public.set_test_score(:'candidate1_id'::uuid, 'english', 45, 50);
select public.set_test_score(:'candidate2_id'::uuid, 'math', 42, 50);
select public.set_test_score(:'candidate2_id'::uuid, 'english', 43, 50);
select public.set_test_score(:'candidate3_id'::uuid, 'math', 30, 50);
select public.set_test_score(:'candidate3_id'::uuid, 'english', 20, 50);

select is(
  (select count(*)::int from public.admission_test_score where candidate_id = :'candidate1_id'::uuid),
  2,
  'both subject scores are recorded for candidate one'
);

-- ── AC3: a tie on percentage is broken by the older child ranking
--    higher, and the basis is exposed on the row ────────────────────────

select is(
  (select rnk::int from public.v_admission_merit_rank where candidate_id = :'candidate2_id'::uuid),
  1,
  'AC: candidate two, the older of the tied pair, ranks first'
);
select is(
  (select rnk::int from public.v_admission_merit_rank where candidate_id = :'candidate1_id'::uuid),
  2,
  'candidate one, tied on pct but younger, ranks second'
);
select is(
  (select pct from public.v_admission_merit_rank where candidate_id = :'candidate1_id'::uuid),
  85.00,
  'the aggregate percentage is computed across both subjects'
);
select is(
  (select tie_break_basis from public.v_admission_merit_rank where candidate_id = :'candidate1_id'::uuid),
  'percentage descending, then date of birth ascending (older ranks higher)',
  'AC: the tie-break basis is exposed on the ranked list'
);

-- ── AC2: an absent candidate has a null aggregate and is excluded ─────

select public.set_test_attendance(:'candidate3_id'::uuid, 'absent');
select is(
  (select attendance from public.admission_test_candidate where id = :'candidate3_id'::uuid)::text,
  'absent',
  'candidate three is marked absent'
);
select is(
  (select status from public.admission_application where id = :'app3_id'::uuid)::text,
  'test_absent',
  'AC: the application status flips to test_absent'
);
select is(
  (select count(*)::int from public.v_admission_merit_rank where candidate_id = :'candidate3_id'::uuid),
  0,
  'AC: the absent candidate is excluded from the ranking entirely'
);

-- ── AC5: publishing locks the sitting; corrections are refused until a
--    Principal unlocks it, and the published snapshot is untouched by
--    the refused attempt ──────────────────────────────────────────────

select public.fn_publish_merit_list(:'sitting_id'::uuid);
select is(
  (select count(*)::int from public.admission_merit_snapshot where sitting_id = :'sitting_id'::uuid),
  2,
  'the snapshot holds exactly the 2 ranked (non-absent) candidates'
);
select is(
  (select rank from public.admission_merit_snapshot where sitting_id = :'sitting_id'::uuid and application_id = :'app2_id'::uuid),
  1,
  'the snapshot preserves the tie-break-resolved rank'
);

select throws_ok(
  format('select public.set_test_score(%L, %L, 41, 50)', :'candidate1_id', 'math'),
  'SITTING_LOCKED',
  'AC: a score correction after publish is refused'
);
select is(
  (select obtained from public.admission_test_score where candidate_id = :'candidate1_id'::uuid and subject_code = 'math'),
  40.00,
  'the refused correction left the live score untouched'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.fn_unlock_test_scores(%L)', :'sitting_id'),
  'FORBIDDEN',
  'AC: only a Principal (or owner/super_admin) can unlock a published sitting — an Exam Controller cannot'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.fn_unlock_test_scores(:'sitting_id'::uuid);
select public.set_test_score(:'candidate1_id'::uuid, 'math', 41, 50);
select is(
  (select obtained from public.admission_test_score where candidate_id = :'candidate1_id'::uuid and subject_code = 'math'),
  41.00,
  'once unlocked, the correction is accepted'
);

-- Republishing overwrites the snapshot with the corrected numbers — the
-- prior refusal never touched it, but a deliberate unlock+republish does.
select public.fn_publish_merit_list(:'sitting_id'::uuid);
select is(
  (select rank from public.admission_merit_snapshot where sitting_id = :'sitting_id'::uuid and application_id = :'app1_id'::uuid),
  1,
  'AC: republishing reflects the corrected score — candidate one now edges out on pct and ranks first'
);

-- ── validation and tenant isolation ─────────────────────────────────

select throws_ok(
  format('select public.set_test_score(%L, %L, 10, 20)', :'candidate1_id', 'math'),
  'SITTING_LOCKED',
  'the republish re-locked the sitting'
);

reset role;
select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'owner@meritotherco2.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json, 'sub', :'other_user_id')::text,
  true
);
select throws_ok(
  format('select public.set_test_score(%L, %L, 10, 20)', :'candidate1_id', 'math'),
  'CANDIDATE_NOT_FOUND',
  'set_test_score refuses a foreign-tenant candidate id'
);
select is(
  (select count(*)::int from public.admission_test_score),
  0,
  'AC/defense-in-depth: another tenant''s owner sees zero test scores via RLS'
);
select is(
  (select count(*)::int from public.admission_merit_snapshot),
  0,
  'another tenant''s owner sees zero merit snapshot rows via RLS'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.set_test_score(%L, %L, 10, 20)', :'candidate1_id', 'math'),
  'FORBIDDEN',
  'a role with no admissions access cannot record a test score'
);

select * from finish();
rollback;
