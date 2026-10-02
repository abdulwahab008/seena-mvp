-- pgTAP tests for FR-H02: homework attachments with size and type limits.
begin;
select plan(23);

select public.provision_tenant('test-hwatt-co', 'Homework Attach Co', 'owner@hwatt.test');
select id as tenant_id from public.tenant where slug = 'test-hwatt-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-hwatt-other', 'Other Homework Co', 'owner@otherhwatt.test');
select id as other_tenant_id from public.tenant where slug = 'test-hwatt-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as t1_uid \gset
select gen_random_uuid() as t2_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@hwatt.test', 'authenticated', 'authenticated', 'x'), (:'t1_uid', 't1@hwatt.test', 'authenticated', 'authenticated', 'x'), (:'t2_uid', 't2@hwatt.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'t1_uid', :'tenant_id', 'subject_teacher', 'Teacher One'), (:'t2_uid', :'tenant_id', 'subject_teacher', 'Teacher Two');
insert into public.subject (tenant_id, code, name_en, name_ur) values (:'tenant_id', 'SCI', 'Science', 'سائنس');
select id as subj from public.subject where tenant_id = :'tenant_id' and code = 'SCI' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Hw Kid', '2015-01-01'::date, 'male') as s1 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid) as e1 \gset
select public.fn_find_or_create_guardian(p_name_en => 'Hw Father', p_phone_e164 => '+923005550001') as g1 \gset
select public.link_guardian(:'s1'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
reset role;
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role) values (:'parent_uid', '923005550001', now(), 'x', 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'parent_uid' where id = :'g1'::uuid;
insert into public.homework (tenant_id, campus_id, session_id, section_id, subject_id, teacher_id, title, due_date, status, published_at)
values (:'tenant_id', :'campus_id', :'session_id', :'section_id', :'subj', :'t1_uid', 'Chapter 4 worksheet', current_date + 3, 'draft', null) returning id as hw \gset

-- ── limits ────────────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'t1_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.register_homework_attachment(%L, 'big.pdf', 'application/pdf', 6291456) $$, :'hw'), 'FILE_EXCEEDS_5MB', 'AC1: a 6 MB file is refused and nothing is registered');
select is((select count(*) from public.homework_attachment), 0::bigint, 'so no row, and therefore no object, exists for it');
select throws_ok(format($$ select public.register_homework_attachment(%L, 'x.exe', 'application/x-msdownload', 100) $$, :'hw'), 'ATTACHMENT_TYPE_NOT_ALLOWED', 'a non-allowed type is refused');
select public.register_homework_attachment(:'hw'::uuid, 'worksheet one.pdf', 'application/pdf', 1000000) ->> 'storage_path' as p1 \gset
select is(:'p1' ~ ('^' || :'tenant_id' || '/' || :'campus_id' || '/' || :'session_id' || '/' || :'hw' || '/[0-9a-f-]{36}\.pdf$'), true, 'the path is tenant/campus/session/homework/uuid.ext');
select public.register_homework_attachment(:'hw'::uuid, 'two.jpg', 'image/jpeg', 2000000);
select public.register_homework_attachment(:'hw'::uuid, 'three.png', 'image/png', 2000000);
select public.register_homework_attachment(:'hw'::uuid, 'four.webp', 'image/webp', 2000000);
select public.register_homework_attachment(:'hw'::uuid, 'five.pdf', 'application/pdf', 5242880);
select throws_ok(format($$ select public.register_homework_attachment(%L, 'six.pdf', 'application/pdf', 100) $$, :'hw'), 'MAX_5_ATTACHMENTS', 'AC2: a sixth attachment is refused');
select is((select count(*) from public.homework_attachment where homework_id = :'hw'::uuid), 5::bigint, 'and exactly five are attached');

-- ── who may attach, who may read ──────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'t2_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.register_homework_attachment(%L, 'a.pdf', 'application/pdf', 100) $$, :'hw'), 'FORBIDDEN', 'another teacher cannot attach to this homework');
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*) from public.homework_attachment), 0::bigint, 'a parent cannot see attachments of a draft');
reset role;
update public.homework set status = 'published', published_at = now() where id = :'hw'::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*) from public.homework_attachment), 5::bigint, 'once published, the parent sees all five');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.homework_attachment), 0::bigint, 'another school sees none');
select throws_ok(format($$ select public.register_homework_attachment(%L, 'a.pdf', 'application/pdf', 100) $$, :'hw'), 'HOMEWORK_NOT_FOUND', 'and cannot attach to this homework');

-- ── storage policy: only a reserved path can be written ───────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'t1_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select lives_ok(format($$ insert into storage.objects (bucket_id, name, owner) values ('homework-attachments', %L, %L) $$, :'p1', :'t1_uid'), 'the reserved path can be written');
select throws_ok(format($$ insert into storage.objects (bucket_id, name, owner) values ('homework-attachments', %L, %L) $$, :'tenant_id' || '/elsewhere/file.pdf', :'t1_uid'), '42501', null, 'AC3: an object at any other path is blocked by the storage policy');
select is((select count(*) from storage.objects where bucket_id = 'homework-attachments' and name = :'p1'), 1::bigint, 'the uploader can read the reserved object');

-- ── cleanup: removing a row or the homework queues the objects ────────────
select public.remove_homework_attachment((select id from public.homework_attachment where original_filename = 'two.jpg'));
reset role;
select is((select count(*) from public.storage_delete_queue where path like '%.jpg' and done_at is null), 1::bigint, 'removing an attachment queues its object for deletion');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'t1_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.delete_homework(:'hw'::uuid);
reset role;
select is((select count(*) from public.homework_attachment where homework_id = :'hw'::uuid), 0::bigint, 'AC5: deleting the homework removes its attachment rows');
select is((select count(*) from public.storage_delete_queue where bucket = 'homework-attachments' and done_at is null and path like :'tenant_id' || '/%'), 5::bigint, 'AC5: and queues all five objects for removal');
set local role service_role;
select is((select count(*) from public.claim_storage_deletes(100) where path like :'tenant_id' || '/%'), 5::bigint, 'the worker claims them');
select public.complete_storage_delete(id) from public.storage_delete_queue where path like :'tenant_id' || '/%';
reset role;
select is((select count(*) from public.storage_delete_queue where path like :'tenant_id' || '/%' and done_at is not null), 5::bigint, 'and marks them done');

-- ── orphan sweep ──────────────────────────────────────────────────────────
insert into storage.objects (bucket_id, name, owner, created_at) values
  ('homework-attachments', :'tenant_id' || '/orphan/old.pdf', null, now() - interval '3 hours'),
  ('homework-attachments', :'tenant_id' || '/orphan/new.pdf', null, now());
select public.homework_orphan_sweep() as swept \gset
select cmp_ok(:'swept'::int, '>=', 1, 'the sweep finds the old orphan object');
select is((select count(*) from public.storage_delete_queue where path = :'tenant_id' || '/orphan/old.pdf'), 1::bigint, 'it is queued for deletion');
select is((select count(*) from public.storage_delete_queue where path = :'tenant_id' || '/orphan/new.pdf'), 0::bigint, 'an upload still in flight is left alone');
select is(has_function_privilege('authenticated', 'public.claim_storage_deletes(int)', 'execute'), false, 'a signed-in user cannot drain the queue');

select * from finish();
rollback;
