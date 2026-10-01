-- pgTAP tests for FR-S09: branded PDF report rendering (the data layer; layout, Urdu
-- shaping and pagination are asserted in lib/reports/*.test.ts against a real render).
begin;
select plan(24);

select public.provision_tenant('test-pdf-co', 'PDF Co', 'owner@pdf.test');
select id as tenant_id from public.tenant where slug = 'test-pdf-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
insert into public.campus (tenant_id, code, name, name_ur, address_line) values (:'tenant_id', 'P2', 'Second Campus', 'دوسرا کیمپس', 'Plot 9, Lahore') returning id as campus_b \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'P3', 'Bare Campus') returning id as campus_c \gset
select public.provision_tenant('test-pdf-other', 'Other PDF Co', 'owner@otherpdf.test');
select id as other_tenant_id from public.tenant where slug = 'test-pdf-other' \gset
select id as other_campus from public.campus where tenant_id = :'other_tenant_id' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@pdf.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@pdf.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@pdf.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'PDF Owner'), (:'prin_uid', :'tenant_id', 'principal', 'PDF Principal'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'PDF Teacher');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'prin_uid', :'tenant_id', :'campus_a');

-- branding assets: tenant-level logo; campus A has its own letterhead and logo; campus B has nothing of its own
insert into public.branding_asset (tenant_id, campus_id, asset_type, storage_path, width_px, height_px, bytes, version, is_current) values
  (:'tenant_id', null, 'logo', :'tenant_id' || '/tenant/logo/1.png', 800, 800, 1000, 1, true),
  (:'tenant_id', :'campus_a', 'letterhead', :'tenant_id' || '/' || :'campus_a' || '/letterhead/1.png', 1600, 400, 1000, 1, true),
  (:'tenant_id', :'campus_a', 'logo', :'tenant_id' || '/' || :'campus_a' || '/logo/1.png', 800, 800, 1000, 1, true);

select has_table('public', 'campus_branding', 'campus_branding exists');
select is((select relrowsecurity from pg_class where oid = 'public.campus_branding'::regclass), true, 'RLS is on for campus_branding');

-- ── addresses ─────────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'))::text, true);
select public.set_campus_address(:'campus_a'::uuid, '12 Canal Road, Lahore', 'بارہ کینال روڈ، لاہور');
select is((select address_ur from public.campus_branding where campus_id = :'campus_a'), 'بارہ کینال روڈ، لاہور', 'the Urdu address is stored as written');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok(format($$ select public.set_campus_address(%L, 'x', null) $$, :'campus_b'), 'CAMPUS_NOT_FOUND', 'a principal cannot edit another campus''s address');
select lives_ok(format($$ select public.set_campus_address(%L, '12 Canal Road, Lahore', 'بارہ کینال روڈ، لاہور') $$, :'campus_a'), 'a principal can edit their own campus''s address');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok(format($$ select public.set_campus_address(%L, 'x', null) $$, :'campus_a'), 'FORBIDDEN', 'a teacher cannot');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.campus_branding), 1, 'a principal reads only their campus''s branding row');

-- ── AC4: no uploaded letterhead -> the tenant-level logo is substituted ────
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b', :'campus_c'))::text, true);
select is(public.resolve_report_branding(:'campus_a'::uuid) ->> 'header_mode', 'letterhead', 'a campus with a letterhead prints it');
select is(public.resolve_report_branding(:'campus_a'::uuid) ->> 'address_ur', 'بارہ کینال روڈ، لاہور', 'with its Urdu address');
select is(public.resolve_report_branding(:'campus_b'::uuid) ->> 'header_mode', 'logo', 'AC4: a campus with no letterhead falls back to a logo');
select is(public.resolve_report_branding(:'campus_b'::uuid) ->> 'logo_path', :'tenant_id' || '/tenant/logo/1.png', 'AC4: and that logo is the tenant-level one');
select is(public.resolve_report_branding(:'campus_b'::uuid) ->> 'address_en', 'Plot 9, Lahore', 'the campus''s own address line is used when no branding address was set');
select is(public.resolve_report_branding(:'campus_b'::uuid) ->> 'campus_name_ur', 'دوسرا کیمپس', 'the Urdu campus name is carried');
reset role;
delete from public.branding_asset where tenant_id = :'tenant_id' and campus_id is null;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b', :'campus_c'))::text, true);
select is(public.resolve_report_branding(:'campus_c'::uuid) ->> 'header_mode', 'none', 'with no logo anywhere the identity block is text only (layout still renders)');
select throws_ok(format($$ select public.resolve_report_branding(%L) $$, :'other_campus'), 'CAMPUS_NOT_FOUND', 'another school''s campus cannot be resolved');

-- ── PDFs ride the export queue ────────────────────────────────────────────
select (public.request_report_pdf('fee_collection', jsonb_build_object('from', '2026-01-01'), null, null) ->> 'job_id')::uuid as pdf_job \gset
select (public.request_report_export('fee_collection', jsonb_build_object('from', '2026-01-01'), null, null) ->> 'job_id')::uuid as xlsx_job \gset
select is((select format from public.report_export_job where id = :'pdf_job'), 'pdf', 'a PDF request is a report_export_job with format = pdf');
select isnt(:'pdf_job'::text, :'xlsx_job'::text, 'a PDF is not deduplicated against the identical Excel export');
select is((select destination from public.report_audit where id = (select audit_id from public.report_export_job where id = :'pdf_job')), 'pdf', 'the audit row (FR-S11) records destination = pdf');
select is((public.request_report_pdf('fee_collection', jsonb_build_object('from', '2026-01-01'), null, null) ->> 'deduplicated')::boolean, true, 'a repeat PDF request inside 60 s returns the same job');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok($$ select public.request_report_pdf('students', '{}'::jsonb, 'Printing the board registration list for the district office', null) $$, 'DATASET_NOT_AVAILABLE', 'a dataset the role cannot see cannot be printed');
reset role;

update public.report_export_job set status = 'failed' where status = 'queued' and id <> :'pdf_job' and id <> :'xlsx_job';
update public.report_export_job set status = 'failed' where id = :'xlsx_job';
select * from public.claim_export_job() \gset claim_
select is(:'claim_format'::text, 'pdf', 'the worker claim carries the format');
select is(:'claim_campus_id'::uuid, :'campus_a'::uuid, 'and the campus whose letterhead to print (the requester''s)');
select public.complete_export_job(:'pdf_job'::uuid, 500, 'x/y/z.pdf', 13, 'portrait');
select is((select page_count || '/' || orientation from public.report_export_job where id = :'pdf_job'), '13/portrait', 'the job records the page count and orientation');
select is((public.report_job_branding(:'pdf_job'::uuid, :'campus_a'::uuid) ->> 'header_mode'), 'letterhead', 'the worker resolves the job campus''s branding from the job''s own tenant');

select * from finish();
rollback;
