-- pgTAP tests for FR-T07: School Leaving Certificate issuance.
-- The PDF bytes are produced outside the database; what is asserted here is the
-- snapshot the renderer prints (board, roll, group, class, result status) and
-- every rule the database owns about who may be given one.
begin;
select plan(25);

select public.provision_tenant('test-slc-co', 'SLC Co', 'owner@slc.test');
select id as tenant_id from public.tenant where slug = 'test-slc-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as c8 from public.class_level where tenant_id = :'tenant_id' and code = '8' \gset
select id as c10 from public.class_level where tenant_id = :'tenant_id' and code = '10' \gset
select id as c12 from public.class_level where tenant_id = :'tenant_id' and code = '12' \gset
select public.provision_tenant('test-slc-other', 'Other SLC Co', 'owner@otherslc.test');
select id as other_tenant_id from public.tenant where slug = 'test-slc-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@slc.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@slc.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Principal Owner'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'c8'::uuid, 'A', 30) as sec8 \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'c10'::uuid, 'A', 30) as sec10 \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'c12'::uuid, 'A', 30) as sec12 \gset

reset role;
-- students in the situations the acceptance criteria describe
insert into public.student (tenant_id, campus_id, gr_number, name_en, father_name_en, dob, gender, status) values
  (:'tenant_id', :'campus_id', '2019-0001', 'Hira Pre-Medical', 'F', '2008-01-01', 'female', 'passed_out'),
  (:'tenant_id', :'campus_id', '2019-0002', 'Grade Eight', 'F', '2012-01-01', 'male', 'passed_out'),
  (:'tenant_id', :'campus_id', '2019-0003', 'Awaiting Result', 'F', '2010-01-01', 'male', 'passed_out'),
  (:'tenant_id', :'campus_id', '2019-0004', 'Struck Off Twelve', 'F', '2008-02-01', 'male', 'struck_off'),
  (:'tenant_id', :'campus_id', '2019-0005', 'Still Studying', 'F', '2008-03-01', 'male', 'active'),
  (:'tenant_id', :'campus_id', '2019-0006', 'Struck But Sat Exam', 'F', '2008-04-01', 'female', 'struck_off'),
  (:'tenant_id', :'campus_id', '2019-0007', 'Passed Result', 'F', '2010-02-01', 'female', 'passed_out');
select id as s_hira from public.student where gr_number = '2019-0001' and tenant_id = :'tenant_id' \gset
select id as s_eight from public.student where gr_number = '2019-0002' and tenant_id = :'tenant_id' \gset
select id as s_wait from public.student where gr_number = '2019-0003' and tenant_id = :'tenant_id' \gset
select id as s_struck from public.student where gr_number = '2019-0004' and tenant_id = :'tenant_id' \gset
select id as s_active from public.student where gr_number = '2019-0005' and tenant_id = :'tenant_id' \gset
select id as s_sat from public.student where gr_number = '2019-0006' and tenant_id = :'tenant_id' \gset
select id as s_pass from public.student where gr_number = '2019-0007' and tenant_id = :'tenant_id' \gset
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status, joined_on) values
  (:'tenant_id', :'campus_id', :'session_id', :'s_hira', :'c12', :'sec12', 'graduated', current_date - 400) returning id as e_hira \gset
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status, joined_on) values
  (:'tenant_id', :'campus_id', :'session_id', :'s_eight', :'c8', :'sec8', 'graduated', current_date - 400) returning id as e_eight \gset
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status, joined_on) values
  (:'tenant_id', :'campus_id', :'session_id', :'s_wait', :'c10', :'sec10', 'graduated', current_date - 400) returning id as e_wait \gset
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status, joined_on) values
  (:'tenant_id', :'campus_id', :'session_id', :'s_struck', :'c12', :'sec12', 'left', current_date - 400) returning id as e_struck \gset
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status, joined_on) values
  (:'tenant_id', :'campus_id', :'session_id', :'s_active', :'c12', :'sec12', 'active', current_date - 400) returning id as e_active \gset
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status, joined_on) values
  (:'tenant_id', :'campus_id', :'session_id', :'s_sat', :'c12', :'sec12', 'left', current_date - 400) returning id as e_sat \gset
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status, joined_on) values
  (:'tenant_id', :'campus_id', :'session_id', :'s_pass', :'c10', :'sec10', 'graduated', current_date - 400) returning id as e_pass \gset

insert into public.exam_registration (tenant_id, campus_id, student_id, enrolment_id, board_code, roll_no, group_code) values
  (:'tenant_id', :'campus_id', :'s_hira', :'e_hira', 'FBISE', '462119', 'Pre-Medical') returning id as reg_hira \gset
insert into public.exam_registration (tenant_id, campus_id, student_id, enrolment_id, board_code, roll_no, group_code) values
  (:'tenant_id', :'campus_id', :'s_wait', :'e_wait', 'FBISE', '510022', 'SCIENCE') returning id as reg_wait \gset
insert into public.exam_registration (tenant_id, campus_id, student_id, enrolment_id, board_code, roll_no, group_code) values
  (:'tenant_id', :'campus_id', :'s_sat', :'e_sat', 'FBISE', '462200', 'PRE_ENGINEERING') returning id as reg_sat \gset
insert into public.exam_registration (tenant_id, campus_id, student_id, enrolment_id, board_code, roll_no, group_code) values
  (:'tenant_id', :'campus_id', :'s_pass', :'e_pass', 'FBISE', '510023', 'SCIENCE') returning id as reg_pass \gset
insert into public.board_result (tenant_id, campus_id, registration_id, result_status) values (:'tenant_id', :'campus_id', :'reg_pass', 'passed');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── a template is needed, and the type has its own required fields ─────────
select throws_ok(format($$ select public.issue_leaving_certificate(%L) $$, :'e_hira'), 'P0002', 'TEMPLATE_NOT_FOUND', 'with no active Leaving Certificate template, issuing is refused');
select public.create_certificate_template(
  'leaving'::public.certificate_type, 'School Leaving Certificate',
  '<p>{{student.name_en}} (GR {{student.gr_number}}) completed class {{leaving.class_roman}} and sat the {{leaving.board}} examination, roll {{leaving.roll_no}}, group {{leaving.group}}. '
  || 'Result: {{leaving.result_status}}. Serial {{issue.serial_no}}, issued {{issue.date}}.</p>',
  null, 'en'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_id'::uuid) as tpl \gset
select public.activate_certificate_template(:'tpl'::uuid) as _a \gset

-- ── AC1: Grade 12 Pre-Medical, FBISE roll 462119 ──────────────────────────
select public.issue_leaving_certificate(:'e_hira'::uuid) as r1 \gset
select is(:'r1'::jsonb -> 'payload_snapshot' -> 'values' ->> 'leaving.board', 'FBISE', 'AC1: the certificate shows board FBISE');
select is(:'r1'::jsonb -> 'payload_snapshot' -> 'values' ->> 'leaving.roll_no', '462119', 'AC1: roll 462119');
select is(:'r1'::jsonb -> 'payload_snapshot' -> 'values' ->> 'leaving.group', 'Pre-Medical', 'AC1: group Pre-Medical');
select is(:'r1'::jsonb -> 'payload_snapshot' -> 'values' ->> 'leaving.class_roman', 'XII', 'AC1: class XII');
select is(:'r1'::jsonb ->> 'certificate_type', 'leaving', 'it is a leaving certificate, not a transfer or character one');
select ok((:'r1'::jsonb ->> 'serial_no') like 'SLC-%', 'it has its own serial series (SLC-...)');
select is((select certificate_type::text from public.certificate_issue where id = (:'r1'::jsonb ->> 'issue_id')::uuid), 'leaving', 'the register row has the leaving type');
select is(:'r1'::jsonb ->> 'result_status', 'Result Awaited', 'no board result has been imported for Hira, and it still issued');

-- ── AC2: Grade 8 is rejected with the exact sentence ──────────────────────
select throws_ok(format($$ select public.issue_leaving_certificate(%L) $$, :'e_eight'), '22023', 'Grade 8 leavers require a Transfer Certificate, not a Leaving Certificate', 'AC2: Grade 8 leavers require a Transfer Certificate, not a Leaving Certificate');
select throws_ok(format($$ select public.assert_terminal_class(%L) $$, :'e_eight'), '22023', 'Grade 8 leavers require a Transfer Certificate, not a Leaving Certificate', 'assert_terminal_class raises for a non-terminal class');
select lives_ok(format($$ select public.assert_terminal_class(%L) $$, :'e_hira'), 'and accepts class 12');

-- ── AC3: Grade 10 with no result imported -> Result Awaited ───────────────
select public.issue_leaving_certificate(:'e_wait'::uuid) as r3 \gset
select is(:'r3'::jsonb -> 'payload_snapshot' -> 'values' ->> 'leaving.result_status', 'Result Awaited', 'AC3: a Grade 10 student whose result has not been imported issues with Result Awaited');
select is(:'r3'::jsonb -> 'payload_snapshot' -> 'values' ->> 'leaving.class_roman', 'X', 'AC3: Grade 10 prints X');
select is(:'r3'::jsonb -> 'payload_snapshot' -> 'values' ->> 'leaving.group', 'Science', 'a stored group code is printed readably');
select public.issue_leaving_certificate(:'e_pass'::uuid) as r3b \gset
select is(:'r3b'::jsonb -> 'payload_snapshot' -> 'values' ->> 'leaving.result_status', 'Passed', 'once the board result is imported the certificate prints it');

-- ── AC4: struck off in Grade 12 without sitting the exam ──────────────────
select throws_ok(format($$ select public.issue_leaving_certificate(%L) $$, :'e_struck'), '22023', 'Student was struck off without sitting the board examination; issue a Transfer Certificate instead', 'AC4: a student struck off without sitting the exam is rejected and TC is offered');
select lives_ok(format($$ select public.issue_leaving_certificate(%L) $$, :'e_sat'), 'a student struck off AFTER registering for the exam did complete the course and can be issued one');
select throws_ok(format($$ select public.issue_leaving_certificate(%L) $$, :'e_active'), '22023', 'STUDENT_NOT_COMPLETED', 'a student still studying is refused');

-- ── series, duplicates and the register ───────────────────────────────────
select throws_ok(format($$ select public.issue_leaving_certificate(%L) $$, :'e_hira'), '23505', 'LEAVING_CERTIFICATE_ALREADY_ISSUED', 'one live Leaving Certificate per enrolment');
select is((select count(*) from public.certificate_serial_counter where campus_id = :'campus_id' and certificate_type = 'transfer'), 0::bigint, 'the transfer series is untouched');
select is((select current_value from public.certificate_serial_counter where campus_id = :'campus_id' and certificate_type = 'leaving'), 4::bigint, 'four leaving certificates were issued and numbered without gaps');
select is((select count(*) from public.certificate_serial_counter where campus_id = :'campus_id' and certificate_type = 'leaving' and prefix_pattern = 'SLC-{YEAR}-{SEQ}'), 1::bigint, 'the series pattern is SLC-{YEAR}-{SEQ}');

-- ── roles and tenant isolation ────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.issue_leaving_certificate(%L) $$, :'e_hira'), 'FORBIDDEN', 'a teacher cannot issue a Leaving Certificate');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select throws_ok(format($$ select public.issue_leaving_certificate(%L) $$, :'e_hira'), 'P0002', 'ENROLMENT_NOT_FOUND', 'another school cannot see the enrolment');

select * from finish();
rollback;
