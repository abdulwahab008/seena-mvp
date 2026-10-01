-- pgTAP tests for FR-S11: report execution and export audit.
begin;
select plan(27);

select public.provision_tenant('test-audit-co', 'Audit Co', 'owner@auditco.test');
select id as tenant_id from public.tenant where slug = 'test-audit-co' \gset
select public.provision_tenant('test-audit-other', 'Other Audit Co', 'owner@otherauditco.test');
select id as other_tenant_id from public.tenant where slug = 'test-audit-other' \gset
select gen_random_uuid() as u1 \gset
select gen_random_uuid() as u2 \gset
select gen_random_uuid() as u_owner \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'u1', 'u1@auditco.test', 'authenticated', 'authenticated', 'x'), (:'u2', 'u2@auditco.test', 'authenticated', 'authenticated', 'x'), (:'u_owner', 'o@auditco.test', 'authenticated', 'authenticated', 'x');

select is(public.fn_report_contains_pii('students', '["gr_number","name_en","guardian_cnic"]'::jsonb), true, 'a column named guardian_cnic marks the report as PII');
select is(public.fn_report_contains_pii('students', '["gr_number","B_Form_No"]'::jsonb), true, 'B-Form is PII, case-insensitively');
select is(public.fn_report_contains_pii('fees', '["challan_no","net_paisa","due_date"]'::jsonb), false, 'a fee-only report is not PII');
select is(public.fn_report_contains_pii('x', 'null'::jsonb), false, 'a missing column list is not PII');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'u1', 'tenant_id', :'tenant_id', 'app_role', 'accountant')::text, true);

select throws_ok($$ select public.record_report_run('student_list', 'students', '["gr_number","guardian_cnic"]'::jsonb, '{}'::jsonb, 40, 'too short', 'xlsx') $$, 'REASON_REQUIRED_FOR_PII_EXPORT', 'AC: a PII export needs a reason');
select throws_ok($$ select public.record_report_run('student_list', 'students', '["guardian_cnic"]'::jsonb, '{}'::jsonb, 40, null, 'xlsx') $$, 'REASON_REQUIRED_FOR_PII_EXPORT', 'and a missing reason is refused too');
select public.record_report_run('student_list', 'students', '["gr_number","guardian_cnic"]'::jsonb, '{"class":"9"}'::jsonb, 40, 'Board registration forms for class 9', 'xlsx', '203.0.113.7') as run1 \gset
select public.record_report_run('fee_summary', 'fees', '["challan_no","net_paisa"]'::jsonb, '{}'::jsonb, 300, null, 'screen', null) as run2 \gset
reset role;

select is((select contains_pii from public.report_audit where id = :'run1'), true, 'AC: contains_pii = true is stored');
select is((select reason from public.report_audit where id = :'run1'), 'Board registration forms for class 9', 'AC: with the reason');
select is((select user_id from public.report_audit where id = :'run1'), :'u1'::uuid, 'the user comes from the token, not the caller');
select is((select host(ip) from public.report_audit where id = :'run1'), '203.0.113.7', 'the request IP is stored');
select is((select contains_pii from public.report_audit where id = :'run2'), false, 'a non-PII report needs no reason and is flagged false');

-- ── append-only for everyone ──────────────────────────────────────────────
select throws_ok(format($$ update public.report_audit set row_count = 0 where id = %L $$, :'run1'), 'audit_append_only', 'AC: UPDATE fails with audit_append_only (as superuser)');
select throws_ok(format($$ delete from public.report_audit where id = %L $$, :'run1'), 'audit_append_only', 'AC: DELETE fails with audit_append_only');
select throws_ok($$ truncate public.report_audit $$, 'audit_append_only', 'TRUNCATE fails too');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'u_owner', 'tenant_id', :'tenant_id', 'app_role', 'super_admin')::text, true);
select throws_ok($$ update public.report_audit set reason = 'edited' $$, 'audit_append_only', 'AC: a tenant super admin cannot UPDATE even with no matching rows');
select throws_ok($$ delete from public.report_audit $$, 'audit_append_only', 'nor DELETE');
select throws_ok(format($$ insert into public.report_audit (tenant_id, user_id, report_key, dataset_key, contains_pii) values (%L, %L, 'x', 'x', false) $$, :'tenant_id', gen_random_uuid()), '42501', null, 'and cannot insert a row for someone else');
reset role;

-- ── visibility ────────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'u1', 'tenant_id', :'tenant_id', 'app_role', 'accountant')::text, true);
select is((select count(*)::int from public.report_audit), 0, 'an accountant cannot read the audit trail, not even their own rows');
select set_config('request.jwt.claims', json_build_object('sub', :'u_owner', 'tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);
select is((select count(*)::int from public.report_audit), 2, 'the owner reads the trail');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'owner')::text, true);
select is((select count(*)::int from public.report_audit), 0, 'another school''s owner sees nothing');
select set_config('request.jwt.claims', json_build_object('sub', :'u_owner', 'tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);

-- ── exporting the audit list writes a further audit row ───────────────────
select is((select count(*)::int from public.export_report_audit(:'u1'::uuid)), 2, 'the owner exports one user''s audit rows');
select is((select count(*)::int from public.report_audit where report_key = 'report_audit'), 1, 'AC: the export created a further audit row');
select is((select user_id from public.report_audit where report_key = 'report_audit'), :'u_owner'::uuid, 'naming who exported it');
select set_config('request.jwt.claims', json_build_object('sub', :'u1', 'tenant_id', :'tenant_id', 'app_role', 'accountant')::text, true);
select throws_ok($$ select * from public.export_report_audit() $$, 'FORBIDDEN', 'a non-owner cannot export the audit list');
reset role;

-- ── alert: more than 3 PII exports in 24 hours ────────────────────────────
insert into public.report_audit (tenant_id, user_id, report_key, dataset_key, contains_pii, reason, destination)
select :'tenant_id', :'u2', 'pii_report_' || n, 'students', true, 'Quarterly board submission paperwork', 'xlsx' from generate_series(1, 4) n;
select is(public.check_pii_export_alerts(), 1, 'AC: the hourly check alerts on the user with 4 PII exports in 24 hours');
select is((select pii_report_count from public.report_audit_alert where user_id = :'u2'), 4, 'the alert counts them');
select is((select count(*)::int from public.report_audit_alert where user_id = :'u1'), 0, 'a user with a single PII export is not flagged');

select * from finish();
rollback;
