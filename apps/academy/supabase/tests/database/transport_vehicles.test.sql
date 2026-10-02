-- pgTAP tests for FR-P02: vehicle register with document expiry block.
begin;
select plan(24);

select public.provision_tenant('test-vehicle-co', 'Vehicle Co', 'owner@vehicle.test');
select id as tenant_id from public.tenant where slug = 'test-vehicle-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-vehicle-other', 'Other Vehicle Co', 'owner@othervehicle.test');
select id as other_tenant_id from public.tenant where slug = 'test-vehicle-other' \gset

select gen_random_uuid() as tm_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'tm_uid', 'tm@vehicle.test', 'authenticated', 'authenticated', 'x'),
  (:'prin_uid', 'prin@vehicle.test', 'authenticated', 'authenticated', 'x'),
  (:'teacher_uid', 'teacher@vehicle.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'tm_uid', :'tenant_id', 'transport_manager', 'Transport Manager'),
  (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'teacher_uid', :'tenant_id', 'class_teacher', 'Teacher');
insert into public.user_campus (user_id, tenant_id, campus_id) values
  (:'tm_uid', :'tenant_id', :'campus_id'), (:'prin_uid', :'tenant_id', :'campus_id');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- AC1: LEB-1234 fitness certificate expired 2026-07-01, assignment on 2026-07-29 refused.
select public.save_transport_vehicle(:'campus_id'::uuid, 'leb-1234', 42, 'Hino', 'RK', 'diesel', 'owned') as veh \gset
select is((select reg_no from public.transport_vehicle where id = :'veh'::uuid), 'LEB-1234', 'the registration is stored normalised');
select public.add_vehicle_document(:'veh'::uuid, 'fitness', '2026-07-01', 'F-77', '2025-07-02');
select public.add_vehicle_document(:'veh'::uuid, 'insurance', '2027-01-01');
select public.add_vehicle_document(:'veh'::uuid, 'token_tax', '2027-01-01');
select throws_ok(format($$ select public.assert_vehicle_roadworthy(%L, '2026-07-29') $$, :'veh'), 'P0001', 'VEHICLE_BLOCKED: fitness certificate expired 28 days ago', 'AC1: fitness expired 28 days ago blocks the assignment');
select lives_ok(format($$ select public.assert_vehicle_roadworthy(%L, '2026-07-01') $$, :'veh'), 'the certificate is still valid on its last day');
select throws_ok(format($$ select public.save_transport_vehicle(%L, 'LEB-1234', 40) $$, :'campus_id'), 'VEHICLE_REG_EXISTS', 'registration numbers are unique in the school');

-- Renewing the certificate lifts the block (latest document wins).
select public.add_vehicle_document(:'veh'::uuid, 'fitness', '2027-06-30', 'F-78');
select lives_ok(format($$ select public.assert_vehicle_roadworthy(%L, '2026-07-29') $$, :'veh'), 'a renewed certificate lifts the block');

-- AC2: a Principal's named override lets an expired vehicle through, and is audited.
select public.save_transport_vehicle(:'campus_id'::uuid, 'LEB-5678', 30) as veh2 \gset
select public.add_vehicle_document(:'veh2'::uuid, 'fitness', '2026-07-01');
select public.add_vehicle_document(:'veh2'::uuid, 'insurance', '2027-01-01');
select public.add_vehicle_document(:'veh2'::uuid, 'token_tax', '2027-01-01');
select throws_ok(format($$ select public.assert_vehicle_roadworthy(%L, '2026-07-29') $$, :'veh2'), 'P0001', null, 'the second bus is blocked too');
select throws_ok(format($$ select public.override_vehicle_block(%L, '2026-07-29', '2026-07-31', 'Replacement booked for Friday') $$, :'veh2'), 'FORBIDDEN', 'the Transport Manager cannot override the block');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.override_vehicle_block(%L, '2026-07-29', '2026-07-31', 'short') $$, :'veh2'), 'REASON_MIN_LENGTH_10', 'an override needs a real reason');
select public.override_vehicle_block(:'veh2'::uuid, '2026-07-29', '2026-07-31', 'Replacement bus booked for Friday') as ovr \gset
select lives_ok(format($$ select public.assert_vehicle_roadworthy(%L, '2026-07-30') $$, :'veh2'), 'AC2: the overridden vehicle can be assigned inside the span');
select throws_ok(format($$ select public.assert_vehicle_roadworthy(%L, '2026-08-01') $$, :'veh2'), 'P0001', null, 'AC2: and is blocked again after it');
select is((select (after ->> 'approved_by') || '|' || (after ->> 'reason') from public.audit_log where table_name = 'transport_vehicle_override' and row_id = :'ovr'::uuid and action = 'insert'),
  :'prin_uid' || '|Replacement bus booked for Friday', 'AC2: audit_log records the approver and the reason');
select ok((select (after ->> 'approved_at') is not null from public.audit_log where table_name = 'transport_vehicle_override' and row_id = :'ovr'::uuid), 'AC2: and the timestamp');

-- AC4: contracted van, token tax non-mandatory by tenant setting.
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_transport_vehicle(:'campus_id'::uuid, 'LEB-9000', 14, 'Toyota', 'Hiace', 'petrol', 'contracted') as van \gset
select public.add_vehicle_document(:'van'::uuid, 'fitness', '2027-03-01');
select public.add_vehicle_document(:'van'::uuid, 'insurance', '2027-03-01');
select throws_ok(format($$ select public.assert_vehicle_roadworthy(%L, '2026-08-10') $$, :'van'), 'P0001', 'VEHICLE_BLOCKED: token tax is not on file', 'a contracted van with no token tax is blocked by default');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_transport_setting('transport.token_tax_mandatory_for_contracted', 'false'::jsonb);
select lives_ok(format($$ select public.assert_vehicle_roadworthy(%L, '2026-08-10') $$, :'van'), 'AC4: with the setting off, the contracted van proceeds with no token tax on file');
select throws_ok(format($$ select public.assert_vehicle_roadworthy(%L, '2026-08-10') $$, (select id from public.transport_vehicle where reg_no = 'LEB-5678')), 'P0001', null, 'the setting does not relax owned vehicles');

-- AC3: 7 documents expiring within 30 days, one message each, not repeated for 7 days.
reset role;
update public.transport_vehicle set active = false where reg_no = 'LEB-5678';
insert into public.transport_vehicle (tenant_id, campus_id, reg_no, seat_capacity)
select :'tenant_id', :'campus_id', 'DIG-' || i, 30 from generate_series(1, 7) i;
insert into public.transport_vehicle_document (tenant_id, campus_id, vehicle_id, doc_type, expires_on)
select :'tenant_id', :'campus_id', v.id, 'fitness', '2026-09-20' from public.transport_vehicle v where v.reg_no like 'DIG-%';
select is(public.transport_document_expiry_digest('2026-09-05'), 7, 'AC3: the digest lists the 7 expiring documents');
select is((select count(*) from public.user_notification where kind = 'transport_document_expiry' and user_id = :'tm_uid'), 1::bigint, 'AC3: the Transport Manager gets exactly one message');
select is((select count(*) from public.user_notification where kind = 'transport_document_expiry' and user_id = :'prin_uid'), 1::bigint, 'AC3: and so does the Principal');
select is((select array_length(string_to_array(body, E'\n'), 1) from public.user_notification where kind = 'transport_document_expiry' and user_id = :'tm_uid'), 7, 'AC3: one message listing all 7');
select is(public.transport_document_expiry_digest('2026-09-06'), 0, 'AC3: the same documents are not re-sent the next day');
select is(public.transport_document_expiry_digest('2026-09-12'), 7, 'AC3: they are sent again after 7 days');

select is((select public from storage.buckets where id = 'transport-documents'), false, 'the transport-documents bucket is private');

select set_config('request.jwt.claims', json_build_object('sub', :'teacher_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
set local role authenticated;
select is((select count(*) from public.transport_vehicle_document), 0::bigint, 'a class teacher cannot read vehicle documents');
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'transport_manager', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.transport_vehicle), 0::bigint, 'another school sees no vehicles');

select * from finish();
rollback;
