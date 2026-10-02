-- pgTAP tests for 20260801050000_cross_campus_attendance_register_save.sql.
--
-- The defect: save_attendance_register() (FR-G02) authorizes by
-- section_class_teacher and deliberately NOT by campus, but resolved the
-- section's holiday and policy through resolvers that
-- 20260731770000_security_definer_campus_scope_audit.sql taught to
-- return NULL for a campus outside the CALLER's campus_ids claim. So for
-- a class teacher the function had just authorized:
--
--   * resolve_attendance_holiday() → NULL → the holiday branch never
--     fired and a full register was WRITTEN on a declared holiday, with
--     no error and nothing to show it should not exist;
--   * resolve_attendance_policy() → NULL → POLICY_NOT_CONFIGURED on a
--     campus whose policy is configured perfectly well.
--
-- Both symptoms are asserted for both populations that hit them: a
-- teacher scoped to another campus, and a teacher with no user_campus
-- row at all, whose claim is '{}' — `not (campus = any('{}'))` is true
-- for EVERY campus, so she hit this on her own campus, every day.
--
-- Every assertion below FAILS against the pre-fix function: the holiday
-- saves succeeded, and the ordinary saves threw POLICY_NOT_CONFIGURED.
begin;
select plan(14);

select public.provision_tenant('test-xcampus-register-co', 'Cross Campus Register Co', 'owner@xcampusregister.test');
select id as tenant_id from public.tenant where slug = 'test-xcampus-register-co' \gset
select id as campus_a_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@xcampusregister.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Register Owner');

-- Ms Sana is class teacher of a section at campus South; her claim
-- covers campus North only, or nothing at all.
select gen_random_uuid() as sana_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'sana_uid', 'sana@xcampusregister.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'sana_uid', :'tenant_id', 'class_teacher', 'Ms Sana');

select gen_random_uuid() as other_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_uid', 'unassigned@xcampusregister.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_uid', :'tenant_id', 'class_teacher', 'Unassigned Teacher');

insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus South', 'SOUTH') returning id as campus_b_id \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id', :'campus_b_id'), 'sub', :'owner_uid')::text,
  true
);

select public.create_section(:'campus_b_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'Zulu', 40) as section_zulu \gset
select public.assign_class_teacher(:'section_zulu'::uuid, :'sana_uid'::uuid, current_date - 90);
select public.set_attendance_policy(p_campus_id => :'campus_b_id'::uuid, p_session_id => :'session_id'::uuid, p_lock_window_hours => 24);

select public.create_student(:'campus_b_id'::uuid, 'South Kid One', '2015-01-01'::date, 'male') as student1_id \gset
select public.enrol_student(:'section_zulu'::uuid, :'student1_id'::uuid) as enrol1_id \gset
select public.create_student(:'campus_b_id'::uuid, 'South Kid Two', '2015-01-01'::date, 'female') as student2_id \gset
select public.enrol_student(:'section_zulu'::uuid, :'student2_id'::uuid) as enrol2_id \gset

select public.add_holiday((current_date + 1)::date, 'Founders Day', :'campus_b_id'::uuid);

-- ── Ms Sana, claim = campus North only, marking her campus South section ──

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'sana_uid')::text,
  true
);

select throws_ok(
  format(
    $$ select public.save_attendance_register(%L, %L, %L) $$,
    :'section_zulu', (current_date + 1)::date, jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol1_id', 'status', 'present'))
  ),
  'HOLIDAY:Founders Day',
  'AC4: a declared holiday is refused by name for a teacher scoped to another campus — attendance is no longer silently accepted on a holiday'
);
select public.save_attendance_register(
  :'section_zulu'::uuid, current_date,
  jsonb_build_array(
    jsonb_build_object('enrolment_id', :'enrol1_id', 'status', 'present'),
    jsonb_build_object('enrolment_id', :'enrol2_id', 'status', 'absent')
  )
) as sana_save \gset
select is(
  (:'sana_save'::jsonb ->> 'saved')::int,
  2,
  'AC1: her ordinary register saves — no more POLICY_NOT_CONFIGURED for a campus whose policy is configured'
);

select throws_ok(
  format(
    $$ select public.save_attendance_register(%L, %L, %L) $$,
    :'section_zulu', (current_date - 30)::date, jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol1_id', 'status', 'present'))
  ),
  'ATT_LOCKED',
  'AC3: and a date whose lock window elapsed 30 days ago is refused as LOCKED, with the lock''s own error rather than a misleading policy one'
);

-- FR-G05: the offline queue path reaches both facts through the same
-- function, so it inherits the fix rather than needing its own.
select throws_ok(
  format(
    $$ select public.rpc_bulk_mark_attendance(%L, %L, '[]'::jsonb, %L, clock_timestamp()) $$,
    :'section_zulu', (current_date + 1)::date, gen_random_uuid()
  ),
  'HOLIDAY:Founders Day',
  'FR-G05: a queued offline submission for that holiday is refused too — the sync path is not a way around it'
);

-- ── The same defect with no second campus in sight ─────────────────────
-- A teacher with no user_campus row claims '{}', which contains no
-- campus, so she hit both symptoms on her own campus.

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(), 'sub', :'sana_uid')::text,
  true
);
select throws_ok(
  format(
    $$ select public.save_attendance_register(%L, %L, %L) $$,
    :'section_zulu', (current_date + 1)::date, jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol1_id', 'status', 'present'))
  ),
  'HOLIDAY:Founders Day',
  'a teacher whose campus_ids claim is empty is refused on the holiday too'
);
select is(
  (select (public.save_attendance_register(
     :'section_zulu'::uuid, current_date,
     jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol1_id', 'status', 'late'))
   ) ->> 'saved')::int),
  1,
  'and her ordinary register saves rather than reporting a policy that is not missing'
);
-- ── What actually landed, read by someone who can see campus South ─────
-- Ms Sana's own claim cannot read attendance_day for campus South (RLS
-- is campus-scoped), which is itself the point: the rows are only
-- inspectable from a scope that covers them.

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id', :'campus_b_id'), 'sub', :'owner_uid')::text,
  true
);
select is(
  (select count(*)::int from public.attendance_day where attendance_date = current_date + 1),
  0,
  'the refused holiday submissions wrote no attendance row at all'
);
select is(
  (select count(*)::int from public.attendance_day where section_id = :'section_zulu'::uuid and attendance_date = current_date),
  2,
  'while the ordinary register wrote exactly one row per active enrolment'
);
select is(
  (select status from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date)::text,
  'late',
  'AC3: the empty-claim re-submission upserted the existing mark rather than duplicating it'
);

-- ── The function's own access rule did not widen ───────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_a_id', :'campus_b_id'), 'sub', :'other_uid')::text,
  true
);
select throws_ok(
  format(
    $$ select public.save_attendance_register(%L, %L, %L) $$,
    :'section_zulu', current_date, jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol1_id', 'status', 'present'))
  ),
  'FORBIDDEN',
  'a class_teacher never assigned to this section still cannot save its register — even one whose claim DOES cover its campus'
);

-- ── The audit''s guard still holds for ordinary, direct callers ────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'sana_uid')::text,
  true
);
select is(
  (select public.resolve_attendance_holiday(:'campus_b_id'::uuid, (current_date + 1)::date)),
  null,
  'the campus guard is untouched: the SAME teacher calling resolve_attendance_holiday() directly for campus South still gets NULL'
);
select is(
  (select public.resolve_attendance_policy(:'campus_b_id'::uuid, :'session_id'::uuid)),
  null,
  'and resolve_attendance_policy() for campus South still gets NULL'
);
select is(
  (select count(*)::int from public.holiday_calendar where campus_id = :'campus_b_id'::uuid),
  0,
  'and campus South''s holiday rows are still unreadable to her directly — the refusal discloses nothing she could fetch herself'
);
select throws_ok(
  format($$ select app.resolve_attendance_holiday_unscoped(%L::uuid, %L::uuid, %L::date) $$, :'tenant_id', :'campus_b_id', (current_date + 1)::date),
  '42501',
  null,
  'authenticated cannot call the unscoped holiday resolver directly — the guard cannot be routed around'
);

select * from finish();
rollback;
