-- pgTAP tests for FR-D17: final settlement statement computation.
begin;
select plan(30);

select public.provision_tenant('test-settle-co', 'Settle Co', 'owner@settle.test');
select id as tenant_id from public.tenant where slug = 'test-settle-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-settle-other', 'Other Settle Co', 'owner@othersettle.test');
select id as other_tenant_id from public.tenant where slug = 'test-settle-other' \gset

select gen_random_uuid() as hr_uid \gset
select gen_random_uuid() as acc_uid \gset
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'hr_uid', 'h@settle.test', 'authenticated', 'authenticated', 'x'), (:'acc_uid', 'a@settle.test', 'authenticated', 'authenticated', 'x'),
  (:'owner_uid', 'o@settle.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@settle.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@settle.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'hr_uid', :'tenant_id', 'hr_manager', 'HR'), (:'acc_uid', :'tenant_id', 'accountant', 'Accountant'), (:'owner_uid', :'tenant_id', 'owner', 'Owner'),
  (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');
insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, doj, full_name) values
  (:'tenant_id', :'campus_id', 'ST-1', '42101-3333333-1', 'female', '2020-01-01', 'Leaver One'),
  (:'tenant_id', :'campus_id', 'ST-2', '42101-3333333-2', 'male', '2020-01-01', 'Leaver Two');
select id as s1 from public.staff where employee_code = 'ST-1' and tenant_id = :'tenant_id' \gset
select id as s2 from public.staff where employee_code = 'ST-2' and tenant_id = :'tenant_id' \gset

insert into public.leave_type (tenant_id, code, name_en, entitlement_days, is_encashable, encashment_cap_days) values
  (:'tenant_id', 'EARNED', 'Earned leave', 30, true, 10), (:'tenant_id', 'CASUAL', 'Casual leave', 10, false, null);
select id as earned from public.leave_type where tenant_id = :'tenant_id' and code = 'EARNED' \gset
select id as casual from public.leave_type where tenant_id = :'tenant_id' and code = 'CASUAL' \gset
insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days) values
  (:'tenant_id', :'s1', :'earned', 'grant', 12), (:'tenant_id', :'s1', :'casual', 'grant', 5);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_staff_contract(:'s1'::uuid, 'permanent', '2026-01-01'::date, null, 30::smallint, 80000);
select public.create_staff_contract(:'s2'::uuid, 'permanent', '2026-01-01'::date, null, 30::smallint, 50000);
select public.initiate_staff_exit(:'s1'::uuid, 'resignation', '2026-08-15'::date, '2026-08-20'::date) as ex1 \gset
select public.initiate_staff_exit(:'s2'::uuid, 'retirement', null, '2026-09-30'::date) as ex2 \gset
reset role;
insert into public.staff_loan (tenant_id, campus_id, staff_id, loan_type, principal_paisa, installment_paisa, repayment_start_month, total_repaid_paisa)
values (:'tenant_id', :'campus_id', :'s2', 'salary_advance', 5000000, 500000, '2026-06-01', 3000000);

-- ── AC1-AC3: the lines ───────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acc_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select amount_paisa from public.compute_final_settlement(:'ex1'::uuid) where line_type = 'salary'), 5161290::bigint, 'AC1: salary = 80,000 x 20/31 = Rs 51,612.90');
select is((select amount_paisa from public.compute_final_settlement(:'ex1'::uuid) where line_type = 'leave_encashment'), 2666670::bigint, 'AC2: encashment = 10 capped days x Rs 2,666.67 = Rs 26,666.70');
select is((select count(*) from public.compute_final_settlement(:'ex1'::uuid) where line_type = 'leave_encashment'), 1::bigint, 'AC2: casual leave is not encashable, so only earned leave produces a line');
select ok((select description like '%12 unused, capped at 10%' from public.compute_final_settlement(:'ex1'::uuid) where line_type = 'leave_encashment'), 'the line explains the cap');
select is((select amount_paisa from public.compute_final_settlement(:'ex1'::uuid) where line_type = 'notice_recovery'), 6666675::bigint, 'AC3: notice recovery = 25 days x Rs 2,666.67 = Rs 66,666.75');
select is((select sign from public.compute_final_settlement(:'ex1'::uuid) where line_type = 'notice_recovery'), (-1)::smallint, 'AC3: it is a deduction');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select * from public.compute_final_settlement(%L::uuid) $$, :'ex1'), 'FORBIDDEN', 'a teacher cannot compute a settlement');

-- ── draft: lines are rounded one by one and the total is their sum ───────
select set_config('request.jwt.claims', json_build_object('sub', :'acc_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_settlement_draft(:'ex1'::uuid) as st1 \gset
select is((select net_payable_paisa from public.staff_settlement where id = :'st1'::uuid), 1161285::bigint, 'net payable = 5,161,290 + 2,666,670 - 6,666,675 paisa, so the notice recovery is reflected');
select is((select net_payable_paisa from public.staff_settlement where id = :'st1'::uuid), (select sum(sign * amount_paisa)::bigint from public.staff_settlement_line where settlement_id = :'st1'::uuid), 'the printed lines tie exactly to the total');
select public.add_settlement_line(:'st1'::uuid, 'asset_recovery', 'Lost projector remote', 100000, (-1)::smallint) as manual \gset
select is((select net_payable_paisa from public.staff_settlement where id = :'st1'::uuid), 1061285::bigint, 'a manual recovery line changes the net');
select throws_ok(format($$ select public.add_settlement_line(%L::uuid, 'salary', 'fudge', 5, 1::smallint) $$, :'st1'), 'LINE_TYPE_COMPUTED', 'computed line types cannot be typed in');
select is(public.create_settlement_draft(:'ex1'::uuid), :'st1'::uuid, 're-computing the draft reuses it');
select is((select count(*) from public.staff_settlement_line where settlement_id = :'st1'::uuid and is_manual), 1::bigint, 'and keeps the manual line');
select lives_ok(format($$ select public.remove_settlement_line(%L::uuid) $$, :'manual'), 'a manual line can be removed from a draft');
select throws_ok(format($$ select public.remove_settlement_line(%L::uuid) $$, (select id from public.staff_settlement_line where settlement_id = :'st1'::uuid and line_type = 'salary')), 'LINE_IS_COMPUTED', 'a computed line cannot');

-- ── approval freezes the statement ───────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.approve_settlement(%L::uuid) $$, :'st1'), 'FORBIDDEN', 'HR cannot approve a settlement');
select set_config('request.jwt.claims', json_build_object('sub', :'acc_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.approve_settlement(:'st1'::uuid);
select is((select status::text from public.staff_settlement where id = :'st1'::uuid), 'approved', 'the Accountant approves');
select throws_ok(format($$ select public.add_settlement_line(%L::uuid, 'other', 'late addition', 5, 1::smallint) $$, :'st1'), 'SETTLEMENT_IMMUTABLE', 'no line can be added to an approved statement');
select throws_ok(format($$ select public.create_settlement_draft(%L::uuid) $$, :'ex1'), 'SETTLEMENT_ALREADY_APPROVED', 'and it cannot be recomputed over');
reset role;
select is((select sum(days) from public.leave_ledger where staff_id = :'s1'::uuid and leave_type_id = :'earned'::uuid), 2.00::numeric, 'approval takes the 10 encashed days out of the leave ledger');
select throws_ok(format($$ update public.staff_settlement_line set amount_paisa = 1 where settlement_id = %L and line_type = 'salary' $$, :'st1'), '42501', 'SETTLEMENT_IMMUTABLE', 'even a privileged session cannot edit an approved line');
select throws_ok(format($$ update public.staff_settlement set net_payable_paisa = 1 where id = %L $$, :'st1'), '42501', 'SETTLEMENT_IMMUTABLE', 'nor the approved total');

-- ── AC4: the PDF is sealed once ──────────────────────────────────────────
select public.store_settlement_pdf(:'st1'::uuid, :'tenant_id' || '/' || :'st1' || '.pdf', repeat('ab', 32));
select is((select pdf_sha256 from public.staff_settlement where id = :'st1'::uuid), repeat('ab', 32), 'AC4: the hash of the rendered PDF is stored with the statement');
select throws_ok(format($$ select public.store_settlement_pdf(%L::uuid, 'other.pdf', repeat('cd', 32)) $$, :'st1'), '42501', 'SETTLEMENT_PDF_SEALED', 'AC4: a second render cannot replace the sealed PDF');
select throws_ok(format($$ update public.staff_settlement set pdf_sha256 = repeat('ef', 32) where id = %L $$, :'st1'), '42501', 'SETTLEMENT_PDF_SEALED', 'AC4: nor can the hash be edited directly');

-- ── loans are recovered and closed when paid ─────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acc_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_settlement_draft(:'ex2'::uuid) as st2 \gset
select is((select amount_paisa from public.staff_settlement_line where settlement_id = :'st2'::uuid and line_type = 'advance_recovery'), 2000000::bigint, 'the outstanding Rs 20,000 of the advance is recovered');
select is((select net_payable_paisa from public.staff_settlement where id = :'st2'::uuid), 3000000::bigint, 'a full month (30/30 of 50,000) less the advance = Rs 30,000');
select public.approve_settlement(:'st2'::uuid);
select public.mark_settlement_paid(:'st2'::uuid);
reset role;
select is((select status from public.staff_loan where staff_id = :'s2'::uuid), 'closed', 'paying the statement closes the recovered loan');

-- ── visibility ───────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.staff_settlement), 0::bigint, 'a Principal cannot read settlements');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'accountant', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.staff_settlement), 0::bigint, 'another school sees none');

select * from finish();
rollback;
