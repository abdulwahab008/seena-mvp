begin;
select plan(11);

select public.provision_tenant('test-invite-user', 'Invite User School', 'owner@inviteuser.test') as tenant_id \gset
insert into public.tenant_invitation (tenant_id, email, app_role) values (:'tenant_id', 'newteacher@inviteuser.test', 'subject_teacher') returning token as tok \gset
select gen_random_uuid() as other_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password, email_confirmed_at) values (:'other_uid', 'taken@inviteuser.test', 'authenticated', 'authenticated', 'x', now());
insert into public.app_user (user_id, tenant_id, app_role, full_name, username) values (:'other_uid', :'tenant_id', 'accountant', 'Taken Name', 'ahmed');

-- Server-side helpers (service_role only).
set local role service_role;
select is((select valid::text || ' ' || (user_id is null)::text from public.invite_account_state(:'tok')), 'true true', 'a fresh invitation has no account yet');
select is(public.invite_username_check(:'tok', 'Ahmed'), 'taken', 'a username already used in the school is taken, whatever its case');
select is(public.invite_username_check(:'tok', 'x'), 'invalid', 'a username needs 3 to 32 letters or digits');
select is(public.invite_username_check(:'tok', 'sana.k'), 'ok', 'a free username is available');
select is(public.resolve_username_login('AHMED', 'test-invite-user'), 'taken@inviteuser.test', 'username@school resolves to the login address');
select is(public.resolve_username_login('ahmed', 'no-such-school'), null, 'only within that school');
reset role;

set local role authenticated;
select throws_ok($$ select * from public.invite_account_state('x') $$, '42501', null, 'the browser cannot read invitation account state');
select throws_ok($$ select public.resolve_username_login('ahmed', 'test-invite-user') $$, '42501', null, 'or resolve usernames');

-- A member sets their own name and username.
select set_config('request.jwt.claims', json_build_object('sub', :'other_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant')::text, true);
select public.update_my_profile('Ahmed Raza', 'ahmed.r');
reset role;
select is((select full_name || ' ' || username from public.app_user where user_id = :'other_uid'), 'Ahmed Raza ahmed.r', 'name and username are saved');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'other_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant')::text, true);
select throws_ok($$ select public.update_my_profile('Ahmed Raza', 'A') $$, '22023', 'USERNAME_INVALID', 'a bad username is refused');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid())::text, true);
select throws_ok($$ select public.update_my_profile('Nobody', null) $$, '42501', 'FORBIDDEN', 'someone with no school cannot');

select * from finish();
rollback;
