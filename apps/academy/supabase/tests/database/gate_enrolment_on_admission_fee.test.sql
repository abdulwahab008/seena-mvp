-- pgTAP tests for FR-B17: gate enrolment on admission fee payment.
begin;
select plan(27);

select public.provision_tenant('test-enrol-gate-co', 'Enrol Gate Co', 'owner@enrolgateco.test');
select id as tenant_id from public.tenant where slug = 'test-enrol-gate-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class1_id', p_name => 'A', p_capacity => 30) as section_id \gset

-- Helper: an accepted offer for a fresh enquiry, admission fee PKR 25,000.
create function pg_temp.new_accepted_offer(p_phone text, p_child_name text default 'Candidate')
returns uuid language plpgsql as $$
declare
  v_enquiry_id uuid; v_app_id uuid; v_offer_id uuid;
  v_campus_id uuid; v_session_id uuid; v_class1_id uuid;
begin
  select id into v_campus_id from public.campus where tenant_id = app.auth_tenant_id() limit 1;
  select id into v_session_id from public.academic_session where tenant_id = app.auth_tenant_id() limit 1;
  select id into v_class1_id from public.class_level where tenant_id = app.auth_tenant_id() and code = '1' limit 1;

  v_enquiry_id := public.create_enquiry(p_campus_id => v_campus_id, p_session_id => v_session_id, p_child_name => p_child_name, p_dob => '2020-01-01'::date, p_class_applied_id => v_class1_id, p_parent_name => 'A Parent', p_phone => p_phone, p_whatsapp_opt_in => false, p_source => 'walk_in');
  v_app_id := public.fn_submit_application(v_enquiry_id);
  v_offer_id := public.fn_issue_offer(v_app_id, 25000);
  perform public.fn_respond_to_offer(v_offer_id, 'accepted'::public.offer_status);
  return v_offer_id;
end;
$$;

-- ── AC1: an outstanding balance is rejected with the exact shortfall ──

select pg_temp.new_accepted_offer('03001111111') as offer1_id \gset
select public.record_admission_fee_payment(:'offer1_id'::uuid, 2000000, 'cash') as payment1_id \gset
select is(
  (select status from public.admission_fee_payment where id = :'payment1_id'::uuid)::text,
  'reconciled',
  'a cash payment is reconciled immediately, no bank statement needed'
);
select throws_ok(
  format('select public.fn_enrol_from_offer(%L, %L::public.gender, p_payment_id => %L, p_section_id => %L)', :'offer1_id', 'male', :'payment1_id', :'section_id'),
  'OUTSTANDING_BALANCE:5,000',
  'AC1: PKR 20,000 received against a PKR 25,000 fee is rejected naming the exact PKR 5,000 shortfall'
);
select is((select count(*)::int from public.student), 0, 'AC1: no student row was created by the rejected attempt');

-- ── AC2: full settlement enrols atomically — student, GR, enrolment,
--    ledger all in one go ──────────────────────────────────────────────

select public.record_admission_fee_payment(:'offer1_id'::uuid, 500000, 'online') as payment2_id \gset
select public.fn_enrol_from_offer(:'offer1_id'::uuid, 'male'::public.gender, p_payment_id => :'payment2_id'::uuid, p_section_id => :'section_id'::uuid) as enrol_result \gset
select is((:'enrol_result'::jsonb ->> 'is_replay')::boolean, false, 'AC2: the first successful call is not a replay');
select ok((:'enrol_result'::jsonb ->> 'gr_number') is not null, 'AC2: a GR number was allocated');
select is(
  (select count(*)::int from public.student where gr_number = (:'enrol_result'::jsonb ->> 'gr_number')),
  1,
  'AC2: exactly one student row exists'
);
select is(
  (select count(*)::int from public.enrolment where admission_offer_id = :'offer1_id'::uuid),
  1,
  'AC2: exactly one enrolment row, linked back to the offer'
);
select is(
  (select count(*)::int from public.fee_ledger where enrolment_id = (:'enrol_result'::jsonb ->> 'enrolment_id')::uuid and entry_type = 'payment' and direction = 'credit'),
  1,
  'AC2: a payment credit ledger entry was posted for the enrolment'
);
select is(
  (select amount_paisa from public.fee_ledger where enrolment_id = (:'enrol_result'::jsonb ->> 'enrolment_id')::uuid and entry_type = 'payment'),
  2500000::bigint,
  'AC2: the ledger entry is for the full PKR 25,000 admission fee, in paisa'
);
select is(
  (select status from public.admission_application where id = (select application_id from public.admission_offer where id = :'offer1_id'::uuid))::text,
  'enrolled',
  'AC2: the application is marked enrolled'
);

-- ── AC3: a provisionally-received (unreconciled) bank challan blocks
--    enrolment even though the money would fully cover the fee, and
--    pauses the offer's expiry clock with an auditable reason ─────────

select pg_temp.new_accepted_offer('03003333333') as offer3_id \gset
select public.record_admission_fee_payment(:'offer3_id'::uuid, 2500000, 'bank_challan') as payment3_id \gset
select is(
  (select status from public.admission_fee_payment where id = :'payment3_id'::uuid)::text,
  'provisional',
  'a bank_challan payment starts provisional, awaiting reconciliation'
);
select throws_ok(
  format('select public.fn_enrol_from_offer(%L, %L::public.gender, p_payment_id => %L, p_section_id => %L)', :'offer3_id', 'female', :'payment3_id', :'section_id'),
  'PAYMENT_NOT_RECONCILED',
  'AC3: a fully-covering but unreconciled payment blocks enrolment'
);
select ok(
  (select expiry_paused_at from public.admission_offer where id = :'offer3_id'::uuid) is not null,
  'AC3: the offer''s expiry clock is paused'
);
select ok(
  (select expiry_pause_reason from public.admission_offer where id = :'offer3_id'::uuid) is not null,
  'AC3: the pause reason is recorded and auditable'
);
select is((select count(*)::int from public.enrolment where admission_offer_id = :'offer3_id'::uuid), 0, 'AC3: still no enrolment created while blocked');

-- reconciling clears the block and the pause, and enrolment then succeeds
select public.reconcile_admission_fee_payment(:'payment3_id'::uuid);
select is(
  (select status from public.admission_fee_payment where id = :'payment3_id'::uuid)::text,
  'reconciled',
  'reconcile_admission_fee_payment flips the status'
);
select is(
  (select expiry_paused_at from public.admission_offer where id = :'offer3_id'::uuid),
  null,
  'reconciling clears the expiry pause'
);
select public.fn_enrol_from_offer(:'offer3_id'::uuid, 'female'::public.gender, p_payment_id => :'payment3_id'::uuid, p_section_id => :'section_id'::uuid) as enrol3_result \gset
select is((:'enrol3_result'::jsonb ->> 'is_replay')::boolean, false, 'AC3: enrolment now succeeds once reconciled');

-- ── AC4: a 100% waiver satisfies the gate with zero money moved, and
--    the waiver id is recorded on the enrolment ───────────────────────

select pg_temp.new_accepted_offer('03004444444') as offer4_id \gset
select public.waive_admission_fee(:'offer4_id'::uuid, 'Approved staff-child hardship waiver') as waiver4_id \gset
select public.fn_enrol_from_offer(:'offer4_id'::uuid, 'male'::public.gender, p_waiver_id => :'waiver4_id'::uuid, p_section_id => :'section_id'::uuid) as enrol4_result \gset
select is(
  (select admission_fee_waiver_id from public.enrolment where id = (:'enrol4_result'::jsonb ->> 'enrolment_id')::uuid),
  :'waiver4_id'::uuid,
  'AC4: the concession/waiver id is recorded on the enrolment'
);
select is(
  (select count(*)::int from public.fee_ledger where enrolment_id = (:'enrol4_result'::jsonb ->> 'enrolment_id')::uuid),
  0,
  'AC4: no ledger entry for a zero-value waived admission — nothing to record as money movement'
);

-- ── AC5: the same payment submitted twice is idempotent — a replay,
--    not a second student ─────────────────────────────────────────────

select public.fn_enrol_from_offer(:'offer1_id'::uuid, 'male'::public.gender, p_payment_id => :'payment2_id'::uuid, p_section_id => :'section_id'::uuid) as enrol_replay \gset
select is((:'enrol_replay'::jsonb ->> 'is_replay')::boolean, true, 'AC5: re-running the same offer/payment reports a replay');
select is(
  (:'enrol_replay'::jsonb ->> 'student_id')::uuid,
  (:'enrol_result'::jsonb ->> 'student_id')::uuid,
  'AC5: the replay returns the same student id, not a new one'
);
select is((select count(*)::int from public.enrolment where admission_offer_id = :'offer1_id'::uuid), 1, 'AC5: still only one enrolment row for that offer');

-- ── validation ──────────────────────────────────────────────────────

select pg_temp.new_accepted_offer('03005555555') as offer5_id \gset
select throws_ok(
  format('select public.fn_enrol_from_offer(%L, %L::public.gender, p_section_id => %L)', :'offer5_id', 'male', :'section_id'),
  'PAYMENT_OR_WAIVER_REQUIRED',
  'AC: neither a payment nor a waiver is refused'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.fn_enrol_from_offer(%L, %L::public.gender, p_section_id => %L)', :'offer5_id', 'male', :'section_id'),
  'FORBIDDEN',
  'a role with no admissions/accounts access cannot run the enrolment gate'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── tenant isolation ────────────────────────────────────────────────

reset role;
select public.provision_tenant('test-enrol-gate-other-co', 'Enrol Gate Other Co', 'owner@enrolgateotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-enrol-gate-other-co' \gset
select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'owner@enrolgateotherco2.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json, 'sub', :'other_user_id')::text,
  true
);
select throws_ok(
  format('select public.fn_enrol_from_offer(%L, %L::public.gender, p_payment_id => %L, p_section_id => %L)', :'offer5_id', 'male', :'payment2_id', :'section_id'),
  'OFFER_NOT_FOUND',
  'AC/defense-in-depth: another tenant cannot enrol against this tenant''s offer'
);
select is(
  (select count(*)::int from public.admission_fee_payment),
  0,
  'AC/defense-in-depth: another tenant''s owner sees zero admission fee payments via RLS'
);

select * from finish();
rollback;
