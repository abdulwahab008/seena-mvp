-- pgTAP: owners and super admins are linked to every campus of their school, including new ones.
begin;
select plan(3);

select public.provision_tenant('test-link-owner', 'Link Owner Co', 'owner@linkowner.test');
select id as tenant_id from public.tenant where slug = 'test-link-owner' \gset
select gen_random_uuid() as owner_uid, gen_random_uuid() as acct_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@linkowner.test', 'authenticated', 'authenticated', 'x'),
  (:'acct_uid', 'a@linkowner.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Link Owner'),
  (:'acct_uid', :'tenant_id', 'accountant', 'Link Accountant');

insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'NEW', 'New Campus');
select id as new_campus from public.campus where tenant_id = :'tenant_id' and code = 'NEW' \gset

select ok(exists (select 1 from public.user_campus where user_id = :'owner_uid' and campus_id = :'new_campus'), 'a new campus is linked to the owner');
select ok(not exists (select 1 from public.user_campus where user_id = :'acct_uid'), 'an accountant is not linked automatically');
select is((select count(*)::int from public.user_campus where user_id = :'owner_uid' and campus_id = :'new_campus'), 1, 'linked once');

select * from finish();
rollback;
