-- pgTAP tests for FR-Q04: hostel visitor entry and exit log.
begin;
select plan(28);

select public.provision_tenant('test-visit-co', 'Visit Co', 'owner@visit.test');
select id as tenant_id from public.tenant where slug = 'test-visit-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-visit-other', 'Other Visit Co', 'owner@othervisit.test');
select id as other_tenant_id from public.tenant where slug = 'test-visit-other' \gset

select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as gate_uid \gset
select gen_random_uuid() as warden_uid \gset
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'prin_uid', 'p@visit.test', 'authenticated', 'authenticated', 'x'), (:'gate_uid', 'g@visit.test', 'authenticated', 'authenticated', 'x'),
  (:'warden_uid', 'w@visit.test', 'authenticated', 'authenticated', 'x'), (:'parent_uid', 'par@visit.test', 'authenticated', 'authenticated', 'x'),
  (:'teacher_uid', 't@visit.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'gate_uid', :'tenant_id', 'receptionist', 'Gate Clerk'),
  (:'warden_uid', :'tenant_id', 'vice_principal', 'Warden'), (:'teacher_uid', :'tenant_id', 'class_teacher', 'Teacher');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'prin_uid', :'tenant_id', :'campus_id');
insert into public.staff (tenant_id, campus_id, user_id, employee_code, gender, full_name, cnic)
values (:'tenant_id', :'campus_id', :'warden_uid', 'E-WARD-4', 'male', 'Warden', '35202-3333333-3');
select id as warden_staff from public.staff where user_id = :'warden_uid' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.create_hostel_block(:'campus_id'::uuid, 'IQ', 'Iqbal Block', 'male', 2, 4, 10, 'quad', :'warden_staff'::uuid);
select public.create_student(:'campus_id'::uuid, 'Boarder One', '2012-01-01'::date, 'male') as s1 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid);
reset role;
insert into public.guardian (tenant_id, name_en, cnic, auth_user_id) values (:'tenant_id', 'Father One', '35202-1234567-1', :'parent_uid');
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
select :'tenant_id', :'s1'::uuid, id, 'father', true, true from public.guardian where cnic = '35202-1234567-1';

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'gate_uid', 'tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- AC2: a guardian CNIC pre-fills the relationship and flags the visit verified.
select is(public.lookup_visitor_relationship(:'s1'::uuid, '3520212345671'), 'father', 'AC2: the gate form is told the CNIC belongs to the student''s father');
select public.log_hostel_visit(:'s1'::uuid, 'Father One', '35202-1234567-1') as v_verified \gset
select is(:'v_verified'::jsonb ->> 'verified', 'true', 'AC2: a CNIC matching a guardian is flagged verified');
select is(:'v_verified'::jsonb ->> 'relationship', 'father', 'AC2: and the relationship is pre-filled');
select public.log_hostel_visit(:'s1'::uuid, 'Family Friend', '35202-7654321-9', 'family friend', '0300-5555555') as v_unverified \gset
select is(:'v_unverified'::jsonb ->> 'verified', 'false', 'AC2: any other CNIC is flagged unverified');
select is((select relationship from public.hostel_visitor_log where id = (:'v_unverified'::jsonb ->> 'id')::uuid), 'family friend', 'with the relationship the gate typed');
select throws_ok(format($$ select public.log_hostel_visit(%L, 'Bad Cnic', '12345') $$, :'s1'), 'CNIC_INVALID', 'a malformed CNIC is refused');

-- AC1: six entered today, four have left, two remain, newest first.
select public.log_hostel_visit(:'s1'::uuid, 'Visitor ' || i, '35202-000000' || i || '-' || i) from generate_series(1, 4) i;
select count(*) as total_visits from public.hostel_visitor_log \gset
select is(:'total_visits'::int, 6, 'AC1: six visitors entered today');
reset role;
update public.hostel_visitor_log set entered_at = '2026-09-14T08:00:00Z'::timestamptz + (substr(visitor_name, 9)::int || ' hours')::interval where visitor_name like 'Visitor _';
update public.hostel_visitor_log set entered_at = '2026-09-14T07:00:00Z' where visitor_name = 'Father One';
update public.hostel_visitor_log set entered_at = '2026-09-14T07:30:00Z' where visitor_name = 'Family Friend';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'gate_uid', 'tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.exit_hostel_visit(id, '2026-09-14T15:00:00Z') from public.hostel_visitor_log where visitor_name in ('Father One', 'Family Friend', 'Visitor 1', 'Visitor 2');
select is((select count(*) from public.v_hostel_open_visits), 2::bigint, 'AC1: exactly two open visits are listed');
select is((select array_agg(visitor_name order by entered_at desc) from public.v_hostel_open_visits), array['Visitor 4', 'Visitor 3'], 'AC1: newest entry first');
select throws_ok(format($$ select public.exit_hostel_visit(%L) $$, (:'v_verified'::jsonb ->> 'id')), 'VISIT_ALREADY_CLOSED', 'a visit can be closed only once');

-- AC3: still inside at closing time -> alert at 21:05.
select is(public.log_hostel_visit(:'s1'::uuid, 'Late Visitor', '35202-1111111-1', 'cousin') is not null, true, 'a late visitor is logged');
reset role;
update public.hostel_visitor_log set entered_at = '2026-09-14T13:30:00Z' where visitor_name = 'Late Visitor';
update public.hostel_visitor_log set exited_at = '2026-09-14T15:30:00Z' where visitor_name in ('Visitor 3', 'Visitor 4');
select is(public.hostel_open_visit_check('2026-09-14T15:59:00Z'::timestamptz), 0, 'AC3: before the 21:00 PKT closing time nothing is raised');
select is(public.hostel_open_visit_check('2026-09-14T16:05:00Z'::timestamptz), 1, 'AC3: at 21:05 PKT the one visit still open raises an alert');
select ok((select body like '%Late Visitor%' and body like '%Boarder One%' from public.user_notification where kind = 'hostel_visitor_inside' and user_id = :'warden_uid'), 'AC3: the warden''s alert names the visitor and the student');
select is((select count(*) from public.user_notification where kind = 'hostel_visitor_inside' and user_id = :'prin_uid'), 1::bigint, 'and the Principal is told too');
select is(public.hostel_open_visit_check('2026-09-14T16:30:00Z'::timestamptz), 0, 'the same visit is alerted only once');

-- AC4: the photograph bucket is private and closed to parents and students.
select is((select public from storage.buckets where id = 'hostel-visitor-photos'), false, 'AC4: hostel-visitor-photos is a private bucket');
insert into storage.objects (bucket_id, name, owner) values ('hostel-visitor-photos', :'tenant_id' || '/' || :'campus_id' || '/' || gen_random_uuid() || '.jpg', null);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'gate_uid', 'tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from storage.objects where bucket_id = 'hostel-visitor-photos'), 1::bigint, 'AC4: gate staff can read the photograph');
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from storage.objects where bucket_id = 'hostel-visitor-photos'), 0::bigint, 'AC4: a parent account cannot read it');
select is((select count(*) from public.hostel_visitor_log), 0::bigint, 'AC4: nor the visitor log itself');
select set_config('request.jwt.claims', json_build_object('sub', :'teacher_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.hostel_visitor_log), 0::bigint, 'a class teacher cannot read the visitor log');

-- Retention: an old visit and its photograph are purged on the 180-day clock; identity is redacted from the audit trail.
reset role;
select is((select after ->> 'visitor_cnic' from public.audit_log where table_name = 'hostel_visitor_log' and row_id = (:'v_verified'::jsonb ->> 'id')::uuid and action = 'insert'), '[redacted]', 'visitor CNIC is redacted in audit_log');
select is((select after ->> 'visitor_name' from public.audit_log where table_name = 'hostel_visitor_log' and row_id = (:'v_verified'::jsonb ->> 'id')::uuid and action = 'insert'), '[redacted]', 'and the visitor name');
insert into public.hostel_visitor_log (tenant_id, campus_id, student_id, visitor_name, visitor_cnic, entered_at, exited_at, photo_path)
values (:'tenant_id', :'campus_id', :'s1'::uuid, 'Old Visitor', '35202-9999999-9', now() - interval '200 days', now() - interval '200 days' + interval '1 hour', :'tenant_id' || '/' || :'campus_id' || '/old.jpg'),
       (:'tenant_id', :'campus_id', :'s1'::uuid, 'Month Old Visitor', '35202-8888888-8', now() - interval '60 days', now() - interval '60 days' + interval '1 hour', null);
select is(public.hostel_visitor_retention_purge(), 1, 'the default 180-day retention purges the 200-day-old visit');
select is((select count(*) from public.storage_delete_queue where bucket = 'hostel-visitor-photos' and path like '%/old.jpg'), 1::bigint, 'and queues its photograph on the storage purge queue');
select is((select count(*) from public.hostel_visitor_log where visitor_name = 'Month Old Visitor'), 1::bigint, 'a 60-day-old visit is kept under the default');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_hostel_setting('hostel.visitor_retention_days', '30'::jsonb);
reset role;
select ok(public.hostel_visitor_retention_purge() >= 1, 'a shorter tenant retention setting purges more');
select is((select count(*) from public.hostel_visitor_log where visitor_name = 'Month Old Visitor'), 0::bigint, 'including the 60-day-old visit');

select * from finish();
rollback;
