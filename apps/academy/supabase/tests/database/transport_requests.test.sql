begin;
select plan(8);

select public.provision_tenant('test-bus-req', 'Bus Request Co', 'owner@busreq.test');
select id as tenant_id from public.tenant where slug = 'test-bus-req' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as tm_uid \gset
select gen_random_uuid() as acc_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@busreq.test', 'authenticated', 'authenticated', 'x'), (:'tm_uid', 'tm@busreq.test', 'authenticated', 'authenticated', 'x'),
  (:'acc_uid', 'a@busreq.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'tm_uid', :'tenant_id', 'transport_manager', 'Transport'), (:'acc_uid', :'tenant_id', 'accountant', 'Accounts');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_student(:'campus_id'::uuid, 'Bus Kid', '2015-01-01'::date, 'male') as s1 \gset
select public.create_student(:'campus_id'::uuid, 'Other Kid', '2015-01-01'::date, 'male') as s2 \gset
select public.fn_find_or_create_guardian(p_name_en => 'Bus Father', p_phone_e164 => '+923008880001') as g1 \gset
select public.link_guardian(:'s1'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
reset role;
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role) values (:'parent_uid', '923008880001', now(), 'x', 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'parent_uid' where id = :'g1';

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select throws_ok(format($$ select public.submit_transport_request(%L, 'start') $$, :'s2'), '42501', 'FORBIDDEN', 'a parent cannot ask for another family''s child');
select public.submit_transport_request(:'s1'::uuid, 'start', null, 'From Dhok Amb') as req \gset
select is((select status from public.transport_request where id = :'req'), 'pending', 'the request is pending');
select throws_ok(format($$ select public.submit_transport_request(%L, 'stop') $$, :'s1'), '23505', 'REQUEST_PENDING', 'one pending request per child');
select is((select count(*)::int from public.transport_request), 1, 'the parent sees their own request');

select set_config('request.jwt.claims', json_build_object('sub', :'acc_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.decide_transport_request(%L, true) $$, :'req'), '42501', 'FORBIDDEN', 'an accountant cannot decide bus requests');

select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select lives_ok(format($$ select public.decide_transport_request(%L, true, 'Route 2 from Monday') $$, :'req'), 'the transport manager approves');
select is((select status || '|' || decision_note from public.transport_request where id = :'req'), 'approved|Route 2 from Monday', 'with the note');
select throws_ok(format($$ select public.decide_transport_request(%L, false) $$, :'req'), '55000', 'REQUEST_NOT_PENDING', 'a decided request cannot be decided again');

select * from finish();
rollback;
