-- pgTAP tests for the FR-G11 fix: approving a correction for a date that
-- was NEVER marked creates the attendance_day row instead of raising
-- ATTENDANCE_DAY_NOT_FOUND, with an audit trail that records the absent
-- prior state honestly (NULL old_status) rather than inventing one.
--
-- Three blocks: the never-marked path (the fix), the already-marked path
-- (FR-G11's original behaviour, which must be untouched), and the FR-G05
-- end-to-end that produced the bug in the first place — an offline
-- register replayed onto a locked date nobody had ever marked.
begin;
select plan(33);

select public.provision_tenant('test-att-nevermarked-co', 'Att Never Marked Co', 'owner@attnevermarkedco.test');
select id as tenant_id from public.tenant where slug = 'test-att-nevermarked-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@attnevermarkedco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'class_teacher', 'Ms. Class Teacher');

select gen_random_uuid() as principal_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_user_id', 'principal@attnevermarkedco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_user_id', :'tenant_id', 'principal', 'Mr. Principal');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.assign_class_teacher(:'section_id'::uuid, :'teacher_user_id'::uuid, current_date - 100);
select public.set_attendance_policy(p_campus_id => :'campus_id'::uuid, p_session_id => :'session_id'::uuid, p_lock_window_hours => 24);

select public.create_student(:'campus_id'::uuid, 'Never Marked Kid', '2015-01-01'::date, 'male') as student1_id \gset
select public.enrol_student(:'section_id'::uuid, :'student1_id'::uuid) as enrol1_id \gset
select public.create_student(:'campus_id'::uuid, 'Already Marked Kid', '2015-01-01'::date, 'female') as student2_id \gset
select public.enrol_student(:'section_id'::uuid, :'student2_id'::uuid) as enrol2_id \gset
select public.create_student(:'campus_id'::uuid, 'Offline Queue Kid', '2015-01-01'::date, 'male') as student3_id \gset
select public.enrol_student(:'section_id'::uuid, :'student3_id'::uuid) as enrol3_id \gset

-- ── block A: a correction for a date that was never marked at all ────
--
-- current_date - 40 is past any lock window by construction, which is
-- exactly the "old, already-locked day" FR-G11 exists to let a Principal
-- correct — except this student has no attendance_day row on it at all.

select is(
  (select count(*)::int from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date - 40),
  0,
  'sanity: the date being corrected has no attendance_day row at all'
);

-- Seeded before the approval so the stale hook has a row to flip (FR-G14).
reset role;
insert into public.attendance_month_summary (tenant_id, campus_id, session_id, enrolment_id, year, month, working_days, present_days, absent_days, computed_at, stale)
values (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'enrol1_id'::uuid, extract(year from current_date - 40)::smallint, extract(month from current_date - 40)::smallint, 20, 18, 2, clock_timestamp(), false);
set local role authenticated;

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select public.request_attendance_correction(:'enrol1_id'::uuid, (current_date - 40)::date, 'present'::public.student_attendance_status, 'Register was never submitted for this day, the class was present') as correction1_id \gset

select ok(
  (select old_status is null from public.attendance_correction_request where id = :'correction1_id'::uuid),
  'the request itself records a NULL old_status — there was nothing to amend'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'principal_user_id')::text,
  true
);
select lives_ok(
  format('select public.approve_attendance_correction(%L, %L)', :'correction1_id', 'Confirmed with the teacher, the register was simply never submitted'),
  'FIX: approving a correction for a never-marked date no longer raises ATTENDANCE_DAY_NOT_FOUND'
);

select is(
  (select count(*)::int from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date - 40),
  1,
  'the approval created exactly one attendance_day row'
);
select is(
  (select status from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date - 40)::text,
  'present',
  'the created row carries the approved status'
);
select ok(
  (select corrected from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date - 40),
  'the created row is flagged corrected, same as the amend path'
);
select is(
  (select source from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date - 40)::text,
  'correction',
  'source is "correction" — no register, no device queue and no scanner produced this row'
);
select ok(
  (select synced_at is null from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date - 40),
  'synced_at is NULL — nothing about this row arrived from a device sync'
);
select is(
  (select marked_by from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date - 40),
  :'teacher_user_id'::uuid,
  'marked_by is the requester who asserted the status, not the approver'
);
select is(
  (select section_id from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date - 40),
  :'section_id'::uuid,
  'the created row is attributed to the enrolment''s section'
);

select is(
  (select count(*)::int from public.attendance_audit where source_correction_id = :'correction1_id'::uuid),
  1,
  'AC1 still holds: exactly one attendance_audit row per approval'
);
select ok(
  (select old_status is null from public.attendance_audit where source_correction_id = :'correction1_id'::uuid),
  'AUDIT: the absent prior state is recorded as NULL, not as a fabricated status'
);
select is(
  (select new_status from public.attendance_audit where source_correction_id = :'correction1_id'::uuid)::text,
  'present',
  'the audit row records the new status'
);
select is(
  (select approved_by from public.attendance_audit where source_correction_id = :'correction1_id'::uuid),
  :'principal_user_id'::uuid,
  'the audit row records the Principal who authorised it'
);
select is(
  (select requested_by from public.attendance_audit where source_correction_id = :'correction1_id'::uuid),
  :'teacher_user_id'::uuid,
  'the audit row records the teacher who requested it'
);
select is(
  (select status from public.attendance_correction_request where id = :'correction1_id'::uuid)::text,
  'approved',
  'the request itself is marked approved'
);
select ok(
  (select stale from public.attendance_month_summary where enrolment_id = :'enrol1_id'::uuid and year = extract(year from current_date - 40)::smallint and month = extract(month from current_date - 40)::smallint),
  'AC4 still holds: the enclosing month summary is flagged stale'
);
select throws_ok(
  format('select public.approve_attendance_correction(%L)', :'correction1_id'),
  'CORRECTION_NOT_PENDING',
  'approving the same request twice is still refused'
);

-- attendance_audit stays append-only for a row born of an insert too.
reset role;
select throws_ok(
  format('update public.attendance_audit set old_status = %L where source_correction_id = %L', 'absent', :'correction1_id'),
  'ATTENDANCE_AUDIT_IMMUTABLE',
  'AC2 still holds: the NULL prior state cannot be back-filled after the fact'
);

-- ── block B: the already-marked path, unchanged from FR-G11 ──────────

insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, marked_by, marked_at, source)
values (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_id'::uuid, :'enrol2_id'::uuid, current_date - 40, 'absent', :'teacher_user_id'::uuid, ((current_date - 40) + time '09:00')::timestamptz, 'web');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select public.request_attendance_correction(:'enrol2_id'::uuid, (current_date - 40)::date, 'present'::public.student_attendance_status, 'Was marked absent by mistake, parent brought a note') as correction2_id \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'principal_user_id')::text,
  true
);
select public.approve_attendance_correction(:'correction2_id'::uuid, 'Parent note verified and filed');

select is(
  (select status from public.attendance_day where enrolment_id = :'enrol2_id'::uuid and attendance_date = current_date - 40)::text,
  'present',
  'FR-G11 unchanged: an existing mark is still amended in place'
);
select ok(
  (select corrected from public.attendance_day where enrolment_id = :'enrol2_id'::uuid and attendance_date = current_date - 40),
  'FR-G11 unchanged: the amended day is flagged corrected'
);
select is(
  (select source from public.attendance_day where enrolment_id = :'enrol2_id'::uuid and attendance_date = current_date - 40)::text,
  'web',
  'FR-G11 unchanged: amending never rewrites the original row''s provenance'
);
select is(
  (select marked_at from public.attendance_day where enrolment_id = :'enrol2_id'::uuid and attendance_date = current_date - 40),
  ((current_date - 40) + time '09:00')::timestamptz,
  'FR-G11 unchanged: amending never rewrites the original marked_at'
);
select is(
  (select old_status from public.attendance_audit where source_correction_id = :'correction2_id'::uuid)::text,
  'absent',
  'FR-G11 unchanged: the audit row records the TRUE prior status when there was one'
);
select is(
  (select count(*)::int from public.attendance_audit where source_correction_id = :'correction2_id'::uuid),
  1,
  'FR-G11 unchanged: exactly one audit row for the amend path'
);
select is(
  (select count(*)::int from public.attendance_day where enrolment_id = :'enrol2_id'::uuid and attendance_date = current_date - 40),
  1,
  'FR-G11 unchanged: amending does not insert a second row'
);

-- ── block C: the FR-G05 scenario end to end ──────────────────────────
--
-- A queued offline register replayed onto a locked date nobody had ever
-- marked. rpc_bulk_mark_attendance() files correction requests instead of
-- dropping the submission; before this fix every one of them was
-- unapprovable.

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select gen_random_uuid() as key1 \gset
select public.rpc_bulk_mark_attendance(
  :'section_id'::uuid, (current_date - 39)::date,
  jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol3_id', 'status', 'absent')),
  :'key1'::uuid, ((current_date - 39) + time '08:20') at time zone 'Asia/Karachi'
) as sync1 \gset

select is(:'sync1'::jsonb ->> 'result', 'rejected_locked', 'FR-G05: the queued register lands on a locked date and is not applied');
select is(
  (:'sync1'::jsonb ->> 'corrections_requested')::int, 3,
  'FR-G05: one correction request per captured mark, none of them ever marked'
);
select is(
  (select count(*)::int from public.attendance_day where section_id = :'section_id'::uuid and attendance_date = current_date - 39),
  0,
  'FR-G05: the locked date still has no attendance_day rows at this point'
);

select id as correction4_id from public.attendance_correction_request
 where enrolment_id = :'enrol3_id'::uuid and attendance_date = current_date - 39 and status = 'pending' \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'principal_user_id')::text,
  true
);
select lives_ok(
  format('select public.approve_attendance_correction(%L, %L)', :'correction4_id', 'Device was offline all morning, approving the queued mark'),
  'THE BUG: a Principal can now approve an offline submission for a locked, never-marked date'
);
select is(
  (select status from public.attendance_day where enrolment_id = :'enrol3_id'::uuid and attendance_date = current_date - 39)::text,
  'absent',
  'the offline-captured mark finally reaches attendance_day via the approval'
);
select is(
  (select source from public.attendance_day where enrolment_id = :'enrol3_id'::uuid and attendance_date = current_date - 39)::text,
  'correction',
  'the row is sourced to the correction, not to the offline sync that was rejected'
);
select ok(
  (select old_status is null from public.attendance_audit where source_correction_id = :'correction4_id'::uuid),
  'and its audit row still tells the truth: there was no prior state'
);

select * from finish();
rollback;
