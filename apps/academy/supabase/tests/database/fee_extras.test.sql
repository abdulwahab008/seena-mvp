begin;
select plan(14);

select public.provision_tenant('test-fee-extras', 'Fee Extras Co', 'owner@feeextras.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select gen_random_uuid() as uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'uid', 'acc@feeextras.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'uid', :'tenant_id', 'accountant', 'Fee Accountant');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.create_student(:'campus_id'::uuid, 'Hamza Ali', '2015-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrol_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
reset role;
select id as challan_id, due_date, billing_period from public.fee_challan where enrolment_id = :'enrol_id' \gset
insert into public.guardian (tenant_id, name_en, phone_e164) values (:'tenant_id', 'Father of Hamza', '+923005550000') returning id as father \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id', :'student_id', :'father', 'father', true, true);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- Installments.
select throws_ok(format($$ select public.set_challan_installments(%L, jsonb_build_array(
  jsonb_build_object('due_date', current_date, 'amount_paisa', 300000), jsonb_build_object('due_date', current_date + 30, 'amount_paisa', 100000))) $$, :'challan_id'),
  '22023', 'PLAN_TOTAL_MISMATCH', 'the parts must add up to the challan');
select throws_ok(format($$ select public.set_challan_installments(%L, jsonb_build_array(
  jsonb_build_object('due_date', current_date + 30, 'amount_paisa', 300000), jsonb_build_object('due_date', current_date, 'amount_paisa', 200000))) $$, :'challan_id'),
  '22023', 'PLAN_DATES_ORDER', 'each part falls due after the last');
select throws_ok(format($$ select public.set_challan_installments(%L, jsonb_build_array(jsonb_build_object('due_date', current_date, 'amount_paisa', 500000))) $$, :'challan_id'),
  '22023', 'PLAN_TOO_SHORT', 'a plan has at least two parts');
select is(public.set_challan_installments(:'challan_id', jsonb_build_array(
  jsonb_build_object('due_date', :'due_date'::date, 'amount_paisa', 300000), jsonb_build_object('due_date', :'due_date'::date + 30, 'amount_paisa', 200000))), 2,
  'a challan splits into two installments');
select is((select string_agg(unpaid_paisa::text, ',' order by seq) from public.installment_status() where challan_id = :'challan_id'), '300000,200000', 'both parts start unpaid');

select public.record_payment(:'enrol_id'::uuid, 350000::bigint, 'cash'::public.fee_payment_mode, 'part');
select is((select string_agg(unpaid_paisa::text, ',' order by seq) from public.installment_status() where challan_id = :'challan_id'), '0,150000',
  'a payment clears the first part and some of the second');
select is((select is_overdue from public.installment_status(:'due_date'::date + 31) where challan_id = :'challan_id' and seq = 2), true,
  'the second part is overdue after its date');
select is((select count(*)::int from public.installment_status(:'due_date'::date + 31) where challan_id = :'challan_id' and is_overdue), 1,
  'and only the second');

-- Fee reminders.
select is(public.queue_fee_slip_messages(:'campus_id', :'billing_period'), '{"queued": 1, "no_phone": 0}'::jsonb, 'one reminder for the unpaid challan');
select is((public.queue_fee_slip_messages(:'campus_id', :'billing_period') ->> 'queued')::int, 0, 'never twice the same day');
reset role;
select matches((select body from public.message where idempotency_key like 'fee-slip:' || :'challan_id' || ':%'), 'PKR 1,500 ', 'the reminder gives what is still due');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- Analytics.
select is((select collected_paisa from public.fee_collection_by_month(current_date, current_date)), 350000::bigint, 'collections are counted in the month received');
select is((select bucket || ' ' || outstanding_paisa from public.fee_outstanding_ageing(:'due_date'::date + 40)), '31-60 days 150000',
  'what is still owed is aged by days past due');

select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.queue_fee_slip_messages(%L, %L) $$, :'campus_id', :'billing_period'), '42501', 'FORBIDDEN', 'teachers cannot send fee reminders');

select * from finish();
rollback;
