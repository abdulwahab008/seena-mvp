begin;
select plan(9);

select public.provision_tenant('test-donors', 'Donors Co', 'owner@donors.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select gen_random_uuid() as uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'uid', 'acc@donors.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'uid', :'tenant_id', 'accountant', 'Donor Accountant');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.create_student(:'campus_id'::uuid, 'Hafiz Bilal', '2014-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrol_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);

select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_donor('Haji Rashid', '+923001112222') as donor_id \gset
select isnt(public.record_donation(:'donor_id', 1000000, current_date, 'bank', 'zakat', 'TT-1'), null, 'a donation is recorded');
select throws_ok(format($$ select public.record_donation(%L, 100, current_date + 1, 'cash', 'general') $$, :'donor_id'), '22023', 'DATE_INVALID', 'not in the future');

select public.save_sponsorship(:'donor_id', :'student_id', 300000) as sponsorship_id \gset
select is(public.save_sponsorship(:'donor_id', :'student_id', 350000), :'sponsorship_id'::uuid, 'saving again updates the same sponsorship');
select is(public.apply_sponsorships(current_date), '{"paid": 1, "total_paisa": 350000}'::jsonb, 'applying pays the sponsored amount');
select is((select status::text from public.fee_challan where enrolment_id = :'enrol_id'), 'part_paid', 'the challan is part paid');
select is((select reference_no from public.fee_payment where enrolment_id = :'enrol_id'), 'Sponsored by Haji Rashid', 'the payment names the donor');
select is(public.apply_sponsorships(current_date), '{"paid": 0, "total_paisa": 0}'::jsonb, 'the same month is never paid twice');

select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.apply_sponsorships(current_date) $$, '42501', 'FORBIDDEN', 'a principal cannot apply sponsorships');
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.donor), 0, 'teachers cannot see donors');

select * from finish();
rollback;
