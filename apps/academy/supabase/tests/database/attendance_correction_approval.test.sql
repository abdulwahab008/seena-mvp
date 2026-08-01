-- pgTAP tests for FR-G11: attendance correction approval with immutable audit.
begin;
select plan(21);

select public.provision_tenant('test-att-correction-co', 'Att Correction Co', 'owner@attcorrectionco.test');
select id as tenant_id from public.tenant where slug = 'test-att-correction-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@attcorrectionco.test', 'x', now(), 'authenticated', 'authenticated');
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
select public.set_attendance_policy(p_campus_id => :'campus_id'::uuid, p_session_id => :'session_id'::uuid, p_lock_window_hours => 24);

select public.create_student(:'campus_id'::uuid, 'Correction Kid', '2015-01-01'::date, 'male') as student1_id \gset
select public.enrol_student(:'section_id'::uuid, :'student1_id'::uuid) as enrol1_id \gset

-- Seeded directly, not via save_attendance_register() — a date 40 days
-- back is already past any lock window by construction, exactly the
-- "old, already-locked day" scenario this FR exists to let a Principal
-- correct.
reset role;
insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, source)
values (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_id'::uuid, :'enrol1_id'::uuid, current_date - 40, 'absent', 'web');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select status from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date - 40)::text,
  'absent',
  'sanity: the day was marked absent before any correction'
);

-- ── act as the assigned class teacher: request a correction ─────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);

select public.request_attendance_correction(:'enrol1_id'::uuid, (current_date - 40)::date, 'present'::public.student_attendance_status, 'Was marked absent by mistake, parent brought a note') as correction1_id \gset
select is(
  (select status from public.attendance_correction_request where id = :'correction1_id'::uuid)::text,
  'pending',
  'a fresh correction request is pending'
);
select throws_ok(
  format('select public.approve_attendance_correction(%L)', :'correction1_id'),
  'FORBIDDEN',
  'AC: a class teacher cannot approve their own correction request'
);

-- ── act as the owner (Principal-equivalent): approve it ─────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.approve_attendance_correction(:'correction1_id'::uuid, 'Confirmed with the parent note on file');

-- AC1: attendance_day updated, corrected=true, exactly one audit row.
select is(
  (select status from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date - 40)::text,
  'present',
  'AC1: the approved correction changed the recorded status'
);
select ok(
  (select corrected from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date - 40),
  'AC1: the day is flagged as corrected'
);
select is(
  (select count(*)::int from public.attendance_audit where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date - 40),
  1,
  'AC1: exactly one attendance_audit row exists for this correction'
);
select is(
  (select old_status from public.attendance_audit where source_correction_id = :'correction1_id'::uuid)::text,
  'absent',
  'the audit row records the true prior status'
);
select is(
  (select new_status from public.attendance_audit where source_correction_id = :'correction1_id'::uuid)::text,
  'present',
  'the audit row records the new status'
);
select is(
  (select status from public.attendance_correction_request where id = :'correction1_id'::uuid)::text,
  'approved',
  'the request itself is marked approved'
);
select throws_ok(
  format('select public.approve_attendance_correction(%L)', :'correction1_id'),
  'CORRECTION_NOT_PENDING',
  'approving the same request twice is refused'
);

-- ── AC2: attendance_audit is genuinely append-only — even a table-owner
--    context UPDATE/DELETE is blocked by the trigger, not just RLS ─────

reset role;
select throws_ok(
  format('update public.attendance_audit set reason = %L where source_correction_id = %L', 'tampered', :'correction1_id'),
  'ATTENDANCE_AUDIT_IMMUTABLE',
  'AC2: an UPDATE against attendance_audit is rejected even as the table owner'
);
select throws_ok(
  format('delete from public.attendance_audit where source_correction_id = %L', :'correction1_id'),
  'ATTENDANCE_AUDIT_IMMUTABLE',
  'AC2: a DELETE against attendance_audit is rejected even as the table owner'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── AC3: an approved correction flags an already-finalized monthly
--    summary stale (the hook FR-G14 will consume; a no-op until then
--    for a month with no finalized row) ──────────────────────────────

reset role;
insert into public.attendance_monthly_summary (tenant_id, campus_id, session_id, enrolment_id, year, month, present_days, absent_days, finalized_at, stale)
values (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'enrol1_id'::uuid, extract(year from current_date - 40)::smallint, extract(month from current_date - 40)::smallint, 18, 2, clock_timestamp(), false);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select public.request_attendance_correction(:'enrol1_id'::uuid, (current_date - 40)::date, 'late'::public.student_attendance_status, 'Actually arrived late, not fully present') as correction2_id \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.approve_attendance_correction(:'correction2_id'::uuid);
select ok(
  (select stale from public.attendance_monthly_summary where enrolment_id = :'enrol1_id'::uuid and year = extract(year from current_date - 40)::smallint and month = extract(month from current_date - 40)::smallint),
  'AC3: a finalized monthly summary is flagged stale once a correction lands in its month'
);

-- ── reject path: no attendance_day change, no audit row ──────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select public.request_attendance_correction(:'enrol1_id'::uuid, (current_date - 41)::date, 'excused'::public.student_attendance_status, 'Sick leave, doctor slip provided') as correction3_id \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.reject_attendance_correction(%L, %L)', :'correction3_id', 'no'),
  'NOTE_TOO_SHORT',
  'rejecting requires a real note, not a token one'
);
select public.reject_attendance_correction(:'correction3_id'::uuid, 'No supporting document was ever provided');
select is(
  (select status from public.attendance_correction_request where id = :'correction3_id'::uuid)::text,
  'rejected',
  'the request is marked rejected'
);
select is(
  (select count(*)::int from public.attendance_audit where source_correction_id = :'correction3_id'::uuid),
  0,
  'a rejected request never produces an audit row'
);
select is(
  (select count(*)::int from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date - 41),
  0,
  'a rejected request never creates or changes an attendance_day row'
);

-- ── validation ──────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.request_attendance_correction(%L, %L, %L::public.student_attendance_status, %L)', :'enrol1_id', (current_date - 40)::text, 'present', 'Some reason text here'),
  'FORBIDDEN',
  'a role with no attendance access cannot request a correction'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── tenant isolation ────────────────────────────────────────────────

reset role;
select public.provision_tenant('test-att-correction-other-co', 'Att Correction Other Co', 'owner@attcorrectionotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-att-correction-other-co' \gset
select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'owner@attcorrectionotherco2.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json, 'sub', :'other_user_id')::text,
  true
);
select throws_ok(
  format('select public.approve_attendance_correction(%L)', :'correction2_id'),
  'CORRECTION_NOT_FOUND',
  'AC/defense-in-depth: another tenant cannot approve this tenant''s correction request'
);
select is(
  (select count(*)::int from public.attendance_audit),
  0,
  'AC/defense-in-depth: another tenant''s owner sees zero attendance_audit rows via RLS'
);
select is(
  (select count(*)::int from public.attendance_correction_request),
  0,
  'AC/defense-in-depth: another tenant''s owner sees zero correction requests via RLS'
);

select * from finish();
rollback;
