-- pgTAP tests for FR-R03: fixed asset register with depreciation.
begin;
select plan(30);

select public.provision_tenant('test-asset-co', 'Asset Co', 'owner@asset.test');
select id as tenant_id from public.tenant where slug = 'test-asset-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Second Campus', 'C2') returning id as campus2_id \gset
select public.provision_tenant('test-asset-other', 'Other Asset Co', 'owner@otherasset.test');
select id as other_tenant_id from public.tenant where slug = 'test-asset-other' \gset

select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as acct2_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'acct_uid', 'a@asset.test', 'authenticated', 'authenticated', 'x'), (:'acct2_uid', 'a2@asset.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@asset.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'acct_uid', :'tenant_id', 'accountant', 'Accountant'), (:'acct2_uid', :'tenant_id', 'accountant', 'Accountant Two'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── AC1: PKR 120,000 projector, 60 months, zero salvage, straight line ────
select public.create_asset(:'campus_id'::uuid, 'IT-0001', 'Projector', 'it', '2026-01-10'::date, 12000000, 60) as proj \gset
select is((public.run_monthly_depreciation('2030-12-01'::date) ->> 'status'), 'POSTED', 'the run reports POSTED');
select is((select count(*) from public.asset_depreciation_entry where asset_id = :'proj'::uuid), 60::bigint, 'AC1: 60 monthly entries are posted');
select is((select count(distinct amount) from public.asset_depreciation_entry where asset_id = :'proj'::uuid), 1::bigint, 'AC1: every instalment is the same amount');
select is((select amount from public.asset_depreciation_entry where asset_id = :'proj'::uuid and period = '2026-01-01'), 200000::bigint, 'AC1: each run posts PKR 2,000');
select is((select net_book_value from public.v_asset_register where asset_id = :'proj'::uuid), 0::bigint, 'AC1: after 60 periods the net book value is exactly 0');

-- an asset that does not divide evenly still ends with no residual paisa
select public.create_asset(:'campus_id'::uuid, 'FUR-0001', 'Odd-cost bench', 'furniture', '2026-01-05'::date, 100000, 3) as odd \gset
select public.run_monthly_depreciation('2026-03-01'::date);
select is((select string_agg(amount::text, ',' order by period) from public.asset_depreciation_entry where asset_id = :'odd'::uuid), '33333,33334,33333', 'instalments are re-derived from what remains, so the series sums exactly');
select is((select net_book_value from public.v_asset_register where asset_id = :'odd'::uuid), 0::bigint, 'and net book value is exactly 0, not 0.40');

-- salvage is never depreciated below
select public.create_asset(:'campus_id'::uuid, 'LAB-0001', 'Microscope', 'lab', '2026-01-02'::date, 1000000, 10, 100000) as lab \gset
select public.run_monthly_depreciation('2026-10-01'::date);
select is((select net_book_value from public.v_asset_register where asset_id = :'lab'::uuid), 100000::bigint, 'depreciation stops at the salvage value');

-- ── AC2: reducing balance 20% p.a. ────────────────────────────────────────
select public.create_asset(:'campus_id'::uuid, 'FUR-0002', 'Desks', 'furniture', '2026-01-01'::date, 10000000, 120, 0, 'RB', 20) as rb \gset
select public.run_monthly_depreciation('2027-01-01'::date);
select is((select opening_wdv from public.asset_depreciation_entry where asset_id = :'rb'::uuid and period = '2026-01-01'), 10000000::bigint, 'AC2: period 1 posts on the opening written-down value');
select is((select amount from public.asset_depreciation_entry where asset_id = :'rb'::uuid and period = '2026-01-01'), 166666::bigint, 'AC2: 20% of 100,000 is spread over 12 months (1,666.66)');
select is((select sum(amount)::bigint from public.asset_depreciation_entry where asset_id = :'rb'::uuid and period < '2027-01-01'), 2000000::bigint, 'the twelve months of year one add up to exactly 20,000');
select is((select opening_wdv from public.asset_depreciation_entry where asset_id = :'rb'::uuid and period = '2027-01-01'), 8000000::bigint, 'AC2: period 13 opens on the reduced written-down value');
select is((select amount from public.asset_depreciation_entry where asset_id = :'rb'::uuid and period = '2027-01-01'), 133333::bigint, 'AC2: and posts 20% of the reduced value (1,333.33)');

-- ── AC3: a second run for the same period posts nothing ───────────────────
select public.create_asset(:'campus_id'::uuid, 'IT-0002', 'Laptop', 'it', '2026-08-03'::date, 6000000, 36) as lap \gset
select is((public.run_monthly_depreciation('2026-08-01'::date) ->> 'status'), 'POSTED', 'the first run for 2026-08 posts');
select is((public.run_monthly_depreciation('2026-08-01'::date) ->> 'status'), 'ALREADY_POSTED', 'AC3: the second run for 2026-08 reports ALREADY_POSTED');
select is((public.run_monthly_depreciation('2026-08-15'::date) ->> 'posted')::int, 0, 'AC3: and posts nothing');
select is((select count(*) from public.asset_depreciation_entry where asset_id = :'lap'::uuid), 1::bigint, 'AC3: there is still one entry for the laptop');
reset role;
select is((select count(*) from pg_indexes where indexname = 'uq_dep_period'), 1::bigint, 'AC3: uq_dep_period (asset_id, period) enforces it');
select throws_ok(format($$ update public.asset_depreciation_entry set amount = 1 where asset_id = %L $$, :'lap'), 'DEPRECIATION_ENTRY_IMMUTABLE', 'a posted entry cannot be edited');

-- ── AC4: disposal on 2026-09-14, NBV 34,000 sold for 40,000 ───────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
-- 100,000 over 50 months = 2,000 a month; 33 periods (Jan 2024 .. Sep 2026) -> NBV 34,000
select public.create_asset(:'campus_id'::uuid, 'FUR-0003', 'Chairs', 'furniture', '2024-01-05'::date, 10000000, 50) as chair \gset
select is((public.dispose_asset(:'chair'::uuid, '2026-09-14'::date, 4000000) ->> 'nbv_at_disposal')::bigint, 3400000::bigint, 'AC4: net book value at disposal is PKR 34,000');
select is((select gain_loss from public.asset_disposal where asset_id = :'chair'::uuid), 600000::bigint, 'AC4: a gain on disposal of PKR 6,000 is recorded');
select is((select status::text from public.asset where id = :'chair'::uuid), 'disposed', 'AC4: the status becomes disposed');
select is((select max(period) from public.asset_depreciation_entry where asset_id = :'chair'::uuid), '2026-09-01'::date, 'AC4: depreciation stops at the September period');
select public.run_monthly_depreciation('2026-12-01'::date);
select is((select count(*) from public.asset_depreciation_entry where asset_id = :'chair'::uuid), 33::bigint, 'AC4: later runs post nothing for a disposed asset');
select throws_ok(format($$ select public.dispose_asset(%L, '2026-10-01', 0) $$, :'chair'), 'ASSET_ALREADY_DISPOSED', 'an asset cannot be disposed twice');

-- ── validation and write-off ──────────────────────────────────────────────
select throws_ok(format($$ select public.create_asset(%L, 'FUR-0009', 'No rate', 'furniture', '2026-01-01', 100000, 12, 0, 'RB') $$, :'campus_id'), 'RATE_REQUIRED', 'reducing balance needs a rate');
select throws_ok(format($$ select public.create_asset(%L, 'IT-0001', 'Duplicate tag', 'it', '2026-01-01', 100000, 12) $$, :'campus_id'), 'ASSET_TAG_EXISTS', 'tag numbers are unique within the school');
select is((public.dispose_asset(:'odd'::uuid, '2026-04-02'::date, 0, true) ->> 'gain_loss')::bigint, 0::bigint, 'a fully depreciated asset written off has no gain or loss');

-- ── roles and tenant isolation ────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'acct2_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus2_id'))::text, true);
select is((select count(*) from public.asset), 0::bigint, 'an accountant of another campus sees none of campus 1''s assets');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.create_asset(%L, 'X-1', 'Nope', 'it', '2026-01-01', 100, 12) $$, :'campus_id'), 'FORBIDDEN', 'a teacher cannot register an asset');

select * from finish();
rollback;
