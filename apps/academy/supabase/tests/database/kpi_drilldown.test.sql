-- pgTAP tests for FR-S04: KPI drill-down to source rows.
begin;
select plan(29);

select public.provision_tenant('test-drill-co', 'Drill Co', 'owner@drill.test');
select id as tenant_id from public.tenant where slug = 'test-drill-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-drill-other', 'Other Drill Co', 'owner@otherdrill.test');
select id as other_tenant_id from public.tenant where slug = 'test-drill-other' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'D2', 'Drill Campus Two') returning id as campus_b \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as vp_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@drill.test', 'authenticated', 'authenticated', 'x'), (:'vp_uid', 'vp@drill.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Drill Owner'), (:'vp_uid', :'tenant_id', 'vice_principal', 'Drill VP');

-- 214 students with one challan each. 213 owe 8,400 PKR, the last 10,800: exactly PKR 1,800,000.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select public.create_section(:'campus_a'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 150) as sec_a \gset
select public.create_section(:'campus_a'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 100) as sec_b \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
reset role;
select id as head_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', :'campus_a', 'DR' || lpad(g::text, 4, '0'), 'Drill Kid ' || g, '2015-01-01', 'male' from generate_series(1, 214) g;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id)
select tenant_id, campus_id, :'session_id', id, :'class1_id', case when row_number() over (order by gr_number) <= 150 then :'sec_a'::uuid else :'sec_b'::uuid end
  from public.student where tenant_id = :'tenant_id';
insert into public.fee_challan (tenant_id, campus_id, enrolment_id, session_id, billing_period, challan_no, issue_date, due_date, gross_paisa, concession_paisa, arrears_paisa, net_paisa, status)
select e.tenant_id, e.campus_id, e.id, e.session_id, current_date, 'DRCH-' || lpad(row_number() over (order by s.gr_number)::text, 4, '0'), current_date - 10, current_date + 5,
       case when s.gr_number = 'DR0214' then 1080000 else 840000 end, 0, 0, case when s.gr_number = 'DR0214' then 1080000 else 840000 end, 'unpaid'
  from public.enrolment e join public.student s on s.id = e.student_id where e.tenant_id = :'tenant_id';
-- an unrelated-campus student the owner's campus-A-only token must not see
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender) values (:'tenant_id', :'campus_b', 'DRB001', 'Other Campus Kid', '2015-01-01', 'male');

-- the nightly aggregate, as of its last refresh: 1,800,000 PKR
insert into public.agg_campus_day (tenant_id, campus_id, day, enrolled_count, present_count, outstanding_paisa, outstanding_0_30_paisa, last_refreshed_at)
values (:'tenant_id', :'campus_a', app.fn_karachi_today(), 214, 200, 180000000, 180000000, now() - interval '3 hours');

select has_view('public', 'v_drilldown_outstanding', 'v_drilldown_outstanding exists');
select has_view('public', 'v_drilldown_absentees', 'v_drilldown_absentees exists');
select has_view('public', 'v_drilldown_staff_cost', 'v_drilldown_staff_cost exists');
select is((select count(*)::int from pg_class where oid in ('public.v_drilldown_outstanding'::regclass, 'public.v_drilldown_absentees'::regclass, 'public.v_drilldown_staff_cost'::regclass) and reloptions::text like '%security_invoker=true%'), 3, 'all three drill-down views are security_invoker');
select is((select drilldown_view from public.metric_definition where metric_key = 'outstanding'), 'v_drilldown_outstanding', 'metric_definition names the outstanding drill-down view');
select is((select tolerance_pct from public.metric_definition where metric_key = 'outstanding'), 0.50::numeric, 'default reconciliation tolerance is 0.5%');

-- ── AC1: 214 student rows with challan numbers summing to exactly PKR 1,800,000 ──
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.v_drilldown_outstanding), 214, 'AC1: 214 student rows are listed');
select is((select count(*)::int from public.v_drilldown_outstanding where challan_no like 'DRCH-%' and gr_number is not null), 214, 'AC1: every row carries a challan number and a student');
select is((select sum(balance_paisa)::bigint from public.v_drilldown_outstanding), 180000000::bigint, 'AC1: the outstanding amounts sum to exactly PKR 1,800,000');
select is((select count(*)::int from public.v_drilldown_outstanding where bucket = '0_30'), 214, 'rows are tagged with their age bucket');

-- ── AC2: reconciliation ───────────────────────────────────────────────────
select is((select live_value from public.fn_metric_reconcile('outstanding', null, app.fn_karachi_today())), 180000000::numeric, 'live equals the aggregate while nothing has changed');
select is((select exceeds_tolerance from public.fn_metric_reconcile('outstanding', null, app.fn_karachi_today())), false, 'AC2: no notice while they agree');
reset role;
-- a back-dated receipt of 2,000,000 paisa lands after the last aggregate refresh
insert into public.fee_payment (tenant_id, campus_id, enrolment_id, amount_paisa, mode, value_date, reference_no)
select tenant_id, campus_id, id, 840000, 'cash', current_date - 3, 'drill-1' from public.enrolment where tenant_id = :'tenant_id' order by id limit 1 returning id as pay_id \gset
insert into public.fee_payment_allocation (payment_id, challan_id, fee_head_id, amount_paisa)
select :'pay_id', c.id, :'head_id', 840000 from public.fee_challan c where c.enrolment_id = (select enrolment_id from public.fee_payment where id = :'pay_id');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select agg_value from public.fn_metric_reconcile('outstanding', :'campus_a'::uuid, app.fn_karachi_today())), 180000000::numeric, 'AC2: the reconciliation reports the aggregate figure');
select is((select live_value from public.fn_metric_reconcile('outstanding', :'campus_a'::uuid, app.fn_karachi_today())), 179160000::numeric, 'AC2: and the live figure');
select is((select delta_pct from public.fn_metric_reconcile('outstanding', :'campus_a'::uuid, app.fn_karachi_today())), 0.47::numeric, 'delta is computed against the aggregate');
select is((select exceeds_tolerance from public.fn_metric_reconcile('outstanding', :'campus_a'::uuid, app.fn_karachi_today())), false, 'a 0.47% gap is inside the 0.5% tolerance');
reset role;
insert into public.fee_payment (tenant_id, campus_id, enrolment_id, amount_paisa, mode, value_date, reference_no)
select tenant_id, campus_id, id, 840000, 'cash', current_date - 2, 'drill-2' from public.enrolment where tenant_id = :'tenant_id' order by id offset 1 limit 1 returning id as pay2_id \gset
insert into public.fee_payment_allocation (payment_id, challan_id, fee_head_id, amount_paisa)
select :'pay2_id', c.id, :'head_id', 840000 from public.fee_challan c where c.enrolment_id = (select enrolment_id from public.fee_payment where id = :'pay2_id');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select exceeds_tolerance from public.fn_metric_reconcile('outstanding', :'campus_a'::uuid, app.fn_karachi_today())), true, 'AC2: a gap above 0.5% raises the reconciliation notice');
select ok((select agg_refreshed_at from public.fn_metric_reconcile('outstanding', :'campus_a'::uuid, app.fn_karachi_today())) < now() - interval '2 hours', 'AC2: the notice carries the aggregate refresh time');
select is((select count(*)::int from public.v_drilldown_outstanding), 212, 'the live drill-down already excludes the two paid challans');

-- ── AC3: a role that sees the KPI but not the student rows ────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'vp_uid', 'tenant_id', :'tenant_id', 'app_role', 'vice_principal', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.agg_campus_day where tenant_id = :'tenant_id'), 1, 'the vice principal can see the collection KPI');
select is((select count(*)::int from public.v_drilldown_outstanding), 0, 'AC3: the drill-down returns an empty result, not an error or a partial list');
select is(public.fn_drilldown_permitted('outstanding'), false, 'AC3: and fn_drilldown_permitted says so, so the page can print "not permitted"');
select is((select count(*)::int from public.fn_metric_reconcile('outstanding', null, app.fn_karachi_today())), 0, 'reconciliation reveals no figures to a role without the drill-down');

-- ── AC4: the export job receives the same filter set, no re-selection ─────
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select (public.request_report_export('drilldown_outstanding', jsonb_build_object('campus_id', :'campus_a', 'bucket', '0_30'), null, null) ->> 'job_id')::uuid as job_id \gset
select is((select params from public.report_export_job where id = :'job_id'), jsonb_build_object('campus_id', :'campus_a', 'bucket', '0_30'), 'AC4: the job stores exactly the filters the drill-down was showing');
select set_config('request.jwt.claims', json_build_object('sub', :'vp_uid', 'tenant_id', :'tenant_id', 'app_role', 'vice_principal', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok($$ select public.request_report_export('drilldown_outstanding', '{}'::jsonb, null, null) $$, 'DATASET_NOT_AVAILABLE', 'a role without the drill-down cannot export it either');
reset role;
update public.report_export_job set status = 'running', started_at = now() where id = :'job_id';
select is((select jsonb_array_length(public.export_job_page(:'job_id'::uuid, 0, 5000))), 212, 'AC4: the worker page returns the same 212 rows the screen showed');
select is((select sum((x ->> 'balance_paisa')::bigint) from jsonb_array_elements(public.export_job_page(:'job_id'::uuid, 0, 5000)) x), 178320000::numeric, 'and the amounts agree with the screen');

-- ── isolation: the base-table RLS bounds the views ────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_b'))::text, true);
select is((select count(*)::int from public.v_drilldown_outstanding), 0, 'a principal of another campus sees none of campus A''s students');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.v_drilldown_outstanding), 0, 'another school sees nothing even when claiming this campus');
reset role;

select * from finish();
rollback;
