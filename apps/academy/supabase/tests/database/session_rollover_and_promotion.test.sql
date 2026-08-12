-- pgTAP tests for FR-A06: session rollover and promotion engine.
--
-- Scale note: the AC's own numbers (2,000 enrolments, 1,100-student crash
-- point) describe illustrative scale, not a literal row count to test at —
-- this file uses smaller, proportionally representative cohorts (100 / 20
-- students) that exercise the exact same counting, idempotency and
-- resumability logic. True 2,000-row/mid-batch-crash-of-a-real-process
-- behaviour is not something a single pgTAP transaction can exercise
-- either way (a "crash" here is simulated by simply stopping short on how
-- many execute_rollover_batch calls are made — a real process crash and a
-- deliberately short-called batch are indistinguishable from the
-- function's own point of view, since each call is already its own
-- transaction).
--
-- Five independent scenarios, each with its own from/to session pair on
-- non-overlapping date ranges (all in the same campus, so the overlap
-- guard from session_lifecycle.sql would otherwise conflate them):
--   A: the AC1 counts (promote/retain/pass-out, GR unchanged).
--   B: AC2, re-running A's exact input a second time (no-op).
--   C: AC3, crash-and-resume via two separate execute_rollover_batch calls.
--   D: AC4, NO_TARGET_CLASS — class 10 with no class 11 defined.
--   E: the terminal-class default (Class 12, nothing higher defined at
--      all) — required so D's own "gap vs terminal" distinction is
--      actually proven, not just asserted in the migration's comments.
begin;
select plan(43);

select public.provision_tenant('test-rollover-co', 'Rollover Co', 'owner@rolloverpromoco.test');
select id as tenant_id from public.tenant where slug = 'test-rollover-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session0_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class6_id from public.class_level where tenant_id = :'tenant_id' and code = '6' \gset
select id as class7_id from public.class_level where tenant_id = :'tenant_id' and code = '7' \gset
select id as class9_id from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select id as class10_id from public.class_level where tenant_id = :'tenant_id' and code = '10' \gset
select id as class11_id from public.class_level where tenant_id = :'tenant_id' and code = '11' \gset
select id as class12_id from public.class_level where tenant_id = :'tenant_id' and code = '12' \gset

select public.provision_tenant('test-rollover-other-co', 'Rollover Other Co', 'owner@rolloverotherpromoco.test');
select id as other_tenant_id from public.tenant where slug = 'test-rollover-other-co' \gset
select id as other_session_id from public.academic_session where tenant_id = :'other_tenant_id' \gset
select id as other_class_id from public.class_level where tenant_id = :'other_tenant_id' and code = '7' \gset

-- A second campus in the SAME tenant, for the campus-scope checks at the
-- end: tenant isolation and campus scoping are different guards and a
-- same-tenant/other-campus principal is the only caller that tells them
-- apart. Inserted directly (as postgres, before the role switch below),
-- same as per_campus_role_scoping.test.sql does.
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Rollover Campus 2', 'RC2') returning id as campus2_id \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- One dedicated from/to session pair per scenario, all non-overlapping on
-- the shared campus (create_academic_session's overlap guard is per
-- campus, not per test scenario).
select public.create_academic_session(:'campus_id'::uuid, 'to-a', (current_date + interval '1 year')::date, (current_date + interval '2 years' - interval '1 day')::date) as to_a_id \gset
select public.create_academic_session(:'campus_id'::uuid, 'from-c', (current_date + interval '2 years')::date, (current_date + interval '3 years' - interval '1 day')::date) as from_c_id \gset
select public.create_academic_session(:'campus_id'::uuid, 'to-c', (current_date + interval '3 years')::date, (current_date + interval '4 years' - interval '1 day')::date) as to_c_id \gset
select public.create_academic_session(:'campus_id'::uuid, 'from-d', (current_date + interval '4 years')::date, (current_date + interval '5 years' - interval '1 day')::date) as from_d_id \gset
select public.create_academic_session(:'campus_id'::uuid, 'to-d', (current_date + interval '5 years')::date, (current_date + interval '6 years' - interval '1 day')::date) as to_d_id \gset
select public.create_academic_session(:'campus_id'::uuid, 'from-e', (current_date + interval '6 years')::date, (current_date + interval '7 years' - interval '1 day')::date) as from_e_id \gset
select public.create_academic_session(:'campus_id'::uuid, 'to-e', (current_date + interval '7 years')::date, (current_date + interval '8 years' - interval '1 day')::date) as to_e_id \gset

-- Sections: class 9 in session0 (scenario A's source), class 10 in to-a
-- (scenario A's target). One section each, generously capacitied, so the
-- least-filled-section picker always resolves to the one deterministic id.
select public.create_section(:'campus_id'::uuid, :'session0_id'::uuid, :'class9_id'::uuid, 'A', 150) as section_class9_from_id \gset
select public.create_section(:'campus_id'::uuid, :'to_a_id'::uuid, :'class10_id'::uuid, 'A', 150) as section_class10_to_a_id \gset
-- Retain decisions keep the student in the SAME class (9), so a class-9
-- section must also exist in the target session, not just class 10's.
select public.create_section(:'campus_id'::uuid, :'to_a_id'::uuid, :'class9_id'::uuid, 'A', 20) as section_class9_to_a_id \gset

select public.create_section(:'campus_id'::uuid, :'from_c_id'::uuid, :'class6_id'::uuid, 'A', 40) as section_class6_from_c_id \gset
select public.create_section(:'campus_id'::uuid, :'to_c_id'::uuid, :'class7_id'::uuid, 'A', 40) as section_class7_to_c_id \gset

select public.create_section(:'campus_id'::uuid, :'from_d_id'::uuid, :'class10_id'::uuid, 'A', 40) as section_class10_from_d_id \gset

select public.create_section(:'campus_id'::uuid, :'from_e_id'::uuid, :'class12_id'::uuid, 'A', 40) as section_class12_from_e_id \gset

-- ══════════════════════════════════════════════════════════════════════
-- Scenario A — AC1: 100 active enrolments, 94 promote (default) / 4
-- retain / 2 pass-out. Expect 98 enrolments in the target session, 2
-- students status='passed_out', GR numbers untouched.
-- ══════════════════════════════════════════════════════════════════════

select public.enrol_student(:'section_class9_from_id'::uuid, (public.create_student(:'campus_id'::uuid, 'Promote ' || g, '2014-01-01'::date, 'male'))::uuid)
  from generate_series(1, 94) as g;
select public.enrol_student(:'section_class9_from_id'::uuid, (public.create_student(:'campus_id'::uuid, 'Retain ' || g, '2014-01-01'::date, 'male'))::uuid)
  from generate_series(1, 4) as g;
select public.enrol_student(:'section_class9_from_id'::uuid, (public.create_student(:'campus_id'::uuid, 'PassOut ' || g, '2014-01-01'::date, 'male'))::uuid)
  from generate_series(1, 2) as g;

select id as promote1_id, gr_number as promote1_gr from public.student where tenant_id = :'tenant_id' and name_en = 'Promote 1' \gset

select is((select count(*)::int from public.student where tenant_id = :'tenant_id' and (name_en like 'Promote %' or name_en like 'Retain %' or name_en like 'PassOut %')), 100, 'setup: 100 students created for scenario A');

-- The AC's "GR numbers are unchanged for ALL 2,000" is a whole-cohort
-- claim, so it is checked as a whole-cohort digest, not one sampled
-- student: any reallocation, renumbering or swap anywhere in the 100
-- changes this hash.
select md5(string_agg(gr_number, ',' order by gr_number)) as gr_digest_before
  from public.student
 where tenant_id = :'tenant_id'
   and (name_en like 'Promote %' or name_en like 'Retain %' or name_en like 'PassOut %') \gset

select public.start_session_rollover(:'campus_id'::uuid, :'session0_id'::uuid, :'to_a_id'::uuid) as run_a_summary \gset
select id as run_a_id from public.session_rollover_run where to_session_id = :'to_a_id'::uuid \gset

select is(((:'run_a_summary')::jsonb ->> 'total_count')::int, 100, 'AC: the run snapshot covers all 100 active enrolments');
select is(
  (select decision::text from public.session_rollover_decision where run_id = :'run_a_id'::uuid and student_id = :'promote1_id'::uuid),
  'promote',
  'the default decision for a class with an active next class is promote'
);

-- Principal overrides: 4 retain, 2 pass-out.
select public.set_rollover_decision(:'run_a_id'::uuid, id, 'retain') from public.student where tenant_id = :'tenant_id' and name_en like 'Retain %';
select public.set_rollover_decision(:'run_a_id'::uuid, id, 'pass_out') from public.student where tenant_id = :'tenant_id' and name_en like 'PassOut %';

-- Driven in batches of 25 (not one giant call) to exercise the same
-- "batches, not one transaction" code path the crash-resume AC needs.
select public.execute_rollover_batch(:'run_a_id'::uuid, 25);
select public.execute_rollover_batch(:'run_a_id'::uuid, 25);
select public.execute_rollover_batch(:'run_a_id'::uuid, 25);
select public.execute_rollover_batch(:'run_a_id'::uuid, 25) as run_a_final \gset

select is((select status::text from public.session_rollover_run where id = :'run_a_id'::uuid), 'completed', 'AC1: the run completes after all batches are driven to the end');
select is((select processed_count from public.session_rollover_run where id = :'run_a_id'::uuid), 100, 'AC1: all 100 decisions were processed');
select is(
  (select count(*)::int from public.enrolment where session_id = :'to_a_id'::uuid and deleted_at is null),
  98,
  'AC1: 1,970-equivalent — 98 enrolments (94 promote + 4 retain) exist in the new session'
);
select is(
  (select count(*)::int from public.student where tenant_id = :'tenant_id' and status = 'passed_out'),
  2,
  'AC1: 30-equivalent — exactly 2 students have status=passed_out'
);
select is(
  (select count(*)::int from public.enrolment e join public.student s on s.id = e.student_id
    where e.session_id = :'to_a_id'::uuid and s.name_en like 'Retain %' and e.class_level_id = :'class9_id'::uuid),
  4,
  'retained students land back in the SAME class (class 9) in the new session, not promoted'
);
select is(
  (select count(*)::int from public.enrolment e join public.student s on s.id = e.student_id
    where e.session_id = :'to_a_id'::uuid and s.name_en like 'Promote %' and e.class_level_id = :'class10_id'::uuid),
  94,
  'promoted students land in class 10 (class 9''s ordinal + 1) in the new session'
);
select is(
  (select gr_number from public.student where id = :'promote1_id'::uuid),
  :'promote1_gr',
  'AC1: GR numbers are unchanged by rollover'
);
select is(
  (select md5(string_agg(gr_number, ',' order by gr_number)) from public.student
    where tenant_id = :'tenant_id'
      and (name_en like 'Promote %' or name_en like 'Retain %' or name_en like 'PassOut %')),
  :'gr_digest_before',
  'AC1: every one of the 100 GR numbers is byte-for-byte unchanged, not just the sampled student'
);
select is(
  (select previous_enrolment_id from public.enrolment where session_id = :'to_a_id'::uuid and student_id = :'promote1_id'::uuid),
  (select id from public.enrolment where session_id = :'session0_id'::uuid and student_id = :'promote1_id'::uuid),
  'the new enrolment links back to the prior session''s enrolment via previous_enrolment_id (FR-K24''s own primitive)'
);
select is((select is_no_op from public.session_rollover_run where id = :'run_a_id'::uuid), false, 'AC1: the first real run is NOT reported as a no-op');

-- ══════════════════════════════════════════════════════════════════════
-- Scenario B — AC2: running the exact same (campus, from, to) input again
-- creates zero additional enrolment rows and reports as a no-op.
-- ══════════════════════════════════════════════════════════════════════

select public.start_session_rollover(:'campus_id'::uuid, :'session0_id'::uuid, :'to_a_id'::uuid) as run_b_summary \gset
select id as run_b_id from public.session_rollover_run where to_session_id = :'to_a_id'::uuid and id <> :'run_a_id'::uuid \gset

select is(
  ((:'run_b_summary')::jsonb ->> 'total_count')::int, 98,
  'AC2: the re-run''s eligible set excludes the 2 now-passed-out students (student.status is no longer active)'
);

select public.execute_rollover_batch(:'run_b_id'::uuid, 200) as run_b_result \gset

select is((select status::text from public.session_rollover_run where id = :'run_b_id'::uuid), 'completed', 'AC2: the re-run also completes');
select is((select created_count from public.session_rollover_run where id = :'run_b_id'::uuid), 0, 'AC2: zero additional enrolment rows are created');
select is((select is_no_op from public.session_rollover_run where id = :'run_b_id'::uuid), true, 'AC2: the run is reported as a no-op');
select is(
  (select count(*)::int from public.enrolment where session_id = :'to_a_id'::uuid and deleted_at is null),
  98,
  'AC2: still exactly 98 enrolments in the target session — no duplicates'
);

-- ══════════════════════════════════════════════════════════════════════
-- Scenario C — AC3: crash after part of a batch, resume, final count
-- is exactly right.
-- ══════════════════════════════════════════════════════════════════════

select public.enrol_student(:'section_class6_from_c_id'::uuid, (public.create_student(:'campus_id'::uuid, 'Crash ' || g, '2016-01-01'::date, 'female'))::uuid)
  from generate_series(1, 20) as g;

select public.start_session_rollover(:'campus_id'::uuid, :'from_c_id'::uuid, :'to_c_id'::uuid) as run_c_summary \gset
select id as run_c_id from public.session_rollover_run where to_session_id = :'to_c_id'::uuid \gset
select is(((:'run_c_summary')::jsonb ->> 'total_count')::int, 20, 'AC3 setup: 20 eligible enrolments for the crash/resume scenario');

-- "Crashes after" most of the cohort: a single batch call short of the
-- full 20 — indistinguishable, from execute_rollover_batch's own point of
-- view, from a process that died right after this call returned.
select public.execute_rollover_batch(:'run_c_id'::uuid, 12);

select is((select processed_count from public.session_rollover_run where id = :'run_c_id'::uuid), 12, 'AC3: exactly 12 of 20 processed before the simulated crash');
select is((select status::text from public.session_rollover_run where id = :'run_c_id'::uuid), 'running', 'AC3: the run is not yet complete');
select is(
  (select count(*)::int from public.enrolment where session_id = :'to_c_id'::uuid and deleted_at is null),
  12,
  'AC3: 12 enrolments exist in the target session at the crash point'
);

-- "Restarted": the driver simply calls execute_rollover_batch again — no
-- separate resume/checkpoint API, the pending-decisions partial index does
-- the resuming.
select public.execute_rollover_batch(:'run_c_id'::uuid, 100);

select is((select processed_count from public.session_rollover_run where id = :'run_c_id'::uuid), 20, 'AC3: resumed from student 13 and finished the remaining 8');
select is((select status::text from public.session_rollover_run where id = :'run_c_id'::uuid), 'completed', 'AC3: the run is now complete');
select is(
  (select count(*)::int from public.enrolment where session_id = :'to_c_id'::uuid and deleted_at is null),
  20,
  'AC3: the final count is exactly 20 — resume never re-created the first 12'
);

-- ══════════════════════════════════════════════════════════════════════
-- Scenario D — AC4: class 10 has no class 11 defined for the tenant ->
-- held with NO_TARGET_CLASS, reported in the exception list.
-- ══════════════════════════════════════════════════════════════════════

select public.set_class_level_active(:'class11_id'::uuid, false);

select public.enrol_student(:'section_class10_from_d_id'::uuid, (public.create_student(:'campus_id'::uuid, 'NoTarget ' || g, '2011-01-01'::date, 'male'))::uuid)
  from generate_series(1, 5) as g;

select public.start_session_rollover(:'campus_id'::uuid, :'from_d_id'::uuid, :'to_d_id'::uuid) as run_d_summary \gset
select id as run_d_id from public.session_rollover_run where to_session_id = :'to_d_id'::uuid \gset

select is(
  (select decision::text from public.session_rollover_decision where run_id = :'run_d_id'::uuid limit 1),
  'hold',
  'AC4: a class-10 student with no class 11 defined defaults to hold, not silently dropped'
);
select is(
  (select count(*)::int from public.session_rollover_decision where run_id = :'run_d_id'::uuid and error_code = 'NO_TARGET_CLASS'),
  5,
  'AC4: all 5 students are held with reason NO_TARGET_CLASS'
);
select is(
  (select count(*)::int from public.v_rollover_decision_detail where run_id = :'run_d_id'::uuid and error_code is not null),
  5,
  'AC4: the exception list (v_rollover_decision_detail) surfaces all 5 held students'
);

-- A held student is exactly where a Principal would reach for the manual
-- "promote them into THIS class instead" override, so that override's own
-- tenant guard is checked here, while run D still has unprocessed rows.
select id as notarget1_id from public.student where tenant_id = :'tenant_id' and name_en = 'NoTarget 1' \gset
select throws_ok(
  format('select public.set_rollover_decision(%L, %L, %L, %L)', :'run_d_id', :'notarget1_id', 'promote', :'other_class_id'),
  'TARGET_CLASS_NOT_FOUND',
  'an explicit target class belonging to another tenant is refused, not written onto the decision'
);

select public.execute_rollover_batch(:'run_d_id'::uuid, 100);

select is((select status::text from public.session_rollover_run where id = :'run_d_id'::uuid), 'completed', 'AC4: the run still completes — held students don''t block the run');
select is((select held_count from public.session_rollover_run where id = :'run_d_id'::uuid), 5, 'AC4: run.held_count reflects all 5 held students');
select is(
  (select count(*)::int from public.enrolment where session_id = :'to_d_id'::uuid),
  0,
  'AC4: no enrolment row was created for a held student'
);

-- ══════════════════════════════════════════════════════════════════════
-- Scenario E — the terminal-class default: Class 12 has no higher class
-- at all, so the default is pass_out, NOT a NO_TARGET_CLASS hold.
-- ══════════════════════════════════════════════════════════════════════

select public.enrol_student(:'section_class12_from_e_id'::uuid, (public.create_student(:'campus_id'::uuid, 'Terminal ' || g, '2009-01-01'::date, 'female'))::uuid)
  from generate_series(1, 3) as g;

select public.start_session_rollover(:'campus_id'::uuid, :'from_e_id'::uuid, :'to_e_id'::uuid) as run_e_summary \gset
select id as run_e_id from public.session_rollover_run where to_session_id = :'to_e_id'::uuid \gset

select is(
  (select decision::text from public.session_rollover_decision where run_id = :'run_e_id'::uuid limit 1),
  'pass_out',
  'the highest defined class defaults to pass_out, not hold'
);
select is(
  (select count(*)::int from public.session_rollover_decision where run_id = :'run_e_id'::uuid and error_code is not null),
  0,
  'a terminal-class pass-out is not an exception — error_code stays null'
);

select public.execute_rollover_batch(:'run_e_id'::uuid, 100);

select is(
  (select count(*)::int from public.student where tenant_id = :'tenant_id' and name_en like 'Terminal %' and status = 'passed_out'),
  3,
  'all 3 terminal-class students end up status=passed_out'
);

-- ══════════════════════════════════════════════════════════════════════
-- RBAC, validation, tenant isolation
-- ══════════════════════════════════════════════════════════════════════

select throws_ok(
  format('select public.start_session_rollover(%L, %L, %L)', :'campus_id', :'session0_id', :'session0_id'),
  'SAME_SESSION',
  'rolling a session into itself is rejected'
);
select throws_ok(
  format('select public.start_session_rollover(%L, %L, %L)', :'campus_id', :'other_session_id', :'to_a_id'),
  'FROM_SESSION_NOT_FOUND',
  'a foreign-tenant from-session is refused'
);
select throws_ok(
  format('select public.execute_rollover_batch(%L)', gen_random_uuid()),
  'RUN_NOT_FOUND',
  'a nonexistent run id is refused'
);

select gen_random_uuid() as teacher_user_id \gset
reset role;
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@rolloverpromoco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'class_teacher', 'A Teacher');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select throws_ok(
  format('select public.start_session_rollover(%L, %L, %L)', :'campus_id', :'session0_id', :'to_a_id'),
  'FORBIDDEN',
  'a class_teacher may not start a rollover'
);

-- Campus scope: a Principal of the SAME tenant but a different campus is
-- refused the write and sees none of campus 1's runs or decisions through
-- RLS — tenant isolation alone would let this caller straight through.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus2_id'))::text,
  true
);
select throws_ok(
  format('select public.start_session_rollover(%L, %L, %L)', :'campus_id', :'session0_id', :'to_a_id'),
  'FORBIDDEN',
  'a Principal scoped to another campus of the same tenant may not start a rollover on campus 1'
);
select throws_ok(
  format('select public.execute_rollover_batch(%L)', :'run_a_id'),
  'FORBIDDEN',
  'a Principal scoped to another campus may not drive campus 1''s run'
);
select is(
  (select count(*)::int from public.session_rollover_run),
  0,
  'RLS: a Principal scoped to another campus sees none of campus 1''s rollover runs'
);
select is(
  (select count(*)::int from public.v_rollover_decision_detail),
  0,
  'RLS: a Principal scoped to another campus sees none of campus 1''s decisions'
);

select * from finish();
rollback;
