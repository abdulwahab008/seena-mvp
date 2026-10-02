-- pgTAP tests for FR-D13 (substitute teacher assignment for absences).
begin;
select plan(27);

select public.provision_tenant('test-sub-co', 'Sub Co', 'owner@subco.test');
select id as tenant_id from public.tenant where slug = 'test-sub-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner@subco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id', 'owner', 'E2E Owner');

-- Teacher A: the absent teacher. Teacher B: busy elsewhere at the exact
-- clash clock time (AC #2's "T2 already teaches period 3" case). Teacher
-- C: free and qualified — the one who actually gets assigned.
select gen_random_uuid() as teacher_a_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_a_user_id', 'teacher-a@subco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_a_user_id', :'tenant_id', 'subject_teacher', 'Teacher A');

select gen_random_uuid() as teacher_b_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_b_user_id', 'teacher-b@subco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_b_user_id', :'tenant_id', 'subject_teacher', 'Teacher B');

select gen_random_uuid() as teacher_c_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_c_user_id', 'teacher-c@subco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_c_user_id', :'tenant_id', 'subject_teacher', 'Teacher C');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- AC4 needs a Module D staff record linked back to Teacher A's login, so
-- the leave-cancel trigger can resolve leave_application.staff_id ->
-- app_user.user_id.
select public.create_staff(:'campus_id'::uuid, 'Teacher A', 'female', p_cnic => '4210112345678') as teacher_a_staff_id \gset
select public.link_staff_user_account(:'teacher_a_staff_id'::uuid, :'teacher_a_user_id'::uuid);
select public.create_leave_type('CASUAL', 'Casual Leave', 10) as casual_id \gset
select public.fn_grant_leave_balance(:'teacher_a_staff_id'::uuid, :'casual_id'::uuid, 5.00);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_a_id \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 40) as section_b_id \gset

select public.create_subject('PHY', 'Physics', 'فزکس') as physics_id \gset
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'physics_id'::uuid, 5::smallint);

-- All three teachers are approved to teach Physics at class 1 — the
-- ranking tests below turn purely on is_free / periods_covered_today, not
-- can_teach.
select public.create_staff_teachable_subject(:'teacher_a_user_id'::uuid, :'physics_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);
select public.create_staff_teachable_subject(:'teacher_b_user_id'::uuid, :'physics_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);
select public.create_staff_teachable_subject(:'teacher_c_user_id'::uuid, :'physics_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);

select public.create_bell_template(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'Regular',
  jsonb_build_array(
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '09:00', 'end_time', '09:40')
  ),
  true
) as template_id \gset

select public.create_timetable_version(:'campus_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'Draft v1') as version_id \gset

-- A real Monday, derived (never hand-picked) so the weekday check inside
-- create_substitution/suggest_substitutes is satisfied by construction —
-- this codebase has already been bitten once by hardcoded wall-clock/
-- calendar assumptions drifting from what a literal date actually is.
select extract(dow from date '2026-08-03')::smallint as monday \gset

-- Teacher A: period 1 (08:00-08:40), the slot that will need covering.
select public.upsert_timetable_slot(:'version_id'::uuid, :'section_a_id'::uuid, :'monday'::smallint, 1::smallint, :'physics_id'::uuid, :'teacher_a_user_id'::uuid) as slot_a_p1 \gset
-- Teacher B: busy in section B at the SAME clock time (period 1) —
-- excluded from period 1's free candidates.
select public.upsert_timetable_slot(:'version_id'::uuid, :'section_b_id'::uuid, :'monday'::smallint, 1::smallint, :'physics_id'::uuid, :'teacher_b_user_id'::uuid) as slot_b_p1 \gset
-- A second slot for Teacher A, period 2 — Teacher B is NOT busy at this
-- clock time, so they're free for it (AC #2's "may still appear for
-- period 4" half).
select public.upsert_timetable_slot(:'version_id'::uuid, :'section_a_id'::uuid, :'monday'::smallint, 2::smallint, :'physics_id'::uuid, :'teacher_a_user_id'::uuid) as slot_a_p2 \gset

-- ── AC #1/#2: suggest_substitutes ranks by is_free, then can_teach ──────

select is(
  (select is_free from public.suggest_substitutes(:'slot_a_p1'::uuid, '2026-08-03'::date) where staff_id = :'teacher_b_user_id'::uuid),
  false,
  'AC: Teacher B, already teaching section B at the same clock time, is marked not-free for period 1'
);
select is(
  (select is_free from public.suggest_substitutes(:'slot_a_p1'::uuid, '2026-08-03'::date) where staff_id = :'teacher_c_user_id'::uuid),
  true,
  'Teacher C, with nothing scheduled then, is marked free for period 1'
);
select is(
  (select is_free from public.suggest_substitutes(:'slot_a_p2'::uuid, '2026-08-03'::date) where staff_id = :'teacher_b_user_id'::uuid),
  true,
  'AC: the same Teacher B is free for period 2, a different clock time — exclusion is per-period, not blanket'
);
select is(
  (select count(*)::int from public.suggest_substitutes(:'slot_a_p1'::uuid, '2026-08-03'::date) where staff_id = :'teacher_a_user_id'::uuid),
  0,
  'the absent teacher never appears as their own substitute candidate'
);
select ok(
  (
    select array_agg(staff_id order by ord) = array[:'teacher_c_user_id'::uuid, :'teacher_b_user_id'::uuid]
    from (select staff_id, row_number() over () as ord from public.suggest_substitutes(:'slot_a_p1'::uuid, '2026-08-03'::date)) t
  ),
  'is_free sorts first: free Teacher C ranks above busy Teacher B for period 1'
);

-- 2026-08-04 is the calendar day right after :monday, so it is guaranteed
-- to fall on a different weekday, regardless of which weekday :monday
-- itself resolves to.
select throws_ok(
  format($$ select public.suggest_substitutes(%L, '2026-08-04'::date) $$, :'slot_a_p1'),
  'SUB_DATE_WEEKDAY_MISMATCH',
  'a sub_date whose weekday does not match the slot''s own weekday is rejected'
);

-- ── create_substitution ──────────────────────────────────────────────

select public.create_substitution(:'slot_a_p1'::uuid, '2026-08-03'::date, :'teacher_c_user_id'::uuid, 'leave') as sub_id \gset
select ok(:'sub_id' is not null, 'AC: assigning a free, qualified candidate creates a substitution row');
select is(
  (select status::text from public.timetable_substitution where id = :'sub_id'),
  'active',
  'a fresh substitution starts active'
);
select is(
  (select staff_id from public.timetable_slot where id = :'slot_a_p1'),
  :'teacher_a_user_id'::uuid,
  'AC: the master timetable_slot row is completely unchanged — still Teacher A, never edited'
);
select is(
  (select absent_staff_id from public.timetable_substitution where id = :'sub_id'),
  :'teacher_a_user_id'::uuid,
  'the substitution records who was absent'
);

-- AC (fairness term): once assigned, Teacher C shows 1 period covered
-- today in a fresh ranking call.
select is(
  (select periods_covered_today from public.suggest_substitutes(:'slot_a_p2'::uuid, '2026-08-03'::date) where staff_id = :'teacher_c_user_id'::uuid),
  1,
  'AC: periods_covered_today reflects the substitution just created, as the fairness term for the next period'
);

-- Re-filling the SAME (slot, date) cell in 2 taps re-targets the one row,
-- never accumulates a duplicate.
select public.create_substitution(:'slot_a_p1'::uuid, '2026-08-03'::date, :'teacher_c_user_id'::uuid, 'official_duty') as sub_id_again \gset
select is(:'sub_id_again'::uuid, :'sub_id'::uuid, 're-saving the same period reuses the same substitution row (unique on slot_id, sub_date)');
select is(
  (select count(*)::int from public.timetable_substitution where slot_id = :'slot_a_p1'),
  1,
  'exactly one substitution row exists for this slot regardless of how many times it was filled'
);

-- ── hard rejects ─────────────────────────────────────────────────────

-- Teacher B's OWN regular slot (slot_b_p1) is at the same clock time as
-- slot_a_p1 (both period 1) — trying to substitute them into slot_a_p1
-- clashes regardless of who currently fills that cell.
select throws_ok(
  format(
    $$ select public.create_substitution(%L, '2026-08-03'::date, %L, 'leave') $$,
    :'slot_a_p1', :'teacher_b_user_id'
  ),
  'SUBSTITUTE_CLASH',
  'AC-adjacent: assigning a substitute who is busy elsewhere at that clock time is rejected even though the UI already filtered them out'
);

select public.upsert_timetable_slot(:'version_id'::uuid, :'section_b_id'::uuid, :'monday'::smallint, 2::smallint, :'physics_id'::uuid) as slot_no_teacher \gset
select throws_ok(
  format(
    $$ select public.create_substitution(%L, '2026-08-03'::date, %L, 'leave') $$,
    :'slot_no_teacher', :'teacher_c_user_id'
  ),
  'SLOT_HAS_NO_TEACHER',
  'a slot with no regular teacher has nobody absent to substitute for'
);

select throws_ok(
  format(
    $$ select public.create_substitution(%L, '2026-08-03'::date, %L, 'leave') $$,
    :'slot_a_p2', :'teacher_a_user_id'
  ),
  'SUBSTITUTE_IS_ABSENT_TEACHER',
  'the absent teacher cannot be assigned as their own substitute'
);

-- ── AC #4: a leave cancellation flags, never deletes, its substitutions ──

select public.apply_for_leave(:'teacher_a_staff_id'::uuid, :'casual_id'::uuid, '2026-08-03'::date, '2026-08-03'::date) as leave_app_id \gset
select public.fn_decide_leave_application(:'leave_app_id'::uuid, 'approved');
select is(
  (select status::text from public.leave_application where id = :'leave_app_id'),
  'approved',
  'the leave application is approved, covering the same date as the substitution'
);

select public.cancel_leave_application(:'leave_app_id'::uuid);
select is(
  (select status::text from public.leave_application where id = :'leave_app_id'),
  'cancelled',
  'AC #4: the leave application is now cancelled'
);
select is(
  (select count(*)::int from public.timetable_substitution where slot_id = :'slot_a_p1'),
  1,
  'AC #4: the substitution row still exists — never silently deleted'
);
select is(
  (select status::text from public.timetable_substitution where slot_id = :'slot_a_p1'),
  'review',
  'AC #4: the substitution built against the now-cancelled leave is flagged for review'
);
select is(
  public.fn_leave_balance(:'teacher_a_staff_id'::uuid, :'casual_id'::uuid),
  5.00,
  'cancelling the approved application reverses its ledger consumption, restoring the balance'
);

select throws_ok(
  format($$ select public.cancel_leave_application(%L) $$, :'leave_app_id'),
  'APPLICATION_NOT_APPROVED',
  'a leave application already cancelled cannot be cancelled again'
);

-- ── authorization ─────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_c_user_id')::text,
  true
);
select throws_ok(
  format($$ select public.suggest_substitutes(%L, '2026-08-03'::date) $$, :'slot_a_p2'),
  'FORBIDDEN',
  'a subject teacher cannot pull the ranked candidate list'
);
select throws_ok(
  format(
    $$ select public.create_substitution(%L, '2026-08-03'::date, %L, 'leave') $$,
    :'slot_a_p2', :'teacher_c_user_id'
  ),
  'FORBIDDEN',
  'a subject teacher cannot assign a substitution'
);

-- ── RLS: the absent teacher and the substitute can both read their own row, a stranger cannot ──

select is(
  (select count(*)::int from public.timetable_substitution where id = :'sub_id'),
  1,
  'the substitute (Teacher C, currently authenticated) can read their own substitution row'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_a_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.timetable_substitution where id = :'sub_id'),
  1,
  'the absent teacher can read the substitution row built for their own slot'
);

-- Teacher B has no stake in this row AND is scoped to a different campus
-- (campus_id_scope, per this policy, is what actually gates a bystander's
-- read — same-campus staff can already see each other's rows, matching
-- timetable_slot_campus_scope's own convention).
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(gen_random_uuid()), 'sub', :'teacher_b_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.timetable_substitution where id = :'sub_id'),
  0,
  'a teacher scoped to a different campus, with no stake in this substitution, cannot read it'
);

select * from finish();
rollback;
