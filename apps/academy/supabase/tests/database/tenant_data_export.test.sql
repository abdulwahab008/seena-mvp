-- pgTAP tests for FR-A19: tenant data export (the CSV/BOM/ZIP assembly is asserted in lib/tenant-export/*.test.ts).
begin;
select plan(34);

select public.provision_tenant('test-tex-co', 'Export Co', 'owner@tex.test');
select id as tenant_id from public.tenant where slug = 'test-tex-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-tex-other', 'Other Export Co', 'owner@othertex.test');
select id as other_tenant_id from public.tenant where slug = 'test-tex-other' \gset
select id as other_campus from public.campus where tenant_id = :'other_tenant_id' \gset

select id as owner_role from public.role where tenant_id = :'tenant_id' and code = 'owner' and deleted_at is null \gset
select id as prin_role from public.role where tenant_id = :'tenant_id' and code = 'principal' and deleted_at is null \gset
select id as other_owner_role from public.role where tenant_id = :'other_tenant_id' and code = 'owner' and deleted_at is null \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as other_owner_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@tex.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@tex.test', 'authenticated', 'authenticated', 'x'), (:'other_owner_uid', 'oo@tex.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Export Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Export Principal'), (:'other_owner_uid', :'other_tenant_id', 'owner', 'Other Owner');

-- some data, Urdu included, in both schools
insert into public.student (tenant_id, campus_id, gr_number, name_en, name_ur, dob, gender) values
  (:'tenant_id', :'campus_id', 'TX1', 'Ayesha Ahmed', 'عائشہ احمد', '2012-03-04', 'female'),
  (:'tenant_id', :'campus_id', 'TX2', 'Bilal Khan', 'بلال خان', '2011-01-02', 'male'),
  (:'other_tenant_id', :'other_campus', 'OT1', 'Other Student', null, '2012-03-04', 'male');
insert into public.guardian (tenant_id, name_en, name_ur, cnic) values (:'tenant_id', 'Ahmed Ali', 'احمد علی', '35202-1111111-1');

select is((select count(*)::int from public.permission where code = 'tenant.export'), 1, 'the tenant.export permission is published');
select is((select count(*)::int from public.role_permission where role_id = :'owner_role' and permission_code = 'tenant.export'), 1, 'the Owner role carries it');
select is((select count(*)::int from public.role_permission where role_id = :'prin_role' and permission_code = 'tenant.export'), 0, 'the Principal role does not');
select is((select public from storage.buckets where id = 'tenant-exports'), false, 'the tenant-exports bucket is private');
select is((select count(*)::int from public.tenant_export_source where table_key in ('students', 'guardians', 'enrolments', 'attendance', 'fee_challans', 'payments', 'marks', 'staff')), 8, 'AC1: students, guardians, enrolments, attendance, fee challans, payments, marks and staff are all in the export');
select ok((select bool_and(cardinality(columns) > 3) from public.tenant_export_tables()), 'every file has its header columns even when the table is empty');
select is(has_function_privilege('authenticated', 'public.tenant_export_page(uuid,text,int,int)', 'execute'), false, 'a client cannot read export pages directly');

-- ── AC3: non-owner -> 403 PERMISSION_DENIED ───────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'role_id', :'prin_role', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.request_tenant_export() $$, '42501', 'PERMISSION_DENIED', 'AC3: a Principal''s request fails with PERMISSION_DENIED (SQLSTATE 42501 = HTTP 403)');
select is((select count(*)::int from public.data_export_request), 0, 'AC3: and nothing was queued');

select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'role_id', :'owner_role', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.request_tenant_export() as req \gset
select is((select status from public.data_export_request where id = :'req'), 'queued', 'the Owner''s request is queued');
select is(public.request_tenant_export(), :'req'::uuid, 'asking again while one is in progress returns the same request');
select is((select count(*)::int from public.data_export_request), 1, 'RLS export_owner_only: the owner sees their school''s requests');
reset role;

-- ── worker: pages are the request's own tenant only ───────────────────────
update public.data_export_request set status = 'running', started_at = now(), attempts = 1 where id = :'req';
select is(jsonb_array_length(public.tenant_export_page(:'req'::uuid, 'students', 0, 100)), 2, 'the students page holds this school''s two students');
select is((select count(*)::int from jsonb_array_elements(public.tenant_export_page(:'req'::uuid, 'students', 0, 100)) x where x ->> 'gr_number' = 'OT1'), 0, 'and none of another school''s');
select is((select x ->> 'name_ur' from jsonb_array_elements(public.tenant_export_page(:'req'::uuid, 'students', 0, 100)) x where x ->> 'gr_number' = 'TX1'), 'عائشہ احمد', 'Urdu names survive the page intact');
select is(jsonb_array_length(public.tenant_export_page(:'req'::uuid, 'students', 1, 100)), 1, 'paging by offset works');
select is(jsonb_array_length(public.tenant_export_page(:'req'::uuid, 'guardians', 0, 100)), 1, 'guardians are exported');
select is(jsonb_array_length(public.tenant_export_page(:'req'::uuid, 'marks', 0, 100)), 0, 'an empty table gives an empty page, not an error');
select throws_ok(format($$ select public.tenant_export_page(%L, 'pg_authid', 0, 10) $$, :'req'), 'EXPORT_TABLE_UNKNOWN', 'only registered tables can be paged');
select throws_ok($$ select public.tenant_export_page(gen_random_uuid(), 'students', 0, 10) $$, 'EXPORT_NOT_RUNNING', 'an unknown or finished request cannot be paged');

-- ── AC5: completion writes exactly one audit row ──────────────────────────
select public.complete_tenant_export(:'req'::uuid, :'tenant_id' || '/' || :'req' || '.zip', 12345, repeat('ab', 32),
  '{"students.csv": 2, "guardians.csv": 1, "marks.csv": 0}'::jsonb);
select public.complete_tenant_export(:'req'::uuid, 'again.zip', 1, repeat('cd', 32), '{}'::jsonb);
select is((select count(*)::int from public.tenant_export_audit where request_id = :'req'), 1, 'AC5: exactly one audit row, even if completion is reported twice');
select is((select requested_by from public.tenant_export_audit where request_id = :'req'), :'owner_uid'::uuid, 'AC5: it records the requester');
select is((select row_counts ->> 'students.csv' from public.tenant_export_audit where request_id = :'req'), '2', 'AC5: the per-file row counts');
select is((select checksum_sha256 from public.tenant_export_audit where request_id = :'req'), repeat('ab', 32), 'AC5: and the archive checksum');
select throws_ok(format($$ update public.tenant_export_audit set checksum_sha256 = repeat('0', 64) where request_id = %L $$, :'req'), 'audit_append_only', 'the audit row can never be altered');
select is((select expires_at - completed_at from public.data_export_request where id = :'req'), interval '72 hours', 'the link lives 72 hours from completion');

-- ── AC4: the link at hour 73 ──────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'role_id', :'owner_role', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.get_tenant_export_download(:'req'::uuid), :'tenant_id' || '/' || :'req' || '.zip', 'inside 72 hours the download resolves');
reset role;
update public.data_export_request set completed_at = now() - interval '71 hours', expires_at = now() - interval '71 hours' + interval '72 hours' where id = :'req';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'role_id', :'owner_role', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select lives_ok(format($$ select public.get_tenant_export_download(%L) $$, :'req'), 'at hour 71 it still works');
reset role;
update public.data_export_request set completed_at = now() - interval '73 hours', expires_at = now() - interval '73 hours' + interval '72 hours' where id = :'req';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'role_id', :'owner_role', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.get_tenant_export_download(%L) $$, :'req'), 'EXPORT_LINK_EXPIRED', 'AC4: at hour 73 the link answers EXPORT_LINK_EXPIRED');
select set_config('request.jwt.claims', json_build_object('sub', :'other_owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'role_id', :'other_owner_role', 'campus_ids', json_build_array(:'other_campus'))::text, true);
select throws_ok(format($$ select public.get_tenant_export_download(%L) $$, :'req'), 'EXPORT_NOT_FOUND', 'another school''s owner cannot resolve this export');
select is((select count(*)::int from public.data_export_request), 0, 'nor see it');
reset role;

-- ── retention ─────────────────────────────────────────────────────────────
select ok(public.expire_tenant_exports() >= 1, 'the daily job marks lapsed archives expired');
select is((select count(*)::int from public.tenant_exports_to_purge() where request_id = :'req'), 1, 'and queues their blobs for deletion');
select public.mark_tenant_export_purged(:'req'::uuid);
select is((select storage_path from public.data_export_request where id = :'req'), null, 'once the blob is deleted the path is cleared');

select * from finish();
rollback;
