begin;
select plan(9);

select public.provision_tenant('test-downloads-co', 'Downloads Co', 'owner@downloads.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select gen_random_uuid() as teacher_uid \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'teacher_uid', 'teacher@downloads.test', 'authenticated', 'authenticated', 'x'),
  (:'parent_uid', 'parent@downloads.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'teacher_uid', :'tenant_id', 'owner', 'Staff');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teacher_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as sec_a \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 20) as sec_b \gset
select public.create_student(:'campus_id'::uuid, 'Download Kid', '2016-01-01'::date, 'male') as kid \gset
select public.enrol_student(:'sec_a'::uuid, :'kid'::uuid);

reset role;
insert into public.guardian (tenant_id, name_en, auth_user_id) values (:'tenant_id', 'Download Parent', :'parent_uid') returning id as guardian_id \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing, portal_access)
values (:'tenant_id', :'kid', :'guardian_id', 'father', true, true, true);
set local role authenticated;

select set_config('request.jwt.claims', json_build_object('sub', :'teacher_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select (public.register_download_item(:'campus_id', 'syllabus', 'Whole campus syllabus', null, null, 'syllabus.pdf', 'application/pdf', 1000) ->> 'id') as all_id \gset
select (public.register_download_item(:'campus_id', 'material', 'Section A notes', :'class1_id', :'sec_a', 'a.pdf', 'application/pdf', 1000) ->> 'id') as a_id \gset
select (public.register_download_item(:'campus_id', 'material', 'Section B notes', :'class1_id', :'sec_b', 'b.pdf', 'application/pdf', 1000) ->> 'id') as b_id \gset
select is((select count(*)::int from public.download_item), 3, 'a teacher shares files with the campus, a class and a section');

select throws_ok(format($$ select public.register_download_item(%L, 'other', 'x', null, null, 'x.exe', 'application/x-msdownload', 10) $$, :'campus_id'), '23514', null, 'only document and image types are accepted');

select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.portal_download_items()), 2, 'a parent sees the campus file and their child''s section file');
select is((select count(*)::int from public.portal_download_items() where title = 'Section B notes'), 0, 'but not another section''s file');
select is((select count(*)::int from public.download_item_path(:'b_id')), 0, 'and cannot fetch another section''s file directly');
select is((select count(*)::int from public.download_item_path(:'a_id')), 1, 'a parent can fetch their child''s file');
select is((select count(*)::int from public.download_item), 0, 'parents cannot read the table itself');

select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.delete_download_item(%L) $$, :'a_id'), '42501', 'FORBIDDEN', 'a receptionist cannot delete shared files');

select set_config('request.jwt.claims', json_build_object('sub', :'teacher_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.delete_download_item(:'a_id');
reset role;
select is((select count(*)::int from public.storage_delete_queue where bucket = 'downloads' and done_at is null and path like '%' || :'a_id' || '%'), 1, 'deleting a file queues its object for removal');

select * from finish();
rollback;
