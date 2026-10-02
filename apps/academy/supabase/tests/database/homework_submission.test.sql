-- pgTAP tests for FR-H05: homework submission by student.
begin;
select plan(31);

select public.provision_tenant('test-hwsub-co', 'Homework Submit Co', 'owner@hwsub.test');
select id as tenant_id from public.tenant where slug = 'test-hwsub-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-hwsub-other', 'Other Submit Co', 'owner@otherhwsub.test');
select id as other_tenant_id from public.tenant where slug = 'test-hwsub-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as teach2_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@hwsub.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@hwsub.test', 'authenticated', 'authenticated', 'x'), (:'teach2_uid', 't2@hwsub.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Homework Teacher'), (:'teach2_uid', :'tenant_id', 'subject_teacher', 'Other Teacher');
insert into public.subject (tenant_id, code, name_en, name_ur) values (:'tenant_id', 'SCI', 'Science', 'سائنس');
select id as subj from public.subject where tenant_id = :'tenant_id' and code = 'SCI' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as sec_a \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 30) as sec_b \gset
select public.create_student(:'campus_id'::uuid, 'Submit Kid A', '2015-01-01'::date, 'male') as s1 \gset
select public.enrol_student(:'sec_a'::uuid, :'s1'::uuid) as e1 \gset
select public.create_student(:'campus_id'::uuid, 'Submit Kid B', '2015-02-01'::date, 'female') as s2 \gset
select public.enrol_student(:'sec_b'::uuid, :'s2'::uuid) as e2 \gset
select public.fn_find_or_create_guardian(p_name_en => 'Father A', p_phone_e164 => '+923004440001') as g1 \gset
select public.link_guardian(:'s1'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
select public.fn_find_or_create_guardian(p_name_en => 'Father B', p_phone_e164 => '+923004440002') as g2 \gset
select public.link_guardian(:'s2'::uuid, :'g2'::uuid, 'father'::public.guardian_relationship, true, true);
reset role;
select gen_random_uuid() as par1 \gset
select gen_random_uuid() as par2 \gset
select gen_random_uuid() as stu1 \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role) values
  (:'par1', '923004440001', now(), 'x', 'authenticated', 'authenticated'), (:'par2', '923004440002', now(), 'x', 'authenticated', 'authenticated');
insert into auth.users (id, email, aud, role, encrypted_password) values (:'stu1', 'kid@hwsub.test', 'authenticated', 'authenticated', 'x');
update public.guardian set auth_user_id = :'par1' where id = :'g1'::uuid;
update public.guardian set auth_user_id = :'par2' where id = :'g2'::uuid;
insert into public.student_portal_account (tenant_id, campus_id, student_id, user_id) values (:'tenant_id', :'campus_id', :'s1', :'stu1');
insert into public.homework (tenant_id, campus_id, session_id, section_id, subject_id, teacher_id, title, due_date, status, published_at)
values (:'tenant_id', :'campus_id', :'session_id', :'sec_a', :'subj', :'teach_uid', 'Notebook pages', current_date + 2, 'published', now()) returning id as hw \gset
insert into public.homework (tenant_id, campus_id, session_id, section_id, subject_id, teacher_id, title, due_date, status)
values (:'tenant_id', :'campus_id', :'session_id', :'sec_a', :'subj', :'teach_uid', 'Draft homework', current_date + 2, 'draft') returning id as hw_draft \gset

-- ── a first submission stays invisible until every file is in (AC5) ───────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'par1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select public.begin_submission(:'hw'::uuid, :'e1'::uuid, 'Page 12 to 14 done') as sub \gset
select public.add_submission_file(:'sub'::uuid, 'page12.jpg', 'image/jpeg', 2000000) ->> 'storage_path' as path1 \gset
select is((select status from public.homework_submission where id = :'sub'::uuid), 'draft', 'a started submission is a draft');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.homework_submission), 0::bigint, 'AC5: the teacher sees no partial submission while the upload is unfinished');
select is((select count(*) from public.homework_submission_file), 0::bigint, 'nor its files');
select set_config('request.jwt.claims', json_build_object('sub', :'par1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select public.add_submission_file(:'sub'::uuid, 'page13.jpg', 'image/jpeg', 2000000);
select public.finalize_submission(:'sub'::uuid) as fin1 \gset
select is((:'fin1'::jsonb ->> 'version')::int, 1, 'finalizing publishes version 1');
select is((:'fin1'::jsonb ->> 'is_late')::boolean, false, 'before the due date it is on time');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.homework_submission), 1::bigint, 'only now does the teacher see it');
select is((select count(*) from public.homework_submission_file), 2::bigint, 'with both files');
select set_config('request.jwt.claims', json_build_object('sub', :'teach2_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.homework_submission), 0::bigint, 'a teacher who did not set the homework cannot see submissions');

-- ── AC3: only the section's own students ──────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'par2', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select throws_ok(format($$ select public.begin_submission(%L, %L) $$, :'hw', :'e2'), '42501', null, 'AC3: a student of another section cannot submit');
select throws_ok(format($$ select public.begin_submission(%L, %L) $$, :'hw', :'e1'), '42501', null, 'nor can another family submit for this child');
select set_config('request.jwt.claims', json_build_object('sub', :'par1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select throws_ok(format($$ select public.begin_submission(%L, %L) $$, :'hw_draft', :'e1'), '42501', null, 'a draft homework cannot be submitted to');
select throws_ok(format($$ select public.begin_submission(%L, %L, %L) $$, :'hw', :'e1', repeat('a', 2001)), 'TEXT_TOO_LONG', 'text is capped at 2000 characters');

-- ── AC1: a resubmission replaces and keeps history ────────────────────────
select public.begin_submission(:'hw'::uuid, :'e1'::uuid, 'Redone neatly') as sub2 \gset
select is(:'sub2'::uuid, :'sub'::uuid, 'resubmitting works on the same submission');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select submission_text from public.homework_submission), 'Page 12 to 14 done', 'until the new one is complete the teacher still sees version 1');
select set_config('request.jwt.claims', json_build_object('sub', :'par1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select public.begin_submission(:'hw'::uuid, :'e1'::uuid, null);
select throws_ok(format($$ select public.finalize_submission(%L) $$, :'sub'), 'EMPTY_SUBMISSION', 'finalizing needs text or a file');
select public.begin_submission(:'hw'::uuid, :'e1'::uuid, 'Redone neatly');
select public.add_submission_file(:'sub'::uuid, 'redo.png', 'image/png', 1000000);
select public.finalize_submission(:'sub'::uuid) as fin2 \gset
select is((:'fin2'::jsonb ->> 'version')::int, 2, 'AC1: the version increments');
select is((select submission_text from public.homework_submission where id = :'sub'::uuid), 'Redone neatly', 'and the text is replaced');
select is((select (snapshot ->> 'text') || '/' || jsonb_array_length(snapshot -> 'files') from public.homework_submission_version where submission_id = :'sub'::uuid and version = 1), 'Page 12 to 14 done/2', 'AC1: version 1 is kept in history with its text and files');

-- ── limits ────────────────────────────────────────────────────────────────
select public.begin_submission(:'hw'::uuid, :'e1'::uuid, null);
select throws_ok(format($$ select public.add_submission_file(%L, 'big.pdf', 'application/pdf', 6291456) $$, :'sub'), 'FILE_EXCEEDS_5MB', 'a 6 MB file is refused');
select throws_ok(format($$ select public.add_submission_file(%L, 'x.exe', 'application/x-msdownload', 100) $$, :'sub'), 'ATTACHMENT_TYPE_NOT_ALLOWED', 'a non-image, non-PDF is refused');
select public.add_submission_file(:'sub'::uuid, 'f1.jpg', 'image/jpeg', 100);
select public.add_submission_file(:'sub'::uuid, 'f2.jpg', 'image/jpeg', 100);
select public.add_submission_file(:'sub'::uuid, 'f3.jpg', 'image/jpeg', 100);
select public.add_submission_file(:'sub'::uuid, 'f4.jpg', 'image/jpeg', 100);
select public.add_submission_file(:'sub'::uuid, 'f5.jpg', 'image/jpeg', 100);
select throws_ok(format($$ select public.add_submission_file(%L, 'f6.jpg', 'image/jpeg', 100) $$, :'sub'), 'MAX_5_FILES', 'a sixth file is refused');

-- ── lateness in Asia/Karachi against end of the due date ──────────────────
reset role;
select is(app.fn_late_minutes('2026-08-20'::date, '2026-08-20 19:14:00+00'::timestamptz), 14, 'AC2: submitted at 00:14 PKT the day after the due date is 14 minutes late');
select is(app.fn_late_minutes('2026-08-20'::date, '2026-08-20 18:59:59+00'::timestamptz), 0, 'and 23:59:59 PKT on the due date is on time');
update public.homework set assigned_date = current_date - 5, due_date = current_date - 2 where id = :'hw'::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'par1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select public.finalize_submission(:'sub'::uuid) as fin3 \gset
select is((:'fin3'::jsonb ->> 'is_late')::boolean, true, 'AC2: a submission after the due date is flagged late');
select cmp_ok((:'fin3'::jsonb ->> 'late_by_minutes')::int, '>=', 1440, 'with the minutes recorded');

-- ── the student themselves ────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'stu1', 'tenant_id', :'tenant_id', 'app_role', 'student')::text, true);
select lives_ok(format($$ select public.begin_submission(%L, %L, 'My own words') $$, :'hw', :'e1'), 'the student can submit for themselves');

-- ── AC4: a checked submission is final ────────────────────────────────────
reset role;
update public.homework_submission set status = 'checked', feedback_code = 'good', checked_by = :'teach_uid', checked_at = now(), pending_version = null, pending_text = null where id = :'sub'::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'par1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select throws_ok(format($$ select public.begin_submission(%L, %L, 'again') $$, :'hw', :'e1'), 'SUBMISSION_CHECKED', 'AC4: a checked submission cannot be resubmitted');
select throws_ok(format($$ select public.add_submission_file(%L, 'late.jpg', 'image/jpeg', 100) $$, :'sub'), 'SUBMISSION_CHECKED', 'nor extended with files');

-- ── storage policy and isolation ──────────────────────────────────────────
select lives_ok(format($$ insert into storage.objects (bucket_id, name, owner) values ('homework-submissions', %L, %L) $$, :'path1', :'par1'), 'the reserved path can be written by the submitter');
select throws_ok(format($$ insert into storage.objects (bucket_id, name, owner) values ('homework-submissions', %L, %L) $$, :'tenant_id' || '/x/y/z/file.jpg', :'par1'), '42501', null, 'any other path is blocked');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.homework_submission), 0::bigint, 'another school sees no submissions');

select * from finish();
rollback;
