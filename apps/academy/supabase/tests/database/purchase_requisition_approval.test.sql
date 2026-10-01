-- pgTAP tests for FR-R06: purchase requisition with approval thresholds.
begin;
select plan(38);

select public.provision_tenant('test-purchase-co', 'Purchase Co', 'owner@purchase.test');
select id as tenant_id from public.tenant where slug = 'test-purchase-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-purchase-other', 'Other Purchase Co', 'owner@otherpurchase.test');
select id as other_tenant_id from public.tenant where slug = 'test-purchase-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as hod_uid \gset
select gen_random_uuid() as other_hod_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@purchase.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@purchase.test', 'authenticated', 'authenticated', 'x'),
  (:'acct_uid', 'a@purchase.test', 'authenticated', 'authenticated', 'x'), (:'hod_uid', 'h@purchase.test', 'authenticated', 'authenticated', 'x'),
  (:'other_hod_uid', 'h2@purchase.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Director'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'acct_uid', :'tenant_id', 'accountant', 'Accountant'),
  (:'hod_uid', :'tenant_id', 'head_of_department', 'HOD'), (:'other_hod_uid', :'tenant_id', 'head_of_department', 'Other HOD');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── thresholds: Principal up to PKR 50,000, Director above ────────────────
select throws_ok(format($$ select public.resolve_approval_chain(100, %L) $$, :'campus_id'), 'THRESHOLDS_NOT_CONFIGURED', 'no approvals can be routed until the Owner sets thresholds');
select is(public.save_purchase_thresholds('[{"upto_amount": 5000000, "approver_role": "principal"}, {"upto_amount": null, "approver_role": "owner"}]'::jsonb, null, current_date), 2, 'two tiers are saved');
select throws_ok($$ select public.save_purchase_thresholds('[{"upto_amount": null, "approver_role": "principal"}, {"upto_amount": null, "approver_role": "owner"}]'::jsonb, null, current_date) $$, 'TIERS_INVALID', 'only the last tier may be open-ended');
select is(jsonb_array_length(public.resolve_approval_chain(3500000, :'campus_id'::uuid)), 1, 'PKR 35,000 resolves to one level');
select is(jsonb_array_length(public.resolve_approval_chain(25000000, :'campus_id'::uuid)), 2, 'PKR 250,000 resolves to two levels');

select public.create_inv_item('CHAIR', 'Classroom chair', 'consumable', 'pcs', null, null, null, 0, 0) as chair \gset
select public.create_inv_store(:'campus_id'::uuid, 'Main Store') as store \gset
select public.save_purchase_thresholds('[{"upto_amount": 5000000, "approver_role": "principal"}, {"upto_amount": null, "approver_role": "owner"}]'::jsonb, null, current_date);
select public.create_procurement_vendor('Chair Traders') as vendor \gset

-- ── AC1: PKR 35,000 needs the Principal only ──────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'hod_uid', 'tenant_id', :'tenant_id', 'app_role', 'head_of_department', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_requisition(:'campus_id'::uuid, 'Lab stools', '[{"description": "Stools", "qty": 10, "est_unit_cost": 350000}]'::jsonb) as r35 \gset
select is((select est_total from public.purchase_requisition where id = :'r35'::uuid), 3500000::bigint, 'the estimate is the sum of the lines (PKR 35,000)');
select is(jsonb_array_length(public.submit_requisition(:'r35'::uuid)), 1, 'AC1: only one approval level is required');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.v_requisition_approval_queue where req_id = :'r35'::uuid), 0::bigint, 'AC1: it never appears in the Director''s queue');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.v_requisition_approval_queue where req_id = :'r35'::uuid), 1::bigint, 'AC1: it is in the Principal''s queue');
select is(public.approve_requisition(:'r35'::uuid, 'ok')::text, 'approved', 'AC1: Principal approval alone completes it');

-- ── AC2: PKR 250,000 needs the Principal then the Director ────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'hod_uid', 'tenant_id', :'tenant_id', 'app_role', 'head_of_department', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_requisition(:'campus_id'::uuid, 'Classroom furniture', jsonb_build_array(jsonb_build_object('item_id', :'chair', 'description', 'Chairs', 'qty', 100, 'est_unit_cost', 250000))) as r250 \gset
select public.submit_requisition(:'r250'::uuid);
select is((select approval_chain -> 1 ->> 'approver_role' from public.purchase_requisition where id = :'r250'::uuid), 'owner', 'AC2: the chain is Principal then Director');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.approve_requisition(%L) $$, :'r250'), 'OUT_OF_ORDER', 'AC2: a Director approval attempted first is refused with OUT_OF_ORDER');
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.approve_requisition(%L) $$, :'r250'), 'FORBIDDEN', 'a role outside the chain cannot approve');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.approve_requisition(:'r250'::uuid)::text, 'pending', 'the Principal''s approval moves it to the Director');
select throws_ok(format($$ select public.approve_requisition(%L) $$, :'r250'), 'FORBIDDEN', 'the Principal cannot approve the Director''s level');

-- snapshot: changing the thresholds does not re-route a half-approved requisition
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_purchase_thresholds('[{"upto_amount": null, "approver_role": "owner"}]'::jsonb, null, current_date);
select is(jsonb_array_length((select approval_chain from public.purchase_requisition where id = :'r250'::uuid)), 2, 'the chain was snapshotted at submission: new thresholds do not re-route it');
select is(public.approve_requisition(:'r250'::uuid)::text, 'approved', 'the Director completes the snapshotted chain');
select public.save_purchase_thresholds('[{"upto_amount": 5000000, "approver_role": "principal"}, {"upto_amount": null, "approver_role": "owner"}]'::jsonb, null, current_date);

-- ── AC3: PO for 100 chairs, goods receipt of 92 ──────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.convert_to_purchase_order(:'r250'::uuid, :'vendor'::uuid) as po \gset
select is((select status::text from public.purchase_requisition where id = :'r250'::uuid), 'converted', 'the requisition is marked converted');
select throws_ok(format($$ select public.convert_to_purchase_order(%L, %L) $$, :'r250', :'vendor'), 'REQUISITION_NOT_APPROVED', 'a converted requisition cannot be converted twice');
select is((select qty_ordered from public.purchase_order_line where po_id = :'po'::uuid), 100::numeric, 'the PO carries 100 chairs');
select public.post_goods_receipt(:'po'::uuid, :'store'::uuid, jsonb_build_array(jsonb_build_object('po_line_id', (select id from public.purchase_order_line where po_id = :'po'::uuid), 'qty_received', 92))) as grn \gset
select is((select on_hand from public.v_stock_on_hand where item_id = :'chair'::uuid), 92::numeric, 'AC3: a +92 stock movement is posted (the received quantity, not the ordered one)');
select is((select status::text from public.purchase_order where id = :'po'::uuid), 'partially_fulfilled', 'AC3: the PO stays partially_fulfilled');
select is((select shortfall from public.v_purchase_order_line where po_id = :'po'::uuid), 8::numeric, 'AC3: and the shortfall of 8 is visible on the PO');
select throws_ok(format($$ select public.post_goods_receipt(%L, %L, %L::jsonb) $$, :'po', :'store', jsonb_build_array(jsonb_build_object('po_line_id', (select id from public.purchase_order_line where po_id = :'po'::uuid), 'qty_received', 9))), 'RECEIPT_EXCEEDS_ORDER', 'receiving more than was ordered is refused');
select public.post_goods_receipt(:'po'::uuid, :'store'::uuid, jsonb_build_array(jsonb_build_object('po_line_id', (select id from public.purchase_order_line where po_id = :'po'::uuid), 'qty_received', 8)));
select is((select status::text from public.purchase_order where id = :'po'::uuid), 'fulfilled', 'the late 8 chairs make the PO fulfilled');
select is((select on_hand from public.v_stock_on_hand where item_id = :'chair'::uuid), 100::numeric, 'and stock is 100');

-- ── AC4: editing after the first approval voids everything and restarts ───
select set_config('request.jwt.claims', json_build_object('sub', :'hod_uid', 'tenant_id', :'tenant_id', 'app_role', 'head_of_department', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_requisition(:'campus_id'::uuid, 'Projector screens', '[{"description": "Screens", "qty": 10, "est_unit_cost": 2500000}]'::jsonb) as redit \gset
select public.submit_requisition(:'redit'::uuid);
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.approve_requisition(:'redit'::uuid);
select is((select current_level from public.purchase_requisition where id = :'redit'::uuid), 2, 'the first approval moved it to level 2');
select set_config('request.jwt.claims', json_build_object('sub', :'other_hod_uid', 'tenant_id', :'tenant_id', 'app_role', 'head_of_department', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.update_requisition(%L, 'hijack', '[{"description": "x", "qty": 1, "est_unit_cost": 1}]'::jsonb) $$, :'redit'), 'FORBIDDEN', 'only the requester can edit it');
select set_config('request.jwt.claims', json_build_object('sub', :'hod_uid', 'tenant_id', :'tenant_id', 'app_role', 'head_of_department', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.update_requisition(:'redit'::uuid, 'Projector screens (revised)', '[{"description": "Screens", "qty": 4, "est_unit_cost": 500000}]'::jsonb);
select is((select count(*) from public.purchase_approval where req_id = :'redit'::uuid and voided_at is null), 0::bigint, 'AC4: all approvals are voided');
select is((select count(*) from public.purchase_approval where req_id = :'redit'::uuid and voided_at is not null), 1::bigint, 'AC4: and kept for the audit trail');
select is((select current_level from public.purchase_requisition where id = :'redit'::uuid), 1, 'AC4: the chain restarts from level 1');
select is((select version from public.purchase_requisition where id = :'redit'::uuid), 2, 'AC4: the version moves on');
select is(jsonb_array_length((select approval_chain from public.purchase_requisition where id = :'redit'::uuid)), 1, 'the smaller amount (PKR 20,000) now needs only the Principal');
reset role;
select ok((select count(*) >= 1 from public.audit_log where table_name = 'purchase_requisition' and row_id = :'redit'::uuid and action = 'update' and 'version' = any (changed_columns)), 'AC4: the edit is written to the audit log');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.approve_requisition(:'redit'::uuid);
select set_config('request.jwt.claims', json_build_object('sub', :'hod_uid', 'tenant_id', :'tenant_id', 'app_role', 'head_of_department', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.update_requisition(%L, 'late edit', '[{"description": "x", "qty": 1, "est_unit_cost": 1}]'::jsonb) $$, :'redit'), 'REQUISITION_LOCKED', 'an approved requisition can no longer be edited');
select is((select count(*) from public.purchase_requisition), 3::bigint, 'the requester sees their own requisitions');
select set_config('request.jwt.claims', json_build_object('sub', :'other_hod_uid', 'tenant_id', :'tenant_id', 'app_role', 'head_of_department', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.purchase_requisition), 0::bigint, 'another requester does not see them');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.purchase_requisition), 0::bigint, 'another school sees none');

select * from finish();
rollback;
