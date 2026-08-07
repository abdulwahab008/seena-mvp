-- pgTAP tests for FR-G10 (attendance correction request hardening: a
-- 15-character reason minimum, and one pending request per date).
begin;
select plan(9);

select public.provision_tenant('test-att-correction-req', 'Att Correction Req Co', 'owner@attcorrectionreq.test');
select id as tenant_id from public.tenant where slug = 'test-att-correction-req' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@attcorrectionreq.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'class_teacher', 'Ms. Class Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.assign_class_teacher(:'section_id'::uuid, :'teacher_user_id'::uuid, current_date - 100);

select public.create_student(:'campus_id'::uuid, 'Correction Req Kid', '2015-01-01'::date, 'male') as student1_id \gset
select public.enrol_student(:'section_id'::uuid, :'student1_id'::uuid) as enrol1_id \gset

reset role;
insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, source)
values (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_id'::uuid, :'enrol1_id'::uuid, current_date - 5, 'absent', 'web');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);

-- ── AC: a reason under 15 characters is rejected ────────────────────

select throws_ok(
  format(
    $$ select public.request_attendance_correction(%L, %L::date, 'present'::public.student_attendance_status, %L) $$,
    :'enrol1_id', (current_date - 5)::text, 'too short here'
  ),
  'new row for relation "attendance_correction_request" violates check constraint "chk_correction_reason_len"',
  'AC: a reason under 15 characters is rejected'
);
select is(
  (select count(*)::int from public.attendance_correction_request where enrolment_id = :'enrol1_id'::uuid),
  0,
  'the rejected request never actually saved a row'
);

-- ── exactly 15 characters is accepted (boundary) ────────────────────

select public.request_attendance_correction(:'enrol1_id'::uuid, (current_date - 5)::date, 'present'::public.student_attendance_status, '123456789012345') as correction1_id \gset
select ok(:'correction1_id' is not null, 'a reason of exactly 15 characters is accepted');
select is(
  (select status from public.attendance_correction_request where id = :'correction1_id'::uuid)::text,
  'pending',
  'the accepted request is pending'
);

-- ── AC: a second request for the SAME (enrolment, date) while the first
--    is still pending is rejected ───────────────────────────────────

select throws_ok(
  format(
    $$ select public.request_attendance_correction(%L, %L::date, 'late'::public.student_attendance_status, %L) $$,
    :'enrol1_id', (current_date - 5)::text, 'A second, independent correction reason'
  ),
  'CORRECTION_ALREADY_PENDING',
  'AC: a second request for a date that already has a pending request is rejected'
);
select is(
  (select count(*)::int from public.attendance_correction_request where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date - 5),
  1,
  'the rejected duplicate never actually saved a second row'
);

-- ── once the first request is decided, a new one for the same date is
--    allowed again ──────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.reject_attendance_correction(:'correction1_id'::uuid, 'Not enough evidence provided for this one');
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select public.request_attendance_correction(:'enrol1_id'::uuid, (current_date - 5)::date, 'late'::public.student_attendance_status, 'A fresh correction now the first was decided') as correction2_id \gset
select ok(:'correction2_id' is not null, 'a new request for the same date is allowed once the earlier one is no longer pending');
select isnt(:'correction2_id'::uuid, :'correction1_id'::uuid, 'the new request is genuinely a new row, not the old one reused');

-- ── a pending request on one date never blocks a request for a
--    different date on the same student ─────────────────────────────

reset role;
insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, source)
values (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_id'::uuid, :'enrol1_id'::uuid, current_date - 6, 'absent', 'web');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select public.request_attendance_correction(:'enrol1_id'::uuid, (current_date - 6)::date, 'present'::public.student_attendance_status, 'A wholly different date, should not be blocked') as correction3_id \gset
select ok(:'correction3_id' is not null, 'a pending request on one date never blocks a request for a different date');

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select * from finish();
rollback;
