-- pgTAP tests for FR-K21: online payment initiation.
begin;
select plan(28);

select public.provision_tenant('test-online-pay-co', 'Online Pay Co', 'owner@onlinepayco.test');
select id as tenant_id from public.tenant where slug = 'test-online-pay-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-online-pay-other', 'Other Pay Co', 'owner@otherpayco.test');
select id as other_tenant_id from public.tenant where slug = 'test-online-pay-other' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);

select public.create_student(:'campus_id'::uuid, 'Pay Kid One', '2015-01-01'::date, 'male') as s1 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid) as e1 \gset
select public.create_student(:'campus_id'::uuid, 'Pay Kid Two', '2015-02-01'::date, 'female') as s2 \gset
select public.enrol_student(:'section_id'::uuid, :'s2'::uuid) as e2 \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select public.fn_find_or_create_guardian(p_name_en => 'Pay Father', p_phone_e164 => '+923007770001') as g1 \gset
select public.link_guardian(:'s1'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
select public.fn_find_or_create_guardian(p_name_en => 'Pay Stranger', p_phone_e164 => '+923007770002') as g2 \gset
select public.link_guardian(:'s2'::uuid, :'g2'::uuid, 'father'::public.guardian_relationship, true, true);
reset role;

select id as challan1 from public.fee_challan where enrolment_id = :'e1' \gset
select challan_no as challan1_no from public.fee_challan where id = :'challan1' \gset
select gen_random_uuid() as uid1 \gset
select gen_random_uuid() as uid2 \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role)
values (:'uid1', '923007770001', now(), 'x', 'authenticated', 'authenticated'), (:'uid2', '923007770002', now(), 'x', 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'uid1' where id = :'g1';
update public.guardian set auth_user_id = :'uid2' where id = :'g2';

select has_table('public', 'payment_intent', 'payment_intent exists');
select has_table('public', 'payment_gateway_config', 'payment_gateway_config exists');
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('public.payment_intent'::regclass, 'public.payment_gateway_config'::regclass)), 'RLS enabled on both');
select is((select count(*)::int from information_schema.columns where table_name = 'payment_gateway_config' and column_name ~* '(secret$|key$|password|token)'), 0, 'no column can hold a secret value — only secret_ref, a variable name');

-- ── config ────────────────────────────────────────────────────────────────

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.upsert_payment_gateway_config('jazzcash', 'MC1', 'PAY_SECRET_JAZZCASH') $$, 'FORBIDDEN', 'an accountant cannot configure gateways');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.upsert_payment_gateway_config('jazzcash', 'MC1', 'my-actual-secret-value') $$, 'SECRET_REF_MUST_BE_AN_ENV_VAR_NAME', 'a secret value cannot be stored as the reference');
reset role;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select throws_ok(format($$ select public.create_payment_intent(%L, 'jazzcash') $$, :'challan1'), 'GATEWAY_NOT_CONFIGURED', 'no gateway configured -> nothing to initiate');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.upsert_payment_gateway_config('jazzcash', 'MC-JAZZ-1', 'PAY_SECRET_JAZZCASH');
select public.upsert_payment_gateway_config('onelink', 'MC-1LINK-1', 'PAY_SECRET_ONELINK');
reset role;
select is((select count(*)::int from public.payment_gateway_config where tenant_id = :'tenant_id'), 2, 'the owner configured two gateways');

-- ── initiation ────────────────────────────────────────────────────────────

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select public.create_payment_intent(:'challan1'::uuid, 'jazzcash') as i1 \gset
select is((:'i1'::jsonb ->> 'amount_paisa')::bigint, 500000::bigint, 'AC: expected amount is the challan balance in paisa');
select ok((:'i1'::jsonb ->> 'gateway_ref') like 'JA-%', 'a gateway reference is issued');
select ok(not ((:'i1'::jsonb) ?| array['secret', 'secret_ref', 'merchant_secret', 'hash']), 'no secret appears in the returned payload');
select ok(((:'i1'::jsonb ->> 'expires_at')::timestamptz) between now() + interval '29 minutes' and now() + interval '31 minutes', 'AC: expires_at = now + 30 minutes');
select is((select status from public.payment_intent where id = (:'i1'::jsonb ->> 'intent_id')::uuid), 'initiated', 'AC: the intent row is initiated');
select is((public.create_payment_intent(:'challan1'::uuid, 'jazzcash') ->> 'intent_id'), (:'i1'::jsonb ->> 'intent_id'), 'initiating again returns the same live intent');
select public.create_payment_intent(:'challan1'::uuid, 'onelink') as i2 \gset
select is((:'i2'::jsonb ->> 'gateway_ref'), :'challan1_no', 'AC: a 1LINK voucher reference equals the challan number');
select throws_ok(format($$ select public.create_payment_intent(%L, 'easypaisa') $$, :'challan1'), 'GATEWAY_NOT_CONFIGURED', 'an unconfigured gateway is refused');

select set_config('request.jwt.claims', json_build_object('sub', :'uid2', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select throws_ok(format($$ select public.create_payment_intent(%L, 'jazzcash') $$, :'challan1'), 'FORBIDDEN', 'another family''s parent cannot pay this challan');
select is((select count(*)::int from public.payment_intent), 0, 'nor see its intents');
select is((select count(*)::int from public.payment_gateway_config), 0, 'nor the gateway configuration');

select set_config('request.jwt.claims', json_build_object('sub', :'uid1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*)::int from public.payment_intent), 2, 'the owning parent sees their own intents');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.payment_intent), 2, 'the accountant sees the campus intents');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner')::text, true);
select is((select count(*)::int from public.payment_intent), 0, 'another school sees none');
reset role;

-- ── expiry: abandoned intent leaves the challan unpaid, no ledger row ─────

select count(*)::int as ledger_before from public.fee_ledger where enrolment_id = :'e1' and direction = 'credit' \gset
update public.payment_intent set expires_at = now() - interval '1 minute' where challan_id = :'challan1';
select is(has_function_privilege('anon', 'public.expire_payment_intents(timestamptz)', 'execute'), false, 'anon cannot run the expiry job');
select is(public.expire_payment_intents(), 2, 'AC: the expiry job expires both abandoned intents');
select is((select count(*)::int from public.fee_ledger where enrolment_id = :'e1' and direction = 'credit'), :'ledger_before', 'AC: expiry writes no ledger row');
select is((select status::text from public.fee_challan where id = :'challan1'), 'unpaid', 'AC: the challan remains unpaid');

-- ── balance-only after a partial payment; refused once settled ────────────

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.record_payment(:'e1'::uuid, 200000::bigint, 'cash'::public.fee_payment_mode, 'k21-partial');
select set_config('request.jwt.claims', json_build_object('sub', :'uid1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((public.create_payment_intent(:'challan1'::uuid, 'jazzcash') ->> 'amount_paisa')::bigint, 300000::bigint, 'the new intent is for the balance only');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.record_payment(:'e1'::uuid, 300000::bigint, 'cash'::public.fee_payment_mode, 'k21-rest');
select set_config('request.jwt.claims', json_build_object('sub', :'uid1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select throws_ok(format($$ select public.create_payment_intent(%L, 'jazzcash') $$, :'challan1'), 'CHALLAN_ALREADY_SETTLED', 'AC: a fully paid challan is rejected');
reset role;

select * from finish();
rollback;
