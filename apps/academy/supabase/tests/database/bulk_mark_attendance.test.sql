-- pgTAP tests for FR-G04: mark-all-present then exceptions flow.
begin;
select plan(11);

select public.provision_tenant('test-bulk-mark-co', 'Bulk Mark Co', 'owner@bulkmarkco.test');
select id as tenant_id from public.tenant where slug = 'test-bulk-mark-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@bulkmarkco.test', 'x', now(), 'authenticated', 'authenticated');
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

select public.create_student(:'campus_id'::uuid, 'Kid One', '2015-01-01'::date, 'male') as student1_id \gset
select public.enrol_student(:'section_id'::uuid, :'student1_id'::uuid) as enrol1_id \gset
select public.create_student(:'campus_id'::uuid, 'Kid Two', '2015-01-01'::date, 'female') as student2_id \gset
select public.enrol_student(:'section_id'::uuid, :'student2_id'::uuid) as enrol2_id \gset
select public.create_student(:'campus_id'::uuid, 'Kid Three', '2015-01-01'::date, 'male') as student3_id \gset
select public.enrol_student(:'section_id'::uuid, :'student3_id'::uuid) as enrol3_id \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);

-- ── AC1: zero exceptions still writes every active student present ──

select public.rpc_bulk_mark_attendance(:'section_id'::uuid, current_date, '[]'::jsonb) as bulk_result \gset
select is((:'bulk_result'::jsonb ->> 'saved')::int, 3, 'AC1: all 3 active students are written from zero exceptions');
select is(
  (select count(*)::int from public.attendance_day where section_id = :'section_id'::uuid and attendance_date = current_date and status = 'present'),
  3,
  'AC1: every one of them defaulted to present'
);

-- ── one exception overrides just that student, the rest stay present ──

select public.rpc_bulk_mark_attendance(
  :'section_id'::uuid, current_date + 1,
  jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol2_id', 'status', 'absent'))
) as bulk_result2 \gset
select is((:'bulk_result2'::jsonb ->> 'saved')::int, 3, 'all 3 rows are still written when there is exactly one exception');
select is(
  (select status from public.attendance_day where enrolment_id = :'enrol2_id'::uuid and attendance_date = current_date + 1)::text,
  'absent',
  'the excepted student carries the overridden status'
);
select is(
  (select status from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date + 1)::text,
  'present',
  'an un-excepted student still defaults to present'
);
select is(
  (select count(*)::int from public.attendance_day where section_id = :'section_id'::uuid and attendance_date = current_date + 1 and status = 'present'),
  2,
  'exactly the 2 non-excepted students are present'
);

-- AC4: reopening (re-running with the same exception) loads/keeps the
-- saved statuses rather than reverting to present — the underlying
-- upsert is idempotent.
select public.rpc_bulk_mark_attendance(
  :'section_id'::uuid, current_date + 1,
  jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol2_id', 'status', 'absent'))
) as bulk_result3 \gset
select is(
  (select status from public.attendance_day where enrolment_id = :'enrol2_id'::uuid and attendance_date = current_date + 1)::text,
  'absent',
  'AC4: re-submitting the same exception keeps the saved status, not reset to present'
);
select is(
  (select count(*)::int from public.attendance_day where section_id = :'section_id'::uuid and attendance_date = current_date + 1),
  3,
  'AC4: re-submission does not create duplicate rows'
);

-- ── delegated checks: role/holiday/lock all still apply, because this
--    function is a thin wrapper around save_attendance_register() ────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.rpc_bulk_mark_attendance(%L, %L, %L)', :'section_id', current_date, '[]'::jsonb),
  'FORBIDDEN',
  'a role with no attendance-marking authority is refused, same as save_attendance_register() itself'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.add_holiday((current_date + 2)::date, 'Bulk Mark Holiday', :'campus_id'::uuid);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select throws_ok(
  format('select public.rpc_bulk_mark_attendance(%L, %L, %L)', :'section_id', (current_date + 2)::date, '[]'::jsonb),
  'HOLIDAY:Bulk Mark Holiday',
  'a declared holiday blocks the bulk mark too'
);
select is(
  (select count(*)::int from public.attendance_day where attendance_date = current_date + 2),
  0,
  'the holiday-blocked attempt wrote nothing'
);

select * from finish();
rollback;
