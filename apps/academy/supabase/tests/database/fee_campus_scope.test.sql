-- pgTAP tests: the money functions check the caller's campus, not only their role (FR-A12).
--
-- An accountant, principal or admissions officer assigned to one campus used to be able to post
-- payments and ledger entries, read challans, receipts and balances, approve concessions and move
-- deposits for a student at another campus of the same school, because these SECURITY DEFINER
-- functions checked the role and the tenant but never the campus of the record.
begin;
select plan(56);

select public.provision_tenant('test-fee-campus', 'Fee Campus Co', 'owner@feecampus.test');
select id as tenant_id from public.tenant where slug = 'test-fee-campus' \gset
select id as campus1_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'North Campus', 'NC') returning id as campus2_id \gset
select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'owner_uid', 'o@feecampus.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'owner_uid', :'tenant_id', 'owner', 'Fee Campus Owner');

-- ── fixtures, built by an owner who reaches both campuses ────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus1_id', :'campus2_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset

select public.create_section(:'campus1_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as c1_section \gset
select public.create_section(:'campus2_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as c2_section \gset
select public.create_draft_structure(:'campus1_id'::uuid, :'session_id'::uuid) as c1_structure \gset
select public.add_structure_line(:'c1_structure'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'c1_structure'::uuid);
select public.create_draft_structure(:'campus2_id'::uuid, :'session_id'::uuid) as c2_structure \gset
select public.add_structure_line(:'c2_structure'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'c2_structure'::uuid);

select public.create_student(:'campus1_id'::uuid, 'Main Student A', '2015-01-01'::date, 'male') as c1_student \gset
select public.enrol_student(:'c1_section'::uuid, :'c1_student'::uuid) as c1_enrol \gset
select public.create_student(:'campus1_id'::uuid, 'Main Student B', '2015-01-02'::date, 'female') as c1_student_b \gset
select public.enrol_student(:'c1_section'::uuid, :'c1_student_b'::uuid) as c1_enrol_b \gset
select public.create_student(:'campus2_id'::uuid, 'North Student A', '2015-01-03'::date, 'male') as c2_student \gset
select public.enrol_student(:'c2_section'::uuid, :'c2_student'::uuid) as c2_enrol \gset

select public.generate_challans(:'campus1_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select public.generate_challans(:'campus2_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);

select public.collect_cash_payment((select id from public.fee_challan where enrolment_id = :'c1_enrol'::uuid), 100000, 'fixture-c1') as c1_cash \gset
select (:'c1_cash'::jsonb ->> 'payment_id') as c1_payment, (:'c1_cash'::jsonb ->> 'receipt_id') as c1_receipt \gset

select public.create_concession_scheme('HARDSHIP', 'Hardship', 'مالی مشکلات', 'percentage', 10, array[:'tuition_id']::uuid[],
  p_approver_role => 'principal') as scheme_id \gset
select public.request_concession_award(:'c1_enrol'::uuid, :'scheme_id'::uuid, 10, current_date, current_date + 30) as c1_award \gset
select public.record_security_deposit(:'c1_enrol'::uuid, 500000::bigint, '2026-01-01'::date, 'cash') as c1_deposit \gset
select public.propose_fee_settlement(:'c1_enrol_b'::uuid, (date_trunc('month', current_date)::date + 20), 'half_month') as c1_settlement \gset

create function pg_temp.new_accepted_offer(p_campus uuid, p_phone text, p_child text)
returns uuid language plpgsql as $$
declare v_enquiry uuid; v_app uuid; v_offer uuid;
begin
  v_enquiry := public.create_enquiry(p_campus_id => p_campus, p_session_id => (select id from public.academic_session where tenant_id = app.auth_tenant_id() limit 1),
    p_child_name => p_child, p_dob => '2020-01-01'::date, p_class_applied_id => (select id from public.class_level where tenant_id = app.auth_tenant_id() and code = '1'),
    p_parent_name => 'A Parent', p_phone => p_phone, p_whatsapp_opt_in => false, p_source => 'walk_in');
  v_app := public.fn_submit_application(v_enquiry);
  v_offer := public.fn_issue_offer(v_app, 25000);
  perform public.fn_respond_to_offer(v_offer, 'accepted'::public.offer_status);
  return v_offer;
end;
$$;
select pg_temp.new_accepted_offer(:'campus1_id'::uuid, '03001110001', 'Main Candidate') as c1_offer \gset
select public.record_admission_fee_payment(:'c1_offer'::uuid, 1000000, 'cheque') as c1_adm_payment \gset

select public.fn_find_or_create_guardian(p_name_en => 'Main Father', p_phone_e164 => '+923001110002') as g1 \gset
select public.link_guardian(:'c1_student'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);

reset role;
select id as c1_challan, challan_no as c1_challan_no from public.fee_challan where enrolment_id = :'c1_enrol'::uuid \gset
select id as c1_challan_b, challan_no as c1_challan_no_b from public.fee_challan where enrolment_id = :'c1_enrol_b'::uuid \gset
select id as c2_challan, challan_no as c2_challan_no from public.fee_challan where enrolment_id = :'c2_enrol'::uuid \gset
select id as c1_plan_line from public.fee_plan_line where plan_id = (select id from public.fee_plan where enrolment_id = :'c1_enrol'::uuid) limit 1 \gset
insert into public.hostel_security_deposit (tenant_id, campus_id, student_id, enrolment_id, amount_paisa, charged_on)
values (:'tenant_id', :'campus1_id', :'c1_student', :'c1_enrol', 2000000, current_date) returning id as c1_hostel_deposit \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role)
values (:'parent_uid', '923001110002', now(), 'x', 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'parent_uid' where id = :'g1';

select is(:'c1_challan_no'::text, :'c2_challan_no'::text, 'fixture: both campuses issued the same challan number (the counter is per campus)');

-- ── an accountant at the North campus cannot touch a Main campus student ────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
  'campus_ids', json_build_array(:'campus2_id'))::text, true);

select throws_ok(format($$ select public.record_payment(%L, 1000, 'cash') $$, :'c1_enrol'), 'FORBIDDEN', 'record_payment refuses another campus''s enrolment');
select throws_ok(format($$ select public.post_ledger_entry(%L, 'adjustment', 1000, 'debit') $$, :'c1_enrol'), 'FORBIDDEN', 'post_ledger_entry refuses another campus''s enrolment');
select throws_ok(format($$ select public.allocate_payment(%L) $$, :'c1_payment'), 'FORBIDDEN', 'allocate_payment refuses another campus''s payment');
select throws_ok(format($$ select public.apply_advance_credit(%L, %L) $$, :'c1_enrol', :'c1_challan'), 'FORBIDDEN', 'apply_advance_credit refuses another campus''s enrolment');
select throws_ok(format($$ select public.compute_late_fee(%L) $$, :'c1_challan'), 'FORBIDDEN', 'compute_late_fee refuses another campus''s challan');
select throws_ok(format($$ select public.build_challan_render_payload(%L) $$, :'c1_challan'), 'FORBIDDEN', 'build_challan_render_payload refuses another campus''s challan');
select throws_ok(format($$ select public.collect_cash_payment(%L, 1000, 'cross-campus') $$, :'c1_challan'), 'FORBIDDEN', 'collect_cash_payment refuses another campus''s challan');
select throws_ok(format($$ select public.print_receipt(%L) $$, :'c1_receipt'), 'FORBIDDEN', 'print_receipt refuses another campus''s receipt');
select throws_ok(format($$ select public.create_payment_intent(%L, 'onelink') $$, :'c1_challan'), 'FORBIDDEN', 'create_payment_intent refuses another campus''s challan');
select throws_ok(format($$ select public.security_deposit_balance(%L) $$, :'c1_enrol'), 'FORBIDDEN', 'security_deposit_balance refuses another campus''s enrolment');
select throws_ok(format($$ select public.disburse_deposit_refund(%L, 'cash') $$, :'c1_enrol'), 'FORBIDDEN', 'disburse_deposit_refund refuses another campus''s enrolment');
select throws_ok(format($$ select public.disburse_fee_settlement(%L, 'cash') $$, :'c1_settlement'), 'FORBIDDEN', 'disburse_fee_settlement refuses another campus''s settlement');
select throws_ok(format($$ select public.request_concession_award(%L, %L, 10, current_date, current_date + 30) $$, :'c1_enrol', :'scheme_id'), 'FORBIDDEN', 'request_concession_award refuses another campus''s enrolment');
select throws_ok(format($$ select public.edit_concession_award(%L, 5) $$, :'c1_award'), 'FORBIDDEN', 'edit_concession_award refuses another campus''s award');
select throws_ok(format($$ select public.record_admission_fee_payment(%L, 100000, 'cash') $$, :'c1_offer'), 'FORBIDDEN', 'record_admission_fee_payment refuses another campus''s offer');
select throws_ok(format($$ select public.reconcile_admission_fee_payment(%L) $$, :'c1_adm_payment'), 'FORBIDDEN', 'reconcile_admission_fee_payment refuses another campus''s payment');
select throws_ok(format($$ select public.fn_enrol_from_offer(%L, 'male'::public.gender, p_payment_id => %L, p_section_id => %L) $$, :'c1_offer', :'c1_adm_payment', :'c1_section'),
  'FORBIDDEN', 'fn_enrol_from_offer refuses another campus''s offer');
select throws_ok(format($$ select public.refund_hostel_deposit(%L, 'RV-1') $$, :'c1_hostel_deposit'), 'FORBIDDEN', 'refund_hostel_deposit refuses another campus''s deposit');
select throws_ok(format($$ select public.receive_hostel_deposit(%L, current_date) $$, :'c1_hostel_deposit'), 'FORBIDDEN', 'receive_hostel_deposit refuses another campus''s deposit');
select throws_ok(format($$ select public.propose_fee_plan_override(%L, 1, 'cross-campus try') $$, :'c1_plan_line'), 'FORBIDDEN', 'propose_fee_plan_override refuses another campus''s plan');
select throws_ok(format($$ select public.remove_fee_plan_line(%L) $$, :'c1_plan_line'), 'FORBIDDEN', 'remove_fee_plan_line refuses another campus''s plan');
select throws_ok(format($$ select public.build_fee_plan(%L) $$, :'c1_enrol'), 'FORBIDDEN', 'build_fee_plan refuses another campus''s enrolment');

select throws_ok(format($$ select public.lookup_challan_for_counter(%L) $$, :'c1_challan_no_b'), 'CHALLAN_NOT_FOUND',
  'the cash counter cannot look up another campus''s challan by its number');
select is((public.lookup_challan_for_counter(:'c2_challan_no') ->> 'challan_id')::uuid, :'c2_challan'::uuid,
  'and when both campuses have the same number it returns its own campus''s challan');
select is(public.student_balance(:'c1_enrol'::uuid), 0::bigint, 'student_balance says nothing about another campus''s student');
select is(public.outstanding_balance_as_of(:'c1_enrol'::uuid), 0::bigint, 'nor does outstanding_balance_as_of');

-- ── the same accountant still works at their own campus ───────────────────────
select lives_ok(format($$ select public.record_payment(%L, 100000, 'cash') $$, :'c2_enrol'), 'record_payment works for the accountant''s own campus');
select is(public.student_balance(:'c2_enrol'::uuid), 400000::bigint, 'student_balance works for the accountant''s own campus');
select lives_ok(format($$ select public.compute_late_fee(%L) $$, :'c2_challan'), 'compute_late_fee works for the accountant''s own campus');
select lives_ok(format($$ select public.build_challan_render_payload(%L) $$, :'c2_challan'), 'build_challan_render_payload works for the accountant''s own campus');
reset role;

-- ── and so does an accountant at the Main campus, including the repeated number ──
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
  'campus_ids', json_build_array(:'campus1_id'))::text, true);
select is((public.lookup_challan_for_counter(:'c1_challan_no') ->> 'challan_id')::uuid, :'c1_challan'::uuid,
  'the Main campus accountant gets the Main campus challan for the same number');
select is(public.student_balance(:'c1_enrol'::uuid), 400000::bigint, 'and reads the Main campus balance');
select is(public.security_deposit_balance(:'c1_enrol'::uuid), 500000::bigint, 'and the deposit held');
select throws_ok(format($$ select public.create_payment_intent(%L, 'onelink') $$, :'c1_challan'), 'GATEWAY_NOT_CONFIGURED',
  'create_payment_intent gets past the campus check for the right campus');
select lives_ok(format($$ select public.record_payment(%L, 1000, 'cash') $$, :'c1_enrol'), 'record_payment works at the right campus');
select public.collect_cash_payment(:'c1_challan_b'::uuid, 2000, 'main-campus') as c1_cash_b \gset
select ok((:'c1_cash_b'::jsonb ->> 'receipt_id') is not null, 'collect_cash_payment works at the right campus');
select lives_ok(format($$ select public.print_receipt(%L) $$, :'c1_cash_b'::jsonb ->> 'receipt_id'), 'and so does print_receipt');
reset role;

-- ── a principal at the North campus ──────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
  'campus_ids', json_build_array(:'campus2_id'))::text, true);
select throws_ok(format($$ select public.decide_concession_award(%L, true) $$, :'c1_award'), 'FORBIDDEN', 'decide_concession_award refuses another campus''s award');
select throws_ok(format($$ select public.decide_fee_plan_override(%L, true) $$, :'c1_plan_line'), 'FORBIDDEN', 'decide_fee_plan_override refuses another campus''s plan');
select throws_ok(format($$ select public.waive_admission_fee(%L, 'a perfectly good reason') $$, :'c1_offer'), 'FORBIDDEN', 'waive_admission_fee refuses another campus''s offer');
select throws_ok(format($$ select public.security_deposit_balance(%L) $$, :'c1_enrol'), 'FORBIDDEN', 'a North principal cannot read a Main campus deposit');
reset role;
select is((select status::text from public.concession_award where id = :'c1_award'::uuid), 'pending', 'the Main campus award is still pending');

-- ── an admissions officer at the North campus ─────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer',
  'campus_ids', json_build_array(:'campus2_id'))::text, true);
select throws_ok(
  format($$ select public.fn_quick_admission(%L, %L, 'Cross Campus Kid', '2016-01-01'::date, 'male'::public.gender, %L, %L, 'A Parent', '03001110003') $$,
    :'campus1_id', :'session_id', :'class1_id', :'c1_section'),
  'FORBIDDEN', 'fn_quick_admission refuses a campus the officer is not assigned to');
select throws_ok(format($$ select public.record_admission_fee_payment(%L, 100000, 'cash') $$, :'c1_offer'), 'FORBIDDEN', 'an admissions officer cannot record a fee against another campus''s offer');
reset role;

-- ── an owner reaches both campuses ───────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus1_id', :'campus2_id'))::text, true);
select lives_ok(format($$ select public.record_payment(%L, 1000, 'cash') $$, :'c1_enrol'), 'an owner can post at the Main campus');
select lives_ok(format($$ select public.record_payment(%L, 1000, 'cash') $$, :'c2_enrol'), 'and at the North campus');
select lives_ok(format($$ select public.decide_concession_award(%L, true) $$, :'c1_award'), 'an owner can decide any campus''s concession award');
reset role;

-- ── a parent reads only their own child's balance ────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select ok(public.student_balance(:'c1_enrol'::uuid) > 0, 'a parent sees their own child''s balance');
select is(public.student_balance(:'c2_enrol'::uuid), 0::bigint, 'and gets nothing for somebody else''s child');
select throws_ok(format($$ select public.record_payment(%L, 1000, 'cash') $$, :'c1_enrol'), 'FORBIDDEN', 'a parent still cannot record a payment');
select throws_ok(format($$ select public.apply_advance_credit(%L, %L) $$, :'c1_enrol', :'c1_challan'), 'FORBIDDEN', 'nor apply an advance credit');
select throws_ok(format($$ select public.build_fee_plan(%L) $$, :'c1_enrol'), 'FORBIDDEN', 'nor rebuild a fee plan');
reset role;

-- ── the gateway webhook still posts the payment, as an accountant of the payer's campus ──
select set_config('request.jwt.claims', '', true);
select lives_ok(
  format($$ select app.fn_post_system_payment(%L, %L, 25000, 'online', 'GW-TXN-1', current_date) $$, :'tenant_id', :'c1_enrol'),
  'the gateway webhook can still post a payment for a student'
);
select is((select count(*)::int from public.fee_payment where enrolment_id = :'c1_enrol'::uuid and reference_no = 'GW-TXN-1'), 1, 'and the payment is on file');
select is(nullif(current_setting('request.jwt.claims', true), ''), null, 'and the claims it borrowed are put back');

select * from finish();
rollback;
