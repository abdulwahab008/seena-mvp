-- pgTAP tests for FR-R05: asset maintenance and repair log.
begin;
select plan(23);

select public.provision_tenant('test-maint-co', 'Maintenance Co', 'owner@maint.test');
select id as tenant_id from public.tenant where slug = 'test-maint-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-maint-other', 'Other Maint Co', 'owner@othermaint.test');
select id as other_tenant_id from public.tenant where slug = 'test-maint-other' \gset

select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as tm_uid \gset
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'acct_uid', 'a@maint.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@maint.test', 'authenticated', 'authenticated', 'x'),
  (:'tm_uid', 'tm@maint.test', 'authenticated', 'authenticated', 'x'), (:'owner_uid', 'o@maint.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@maint.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'acct_uid', :'tenant_id', 'accountant', 'Accountant'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'tm_uid', :'tenant_id', 'transport_manager', 'Transport Manager'), (:'owner_uid', :'tenant_id', 'owner', 'Owner'),
  (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'prin_uid', :'tenant_id', :'campus_id'), (:'tm_uid', :'tenant_id', :'campus_id');

-- a fleet vehicle: Transport's table when it exists, otherwise any uuid
create temp table _veh (id uuid);
do $$
declare
  v uuid;
begin
  if to_regclass('public.transport_vehicle') is not null then
    execute 'insert into public.transport_vehicle (tenant_id, campus_id, reg_no, seat_capacity) values ($1, $2, $3, 40) returning id'
      into v using (select id from public.tenant where slug = 'test-maint-co'), (select id from public.campus where tenant_id = (select id from public.tenant where slug = 'test-maint-co') limit 1), 'LEA-1234';
  else
    v := gen_random_uuid();
  end if;
  insert into _veh values (v);
end;
$$;
select id as veh_id from _veh \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_asset(:'campus_id'::uuid, 'BUS-01', 'School bus', 'vehicle', '2025-01-01'::date, 90000000, 120, 0, 'SL', null, :'veh_id'::uuid) as bus \gset
select public.create_asset(:'campus_id'::uuid, 'GEN-01', 'Generator', 'other', '2025-01-01'::date, 12000000, 60) as gen \gset

-- ── AC1: downtime 4-9 Aug blocks a trip on the 6th ─────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.log_asset_maintenance(:'bus'::uuid, 'Gearbox failure', '2026-08-03'::date, null, 0, false, '2026-08-04'::date, '2026-08-09'::date) as m1 \gset
select throws_ok(format($$ select public.assert_vehicle_available(%L, '2026-08-06') $$, :'veh_id'), 'VEHICLE_IN_REPAIR', 'AC1: assigning the bus to a trip on 2026-08-06 is refused with VEHICLE_IN_REPAIR');
select throws_ok(format($$ select public.assert_asset_available(%L, '2026-08-04') $$, :'bus'), 'VEHICLE_IN_REPAIR', 'AC1: the first day of downtime is covered');
select lives_ok(format($$ select public.assert_vehicle_available(%L, '2026-08-10') $$, :'veh_id'), 'AC1: the bus is available again after the downtime');
select lives_ok(format($$ select public.assert_vehicle_available(%L, '2026-08-03') $$, :'veh_id'), 'and before it');
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.issue_asset_custody(%L, 'department', null, null, null, '2026-08-05') $$, :'bus'), 'VEHICLE_IN_REPAIR', 'custody cannot be issued for a date in downtime either');

-- ── status sync ───────────────────────────────────────────────────────────
select public.log_asset_maintenance(:'gen'::uuid, 'Overheating', app.fn_karachi_today(), null, 1000000, false, app.fn_karachi_today() - 1, null) as m_open \gset
select is((select status::text from public.asset where id = :'gen'::uuid), 'in_repair', 'an open repair covering today puts the asset in_repair');
select public.close_asset_maintenance(:'m_open'::uuid);
select is((select status::text from public.asset where id = :'gen'::uuid), 'active', 'closing the repair returns it to active');

-- ── AC3: lifetime maintenance, cost and NBV together ──────────────────────
select public.create_asset(:'campus_id'::uuid, 'IT-0001', 'Projector', 'it', '2026-01-10'::date, 12000000, 60) as proj \gset
select public.log_asset_maintenance(:'proj'::uuid, 'Lamp', '2026-02-01'::date, null, 1000000);
select public.log_asset_maintenance(:'proj'::uuid, 'Board', '2026-03-01'::date, null, 850000);
select public.run_monthly_depreciation('2026-03-01'::date);
select is((select lifetime_maintenance from public.v_asset_ledger where asset_id = :'proj'::uuid), 1850000::bigint, 'AC3: lifetime maintenance is PKR 18,500');
select is((select capitalised_cost from public.v_asset_ledger where asset_id = :'proj'::uuid), 12000000::bigint, 'AC3: shown next to the capitalised cost of PKR 120,000');
select is((select net_book_value from public.v_asset_ledger where asset_id = :'proj'::uuid), 11400000::bigint, 'AC3: and the net book value after three months (PKR 114,000)');

-- ── AC4: capital improvement re-bases depreciation ────────────────────────
select throws_ok(format($$ select public.log_asset_maintenance(%L, 'Small fix', null, null, 3000000, true) $$, :'proj'), 'BELOW_CAPITALISATION_THRESHOLD', 'AC4: a repair under the PKR 50,000 threshold cannot be capitalised');
select public.run_monthly_depreciation('2026-12-01'::date);
select public.log_asset_maintenance(:'proj'::uuid, 'Optical engine replacement', '2026-12-20'::date, null, 6500000, true);
select is((select capitalised_cost from public.asset where id = :'proj'::uuid), 18500000::bigint, 'AC4: the PKR 65,000 is added to the capitalised cost');
select public.run_monthly_depreciation('2027-01-01'::date);
select is((select amount from public.asset_depreciation_entry where asset_id = :'proj'::uuid and period = '2026-12-01'), 200000::bigint, 'AC4: posted periods are untouched');
select is((select amount from public.asset_depreciation_entry where asset_id = :'proj'::uuid and period = '2027-01-01'), 335417::bigint, 'AC4: the next period is recomputed on the new base ((185,000 - 24,000) / 48)');
select public.run_monthly_depreciation('2030-12-01'::date);
select is((select net_book_value from public.v_asset_register where asset_id = :'proj'::uuid), 0::bigint, 'AC4: and the asset still lands on exactly zero at the end of its life');

-- ── AC2: the 14-day service reminder ──────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.log_asset_maintenance(:'gen'::uuid, 'Routine service', '2026-06-01'::date, null, 500000, false, null, null, '2026-09-01'::date, :'owner_uid'::uuid);
reset role;
select is(public.asset_service_due_reminder_run('2026-08-01'::date), 0, 'a service 31 days away sends nothing yet');
select is(public.asset_service_due_reminder_run('2026-08-18'::date), 2, 'AC2: on 2026-08-18 the Principal and the maintenance owner are reminded');
select is((select string_agg(recipient_role, ',' order by recipient_role) from public.asset_service_reminder where asset_id = :'gen'::uuid), 'maintenance_owner,principal', 'AC2: one reminder for each');
select is(public.asset_service_due_reminder_run('2026-08-19'::date), 0, 'the reminder is sent once');

-- ── roles ─────────────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.log_asset_maintenance(%L, 'Hack') $$, :'gen'), 'FORBIDDEN', 'a teacher cannot log maintenance');
select is((select count(*) from public.asset_maintenance), 0::bigint, 'and cannot read it');
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.log_asset_maintenance(%L, 'Generator') $$, :'gen'), 'FORBIDDEN', 'a Transport Manager logs against vehicles only');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.asset_maintenance), 0::bigint, 'another school sees none');

select * from finish();
rollback;
