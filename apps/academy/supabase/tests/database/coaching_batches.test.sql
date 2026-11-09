begin;
select plan(16);

select date_trunc('month', current_date)::date as m0 \gset

select public.provision_tenant('test-coaching', 'Coaching Co', 'owner@coaching.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'NORTH', 'North Campus') returning id as campus_b \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, full_name)
values (:'tenant_id', :'campus_id', 'T-1', '35202-1234567-1', 'female', 'Ayesha Teacher') returning id as teacher \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as acct_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@coaching.test', 'authenticated', 'authenticated', 'x'), (:'acct_uid', 'a@coaching.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'acct_uid', :'tenant_id', 'accountant', 'Accountant');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Hamza One', '2015-01-01'::date, 'male') as s1 \gset
select public.create_student(:'campus_id'::uuid, 'Sana Two', '2015-01-01'::date, 'female') as s2 \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid) as e1 \gset
select public.enrol_student(:'section_id'::uuid, :'s2'::uuid) as e2 \gset

-- Batches.
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_coaching_batch(:'campus_id'::uuid, 'Evening Maths', 'Mathematics', :'teacher'::uuid, 200000, 'Mon-Thu 5-6pm') as batch \gset
select is((select monthly_fee_paisa from public.coaching_batch where id = :'batch'), 200000::bigint, 'a batch records its monthly fee');
select throws_ok(format($$ select public.save_coaching_batch(%L, 'evening maths', null, null, 0, null) $$, :'campus_id'), '23505', 'BATCH_DUPLICATE', 'batch names are unique per campus');
select throws_ok(format($$ select public.save_coaching_batch(%L, 'North Batch', null, null, 0, null) $$, :'campus_b'), '42501', 'FORBIDDEN', 'an accountant cannot run another campus''s batches');
select public.save_coaching_batch(:'campus_id'::uuid, 'Evening Maths', 'Mathematics', :'teacher'::uuid, 250000, 'Mon-Fri 5-6pm', true, :'batch'::uuid);
select is((select monthly_fee_paisa || ' ' || schedule from public.coaching_batch where id = :'batch'), '250000 Mon-Fri 5-6pm', 'a batch can be edited');

-- Enrolment.
select public.enrol_coaching_student(:'batch'::uuid, :'s1'::uuid, :'m0'::date) as ce1 \gset
select throws_ok(format($$ select public.enrol_coaching_student(%L, %L, null) $$, :'batch', :'s1'), '23505', 'ALREADY_ENROLLED', 'a student is enrolled in a batch once at a time');
select public.save_coaching_batch(:'campus_id'::uuid, 'Old Batch', null, null, 100000, null, false) as old_batch \gset
select throws_ok(format($$ select public.enrol_coaching_student(%L, %L, null) $$, :'old_batch', :'s2'), '55000', 'BATCH_INACTIVE', 'an inactive batch takes no students');

-- Posting the month bills the batch fee as a COACHING ledger debit, once.
select is(public.post_coaching_charges(:'m0'::date), 1, 'one coaching charge is posted for the month');
select is(public.post_coaching_charges(:'m0'::date), 0, 're-posting the month adds nothing');
select is((select amount_paisa from public.fee_ledger l join public.fee_head h on h.id = l.fee_head_id
            where l.enrolment_id = :'e1'::uuid and h.code = 'COACHING'), 250000::bigint, 'the charge is the batch fee under the COACHING head');

-- And the challan carries it as its own line.
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, :'m0'::date) as run1 \gset
select is((:'run1'::jsonb ->> 'failed')::int, 0, 'challans generate without failures');
select id as c1 from public.fee_challan where enrolment_id = :'e1'::uuid and billing_period = :'m0'::date \gset
select is((select net_paisa from public.fee_challan_line l join public.fee_head h on h.id = l.fee_head_id where l.challan_id = :'c1' and h.code = 'COACHING'), 250000::bigint, 'the challan has a COACHING line');
select is((select net_paisa from public.fee_challan where id = :'c1'), 750000::bigint, 'the challan total is tuition plus coaching, with no double count');
select is((select count(*)::int from public.fee_challan_line l join public.fee_head h on h.id = l.fee_head_id
            join public.fee_challan c on c.id = l.challan_id where c.enrolment_id = :'e2'::uuid and h.code = 'COACHING'), 0, 'a student not in coaching gets no coaching line');

-- Ending an enrolment.
select throws_ok(format($$ select public.end_coaching_enrolment(%L, %L) $$, :'ce1', (:'m0'::date - 1)::text), '22023', 'DATE_INVALID', 'an enrolment cannot end before it starts');
select public.end_coaching_enrolment(:'ce1'::uuid, :'m0'::date);
select throws_ok(format($$ select public.end_coaching_enrolment(%L, null) $$, :'ce1'), '55000', 'ALREADY_ENDED', 'an ended enrolment stays ended');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.post_coaching_charges(current_date) $$, '42501', 'FORBIDDEN', 'a teacher cannot post coaching fees');

select * from finish();
rollback;
