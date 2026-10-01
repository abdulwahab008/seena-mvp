-- pgTAP tests for FR-D16 AC3 (gap): after an exit completes, a departing
-- teacher's still-cached token is refused when they try to enter marks, and an
-- exit that is not completed leaves the same token working.
begin;
select plan(3);

select public.provision_tenant('test-exit-tok-co', 'Exit Token Co', 'owner@exittok.test');
select id as tenant_id from public.tenant where slug = 'test-exit-tok-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

select gen_random_uuid() as hr_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'hr_uid', 'h@exittok.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@exittok.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'hr_uid', :'tenant_id', 'hr_manager', 'HR'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Leaving Teacher');
insert into public.staff (tenant_id, campus_id, user_id, employee_code, cnic, gender, full_name) values
  (:'tenant_id', :'campus_id', :'teach_uid', 'XT-1', '42101-3333333-1', 'female', 'Leaving Teacher');
select id as s1 from public.staff where employee_code = 'XT-1' and tenant_id = :'tenant_id' \gset
select claims_version as old_cv from public.app_user where user_id = :'teach_uid' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_staff_contract(:'s1'::uuid, 'permanent', '2026-04-01'::date, null, 30::smallint, 80000);
select public.initiate_staff_exit(:'s1'::uuid, 'resignation', current_date - 40, current_date - 1, 'Moving abroad') as ex \gset

select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'cv', :'old_cv'::int, 'campus_ids', json_build_array(:'campus_id'))::text, true);

select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.waive_exit_item(:'ex'::uuid, item_code, 'Waived for token test run') from public.staff_clearance_item where exit_id = :'ex'::uuid;
select public.complete_staff_exit(:'ex'::uuid);

-- the cached token (old claims epoch) is refused for mark entry
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'cv', :'old_cv'::int, 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.fn_upsert_marks('[]'::jsonb) $$, '28000', 'TOKEN_EPOCH_STALE', 'AC3: the cached token is rejected when the departed teacher enters marks');
select throws_ok($$ select count(*) from public.mark_entry $$, '28000', 'TOKEN_EPOCH_STALE', 'AC3: and the mark table cannot even be read with it');
reset role;
select is((select status::text from public.app_user where user_id = :'teach_uid'), 'terminated', 'the login itself is terminated');

select * from finish();
rollback;
