-- pgTAP tests for link_staff_user_account (enabling piece for FR-
-- D10/D11/D12/C05's "the logged-in user's own staff record" RLS checks).
begin;
select plan(6);

select public.provision_tenant('test-link-staff-co', 'Link Staff Co', 'owner@linkstaffco.test');
select id as tenant_id from public.tenant where slug = 'test-link-staff-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@linkstaffco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'teacher_user_id', :'tenant_id', 'subject_teacher', 'Linked Teacher');

select public.provision_tenant('test-link-staff-other', 'Other Co', 'owner@linkstaffother.test');
select gen_random_uuid() as other_owner_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_owner_id', 'owner2@linkstaffother.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_owner_id', (select id from public.tenant where slug = 'test-link-staff-other'), 'owner', 'Other Owner');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_staff(:'campus_id'::uuid, 'Linked Teacher', 'female', p_cnic => '4210112340041') as staff_id \gset
select is(
  (select user_id from public.staff where id = :'staff_id'),
  null,
  'a staff record created without a login has no user_id'
);

select public.link_staff_user_account(:'staff_id'::uuid, :'teacher_user_id'::uuid);
select is(
  (select user_id from public.staff where id = :'staff_id'),
  :'teacher_user_id'::uuid,
  'linking sets user_id to the given auth account'
);

select public.create_staff(:'campus_id'::uuid, 'Second Teacher', 'male', p_cnic => '4210112340042') as staff2_id \gset
select throws_ok(format('select public.link_staff_user_account(%L, %L)', :'staff2_id', :'teacher_user_id'), 'USER_ALREADY_LINKED', 'one login cannot sit on two staff records');
select throws_ok(format('select public.link_staff_user_account(%L, %L)', :'staff2_id', :'other_owner_id'), 'USER_NOT_FOUND', 'a login from another school cannot be linked');
select public.link_staff_user_account(:'staff_id'::uuid, null);
select is((select user_id from public.staff where id = :'staff_id'), null, 'passing no login unlinks the staff record');

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.link_staff_user_account(%L, %L)', :'staff_id', :'teacher_user_id'),
  'FORBIDDEN',
  'a subject teacher cannot link staff accounts — HR/Owner only'
);

select * from finish();
rollback;
