-- pgTAP tests: transport (FR-P04), hostel + mess (FR-Q06) and library recovery fees are lines on the
-- generated fee challan, with no ledger double counting, gap-free numbering and idempotent re-runs.
begin;
select plan(31);

select date_trunc('month', current_date)::date as m0 \gset
select (date_trunc('month', current_date) + interval '1 month')::date as m1 \gset

select public.provision_tenant('test-anc-co', 'Ancillary Co', 'owner@anc.test');
select id as tenant_id from public.tenant where slug = 'test-anc-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as tm_uid \gset
select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as prin_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@anc.test', 'authenticated', 'authenticated', 'x'), (:'tm_uid', 'tm@anc.test', 'authenticated', 'authenticated', 'x'),
  (:'acct_uid', 'a@anc.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@anc.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'tm_uid', :'tenant_id', 'transport_manager', 'Transport Manager'),
  (:'acct_uid', :'tenant_id', 'accountant', 'Accountant'), (:'prin_uid', :'tenant_id', 'principal', 'Principal');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset

-- S1 rides the bus, S2 is a boarder (staff-child room concession), S3 is a day scholar who starts the
-- bus after the first run, S4 buys a uniform on the fee ledger.
select public.create_student(:'campus_id'::uuid, 'Rider One', '2015-01-01'::date, 'male') as s1 \gset
select public.create_student(:'campus_id'::uuid, 'Boarder Two', '2012-01-01'::date, 'male') as s2 \gset
select public.create_student(:'campus_id'::uuid, 'Plain Three', '2015-01-01'::date, 'male') as s3 \gset
select public.create_student(:'campus_id'::uuid, 'Buyer Four', '2015-01-01'::date, 'female') as s4 \gset

select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);

select public.enrol_student(:'section_id'::uuid, :'s1'::uuid) as e1 \gset
select public.enrol_student(:'section_id'::uuid, :'s2'::uuid) as e2 \gset
select public.enrol_student(:'section_id'::uuid, :'s3'::uuid) as e3 \gset
select public.enrol_student(:'section_id'::uuid, :'s4'::uuid) as e4 \gset

-- Hostel: quad PKR 8,000, mess PKR 350 a day, deposit PKR 20,000.
select public.create_hostel_block(:'campus_id'::uuid, 'IQ', 'Iqbal Block', 'male', 2, 4) as iq \gset
select public.allocate_bed(:'s2'::uuid, (select id from public.hostel_bed where bed_code = 'IQ-101-B1'), '2026-01-05');
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_hostel_tariff(:'campus_id'::uuid, 'quad', 800000, 35000, 2000000, '2026-01-01');

-- Transport: Zone B PKR 3,500 (full-month policy by default) on a 40-seat bus.
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_transport_route(:'campus_id'::uuid, 'R-1', 'Morning', 'morning') as r1 \gset
select public.save_fare_slab(:'campus_id'::uuid, 'ZONE-B', 'Zone B', 350000, '2026-01-01') as zb \gset
select public.add_transport_stop(:'r1'::uuid, 'Gate', null, null, null, '06:45', '14:10', :'zb'::uuid) as stop_b \gset
select public.save_transport_vehicle(:'campus_id'::uuid, 'BUS-1', 40) as bus \gset
select public.add_vehicle_document(:'bus'::uuid, t::public.transport_doc_type, '2030-01-01') from (values ('fitness'), ('insurance'), ('token_tax')) y(t);
select public.save_transport_crew(:'campus_id'::uuid, 'Driver', '35202-1111111-1', 'driver', null, 'L1', 'HTV', '2030-01-01', '2026-01-01') as drv \gset
select public.assign_transport_trip(:'r1'::uuid, :'bus'::uuid, :'drv'::uuid, '2026-01-01');
select public.allocate_transport(:'s1'::uuid, :'stop_b'::uuid, :'stop_b'::uuid, :'m0'::date);

-- Inventory: S4 buys a shirt on the fee ledger.
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_inv_item('SHIRT-26', 'School Shirt', 'uniform', 'pcs', '26', null, null, 0, 120000) as shirt \gset
select public.create_inv_store(:'campus_id'::uuid, 'Main Store') as store \gset
select public.post_stock_movement(:'store'::uuid, :'shirt'::uuid, 'receipt', 10);

-- A staff-child 50 percent concession scoped to the room head only.
reset role;
select app.fn_hostel_fee_head(:'tenant_id'::uuid, 'HOSTEL_ROOM') as room_head \gset
insert into public.concession_scheme (tenant_id, code, name_en, name_ur, calc_type, value, applicable_head_ids)
values (:'tenant_id', 'STAFFKID', 'Staff child', 'x', 'percentage', 50, array[:'room_head'::uuid]) returning id as scheme \gset
insert into public.concession_award (tenant_id, campus_id, enrolment_id, scheme_id, calc_type, value, effective_from, effective_to, status, approved_by, approved_at)
values (:'tenant_id', :'campus_id', :'e2'::uuid, :'scheme'::uuid, 'percentage', 50, '2026-01-01', '2036-12-31', 'approved', :'prin_uid', now());

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_sale(:'s4'::uuid, jsonb_build_array(jsonb_build_object('item_id', :'shirt', 'qty', 1)), 'fee_ledger');

-- ── the month's cron jobs post first ──────────────────────────────────────────
select public.post_transport_charges(:'m0'::date);
select public.post_hostel_charges(:'m0'::date);
select public.hostel_monthly_amount(:'s2'::uuid, :'m0'::date) ->> 'mess_net_paisa' as mess \gset
select count(*) as ledger_before from public.fee_ledger where tenant_id = :'tenant_id' \gset

select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, :'m0'::date, true) as dry \gset
select is((:'dry'::jsonb ->> 'generated')::int, 4, 'dry run: four enrolments are billable');
select is((select count(*) from public.fee_challan_ledger_link), 0::bigint, 'a dry run absorbs no ledger row');

select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, :'m0'::date) as run1 \gset
select is((:'run1'::jsonb ->> 'generated')::int, 4, 'run 1: four challans generated');
select is((:'run1'::jsonb ->> 'failed')::int, 0, 'run 1: no failures');

-- transport
select id as c1 from public.fee_challan where enrolment_id = :'e1'::uuid and billing_period = :'m0'::date \gset
select is((select net_paisa from public.fee_challan_line l join public.fee_head h on h.id = l.fee_head_id where l.challan_id = :'c1' and h.code = 'TRANSPORT'), 350000::bigint, 'FR-P04: a separate TRANSPORT line of PKR 3,500 is on the challan');
select is((select count(*) from public.fee_challan_line where challan_id = :'c1'), 2::bigint, 'the challan has the tuition line and the transport line');
select is((select gross_paisa || '/' || net_paisa || '/' || arrears_paisa from public.fee_challan where id = :'c1'), '850000/850000/0', 'header totals include transport and the bus fee is not also carried as arrears');
select is((select public.outstanding_balance_as_of(:'e1'::uuid)), 850000::bigint, 'ledger balance equals the challan net: transport is not double counted');
select is((select count(*) from public.fee_ledger where enrolment_id = :'e1'::uuid and fee_head_id = (select id from public.fee_head where tenant_id = :'tenant_id' and code = 'TRANSPORT')), 1::bigint, 'still exactly one TRANSPORT ledger row');

-- hostel
select id as c2 from public.fee_challan where enrolment_id = :'e2'::uuid and billing_period = :'m0'::date \gset
select is((select net_paisa from public.fee_challan_line l join public.fee_head h on h.id = l.fee_head_id where l.challan_id = :'c2' and h.code = 'HOSTEL_ROOM'), 400000::bigint, 'FR-Q06: HOSTEL_ROOM line is PKR 8,000 less the 50% staff-child concession = PKR 4,000');
select is((select concession_paisa from public.fee_challan_line l join public.fee_head h on h.id = l.fee_head_id where l.challan_id = :'c2' and h.code = 'HOSTEL_ROOM'), 400000::bigint, 'the room concession is shown on the room line');
select is((select net_paisa::text from public.fee_challan_line l join public.fee_head h on h.id = l.fee_head_id where l.challan_id = :'c2' and h.code = 'HOSTEL_MESS'), :'mess', 'HOSTEL_MESS line is the mess for actual days, unaffected by the room concession');
select is((select net_paisa from public.fee_challan_line l join public.fee_head h on h.id = l.fee_head_id where l.challan_id = :'c2' and h.code = 'HOSTEL_DEPOSIT'), 2000000::bigint, 'the refundable PKR 20,000 deposit is on the first challan');
select is((select net_paisa from public.fee_challan where id = :'c2'), 500000 + 400000 + :'mess'::bigint + 2000000, 'boarder challan total = tuition + room + mess + deposit');
select is((select public.outstanding_balance_as_of(:'e2'::uuid)), (select net_paisa from public.fee_challan where id = :'c2'), 'boarder ledger balance equals the challan net');

-- sales (FR-R02) no longer billed twice
select id as c4 from public.fee_challan where enrolment_id = :'e4'::uuid and billing_period = :'m0'::date \gset
select is((select net_paisa || '/' || arrears_paisa from public.fee_challan where id = :'c4'), '620000/0', 'a charge-to-fee sale is one UNIFORM_BOOKS line, not also arrears');
select is((select public.outstanding_balance_as_of(:'e4'::uuid)), 620000::bigint, 'sale: ledger balance equals the challan net');

-- ledger gained only the plan charge rows (4 charges + 1 concession-free); no ancillary row was added
select is((select count(*) from public.fee_ledger where tenant_id = :'tenant_id') - :'ledger_before'::bigint, 4::bigint, 'generation posted only the four plan charges to the ledger');

-- PDF data layer shows the line
select is((select count(*) from jsonb_array_elements(public.build_challan_render_payload(:'c1'::uuid) -> 'lines') x where x ->> 'head_name' = 'Transport Fee' and (x ->> 'net_paisa')::bigint = 350000), 1::bigint, 'the challan PDF payload carries the transport line');

-- idempotent re-generation, gap-free numbering
reset role;
select last_no as last_before from public.challan_counter where tenant_id = :'tenant_id' and campus_id = :'campus_id' and session_id = :'session_id' \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, :'m0'::date) as run2 \gset
select is((:'run2'::jsonb ->> 'generated')::int || '/' || (:'run2'::jsonb ->> 'skipped')::int, '0/4', 're-run: nothing generated, all skipped');
reset role;
select is((select last_no from public.challan_counter where tenant_id = :'tenant_id' and campus_id = :'campus_id' and session_id = :'session_id'), :'last_before'::bigint, 're-run consumes no challan number');
select is((select count(*) from public.fee_challan_ledger_link), (select count(*) from (select distinct ledger_id from public.fee_challan_ledger_link) d), 'no ledger row is linked twice');
select is((select last_no from public.challan_counter where tenant_id = :'tenant_id' and campus_id = :'campus_id' and session_id = :'session_id'), (select count(*) from public.fee_challan where tenant_id = :'tenant_id'), 'challan numbers are gap-free (counter equals challans issued)');

-- ── next month: late-started bus rides the next challan, deposit never repeats ──
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.allocate_transport(:'s3'::uuid, :'stop_b'::uuid, :'stop_b'::uuid, :'m0'::date);
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.post_transport_charges(:'m0'::date);
select public.post_transport_charges(:'m1'::date);
select public.post_hostel_charges(:'m1'::date);
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, :'m1'::date) as run3 \gset
select is((:'run3'::jsonb ->> 'generated')::int, 4, 'next month: four challans');
select id as c3b from public.fee_challan where enrolment_id = :'e3'::uuid and billing_period = :'m1'::date \gset
select is((select net_paisa from public.fee_challan_line l join public.fee_head h on h.id = l.fee_head_id where l.challan_id = :'c3b' and h.code = 'TRANSPORT'), 700000::bigint, 'a bus fee posted after the first run is not lost: two months ride the next challan');
select is((select arrears_paisa from public.fee_challan where id = :'c3b'), 500000::bigint, 'and arrears are only the unpaid tuition of the first challan');
select is((select count(*) from public.fee_challan_line l join public.fee_head h on h.id = l.fee_head_id join public.fee_challan c on c.id = l.challan_id where c.enrolment_id = :'e2'::uuid and c.billing_period = :'m1'::date and h.code = 'HOSTEL_DEPOSIT'), 0::bigint, 'the hostel deposit is on the first challan only');
select id as c1b from public.fee_challan where enrolment_id = :'e1'::uuid and billing_period = :'m1'::date \gset
select is((select arrears_paisa from public.fee_challan where id = :'c1b'), 850000::bigint, 'the previous challan is carried as arrears exactly once');

reset role;
-- library recovery (FR-O08): a LIB_RECOVERY charge is billable; its reversal washes it out
insert into public.fee_head (tenant_id, code, name_en, name_ur, default_frequency) values (:'tenant_id', 'LIB_RECOVERY', 'Library Recovery', 'x', 'one_time') returning id as lib_head \gset
insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction, value_date, source_type, source_id)
values (:'tenant_id', :'campus_id', :'e3', :'session_id', 'charge', :'lib_head', 139500, 'debit', :'m1', 'library_write_off', gen_random_uuid()) returning id as lib_led \gset
select is((select gross_paisa from app.fn_ancillary_challan_lines(:'e3'::uuid, :'m1'::date + 30) where fee_head_id = :'lib_head'::uuid), 139500::bigint, 'FR-O08: a LIB_RECOVERY write-off charge is billable on the next challan');
insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction, value_date, source_type, source_id, reversal_of_id)
values (:'tenant_id', :'campus_id', :'e3', :'session_id', 'reversal', :'lib_head', 139500, 'credit', :'m1', 'reversal', :'lib_led', :'lib_led');
select is((select gross_paisa from app.fn_ancillary_challan_lines(:'e3'::uuid, :'m1'::date + 30) where fee_head_id = :'lib_head'::uuid), 0::bigint, 'and a found-book reversal nets it to nothing, so no line is printed');

-- a cancelled challan releases its ancillary rows to the next run
reset role;
update public.fee_challan set status = 'cancelled' where id = :'c1b';
select is((select count(*) from app.fn_ancillary_challan_lines(:'e1'::uuid, :'m1'::date + 30)), 1::bigint, 'cancelling a challan makes its transport row billable again');

select * from finish();
rollback;
