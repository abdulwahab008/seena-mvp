-- pgTAP tests for FR-S02: owner cross-campus KPI dashboard.
begin;
select plan(20);

select public.provision_tenant('test-kpi-co', 'KPI Co', 'owner@kpico.test');
select id as tenant_id from public.tenant where slug = 'test-kpi-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-kpi-other', 'Other KPI Co', 'owner@otherkpico.test');
select id as other_tenant_id from public.tenant where slug = 'test-kpi-other' \gset

insert into public.campus (tenant_id, code, name) select :'tenant_id', 'K' || n, 'Campus K' || n from generate_series(1, 7) n;
select app.fn_karachi_today() as today \gset

-- Campus B of the AC: 4.2M collected of 6.0M billed, 1.8M outstanding split 1.0M / 0.5M / 0.3M, payroll still a draft.
select id as campus_b from public.campus where tenant_id = :'tenant_id' and code = 'K1' \gset
insert into public.agg_campus_day (tenant_id, campus_id, day, enrolled_count, present_count, collected_paisa, billed_paisa, outstanding_paisa,
  outstanding_0_30_paisa, outstanding_31_60_paisa, outstanding_60plus_paisa, staff_cost_paisa, payroll_status)
select tenant_id, id, :'today', 1000, 900,
       case code when 'K1' then 420000000 else 100000000 end,
       case code when 'K1' then 600000000 else 200000000 end,
       case code when 'K1' then 180000000 else 50000000 end,
       case code when 'K1' then 100000000 else 50000000 end,
       case code when 'K1' then 50000000 else 0 end,
       case code when 'K1' then 30000000 else 0 end,
       case code when 'K1' then 126000000 else 40000000 end,
       case code when 'K1' then 'draft' else 'locked' end
  from public.campus where tenant_id = :'tenant_id';
select array_agg(id) filter (where code in ('K1', 'K2', 'K3')) as three_ids, array_agg(id) as all_ids from public.campus where tenant_id = :'tenant_id' \gset

select has_view('public', 'v_owner_kpi', 'v_owner_kpi exists');
select ok((select reloptions::text like '%security_invoker=true%' from pg_class where oid = 'public.v_owner_kpi'::regclass), 'it is security_invoker');
select ok((select pg_get_viewdef('public.v_owner_kpi'::regclass) like '%agg_campus_day%'), 'it reads the aggregate layer');
select is((select count(*)::int from public.metric_definition where metric_key in ('collection_rate', 'outstanding', 'staff_cost_ratio', 'attendance_rate') and length(numerator_desc) > 5 and length(denominator_desc) > 0), 4, 'the four metric definitions are stored');
select ok((select denominator_desc from public.metric_definition where metric_key = 'staff_cost_ratio') ilike '%collected%', 'the staff cost ratio states its denominator: fees collected');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', to_json(:'all_ids'::uuid[]))::text, true);
select is((select count(*)::int from public.v_owner_kpi), 8, 'the owner sees all 8 campuses');
select is((select collection_pct from public.v_owner_kpi where campus_id = :'campus_b'::uuid), 70.0, 'AC: 4.2M of 6.0M reads 70.0% collection');
select is((select outstanding_paisa from public.v_owner_kpi where campus_id = :'campus_b'::uuid), 180000000::bigint, 'AC: PKR 1.8M outstanding');
select is((select outstanding_0_30_paisa || '/' || outstanding_31_60_paisa || '/' || outstanding_60plus_paisa from public.v_owner_kpi where campus_id = :'campus_b'::uuid), '100000000/50000000/30000000', 'AC: split into 0-30, 31-60 and 60+ buckets');
select is((select outstanding_paisa = outstanding_0_30_paisa + outstanding_31_60_paisa + outstanding_60plus_paisa from public.v_owner_kpi where campus_id = :'campus_b'::uuid), true, 'the buckets sum to the total');
select is((select staff_cost_ratio from public.v_owner_kpi where campus_id = :'campus_b'::uuid), 0.3000::numeric, 'AC: the draft payroll figure is shown (30% of collected), not suppressed');
select is((select payroll_locked from public.v_owner_kpi where campus_id = :'campus_b'::uuid), false, 'AC: and marked "payroll not locked"');
select is((select payroll_locked from public.v_owner_kpi where campus_id <> :'campus_b'::uuid limit 1), true, 'a locked payroll carries no marker');
select is(public.fn_staff_cost_ratio(:'campus_b'::uuid, :'today'::date), 0.3000::numeric, 'fn_staff_cost_ratio agrees with the view');
select is((select attendance_pct from public.v_owner_kpi where campus_id = :'campus_b'::uuid), 90.0, 'attendance rate is present / enrolled');

-- ── RLS: the campus_ids claim, not the role, bounds what comes back ───────
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', to_json(:'three_ids'::uuid[]))::text, true);
select is((select count(*)::int from public.v_owner_kpi), 3, 'AC: a token listing 3 of 8 campuses returns 3 rows');
select is((select count(*)::int from public.v_owner_kpi where campus_id <> all (:'three_ids'::uuid[])), 0, 'AC: a tampered campus filter still returns only those 3');
select is((select count(*)::int from public.v_owner_kpi where campus_id = (select id from public.campus where tenant_id = :'tenant_id' and code = 'K7')), 0, 'asking for a campus outside the claim returns nothing');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', to_json(:'all_ids'::uuid[]))::text, true);
select is((select count(*)::int from public.v_owner_kpi), 0, 'another school sees nothing, even claiming these campuses');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', to_json(:'all_ids'::uuid[]))::text, true);
select is((select count(*)::int from public.v_owner_kpi), 0, 'a parent token sees nothing');
reset role;

select * from finish();
rollback;
