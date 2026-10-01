-- pgTAP tests for FR-K30: fee projection versus collection dashboard.
begin;
select plan(22);

select public.provision_tenant('test-collection-co', 'Collection Co', 'owner@collection.test');
select id as tenant_id from public.tenant where slug = 'test-collection-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-collection-other', 'Other Collection Co', 'owner@othercollection.test');
select id as other_tenant_id from public.tenant where slug = 'test-collection-other' \gset

select set_config('t.campus', :'campus_id', false), set_config('t.section', 'pending', false);
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@collection.test', 'authenticated', 'authenticated', 'x'), (:'acct_uid', 'a@collection.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@collection.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'acct_uid', :'tenant_id', 'accountant', 'Accountant'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as section_id \gset
select set_config('t.section', :'section_id', false);
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 850000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
create temp table kid (n int primary key, enrol_id uuid);
grant all on kid to authenticated;
do $$
declare
  i int; v_student uuid;
begin
  for i in 1..10 loop
    v_student := public.create_student(current_setting('t.campus')::uuid, 'Collect Kid ' || i, '2015-01-01'::date, 'male');
    insert into kid (n, enrol_id) values (i, public.enrol_student(current_setting('t.section')::uuid, v_student));
  end loop;
end $$;
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
reset role;

delete from public.agg_refresh_log where job_name = 'fee_collection_monthly';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.fee_collection_refresh_due(), false, 'a teacher never triggers the rebuild');
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.fee_collection_refresh_due(), true, 'AC3: with no build on record the dashboard knows it must rebuild');
-- eight full payments, one half payment, one family that has not paid
select public.record_payment(enrol_id, 850000::bigint, 'cash'::public.fee_payment_mode, 'k30-full', current_date) from kid where n <= 8;
select public.record_payment(enrol_id, 425000::bigint, 'cash'::public.fee_payment_mode, 'k30-half', current_date) from kid where n = 9;
reset role;
select public.refresh_fee_collection_metrics() as built \gset
select cmp_ok(:'built'::int, '>=', 1, 'the materialized view is built');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select sum(billed_paisa)::bigint from public.v_fee_collection_monthly where tenant_id = :'tenant_id'), 8500000::bigint, 'ten challans of 8,500 are billed');
select is((select sum(collected_paisa)::bigint from public.v_fee_collection_monthly where tenant_id = :'tenant_id'), 7225000::bigint, 'AC1: 72,250 is collected');
select is((select sum(outstanding_paisa)::bigint from public.v_fee_collection_monthly where tenant_id = :'tenant_id'), 1275000::bigint, 'AC1: 12,750 is outstanding');
select is((select collection_efficiency_pct from public.v_fee_collection_monthly where tenant_id = :'tenant_id'), 85.0, 'AC1: collection efficiency is 85.0%');
select is((select challan_count from public.v_fee_collection_monthly where tenant_id = :'tenant_id'), 10, 'the class drill-down row counts the ten challans');
select is((select billed_paisa from public.fn_fee_collection_trend(null, 12) where billing_period = date_trunc('month', current_date)::date), 8500000::bigint, 'AC4: the month shows the sum of that month''s challans net payable');
select is((select count(*) from public.fn_fee_collection_trend(null, 12)), 12::bigint, 'AC4: twelve data points appear even where earlier months are empty');
select is((select sum(billed_paisa)::bigint from public.fn_fee_collection_trend(null, 12)), (select sum(billed_paisa)::bigint from public.v_fee_collection_monthly), 'the trend adds up to the campus figures');

-- arrears paid later fill the OLD month, they do not inflate the new one
reset role;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date + interval '1 month')::date + 14), false);
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.record_payment(enrol_id, 850000::bigint, 'cash'::public.fee_payment_mode, 'k30-arrears', current_date) from kid where n = 10;
reset role;
select public.refresh_fee_collection_metrics();
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select collection_efficiency_pct from public.fn_fee_collection_trend(null, 12) where billing_period = date_trunc('month', current_date)::date), 95.0, 'paying a family''s arrears raises the month that billed them to 95.0%');
select is((select collection_efficiency_pct from public.v_fee_collection_monthly where billing_period >= date_trunc('month', current_date + interval '1 month')::date), 0.0, 'and does not count towards the next month, which stays at 0.0%');
select ok((select max(collection_efficiency_pct) from public.v_fee_collection_monthly) <= 100, 'no month can ever read above 100%');

-- ── scope ─────────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(gen_random_uuid()))::text, true);
select is((select count(*) from public.v_fee_collection_monthly), 0::bigint, 'AC2: a Principal sees only their own campus, so none of this one');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select cmp_ok((select count(*) from public.v_fee_collection_monthly), '>', 0::bigint, 'the Owner sees the campus');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.v_fee_collection_monthly), 0::bigint, 'a teacher sees no money');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.v_fee_collection_monthly), 0::bigint, 'another school sees none of these figures');
select throws_ok($$ select public.refresh_fee_collection_metrics() $$, '42501', null, 'a signed-in user cannot trigger the rebuild');
select is((select schemaname::text from pg_matviews where matviewname = 'mv_fee_collection_monthly'), 'app', 'the materialized view lives in the schema the API does not expose');

-- ── AC3: freshness ────────────────────────────────────────────────────────
reset role;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.fee_collection_refresh_due(), false, 'AC3: just after a build the dashboard does not rebuild');
reset role;
update public.agg_refresh_log set ran_at = now() - interval '2 hours' where job_name = 'fee_collection_monthly';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.fee_collection_refresh_due(), true, 'AC3: more than an hour after the last build it rebuilds, so the figures are never older than an hour');

select * from finish();
rollback;
