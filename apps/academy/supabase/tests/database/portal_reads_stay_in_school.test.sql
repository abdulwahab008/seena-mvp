-- School-wide circulars and calendar events are read only by parents of the same school.
begin;
select plan(4);

select public.provision_tenant('test-iso-a', 'Iso School A', 'owner@iso-a.test');
select public.provision_tenant('test-iso-b', 'Iso School B', 'owner@iso-b.test');
select id as tenant_a from public.tenant where slug = 'test-iso-a' \gset
select id as tenant_b from public.tenant where slug = 'test-iso-b' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_a' \gset
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
values (:'tenant_a', :'campus_a', 'ISO-1', 'Iso Child', '2015-01-01', 'male') returning id as child_a \gset

select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'parent_uid', 'parent@iso-a.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'parent_uid', :'tenant_a', 'parent', 'Iso Parent');
insert into public.guardian (tenant_id, auth_user_id, name_en, phone_e164)
values (:'tenant_a', :'parent_uid', 'Iso Parent', '+923001110001') returning id as guardian_a \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_a', :'child_a', :'guardian_a', 'father', true, true);

insert into public.circular (tenant_id, title, body_en, status, publish_at) values
  (:'tenant_a', 'A notice', 'Body', 'published', now() - interval '1 hour'),
  (:'tenant_b', 'B notice', 'Body', 'published', now() - interval '1 hour');
insert into public.campus_event (tenant_id, title, event_type, starts_at, ends_at) values
  (:'tenant_a', 'A sports day', 'sports', now() + interval '1 day', now() + interval '2 days'),
  (:'tenant_b', 'B sports day', 'sports', now() + interval '1 day', now() + interval '2 days');

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', :'parent_uid', 'role', 'authenticated', 'tenant_id', :'tenant_a', 'app_role', 'parent')::text, true);

select is((select count(*)::int from public.circular where title = 'A notice'), 1, 'a parent reads their own school''s school-wide circular');
select is((select count(*)::int from public.circular where title = 'B notice'), 0, 'but not another school''s');
select is((select count(*)::int from public.campus_event where title = 'A sports day'), 1, 'a parent reads their own school''s school-wide event');
select is((select count(*)::int from public.campus_event where title = 'B sports day'), 0, 'but not another school''s');

select * from finish();
rollback;
