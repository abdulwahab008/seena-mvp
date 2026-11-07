begin;
select plan(7);

select public.provision_tenant('test-smsgw-co', 'SMS GW Co', 'owner@smsgw.test') as tenant_id \gset
select gen_random_uuid() as uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'uid', 'o@smsgw.test', 'authenticated', 'authenticated', 'x');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);
select throws_ok($$ select public.save_sms_gateway('SEENA', '{"url":"http://x.pk","method":"GET","keyParam":"k","senderParam":"s","toParam":"t","textParam":"m"}'::jsonb, 'secret') $$,
  '22023', 'URL_INVALID', 'only https gateways are accepted');
select throws_ok($$ select public.save_sms_gateway('SEENA', '{"url":"https://x.pk","method":"GET","keyParam":"k","senderParam":"s","toParam":"t","textParam":"m"}'::jsonb) $$,
  '22023', 'API_KEY_REQUIRED', 'the first save needs the API key');
select lives_ok($$ select public.save_sms_gateway('SEENA', '{"url":"https://x.pk/send","method":"GET","keyParam":"k","senderParam":"s","toParam":"t","textParam":"m"}'::jsonb, 'secret-123') $$,
  'the owner saves the gateway');
select is((select has_key from public.sms_gateway_settings()), true, 'settings say a key is saved');
select ok(not exists (select 1 from public.sms_gateway_settings() s where s.config::text like '%secret-123%'), 'without ever returning it');

reset role;
select is((select api_key from public.sms_gateway_for_dispatch(:'tenant_id')), 'secret-123', 'the worker can read the key');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'principal')::text, true);
select throws_ok($$ select * from public.sms_gateway_for_dispatch(app.auth_tenant_id()) $$, '42501', null, 'a signed-in user cannot read the key');

select * from finish();
rollback;
