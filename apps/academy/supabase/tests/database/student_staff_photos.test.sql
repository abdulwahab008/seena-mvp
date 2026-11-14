-- pgTAP: who may set a student's or staff member's photo, and that the path must be the record's own folder.
begin;
select plan(8);

select public.provision_tenant('test-photos', 'Photo Co', 'owner@photo.test');
select id as tenant_id from public.tenant where slug = 'test-photos' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select gen_random_uuid() as owner_uid, gen_random_uuid() as acct_uid, gen_random_uuid() as hr_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@photo.test', 'authenticated', 'authenticated', 'x'),
  (:'acct_uid', 'a@photo.test', 'authenticated', 'authenticated', 'x'),
  (:'hr_uid', 'h@photo.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'acct_uid', :'tenant_id', 'accountant', 'Acct'), (:'hr_uid', :'tenant_id', 'hr_manager', 'HR');
insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, full_name) values (:'tenant_id', :'campus_id', 'E1', '35202-1234567-1', 'male', 'Teacher One') returning id as staff_id \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_student(:'campus_id'::uuid, 'Photo Kid', '2015-01-01'::date, 'male') as student_id \gset
select format('%s/%s/%s-1.jpg', :'tenant_id', :'campus_id', :'student_id') as p1, format('%s/%s/%s-2.jpg', :'tenant_id', :'campus_id', :'student_id') as p2 \gset

select is(public.set_student_photo(:'student_id'::uuid, :'p1'), null, 'an owner sets the first photo');
select is(public.set_student_photo(:'student_id'::uuid, :'p2'), :'p1', 'replacing it returns the old path to remove');
select throws_ok(format('select public.set_student_photo(%L, %L)', :'student_id', :'tenant_id' || '/' || :'campus_id' || '/someone-else.jpg'), 'PHOTO_PATH_INVALID', 'a path outside the student''s own name is refused');
select is((select photo_path from public.student where id = :'student_id'::uuid), :'p2', 'the student keeps the latest photo');

select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format('select public.set_student_photo(%L, null)', :'student_id'), 'FORBIDDEN', 'an accountant cannot change a student photo');
select throws_ok(format('select public.set_staff_photo(%L, null)', :'staff_id'), 'FORBIDDEN', 'nor a staff photo');

select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.set_staff_photo(:'staff_id'::uuid, format('%s/%s/%s-9.jpg', :'tenant_id', :'campus_id', :'staff_id')), null, 'HR sets a staff photo');
select is(public.set_staff_photo(:'staff_id'::uuid, null), format('%s/%s/%s-9.jpg', :'tenant_id', :'campus_id', :'staff_id'), 'and can remove it');

select * from finish();
rollback;
