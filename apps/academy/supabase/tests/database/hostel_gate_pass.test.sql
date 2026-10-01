-- pgTAP tests for FR-Q03: student gate pass with return tracking.
begin;
select plan(27);

select public.provision_tenant('test-pass-co', 'Pass Co', 'owner@pass.test');
select id as tenant_id from public.tenant where slug = 'test-pass-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-pass-other', 'Other Pass Co', 'owner@otherpass.test');
select id as other_tenant_id from public.tenant where slug = 'test-pass-other' \gset

select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as warden_uid \gset
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'prin_uid', 'p@pass.test', 'authenticated', 'authenticated', 'x'), (:'warden_uid', 'w@pass.test', 'authenticated', 'authenticated', 'x'),
  (:'parent_uid', 'par@pass.test', 'authenticated', 'authenticated', 'x'), (:'teacher_uid', 't@pass.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'warden_uid', :'tenant_id', 'receptionist', 'Warden Account'), (:'teacher_uid', :'tenant_id', 'class_teacher', 'Teacher');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'prin_uid', :'tenant_id', :'campus_id');
insert into public.staff (tenant_id, campus_id, user_id, employee_code, gender, full_name, cnic)
values (:'tenant_id', :'campus_id', :'warden_uid', 'E-WARD-9', 'male', 'Warden Account', '35202-3333333-3');
select id as warden_staff from public.staff where user_id = :'warden_uid' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.create_hostel_block(:'campus_id'::uuid, 'IQ', 'Iqbal Block', 'male', 2, 4, 10, 'quad', :'warden_staff'::uuid) as iq \gset
select public.create_student(:'campus_id'::uuid, 'Boarder One', '2012-01-01'::date, 'male') as s1 \gset
select public.create_student(:'campus_id'::uuid, 'Day Scholar', '2012-01-01'::date, 'male') as s2 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid);
select public.enrol_student(:'section_id'::uuid, :'s2'::uuid);
select public.allocate_bed(:'s1'::uuid, (select id from public.hostel_bed where bed_code = 'IQ-101-B1'), '2026-01-05');

reset role;
insert into public.guardian (tenant_id, name_en, cnic, auth_user_id, phone_e164, preferred_language) values (:'tenant_id', 'Father One', '35202-1234567-1', :'parent_uid', '+923001112233', 'en');
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
select :'tenant_id', :'s1'::uuid, id, 'father', true, true from public.guardian where cnic = '35202-1234567-1';

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'warden_uid', 'tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- A verified guardian collects; the pass is numbered.
select public.issue_gate_pass(:'s1'::uuid, 'Weekend at home', '2026-08-14T16:00:00+05'::timestamptz, '2026-08-16T20:00:00+05'::timestamptz, 'Father One', '35202-1234567-1', 'Lahore') as pass1 \gset
select is((select serial from public.hostel_gate_pass where id = :'pass1'::uuid), 'GP-2026-00001', 'the first pass of the year is GP-2026-00001');
select ok((select released_to_guardian_id is not null and override_reason is null from public.hostel_gate_pass where id = :'pass1'::uuid), 'a collector matching a guardian CNIC is released to that guardian with no override');
select is((select status::text from public.hostel_gate_pass where id = :'pass1'::uuid), 'open', 'the pass is open');

-- AC3: only one open pass per student.
select throws_ok(format($$ select public.issue_gate_pass(%L, 'Another trip', '2026-08-15T10:00:00+05'::timestamptz, '2026-08-15T18:00:00+05'::timestamptz, 'Father One', '35202-1234567-1') $$, :'s1'), 'PASS_ALREADY_OPEN', 'AC3: a second pass while one is open is refused with PASS_ALREADY_OPEN');
select throws_ok(format($$ select public.issue_gate_pass(%L, 'Day trip', '2026-08-15T10:00:00+05'::timestamptz, '2026-08-15T18:00:00+05'::timestamptz, 'Father One', '35202-1234567-1') $$, :'s2'), 'NOT_A_BOARDER', 'a student with no hostel stay cannot be given a gate pass');

-- AC2: a collector who is not a recorded guardian.
select public.close_gate_pass(:'pass1'::uuid, '2026-08-16T19:00:00+05'::timestamptz);
select is((select status::text from public.hostel_gate_pass where id = :'pass1'::uuid), 'returned', 'closing the pass marks it returned');
select throws_ok(format($$ select public.close_gate_pass(%L) $$, :'pass1'), 'GATE_PASS_CLOSED', 'a returned pass cannot be closed again');
select throws_ok(format($$ select public.issue_gate_pass(%L, 'Visit', '2026-09-20T16:00:00+05'::timestamptz, '2026-09-20T20:00:00+05'::timestamptz, 'Uncle Unknown', '35202-7654321-9') $$, :'s1'), 'GUARDIAN_NOT_VERIFIED', 'AC2: the warden cannot release a student to an adult who matches no guardian');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.issue_gate_pass(%L, 'Visit', '2026-09-20T16:00:00+05'::timestamptz, '2026-09-20T20:00:00+05'::timestamptz, 'Uncle Unknown', '35202-7654321-9') $$, :'s1'), 'OVERRIDE_REASON_REQUIRED', 'AC2: even the Principal must type a reason');
select public.issue_gate_pass(:'s1'::uuid, 'Visit', '2026-09-20T16:00:00+05'::timestamptz, '2026-09-20T20:00:00+05'::timestamptz, 'Uncle Unknown', '35202-7654321-9', null, 'Father phoned the Principal; uncle collecting') as pass2 \gset
select ok((select override_reason = 'Father phoned the Principal; uncle collecting' and override_by = :'prin_uid'::uuid and released_to_guardian_id is null from public.hostel_gate_pass where id = :'pass2'::uuid), 'AC2: the override records the reason and the approver on the pass');
select is((select after ->> 'override_reason' from public.audit_log where table_name = 'hostel_gate_pass' and row_id = :'pass2'::uuid and action = 'insert'), 'Father phoned the Principal; uncle collecting', 'AC2: and the audit log');
select is((select serial from public.hostel_gate_pass where id = :'pass2'::uuid), 'GP-2026-00002', 'the next serial follows');

-- Immutable record.
update public.hostel_gate_pass set collector_name = 'Someone Else' where id = :'pass2'::uuid;
select is((select collector_name from public.hostel_gate_pass where id = :'pass2'::uuid), 'Uncle Unknown', 'the collector cannot be edited after the fact (no update policy exists for any signed-in user)');
reset role;
select throws_ok(format($$ update public.hostel_gate_pass set collector_name = 'Someone Else' where id = %L $$, :'pass2'), 'GATE_PASS_IMMUTABLE', 'even an administrator cannot edit the collector');
select throws_ok(format($$ delete from public.hostel_gate_pass where id = %L $$, :'pass2'), 'GATE_PASS_IMMUTABLE', 'a pass cannot be deleted, even by an administrator');
select throws_ok(format($$ update public.hostel_gate_pass set serial = 'GP-2026-99999' where id = %L $$, :'pass2'), 'GATE_PASS_IMMUTABLE', 'nor renumbered');

-- AC1: overdue after 20:30 with no return.
select is(public.hostel_gate_pass_overdue_check('2026-09-20T19:30:00+05'::timestamptz), 0, 'AC1: before the expected return time nothing is overdue');
select is(public.hostel_gate_pass_overdue_check('2026-09-20T20:30:00+05'::timestamptz), 1, 'AC1: at 20:30, 30 minutes late, the pass moves to overdue');
select is((select status::text from public.hostel_gate_pass where id = :'pass2'::uuid), 'overdue', 'AC1: its status is overdue');
select is((select count(*) from public.user_notification where kind = 'hostel_gate_pass_overdue' and user_id in (:'warden_uid', :'prin_uid')), 2::bigint, 'AC1: the warden and the Principal are alerted in the app');
select is(public.hostel_gate_pass_overdue_check('2026-09-20T21:30:00+05'::timestamptz), 0, 'AC1: a pass already overdue is not alerted again');
select throws_ok(format($$ select public.issue_gate_pass(%L, 'Again', '2026-09-21T10:00:00+05'::timestamptz, '2026-09-21T18:00:00+05'::timestamptz, 'Father One', '35202-1234567-1') $$, :'s1'), 'PASS_ALREADY_OPEN', 'an overdue pass still counts as open: the student is still out');

-- SMS and WhatsApp to the registered guardian for a pass released to them.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.close_gate_pass(:'pass2'::uuid);
select public.issue_gate_pass(:'s1'::uuid, 'Eid break', '2026-10-10T09:00:00+05'::timestamptz, '2026-10-12T20:00:00+05'::timestamptz, 'Father One', '35202-1234567-1') as pass3 \gset
reset role;
select public.hostel_gate_pass_overdue_check('2026-10-12T20:30:00+05'::timestamptz);
select is((select array_agg(channel::text order by channel) from public.message where metadata ->> 'pass_id' = :'pass3'), array['sms', 'whatsapp'], 'AC1: the registered guardian is alerted by SMS and WhatsApp');
select ok((select bool_and(message_class = 'emergency' and body like '%GP-2026-00003%') from public.message where metadata ->> 'pass_id' = :'pass3'), 'AC1: the alert names the pass');

-- Parent reads own child only; others see nothing.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.hostel_gate_pass), 3::bigint, 'a parent sees their own child''s passes');
select set_config('request.jwt.claims', json_build_object('sub', :'teacher_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.hostel_gate_pass), 0::bigint, 'a class teacher sees none');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'principal', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.hostel_gate_pass), 0::bigint, 'another school sees none');

select * from finish();
rollback;
