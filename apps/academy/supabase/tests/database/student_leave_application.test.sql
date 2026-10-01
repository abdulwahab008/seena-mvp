-- pgTAP tests for FR-G07: parent leave application submission.
begin;
select plan(27);

select public.provision_tenant('test-leave-co', 'Leave Co', 'owner@leave.test');
select id as tenant_id from public.tenant where slug = 'test-leave-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-leave-other', 'Other Leave Co', 'owner@otherleave.test');
select id as other_tenant_id from public.tenant where slug = 'test-leave-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as office_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@leave.test', 'authenticated', 'authenticated', 'x'), (:'office_uid', 'r@leave.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@leave.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'office_uid', :'tenant_id', 'receptionist', 'Front Desk'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Leave Kid One', '2015-01-01'::date, 'male') as s1 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid) as e1 \gset
select public.create_student(:'campus_id'::uuid, 'Leave Kid Two', '2015-02-01'::date, 'female') as s2 \gset
select public.enrol_student(:'section_id'::uuid, :'s2'::uuid) as e2 \gset
select public.create_student(:'campus_id'::uuid, 'Leave Kid Three', '2015-03-01'::date, 'male') as s3 \gset
select public.enrol_student(:'section_id'::uuid, :'s3'::uuid) as e3 \gset
select public.fn_find_or_create_guardian(p_name_en => 'Leave Father', p_phone_e164 => '+923007770001') as g1 \gset
select public.link_guardian(:'s1'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
select public.link_guardian(:'s2'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
select public.fn_find_or_create_guardian(p_name_en => 'Other Father', p_phone_e164 => '+923007770002') as g2 \gset
select public.link_guardian(:'s3'::uuid, :'g2'::uuid, 'father'::public.guardian_relationship, true, true);
reset role;
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as parent2_uid \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role) values
  (:'parent_uid', '923007770001', now(), 'x', 'authenticated', 'authenticated'), (:'parent2_uid', '923007770002', now(), 'x', 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'parent_uid' where id = :'g1';
update public.guardian set auth_user_id = :'parent2_uid' where id = :'g2';

-- ── AC1: a parent can only apply for a linked child ───────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select throws_ok(format($$ select public.submit_student_leave(%L, '2026-09-10', '2026-09-11', 'medical') $$, :'e3'), '42501', null, 'AC1: applying for another family''s child is refused (403)');
select throws_ok(format($$ select public.submit_student_leave(%L, '2026-09-10', '2026-09-11', 'medical') $$, gen_random_uuid()), '42501', null, 'and so is an unknown enrolment id');
select public.submit_student_leave(:'e1'::uuid, '2026-09-10', '2026-09-12', 'medical', 'بخار کی وجہ سے چھٹی درکار ہے') as leave1 \gset
select is((select status::text from public.student_leave_application where id = :'leave1'::uuid), 'pending', 'a valid application is created pending');
select is((select remarks from public.student_leave_application where id = :'leave1'::uuid), 'بخار کی وجہ سے چھٹی درکار ہے', 'Urdu remarks round-trip as UTF-8');
select is((select applied_via from public.student_leave_application where id = :'leave1'::uuid), 'parent', 'and it records that the parent applied');
select is((select count(*) from public.student_leave_application), 1::bigint, 'the parent sees only their own children''s applications');

-- ── AC2: date order ───────────────────────────────────────────────────────
select throws_ok(format($$ select public.submit_student_leave(%L, '2026-09-10', '2026-09-08', 'family') $$, :'e1'), 'LEAVE_END_BEFORE_START', 'AC2: an end date before the start date is rejected');
select throws_ok(format($$ select public.submit_student_leave(%L, '2026-10-01', '2026-10-01', 'family', %L) $$, :'e2', repeat('a', 501)), 'REMARKS_TOO_LONG', 'remarks are capped at 500 characters');
select lives_ok(format($$ select public.submit_student_leave(%L, '2026-10-01', '2026-10-01', 'family', %L) $$, :'e2', repeat('ا', 500)), '500 Urdu characters are accepted');

-- ── AC3: overlap ──────────────────────────────────────────────────────────
select throws_ok(format($$ select public.submit_student_leave(%L, '2026-09-11', '2026-09-14', 'travel') $$, :'e1'), 'LEAVE_OVERLAP', 'AC3: a request overlapping a pending one is rejected');
reset role;
select is(app.fn_leave_covering_date(:'e1'::uuid, '2026-09-11', '2026-09-14'), '2026-09-11'::date, 'AC3: the message can name 2026-09-11 as the date already covered');
update public.student_leave_application set status = 'approved' where id = :'leave1'::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select throws_ok(format($$ select public.submit_student_leave(%L, '2026-09-12', '2026-09-13', 'travel') $$, :'e1'), 'LEAVE_OVERLAP', 'an approved leave blocks overlaps too');
select lives_ok(format($$ select public.submit_student_leave(%L, '2026-09-13', '2026-09-14', 'travel') $$, :'e1'), 'the day after the leave ends is free');
reset role;
select throws_ok(format($$ insert into public.student_leave_application (tenant_id, campus_id, session_id, enrolment_id, applied_by_user_id, applied_via, from_date, to_date, reason_category)
  values (%L, %L, %L, %L, %L, 'office', '2026-09-10', '2026-09-10', 'other') $$, :'tenant_id', :'campus_id', :'session_id', :'e1', :'owner_uid'), '23P01', null, 'the database itself refuses an overlap, so two tabs cannot both succeed');
update public.student_leave_application set status = 'cancelled' where enrolment_id = :'e1'::uuid and from_date = '2026-09-13';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select public.cancel_student_leave((select id from public.student_leave_application where enrolment_id = :'e2'::uuid limit 1));
select is((select status::text from public.student_leave_application where enrolment_id = :'e2'::uuid limit 1), 'cancelled', 'a pending application can be cancelled by the parent');
select throws_ok(format($$ select public.cancel_student_leave(%L) $$, :'leave1'), 'LEAVE_NOT_PENDING', 'an approved one cannot');

-- ── AC4: attachments: 3 files and 10 MB in total ──────────────────────────
select public.submit_student_leave(:'e1'::uuid, '2026-12-20', '2026-12-21', 'medical') as leave_att \gset
select public.add_leave_attachment(:'leave_att'::uuid, 'doctor note.pdf', 'application/pdf', 6291456) ->> 'storage_path' as path1 \gset
select is(:'path1' like :'tenant_id' || '/' || :'campus_id' || '/' || :'e1' || '/' || :'leave_att' || '/%-doctor_note.pdf', true, 'the file lands under tenant/campus/enrolment/leave with a safe name');
select throws_ok(format($$ select public.add_leave_attachment(%L, 'report.jpg', 'image/jpeg', 5242880) $$, :'leave_att'), 'ATTACHMENTS_TOTAL_TOO_LARGE', 'AC4: a second 5 MB file is rejected at 10 MB total');
select is((select count(*) from public.student_leave_attachment where leave_application_id = :'leave_att'::uuid), 1::bigint, 'and the first remains attached');
select lives_ok(format($$ select public.add_leave_attachment(%L, 'small.png', 'image/png', 1048576) $$, :'leave_att'), 'a smaller one still fits');
select throws_ok(format($$ select public.add_leave_attachment(%L, 'x.exe', 'application/octet-stream', 100) $$, :'leave_att'), 'ATTACHMENT_TYPE_NOT_ALLOWED', 'only PDF and images are accepted');
select public.add_leave_attachment(:'leave_att'::uuid, 'third.png', 'image/png', 1000);
select throws_ok(format($$ select public.add_leave_attachment(%L, 'fourth.png', 'image/png', 1000) $$, :'leave_att'), 'TOO_MANY_ATTACHMENTS', 'a fourth file is refused');

-- ── office entry on a parent's behalf ─────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'office_uid', 'tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.submit_student_leave(:'e3'::uuid, '2026-11-02', '2026-11-03', 'family', 'Parent phoned the office') as leave3 \gset
select is((select applied_via || '/' || (applied_by_user_id = :'office_uid'::uuid)::text from public.student_leave_application where id = :'leave3'::uuid), 'office/true', 'an office user can enter it, recorded as theirs');

-- ── isolation ─────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'parent2_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*) from public.student_leave_application), 1::bigint, 'another parent sees only their own child''s application');
select throws_ok(format($$ select public.add_leave_attachment(%L, 'a.pdf', 'application/pdf', 10) $$, :'leave_att'), 'FORBIDDEN', 'and cannot attach to a stranger''s application');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.submit_student_leave(%L, '2026-12-01', '2026-12-01', 'other') $$, :'e1'), 'FORBIDDEN', 'a teacher cannot submit applications');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.student_leave_application), 0::bigint, 'another school sees none of these applications');

select * from finish();
rollback;
