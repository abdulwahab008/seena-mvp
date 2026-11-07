begin;
select plan(18);

select public.provision_tenant('test-accounts-co', 'Accounts Co', 'owner@accounts.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-accounts-other', 'Other Co', 'owner@other.test') as other_tenant \gset

insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role, created_at) values
  ('00000000-0000-4000-8000-0000000000b1', 'owner@accounts.test', '', now(), 'authenticated', 'authenticated', now()),
  ('00000000-0000-4000-8000-0000000000b2', 'principal@accounts.test', '', now(), 'authenticated', 'authenticated', now()),
  ('00000000-0000-4000-8000-0000000000b3', 'ahmed.t@test-accounts-co.users.seena.local', '', now(), 'authenticated', 'authenticated', now()),
  ('00000000-0000-4000-8000-0000000000b4', 'old@accounts.test', '', now(), 'authenticated', 'authenticated', now() - interval '1 day'),
  ('00000000-0000-4000-8000-0000000000b5', 'someone@other.test', '', now(), 'authenticated', 'authenticated', now());
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  ('00000000-0000-4000-8000-0000000000b1', :'tenant_id', 'owner', 'Owner'),
  ('00000000-0000-4000-8000-0000000000b2', :'tenant_id', 'principal', 'Principal'),
  ('00000000-0000-4000-8000-0000000000b5', :'other_tenant', 'subject_teacher', 'Other Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000b1', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select is(public.user_account_login_email('Ahmed.T', 'subject_teacher', array[:'campus_id'::uuid]),
  'ahmed.t@test-accounts-co.users.seena.local', 'a username maps to the school''s hidden login address');
select throws_ok($$ select public.user_account_login_email('a b', 'subject_teacher', '{}') $$, '22023', 'USERNAME_INVALID', 'a username with a space is refused');
select throws_ok($$ select public.user_account_login_email('boss', 'super_admin', '{}') $$, '42501', 'FORBIDDEN', 'an owner cannot create a super admin');

select lives_ok(format($$ select public.create_user_account('00000000-0000-4000-8000-0000000000b3', 'Ahmed Tariq', 'subject_teacher', array[%L::uuid], 'ahmed.t') $$, :'campus_id'),
  'an owner creates a teacher login with a username');
select throws_ok($$ select public.user_account_login_email('ahmed.t', 'subject_teacher', '{}') $$, '23505', 'USERNAME_TAKEN', 'the username is now taken in this school');
select throws_ok($$ select public.create_user_account('00000000-0000-4000-8000-0000000000b4', 'Old', 'subject_teacher', '{}', null) $$, '42501', 'ACCOUNT_NOT_LINKABLE', 'an older existing account cannot be pulled in');
select throws_ok($$ select public.create_user_account('00000000-0000-4000-8000-0000000000b5', 'Other', 'subject_teacher', '{}', null) $$, '42501', 'ACCOUNT_NOT_LINKABLE', 'another school''s account cannot be pulled in');

select is((select count(*)::int from public.list_user_accounts() where kind = 'staff'), 3, 'the list shows the school''s staff logins');
select is((select login_id from public.list_user_accounts() where user_id = '00000000-0000-4000-8000-0000000000b3'), 'ahmed.t@test-accounts-co', 'a username login shows as username@school');

select lives_ok($$ select public.set_user_account_active('00000000-0000-4000-8000-0000000000b3', false) $$, 'an owner deactivates a teacher');
reset role;
select is((select status::text from public.app_user where user_id = '00000000-0000-4000-8000-0000000000b3'), 'suspended', 'the teacher login is off');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000b1', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select lives_ok($$ select public.set_user_account_role('00000000-0000-4000-8000-0000000000b3', 'class_teacher') $$, 'an owner changes a teacher''s role');

select throws_ok($$ select public.user_account_kind('00000000-0000-4000-8000-0000000000b5') $$, '42501', 'FORBIDDEN', 'another school''s login cannot be managed');

reset role;
update public.app_user set status = 'terminated' where user_id = '00000000-0000-4000-8000-0000000000b3';
set local role authenticated;
select throws_ok($$ select public.set_user_account_active('00000000-0000-4000-8000-0000000000b3', true) $$, '22023', 'ACCOUNT_TERMINATED', 'a staff member who left cannot be turned back on');

-- a principal limited to another campus cannot manage this campus's staff
reset role;
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'DHA', 'DHA') returning id as dha_id \gset
update public.app_user set status = 'active' where user_id = '00000000-0000-4000-8000-0000000000b3';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000b2', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'dha_id'))::text, true);
select throws_ok($$ select public.user_account_kind('00000000-0000-4000-8000-0000000000b3') $$, '42501', 'FORBIDDEN', 'a principal cannot manage logins on another campus');
select is((select count(*)::int from public.list_user_accounts() where user_id = '00000000-0000-4000-8000-0000000000b3'), 0, 'nor see them in the list');

-- a principal cannot manage the owner, or themselves
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000b2', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.set_user_account_active('00000000-0000-4000-8000-0000000000b1', false) $$, '42501', 'FORBIDDEN', 'a principal cannot turn off the owner');

-- a teacher cannot see the list
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000b3', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select * from public.list_user_accounts() $$, '42501', 'FORBIDDEN', 'a teacher cannot list accounts');

select * from finish();
rollback;
