-- pgTAP tests for FR-Q06: hostel and mess fee derivation.
begin;
select plan(22);

select public.provision_tenant('test-hfee-co', 'Hostel Fee Co', 'owner@hfee.test');
select id as tenant_id from public.tenant where slug = 'test-hfee-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-hfee-other', 'Other Hostel Fee Co', 'owner@otherhfee.test');
select id as other_tenant_id from public.tenant where slug = 'test-hfee-other' \gset

select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'prin_uid', 'p@hfee.test', 'authenticated', 'authenticated', 'x'), (:'acct_uid', 'a@hfee.test', 'authenticated', 'authenticated', 'x'),
  (:'parent_uid', 'par@hfee.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'acct_uid', :'tenant_id', 'accountant', 'Accountant');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.create_hostel_block(:'campus_id'::uuid, 'IQ', 'Iqbal Block', 'male', 2, 4) as iq \gset
select public.create_student(:'campus_id'::uuid, 'Boarder A', '2012-01-01'::date, 'male') as sa \gset
select public.create_student(:'campus_id'::uuid, 'Leaver B', '2012-01-01'::date, 'male') as sb \gset
select public.create_student(:'campus_id'::uuid, 'Staff Child C', '2012-01-01'::date, 'male') as sc \gset
select public.enrol_student(:'section_id'::uuid, :'sa'::uuid) as ea \gset
select public.enrol_student(:'section_id'::uuid, :'sb'::uuid) as eb \gset
select public.enrol_student(:'section_id'::uuid, :'sc'::uuid) as ec \gset
select public.allocate_bed(:'sa'::uuid, (select id from public.hostel_bed where bed_code = 'IQ-101-B1'), '2026-01-05');
select public.allocate_bed(:'sb'::uuid, (select id from public.hostel_bed where bed_code = 'IQ-101-B2'), '2026-01-05');
select public.allocate_bed(:'sc'::uuid, (select id from public.hostel_bed where bed_code = 'IQ-101-B3'), '2026-01-05');

-- Quad tariff PKR 8,000, mess PKR 350 a day, deposit PKR 20,000.
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_hostel_tariff(:'campus_id'::uuid, 'quad', 800000, 35000, 2000000, '2026-01-01');
select throws_ok(format($$ select public.save_hostel_tariff(%L, 'quad', 0, 0, 0, '2026-02-01') $$, :'campus_id'), 'AMOUNT_INVALID', 'a tariff must have a positive room amount');

-- Mess-off of 5 days for A in August: 26 billable days.
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.record_mess_off(:'sa'::uuid, '2026-08-10', '2026-08-14', 'Home');
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- AC1
select is(public.hostel_monthly_amount(:'sa'::uuid, '2026-08-01') ->> 'mess_days', '26', 'the breakdown shows 26 billable mess days');
select is(public.post_hostel_charges('2026-08-01'), 9, 'posting August writes room, mess and deposit lines for the three boarders') ;
select is((select amount_paisa from public.fee_ledger l join public.fee_head h on h.id = l.fee_head_id where l.enrolment_id = :'ea'::uuid and h.code = 'HOSTEL_ROOM' and l.value_date = '2026-08-01'), 800000::bigint, 'AC1: August posts PKR 8,000 to HOSTEL_ROOM (a mess-off never reduces the room fee)');
select is((select amount_paisa from public.fee_ledger l join public.fee_head h on h.id = l.fee_head_id where l.enrolment_id = :'ea'::uuid and h.code = 'HOSTEL_MESS' and l.value_date = '2026-08-01'), 910000::bigint, 'AC1: and PKR 9,100 (26 x 350) to HOSTEL_MESS as a separate line');
select is((select count(*) from public.fee_ledger l join public.fee_head h on h.id = l.fee_head_id where l.enrolment_id = :'ea'::uuid and h.code in ('HOSTEL_ROOM', 'HOSTEL_MESS') and l.value_date = '2026-08-01'), 2::bigint, 'AC1: two ledger lines');
select is(public.post_hostel_charges('2026-08-01'), 0, 'posting again writes nothing');

-- AC2: the deposit appears once, on a liability head, and is traceable.
select is((select count(*) from public.fee_ledger l join public.fee_head h on h.id = l.fee_head_id where l.enrolment_id = :'ea'::uuid and h.code = 'HOSTEL_DEPOSIT'), 1::bigint, 'AC2: the PKR 20,000 deposit is charged at the first posting');
select public.post_hostel_charges('2026-09-01');
select is((select count(*) from public.fee_ledger l join public.fee_head h on h.id = l.fee_head_id where l.enrolment_id = :'ea'::uuid and h.code = 'HOSTEL_DEPOSIT'), 1::bigint, 'AC2: and never again on a later challan');
select ok((select is_refundable and gl_code = 'LIAB-HOSTEL-DEPOSIT' from public.fee_head where tenant_id = :'tenant_id' and code = 'HOSTEL_DEPOSIT'), 'AC2: the deposit head is a refundable liability, not income');
select ok((select ledger_id is not null and amount_paisa = 2000000 from public.hostel_security_deposit where student_id = :'sa'::uuid), 'AC2: the deposit row points at its ledger line');
select throws_ok(format($$ select public.refund_hostel_deposit(%L, 'RV-1') $$, (select id from public.hostel_security_deposit where student_id = :'sa'::uuid)), 'DEPOSIT_NOT_RECEIVED', 'a deposit that was never received cannot be refunded');

-- AC3: leaves on 2026-11-12 in a 30-day month.
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.vacate_bed(id, '2026-11-12', 'Left school') from public.hostel_allocation where student_id = :'sb'::uuid;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.post_hostel_charges('2026-11-01');
select is((select amount_paisa from public.fee_ledger l join public.fee_head h on h.id = l.fee_head_id where l.enrolment_id = :'eb'::uuid and h.code = 'HOSTEL_ROOM' and l.value_date = '2026-11-01'), 320000::bigint, 'AC3: the room tariff is pro-rated at 12/30 = PKR 3,200');
select is((select amount_paisa from public.fee_ledger l join public.fee_head h on h.id = l.fee_head_id where l.enrolment_id = :'eb'::uuid and h.code = 'HOSTEL_MESS' and l.value_date = '2026-11-01'), 420000::bigint, 'AC3: and mess is billed only for the 12 days consumed');

-- Refund on leaving is traceable.
select public.receive_hostel_deposit((select id from public.hostel_security_deposit where student_id = :'sb'::uuid), '2026-01-06');
select public.refund_hostel_deposit((select id from public.hostel_security_deposit where student_id = :'sb'::uuid), 'RV-2026-77', '2026-11-13');
select ok((select refunded_on = '2026-11-13' and refund_voucher_no = 'RV-2026-77' from public.hostel_security_deposit where student_id = :'sb'::uuid), 'the refund records the date and voucher');
select is((select count(*) from public.fee_ledger where source_id = (select id from public.hostel_security_deposit where student_id = :'sb'::uuid) and source_type in ('hostel_deposit_release', 'hostel_deposit_refund')), 2::bigint, 'and posts the release and the refund to the ledger');
select throws_ok(format($$ select public.refund_hostel_deposit(%L, 'RV-2') $$, (select id from public.hostel_security_deposit where student_id = :'sb'::uuid)), 'DEPOSIT_REFUNDED', 'a deposit is refunded once');

-- AC4: 50 percent staff-child concession scoped to accommodation.
reset role;
select id as room_head from public.fee_head where tenant_id = :'tenant_id' and code = 'HOSTEL_ROOM' \gset
insert into public.concession_scheme (tenant_id, code, name_en, name_ur, calc_type, value, applicable_head_ids)
values (:'tenant_id', 'STAFFKID', 'Staff child', 'اسٹاف بچہ', 'percentage', 50, array[:'room_head'::uuid]) returning id as scheme \gset
insert into public.concession_award (tenant_id, campus_id, enrolment_id, scheme_id, calc_type, value, effective_from, effective_to, status, approved_by, approved_at)
values (:'tenant_id', :'campus_id', :'ec'::uuid, :'scheme'::uuid, 'percentage', 50, '2026-01-01', '2026-12-31', 'approved', :'prin_uid', now());
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.hostel_monthly_amount(:'sc'::uuid, '2026-08-01') ->> 'room_net_paisa', '400000', 'AC4: the room tariff is discounted to PKR 4,000');
select is(public.hostel_monthly_amount(:'sc'::uuid, '2026-08-01') ->> 'mess_net_paisa', '1085000', 'AC4: the mess charge is unaffected (31 x 350 = PKR 10,850)');
select public.post_hostel_charges('2026-08-01');
select ok((select count(*) = 1 and sum(amount_paisa) = 400000 from public.fee_ledger l join public.fee_head h on h.id = l.fee_head_id where l.enrolment_id = :'ec'::uuid and h.code = 'HOSTEL_ROOM' and l.entry_type = 'concession' and l.value_date = '2026-08-01'), 'AC4: the concession is posted against the room head only');

-- A mess-off approved after posting is trued up by the next run.
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.record_mess_off(:'sa'::uuid, '2026-09-01', '2026-09-02', 'Late');
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.post_hostel_charges('2026-09-01');
select is((select sum(case direction when 'debit' then amount_paisa else -amount_paisa end)::bigint from public.fee_ledger l join public.fee_head h on h.id = l.fee_head_id where l.enrolment_id = :'ea'::uuid and h.code = 'HOSTEL_MESS' and l.value_date = '2026-09-01'), 28 * 35000::bigint, 'a mess-off recorded after posting is corrected by an adjustment line (28 days in September)');

select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'principal', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.hostel_tariff), 0::bigint, 'another school sees no tariffs');

select * from finish();
rollback;
