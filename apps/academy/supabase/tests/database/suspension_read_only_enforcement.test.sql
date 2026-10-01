-- pgTAP tests for the FR-D15 read-only enforcement: a suspended staff member's
-- writes are blocked by ONE shared guard, reads are not, and ending the
-- suspension restores access.
begin;
select plan(21);

select public.provision_tenant('test-susp-enf-co', 'Susp Enf Co', 'owner@suspenf.test');
select id as tenant_id from public.tenant where slug = 'test-susp-enf-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as hr_uid \gset
select gen_random_uuid() as t1_uid \gset
select gen_random_uuid() as t2_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@suspenf.test', 'authenticated', 'authenticated', 'x'), (:'hr_uid', 'h@suspenf.test', 'authenticated', 'authenticated', 'x'),
  (:'t1_uid', 't1@suspenf.test', 'authenticated', 'authenticated', 'x'), (:'t2_uid', 't2@suspenf.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'hr_uid', :'tenant_id', 'hr_manager', 'HR'),
  (:'t1_uid', :'tenant_id', 'class_teacher', 'Teacher One'), (:'t2_uid', :'tenant_id', 'class_teacher', 'Teacher Two');
insert into public.staff (tenant_id, campus_id, user_id, employee_code, cnic, gender, full_name) values
  (:'tenant_id', :'campus_id', :'t1_uid', 'SE-1', '42101-2222222-1', 'male', 'Teacher One'),
  (:'tenant_id', :'campus_id', :'t2_uid', 'SE-2', '42101-2222222-2', 'female', 'Teacher Two');
select id as s1 from public.staff where employee_code = 'SE-1' and tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as sec \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 40) as sec2 \gset
select public.assign_class_teacher(:'sec'::uuid, :'t1_uid'::uuid, current_date - 30);
select public.assign_class_teacher(:'sec2'::uuid, :'t2_uid'::uuid, current_date - 30);
select public.set_attendance_policy(p_campus_id => :'campus_id'::uuid, p_session_id => :'session_id'::uuid, p_lock_window_hours => 24);
select public.create_subject('CHM', 'Chemistry', 'کیمسٹری') as chm \gset
select public.assign_subject_teacher(:'sec'::uuid, :'chm'::uuid, :'t1_uid'::uuid, current_date - 30);
select public.assign_subject_teacher(:'sec2'::uuid, :'chm'::uuid, :'t2_uid'::uuid, current_date - 30);
select public.create_student(:'campus_id'::uuid, 'Pupil A', '2015-01-01'::date, 'male') as st1 \gset
select public.enrol_student(:'sec'::uuid, :'st1'::uuid) as enr1 \gset
select public.create_student(:'campus_id'::uuid, 'Pupil B', '2015-01-01'::date, 'female') as st2 \gset
select public.enrol_student(:'sec2'::uuid, :'st2'::uuid) as enr2 \gset

-- ── before any suspension everything works ───────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'t1_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select lives_ok(format($$ select public.save_attendance_register(%L::uuid, current_date, jsonb_build_array(jsonb_build_object('enrolment_id', %L, 'status', 'present'))) $$, :'sec', :'enr1'),
  'an unsuspended teacher can mark attendance');
select lives_ok(format($$ select public.create_homework(%L::uuid, %L::uuid, 'Before suspension', current_date + 5, current_date) $$, :'sec', :'chm'),
  'an unsuspended teacher can post homework');

-- ── HR suspends teacher one (today inside the window) ────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.issue_disciplinary_action(:'s1'::uuid, 'suspension', 'Pending inquiry', null, current_date - 1, current_date + 5) as susp \gset
reset role;
select ok(app.is_caller_suspended() is false, 'no end-user uid (system work) is never treated as suspended');
set local role authenticated;

-- ── the suspended teacher is blocked on representative writes ────────────
select set_config('request.jwt.claims', json_build_object('sub', :'t1_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok(app.is_caller_suspended(), 'the guard recognises the suspended caller');
select throws_ok(format($$ select public.save_attendance_register(%L::uuid, current_date, jsonb_build_array(jsonb_build_object('enrolment_id', %L, 'status', 'absent'))) $$, :'sec', :'enr1'),
  'STAFF_SUSPENDED', 'suspended: cannot mark the attendance register');
select throws_ok(format($$ select public.create_homework(%L::uuid, %L::uuid, 'During suspension', current_date + 5, current_date) $$, :'sec', :'chm'),
  'STAFF_SUSPENDED', 'suspended: cannot post homework');
select throws_ok($$ select app.assert_not_suspended() $$, 'STAFF_SUSPENDED', 'the shared assertion raises for new RPCs to call');
select ok((select count(*) from public.attendance_day where enrolment_id = :'enr1'::uuid) = 1, 'reads still work while suspended (own earlier attendance visible)');
select is((select status::text from public.attendance_day where enrolment_id = :'enr1'::uuid and attendance_date = current_date), 'present', 'and the blocked write changed nothing');

-- the same guard sits on the other write paths (fires before privilege/row work)
reset role;
select throws_ok($$ update public.mark_entry set marks_obtained = marks_obtained where false $$, 'STAFF_SUSPENDED', 'suspended: mark entry is blocked');
select throws_ok($$ insert into public.fee_payment select * from public.fee_payment where false $$, 'STAFF_SUSPENDED', 'suspended: fee collection is blocked');
select throws_ok($$ update public.leave_application set status = status where false $$, 'STAFF_SUSPENDED', 'suspended: leave approval is blocked');
select throws_ok($$ update public.certificate_issue set status = status where false $$, 'STAFF_SUSPENDED', 'suspended: certificate issuance/void is blocked');
select throws_ok($$ update public.attendance_day set status = status where false $$, 'STAFF_SUSPENDED', 'suspended: direct attendance DML is blocked too');

-- ── an unsuspended colleague is unaffected ───────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'t2_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok(not app.is_caller_suspended(), 'a colleague with no suspension is not suspended');
select lives_ok(format($$ select public.save_attendance_register(%L::uuid, current_date, jsonb_build_array(jsonb_build_object('enrolment_id', %L, 'status', 'present'))) $$, :'sec2', :'enr2'),
  'an unsuspended teacher can still mark attendance');
select lives_ok(format($$ select public.create_homework(%L::uuid, %L::uuid, 'Colleague homework', current_date + 5, current_date) $$, :'sec2', :'chm'),
  'an unsuspended teacher can still post homework');

-- ── a suspension that has not started / has ended does not block ─────────
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.reinstate_suspended_staff(:'susp'::uuid, 'Inquiry closed');
select set_config('request.jwt.claims', json_build_object('sub', :'t1_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok(not app.is_caller_suspended(), 'ending the suspension (reinstatement row) lifts the guard');
select lives_ok(format($$ select public.save_attendance_register(%L::uuid, current_date, jsonb_build_array(jsonb_build_object('enrolment_id', %L, 'status', 'late'))) $$, :'sec', :'enr1'),
  'access is restored: attendance can be marked again');
select lives_ok(format($$ select public.create_homework(%L::uuid, %L::uuid, 'After suspension', current_date + 5, current_date) $$, :'sec', :'chm'),
  'access is restored: homework can be posted again');

-- a future-dated suspension has not started yet
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.issue_disciplinary_action(:'s1'::uuid, 'suspension', 'Future', null, current_date + 10, current_date + 20);
select set_config('request.jwt.claims', json_build_object('sub', :'t1_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok(not app.is_caller_suspended(), 'a suspension that has not started yet does not block');

select * from finish();
rollback;
