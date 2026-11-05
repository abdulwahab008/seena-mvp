-- pgTAP tests for the 6 Nov 2026 browser-audit fixes in admissions and fees: the parent becomes
-- the primary guardian (BUG-10), the admission fee is charged as well as paid (BUG-11), admission
-- cash goes through the counter shift (BUG-16) and reaches the collection report (BUG-12).
begin;
select plan(9);

select public.provision_tenant('test-audit-adm-co', 'Audit Admissions Co', 'owner@auditadm.test');
select id as tenant_id from public.tenant where slug = 'test-audit-adm-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as officer_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'officer_id', 'officer@auditadm.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'officer_id', :'tenant_id', 'admissions_officer', 'Front Desk');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'officer_id', :'tenant_id', :'campus_id');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class1_id', p_name => 'A', p_capacity => 30) as section_id \gset
select public.create_cash_counter(:'campus_id'::uuid, 'Front desk') as counter_id \gset

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'officer_id')::text, true);

select throws_ok(
  format($$ select public.fn_quick_admission(%L, %L, 'No Shift Kid', '2019-02-02', 'female', %L, %L, 'Parent A', '+923335551001', 4000, 'cash') $$,
         :'campus_id', :'session_id', :'class1_id', :'section_id'),
  '55000', 'COUNTER_SESSION_REQUIRED: open a counter session first',
  'BUG-16: admission cash without an open counter shift is refused'
);
select lives_ok(
  format($$ select public.fn_quick_admission(%L, %L, 'Bank Kid', '2019-02-02', 'male', %L, %L, 'Parent B', '+923335551002', 4000, 'bank_challan') $$,
         :'campus_id', :'session_id', :'class1_id', :'section_id'),
  'BUG-16: a non-cash admission payment needs no shift'
);

select public.open_counter_session(:'counter_id'::uuid, 0) as shift_id \gset
select public.fn_quick_admission(:'campus_id'::uuid, :'session_id'::uuid, 'Walk In Kid', '2019-03-15', 'male', :'class1_id'::uuid, :'section_id'::uuid,
       'Imran Khan', '+923335551003', 4000, 'cash') as admitted \gset

select is(
  ((public.counter_session_totals(:'shift_id'::uuid)) ->> 'cash_total_paisa')::bigint,
  400000::bigint,
  'BUG-16: the admission cash counts in the front-desk shift'
);

reset role;
select (:'admitted'::jsonb ->> 'student_id')::uuid as student_id \gset
select (:'admitted'::jsonb ->> 'enrolment_id')::uuid as enrol_id \gset

select is(
  (select g.name_en || ' ' || g.phone_e164 from public.student_guardian sg join public.guardian g on g.id = sg.guardian_id
    where sg.student_id = :'student_id'::uuid and sg.is_primary),
  'Imran Khan +923335551003',
  'BUG-10: the parent from the admission desk is the primary guardian'
);
select is(
  (select count(*)::int from public.fee_ledger where enrolment_id = :'enrol_id'::uuid and entry_type = 'charge' and direction = 'debit' and amount_paisa = 400000),
  1,
  'BUG-11: the admission fee is charged'
);
select is(
  (select sum(case when direction = 'debit' then amount_paisa else -amount_paisa end)::bigint from public.fee_ledger where enrolment_id = :'enrol_id'::uuid),
  0::bigint,
  'BUG-11: and with its payment the student owes nothing and is owed nothing'
);
select is(
  (select sum(amount_paisa)::bigint from public.v_daily_collection where campus_id = :'campus_id'::uuid and source = 'admission_fee_payment'),
  800000::bigint,
  'BUG-12: both admission payments are in the daily collection'
);

-- A second child with the same parent phone reuses the guardian.
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'officer_id')::text, true);
set local role authenticated;
select public.fn_quick_admission(:'campus_id'::uuid, :'session_id'::uuid, 'Sibling Kid', '2017-01-10', 'female', :'class1_id'::uuid, :'section_id'::uuid,
       'Imran Khan', '+923335551003', 0, 'cash') as sibling \gset
reset role;
select is(
  (select count(*)::int from public.guardian where tenant_id = :'tenant_id'::uuid and phone_e164 = '+923335551003'),
  1,
  'BUG-10: a sibling with the same parent phone shares one guardian record'
);
select is(
  (select count(*)::int from public.student_guardian where student_id = (:'sibling'::jsonb ->> 'student_id')::uuid),
  1,
  'BUG-10: and that guardian is linked to the sibling too'
);

select * from finish();
rollback;
