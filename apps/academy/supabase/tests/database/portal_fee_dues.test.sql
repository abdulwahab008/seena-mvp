-- pgTAP tests for FR-N04: fee dues view with pay action.
begin;
select plan(24);

select public.provision_tenant('test-portal-dues-co', 'Portal Dues Co', 'owner@portalduesco.test');
select id as tenant_id from public.tenant where slug = 'test-portal-dues-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-portal-dues-other', 'Other Dues Co', 'owner@otherduesco.test');
select id as other_tenant_id from public.tenant where slug = 'test-portal-dues-other' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.create_student(:'campus_id'::uuid, 'Dues Kid One', '2015-01-01'::date, 'male') as s1 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid) as e1 \gset
select public.create_student(:'campus_id'::uuid, 'Dues Kid Two', '2015-02-01'::date, 'female') as s2 \gset
select public.enrol_student(:'section_id'::uuid, :'s2'::uuid) as e2 \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select public.fn_find_or_create_guardian(p_name_en => 'Dues Father', p_phone_e164 => '+923008880001') as g1 \gset
select public.link_guardian(:'s1'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
select public.fn_find_or_create_guardian(p_name_en => 'Dues Stranger', p_phone_e164 => '+923008880002') as g2 \gset
select public.link_guardian(:'s2'::uuid, :'g2'::uuid, 'father'::public.guardian_relationship, true, true);
reset role;

select id as ch1, challan_digits as digits1 from public.fee_challan where enrolment_id = :'e1' \gset
select id as ch2 from public.fee_challan where enrolment_id = :'e2' \gset
select gen_random_uuid() as uid1 \gset
select gen_random_uuid() as uid2 \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role)
values (:'uid1', '923008880001', now(), 'x', 'authenticated', 'authenticated'), (:'uid2', '923008880002', now(), 'x', 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'uid1' where id = :'g1';
update public.guardian set auth_user_id = :'uid2' where id = :'g2';

-- a flat 100 PKR late fee after a 0-day grace; the challan is 6 days overdue
insert into public.late_fee_rule (tenant_id, campus_id, session_id, grace_days, basis, amount_paisa, effective_from)
values (:'tenant_id', :'campus_id', :'session_id', 0, 'flat', 10000, '2000-01-01');
update public.fee_challan set due_date = current_date - 6 where id = :'ch1';

select ok((select reloptions::text like '%security_invoker=true%' from pg_class where oid = 'public.v_portal_dues'::regclass), 'v_portal_dues is security_invoker');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*)::int from public.v_portal_dues), 1, 'a parent sees only their own child''s challan');
select is((select challan_id from public.v_portal_dues), :'ch1'::uuid, 'and it is theirs');
select is((select balance_paisa from public.v_portal_dues), 500000::bigint, 'an unpaid challan shows its full balance');
select is((select late_fee_paisa from public.v_portal_dues), 10000::bigint, 'AC: a 6-days-overdue challan shows the late fee');
select is((select balance_paisa + late_fee_paisa = total_due_paisa from public.v_portal_dues), true, 'AC: principal and late fee are separate lines that sum to the total');
select is((select days_overdue from public.v_portal_dues), 6, 'the days overdue are reported');
select is((select gateways from public.v_portal_dues), '{}'::text[], 'AC: with no gateway configured the list is empty (no Pay button, PDF instead)');
select is((select under_reconciliation from public.v_portal_dues), false, 'nothing is under reconciliation yet');
select is((public.late_fee_for(:'ch1'::uuid)), 10000::bigint, 'late_fee_for returns the accrued fee');
select throws_ok(format($$ select public.late_fee_for(%L) $$, :'ch2'), 'CHALLAN_NOT_FOUND', 'and refuses another family''s challan');
select is((public.portal_challan_payload(:'ch1'::uuid) ->> 'challan_no'), (select challan_no from public.fee_challan where id = :'ch1'::uuid), 'a parent can build the printable payload for their own challan');
select throws_ok(format($$ select public.portal_challan_payload(%L) $$, :'ch2'), 'CHALLAN_NOT_FOUND', 'but not for another family''s');
select throws_ok(format($$ select public.build_challan_render_payload(%L) $$, :'ch1'), 'FORBIDDEN', 'the staff payload function is still staff-only');
reset role;

-- ── under reconciliation: bank line not yet posted ────────────────────────

insert into public.campus_bank_account (campus_id, bank_name, title, account_no, iban)
values (:'campus_id', 'HBL', 'Fees', '5', 'PK36HABB0000000000000005') returning id as bank_id \gset
insert into public.bank_statement_import (tenant_id, campus_id, bank_account_id, file_sha256)
values (:'tenant_id', :'campus_id', :'bank_id', repeat('9', 64)) returning id as import_id \gset
insert into public.bank_statement_line (tenant_id, campus_id, import_id, line_no, txn_date, challan_ref, amount_paisa, bank_ref, raw_line)
values (:'tenant_id', :'campus_id', :'import_id', 2, current_date - 1, :'digits1', 500000, 'BANKREF1', 'raw');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select under_reconciliation from public.v_portal_dues), true, 'AC: a bank line that has not posted yet shows "payment under reconciliation"');
reset role;
update public.bank_statement_line set status = 'matched' where import_id = :'import_id';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select under_reconciliation from public.v_portal_dues), false, 'once the line is posted the state clears');
reset role;

-- ── partial payment: balance only; gateway listed once configured ─────────

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.upsert_payment_gateway_config('jazzcash', 'MC-DUES-1', 'PAY_SECRET_JAZZCASH');
select public.record_payment(:'e1'::uuid, 200000::bigint, 'cash'::public.fee_payment_mode, 'n04-partial');
select set_config('request.jwt.claims', json_build_object('sub', :'uid1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select balance_paisa from public.v_portal_dues), 300000::bigint, 'AC: 2,000 paid against 5,000 leaves a balance of 3,000');
select is((select status::text from public.v_portal_dues), 'part_paid', 'and the status is part_paid');
select is((select gateways from public.v_portal_dues), array['jazzcash'], 'a configured gateway is listed so the Pay button appears');
select is((public.create_payment_intent(:'ch1'::uuid, 'jazzcash') ->> 'amount_paisa')::bigint, 300000::bigint, 'AC: the Pay action is for the balance only');
reset role;

insert into public.payment_intent (tenant_id, campus_id, enrolment_id, challan_id, gateway, gateway_ref, amount_paisa, expires_at, status)
values (:'tenant_id', :'campus_id', :'e1', :'ch1', 'easypaisa', 'EP-PENDING', 300000, now() + interval '20 minutes', 'pending');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select under_reconciliation from public.v_portal_dues), true, 'a gateway payment awaiting its callback also blocks a second payment');
reset role;

-- ── paid, and isolation ───────────────────────────────────────────────────

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.record_payment(:'e1'::uuid, 300000::bigint, 'cash'::public.fee_payment_mode, 'n04-rest');
select set_config('request.jwt.claims', json_build_object('sub', :'uid1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select balance_paisa + late_fee_paisa from public.v_portal_dues), 0::bigint, 'a fully paid challan owes nothing, late fee included');
select is((select under_reconciliation from public.v_portal_dues), false, 'and is never "under reconciliation"');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner')::text, true);
select is((select count(*)::int from public.v_portal_dues), 0, 'another school sees none of it');
reset role;

select * from finish();
rollback;
