-- A section's homeroom is set through set_section_home_room(), not a direct UPDATE RLS discards.
begin;
select plan(4);

select public.provision_tenant('test-homeroom-co', 'Homeroom Co', 'owner@homeroom.test');
select id as tenant_id from public.tenant where slug = 'test-homeroom-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' limit 1 \gset
select id as class_id from public.class_level where tenant_id = :'tenant_id' order by ordinal limit 1 \gset

insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
values (:'tenant_id', :'campus_id', :'session_id', :'class_id', 'A', 30) returning id as section_id \gset
insert into public.room (tenant_id, campus_id, code, name, room_type, capacity)
values (:'tenant_id', :'campus_id', 'R1', 'Room 1', 'CLASSROOM', 30) returning id as room_id \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@homeroom.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'owner_uid', :'tenant_id', 'owner', 'Homeroom Owner');

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text, true);

-- The old path: a direct UPDATE changes nothing under RLS.
update public.class_section set home_room_id = :'room_id' where id = :'section_id';
select is((select home_room_id from public.class_section where id = :'section_id'), null::uuid,
  'a direct UPDATE is still discarded by RLS');

select lives_ok(format($$ select public.set_section_home_room(%L, %L) $$, :'section_id', :'room_id'),
  'an owner sets the homeroom through the function');
select is((select home_room_id from public.class_section where id = :'section_id'), :'room_id'::uuid,
  'and the section now has it');

select set_config('request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text, true);
select throws_ok(format($$ select public.set_section_home_room(%L, null) $$, :'section_id'), '42501', 'FORBIDDEN',
  'a subject teacher cannot change it');

select * from finish();
rollback;
