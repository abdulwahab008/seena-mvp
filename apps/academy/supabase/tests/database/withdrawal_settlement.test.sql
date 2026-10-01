-- pgTAP tests for FR-K27: withdrawal refund and pro-rata adjustment.
begin;
select plan(24);

select public.provision_tenant('test-settle-co', 'Settle Co', 'owner@settleco.test');
select id as tenant_id from public.tenant where slug = 'test-settle-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-settle-other', 'Other Settle Co', 'owner@othersettleco.test');
select id as other_tenant_id from public.tenant where slug = 'test-settle-other' \gset

select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'acct_uid', 'a@settleco.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@settleco.test', 'authenticated', 'authenticated', 'x'), (:'owner_uid', 'o@settleco.test', 'authenticated', 'authenticated', 'x');

insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'acct_uid', :'tenant_id', 'accountant', 'Settle Accountant'), (:'prin_uid', :'tenant_id', 'principal', 'Settle Principal'), (:'owner_uid', :'tenant_id', 'owner', 'Settle Owner');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select id as exam_id from public.fee_head where tenant_id = :'tenant_id' and code = 'EXAM' \gset
select id as admission_id from public.fee_head where tenant_id = :'tenant_id' and code = 'ADMISSION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.create_student(:'campus_id'::uuid, 'Leaver One', '2015-01-01'::date, 'male') as s1 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid) as e1 \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date + interval '1 month')::date + 14), false);
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date + interval '2 months')::date + 14), false);
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
-- three prepaid months of tuition, plus 3,000 of exam fees still owed
select public.record_payment(:'e1'::uuid, 1500000::bigint, 'cash'::public.fee_payment_mode, 'k27-prepaid', current_date);
select public.post_ledger_entry(:'e1'::uuid, 'charge'::public.fee_ledger_entry_type, 300000::bigint, 'debit'::public.fee_ledger_direction, :'exam_id'::uuid, current_date, 'k27-test', null);
reset role;
select (date_trunc('month', current_date)::date + 11) as leaving \gset

select is((select withdrawal_treatment from public.fee_head where id = :'tuition_id'), null, 'treatment is unset on the seeded head');
select is(app.fn_head_prorates(:'tuition_id'::uuid), true, 'a monthly head prorates by default');
select is(app.fn_head_prorates(:'admission_id'::uuid), false, 'an admission fee does not');
select is(app.fn_head_prorates(:'exam_id'::uuid), false, 'nor an exam fee');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.compute_withdrawal_settlement(:'e1'::uuid, :'leaving'::date, 'half_month') as calc \gset
select is((:'calc'::jsonb ->> 'credit_adjustment_paisa')::bigint, 1250000::bigint, 'AC1: leaving on the 12th, half-month basis -> half of this month plus the next two = 12,500');
select is((:'calc'::jsonb ->> 'ledger_balance_paisa')::bigint, 300000::bigint, 'the family owes the 3,000 of exam fees on the ledger');
select is((:'calc'::jsonb ->> 'net_refund_paisa')::bigint, 950000::bigint, 'AC2: refund payable is 9,500 after netting the dues');
select is((:'calc'::jsonb ->> 'remaining_dues_paisa')::bigint, 0::bigint, 'AC2: and the exam dues are settled by the netting');
select is(jsonb_array_length(:'calc'::jsonb -> 'lines'), 3, 'the working is shown line by line');
select is((public.compute_withdrawal_settlement(:'e1'::uuid, (date_trunc('month', current_date)::date + 20), 'half_month') ->> 'credit_adjustment_paisa')::bigint, 1000000::bigint, 'leaving after the 15th on half-month: the current month is earned in full');
select is((public.compute_withdrawal_settlement(:'e1'::uuid, :'leaving'::date, 'full_month') ->> 'credit_adjustment_paisa')::bigint, 1000000::bigint, 'full-month basis: the leaving month is not refunded');
select throws_ok($$ select public.compute_withdrawal_settlement(gen_random_uuid(), current_date, 'daily') $$, 'ENROLMENT_NOT_FOUND', 'an unknown enrolment is refused');

select public.propose_fee_settlement(:'e1'::uuid, :'leaving'::date, 'half_month', 'Family relocating') as sid \gset
select throws_ok(format($$ select public.propose_fee_settlement(%L, %L, 'half_month') $$, :'e1', :'leaving'), 'SETTLEMENT_ALREADY_OPEN', 'a second open settlement for the same enrolment is refused');
select throws_ok(format($$ select public.disburse_fee_settlement(%L, 'cash') $$, :'sid'), 'SETTLEMENT_NOT_APPROVED', 'AC3: nothing can be disbursed before approval');
select throws_ok(format($$ select public.decide_fee_settlement(%L, true) $$, :'sid'), 'FORBIDDEN', 'an accountant cannot approve');

select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.decide_fee_settlement(:'sid'::uuid, true, 'Verified with the family'), 'approved', 'AC3: the Principal approves a settlement under the threshold');
select throws_ok(format($$ select public.decide_fee_settlement(%L, true) $$, :'sid'), 'SETTLEMENT_NOT_PENDING', 'and it cannot be decided twice');

select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.disburse_fee_settlement(%L, 'cheque') $$, :'sid'), 'INSTRUMENT_REFERENCE_REQUIRED', 'a cheque disbursement needs its number');
select public.disburse_fee_settlement(:'sid'::uuid, 'cheque', 'CHQ-884412') as disb \gset
select is((:'disb'::jsonb ->> 'ledger_balance_paisa')::bigint, 0::bigint, 'AC4: after disbursement the student balance is exactly 0');
reset role;
select is((select amount_paisa || '/' || direction::text || '/' || entry_type::text from public.fee_ledger where source_id = :'sid'::uuid and entry_type = 'refund'), '950000/debit/refund', 'AC4: the ledger holds a debit entry of type refund');
select is((select instrument_ref from public.fee_settlement where id = :'sid'::uuid), 'CHQ-884412', 'with the cheque number');

-- ── above the owner threshold: both approvals, and never the proposer ─────
update public.fee_settlement_policy set owner_threshold_paisa = 100 where tenant_id = :'tenant_id';
insert into public.fee_settlement_policy (tenant_id, owner_threshold_paisa) values (:'tenant_id', 100) on conflict (tenant_id) do update set owner_threshold_paisa = 100;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_student(:'campus_id'::uuid, 'Leaver Two', '2015-02-01'::date, 'female') as s2 \gset
select public.enrol_student(:'section_id'::uuid, :'s2'::uuid) as e2 \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.record_payment(:'e2'::uuid, 500000::bigint, 'cash'::public.fee_payment_mode, 'k27-two', current_date);
select public.propose_fee_settlement(:'e2'::uuid, (date_trunc('month', current_date)::date + 5), 'half_month') as sid2 \gset
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.decide_fee_settlement(:'sid2'::uuid, true), 'pending', 'AC3: above the threshold the Principal alone is not enough');
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.disburse_fee_settlement(%L, 'cash') $$, :'sid2'), 'SETTLEMENT_NOT_APPROVED', 'AC3: so no disbursement entry can be posted yet');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.decide_fee_settlement(:'sid2'::uuid, true), 'approved', 'AC3: the Owner''s approval completes it');
reset role;

select * from finish();
rollback;
