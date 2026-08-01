-- pgTAP tests for FR-G02: daily section attendance register.
begin;
select plan(19);

select public.provision_tenant('test-att-register-co', 'Att Register Co', 'owner@attregisterco.test');
select id as tenant_id from public.tenant where slug = 'test-att-register-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@attregisterco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'class_teacher', 'Ms. Class Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.assign_class_teacher(:'section_id'::uuid, :'teacher_user_id'::uuid, current_date - 30);
select public.set_attendance_policy(p_campus_id => :'campus_id'::uuid, p_session_id => :'session_id'::uuid, p_lock_window_hours => 24);

select public.create_student(:'campus_id'::uuid, 'Active One', '2015-01-01'::date, 'male') as student1_id \gset
select public.enrol_student(:'section_id'::uuid, :'student1_id'::uuid) as enrol1_id \gset
select public.create_student(:'campus_id'::uuid, 'Active Two', '2015-01-01'::date, 'female') as student2_id \gset
select public.enrol_student(:'section_id'::uuid, :'student2_id'::uuid) as enrol2_id \gset
select public.create_student(:'campus_id'::uuid, 'Struck Off', '2015-01-01'::date, 'male') as student3_id \gset
select public.enrol_student(:'section_id'::uuid, :'student3_id'::uuid) as enrol3_id \gset
select public.fn_change_student_status(:'student3_id'::uuid, 'struck_off', 'other');

-- ── act as the assigned class teacher ──────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);

-- AC1/AC2: 2 active enrolments saved, the struck-off one silently
-- excluded even though a mark for it was submitted.
select public.save_attendance_register(
  :'section_id'::uuid, current_date,
  jsonb_build_array(
    jsonb_build_object('enrolment_id', :'enrol1_id', 'status', 'present'),
    jsonb_build_object('enrolment_id', :'enrol2_id', 'status', 'late'),
    jsonb_build_object('enrolment_id', :'enrol3_id', 'status', 'present')
  )
) as save_result \gset
select is((:'save_result'::jsonb ->> 'saved')::int, 2, 'AC1: exactly the 2 active enrolments are saved, not the struck-off one');
select is(
  (select count(*)::int from public.attendance_day where section_id = :'section_id'::uuid and attendance_date = current_date),
  2,
  'AC1: exactly 2 rows exist for the section/date'
);
select is(
  (select count(*)::int from public.attendance_day where enrolment_id = :'enrol3_id'::uuid),
  0,
  'AC2: the struck-off student has no attendance row at all'
);
select ok(
  (select tenant_id from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date) = :'tenant_id'::uuid,
  'the saved row carries tenant_id'
);
select ok(
  (select campus_id from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date) = :'campus_id'::uuid,
  'the saved row carries campus_id'
);
select ok(
  (select session_id from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date) = :'session_id'::uuid,
  'the saved row carries session_id'
);
select ok(
  (select section_id from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date) = :'section_id'::uuid,
  'the saved row carries section_id'
);
select ok(
  (select marked_by from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date) = :'teacher_user_id'::uuid,
  'the saved row carries marked_by'
);
select is(
  (select status from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date)::text,
  'present',
  'the first student''s status was recorded correctly'
);

-- ── AC3: a second submission for the same date upserts (still
--    unlocked, well within lock_window_hours) ─────────────────────────

select public.save_attendance_register(
  :'section_id'::uuid, current_date,
  jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol1_id', 'status', 'absent'))
) as resave_result \gset
select is((:'resave_result'::jsonb ->> 'saved')::int, 1, 'AC3: the re-submission is accepted (still unlocked)');
select is(
  (select status from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date)::text,
  'absent',
  'AC3: the re-submission overwrote the earlier status, not duplicated it'
);
select is(
  (select count(*)::int from public.attendance_day where enrolment_id = :'enrol1_id'::uuid),
  1,
  'AC3: still exactly one row for that (enrolment, date) — the unique constraint held'
);

-- A long-past date, still within a 24h lock window measured from THAT
-- date, is refused as locked.
select throws_ok(
  format(
    $$ select public.save_attendance_register(%L, %L, %L) $$,
    :'section_id', (current_date - 30)::date, jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol1_id', 'status', 'present'))
  ),
  'ATT_LOCKED',
  'AC3: a date whose lock window has long since elapsed is refused'
);
select is(
  (select count(*)::int from public.attendance_day where attendance_date = current_date - 30),
  0,
  'AC3: the locked attempt created no row'
);

-- ── AC4: a declared holiday makes the register read-only ────────────

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.add_holiday((current_date + 1)::date, 'Founders Day', :'campus_id'::uuid) as holiday_id \gset
select is(
  public.resolve_attendance_holiday(:'campus_id'::uuid, (current_date + 1)::date),
  'Founders Day',
  'AC4: the holiday resolves by name for that campus/date'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select throws_ok(
  format(
    $$ select public.save_attendance_register(%L, %L, %L) $$,
    :'section_id', (current_date + 1)::date, jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol1_id', 'status', 'present'))
  ),
  'HOLIDAY:Founders Day',
  'AC4: saving against a declared holiday is refused'
);

-- ── validation ──────────────────────────────────────────────────────

select gen_random_uuid() as other_teacher_id \gset
reset role;
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_teacher_id', 'unassigned@attregisterco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_teacher_id', :'tenant_id', 'class_teacher', 'Unassigned Teacher');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'other_teacher_id')::text,
  true
);
select throws_ok(
  format(
    $$ select public.save_attendance_register(%L, %L, %L) $$,
    :'section_id', current_date, jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol1_id', 'status', 'present'))
  ),
  'FORBIDDEN',
  'a class_teacher never assigned to this section cannot save its register'
);

-- ── tenant isolation ────────────────────────────────────────────────

reset role;
select public.provision_tenant('test-att-register-other-co', 'Att Register Other Co', 'owner@attregisterotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-att-register-other-co' \gset
select gen_random_uuid() as other_owner_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_owner_id', 'owner@attregisterotherco2.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_owner_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json, 'sub', :'other_owner_id')::text,
  true
);
select throws_ok(
  format(
    $$ select public.save_attendance_register(%L, %L, %L) $$,
    :'section_id', current_date, '[]'::jsonb
  ),
  'SECTION_NOT_FOUND',
  'AC/defense-in-depth: another tenant cannot save a register against this tenant''s section'
);
select is(
  (select count(*)::int from public.attendance_day),
  0,
  'AC/defense-in-depth: another tenant sees zero attendance_day rows via RLS'
);

select * from finish();
rollback;
