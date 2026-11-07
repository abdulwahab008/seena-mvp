begin;
select plan(8);

select public.provision_tenant('test-front-desk-co', 'Front Desk Co', 'owner@frontdesk.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'DHA', 'DHA') returning id as dha_id \gset
select gen_random_uuid() as uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'uid', 'reception@frontdesk.test', 'authenticated', 'authenticated', 'x');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select public.log_front_desk_entry(:'campus_id'::uuid, 'visitor', 'Mr Khan', '03001234567', 'Meet principal', 'Principal', '35202-1234567-1') as visit_id \gset
select is((select count(*)::int from public.front_desk_entry where kind = 'visitor' and closed_at is null), 1, 'a receptionist logs a visitor who is inside');
select lives_ok(format($$ select public.close_front_desk_entry(%L, 'Left at 11') $$, :'visit_id'), 'the visitor is signed out');
select isnt((select closed_at from public.front_desk_entry where id = :'visit_id'), null, 'the time out is recorded');
select throws_ok(format($$ select public.close_front_desk_entry(%L) $$, :'visit_id'), 'P0002', 'ENTRY_NOT_FOUND', 'an entry cannot be closed twice');
select throws_ok(format($$ select public.log_front_desk_entry(%L, 'call', 'Parent') $$, :'dha_id'), '42501', 'FORBIDDEN', 'another campus''s register is out of scope');

select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.front_desk_entry), 0, 'a teacher cannot read the front desk registers');
select throws_ok(format($$ select public.log_front_desk_entry(%L, 'parcel', 'TCS') $$, :'campus_id'), '42501', 'FORBIDDEN', 'a teacher cannot write to them');

select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.front_desk_entry), 0, 'parents cannot read the registers');

select * from finish();
rollback;
