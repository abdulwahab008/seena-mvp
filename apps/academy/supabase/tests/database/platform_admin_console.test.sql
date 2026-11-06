begin;
select plan(13);

select public.provision_tenant('test-platform-co', 'Platform Co', 'owner@platform.test') as tenant_id \gset

insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values ('00000000-0000-4000-8000-0000000000a1', 'pa@platform.test', '', now(), 'authenticated', 'authenticated'),
       ('00000000-0000-4000-8000-0000000000a2', 'owner@platform.test', '', now(), 'authenticated', 'authenticated');
insert into public.platform_admin (user_id) values ('00000000-0000-4000-8000-0000000000a1');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values ('00000000-0000-4000-8000-0000000000a2', :'tenant_id', 'owner', 'Platform Owner');

-- a school owner is not a platform admin
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000a2', 'tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);
select throws_ok($$ select * from public.platform_list_tenants() $$, '42501', 'FORBIDDEN', 'a school owner cannot list schools');
select throws_ok(format($$ select public.platform_set_tenant_status(%L, 'suspended', 'x') $$, :'tenant_id'), '42501', 'FORBIDDEN', 'a school owner cannot suspend a school');
select is((select count(*)::int from public.platform_admin), 0, 'a school owner sees no platform admin rows');
select is(public.is_platform_admin(), false, 'is_platform_admin is false for an owner');

-- the platform admin
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000a1')::text, true);
select is(public.is_platform_admin(), true, 'is_platform_admin is true for a platform admin');
select is((select owner_name from public.platform_list_tenants() where id = :'tenant_id'::uuid), 'Platform Owner', 'the list shows the school and its owner');
select isnt(public.platform_provision_tenant('test-platform-two', 'Platform Two', 'two@platform.test'), null, 'a platform admin creates a school');
select throws_ok(format($$ select public.platform_set_tenant_status(%L, 'suspended', '  ') $$, :'tenant_id'), '22023', 'REASON_REQUIRED', 'a reason is required');

select public.platform_set_tenant_status(:'tenant_id', 'suspended', 'Unpaid invoice');
reset role;
select is((select status::text from public.tenant where id = :'tenant_id'::uuid), 'suspended', 'the school is suspended');
select is((select claims_version from public.app_user where user_id = '00000000-0000-4000-8000-0000000000a2'), 2, 'staff tokens are made stale');
select ok((public.custom_access_token_hook(jsonb_build_object('user_id', '00000000-0000-4000-8000-0000000000a2', 'claims', '{}'::jsonb)) #>> '{claims,tenant_id}') is null,
  'a suspended school''s owner gets a token with no tenant');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000a1')::text, true);
select public.platform_set_tenant_status(:'tenant_id', 'active', 'Paid');
reset role;
select is(public.custom_access_token_hook(jsonb_build_object('user_id', '00000000-0000-4000-8000-0000000000a2', 'claims', '{}'::jsonb)) #>> '{claims,tenant_id}',
  :'tenant_id', 'a reactivated school''s owner gets their tenant back');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000a1')::text, true);
select public.platform_set_tenant_status(:'tenant_id', 'closed', 'Left Seena');
select throws_ok(format($$ select public.platform_set_tenant_status(%L, 'active', 'oops') $$, :'tenant_id'), '22023', 'TENANT_CLOSED', 'a closed school stays closed');

select * from finish();
rollback;
