begin;
select plan(8);

select public.provision_tenant('test-reg-school', 'Registration Test School', 'owner@regschool.test') as tenant_id \gset
select gen_random_uuid() as admin_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'admin_uid', 'platform@regschool.test', 'authenticated', 'authenticated', 'x');
insert into public.platform_admin (user_id) values (:'admin_uid');

set local role anon;
select isnt(public.submit_school_registration('Al-Noor Grammar', 'Bilal Ahmed', '0300-1234567', 'bilal@alnoor.pk', 'Lahore', 450, 'Two campuses'), null,
  'anyone can ask to join');
select public.submit_school_registration('Al-Noor Grammar', 'Bilal Ahmed', '0300 1234567');
select public.submit_school_registration('Al-Noor Grammar', 'Bilal Ahmed', '03001234567');
select throws_ok($$ select public.submit_school_registration('Al-Noor Grammar', 'Bilal Ahmed', '03001234567') $$, '54000', 'TOO_MANY_REQUESTS',
  'the same phone at most three times a day');
select throws_ok($$ select public.submit_school_registration('X', 'Bilal', '0300') $$, '23514', null, 'a real phone number and school name are required');
select is(public.school_login_name('TEST-REG-SCHOOL'), 'Registration Test School', 'a school code gives its name for the sign-in page');
select throws_ok($$ select count(*) from public.school_registration_request $$, '42501', null, 'the public cannot read requests');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);
select is((select count(*)::int from public.school_registration_request), 0, 'a school owner cannot read requests');
select set_config('request.jwt.claims', json_build_object('sub', :'admin_uid')::text, true);
select is((select count(*)::int from public.school_registration_request where phone = '03001234567'), 3, 'the platform admin sees them, phone numbers normalised');
select id as req_id from public.school_registration_request where phone = '03001234567' limit 1 \gset
select public.platform_set_registration_status(:'req_id', 'contacted');
select is((select status from public.school_registration_request where id = :'req_id'), 'contacted', 'and moves them along');

select * from finish();
rollback;
