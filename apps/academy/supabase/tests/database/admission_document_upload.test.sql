-- pgTAP tests for FR-B10: upload and verify applicant documents.
--
-- Storage bucket RLS (admission_docs_read_campus / _insert_officer /
-- _no_delete_after_verify) is exercised end-to-end against the real
-- Storage HTTP API in e2e/admission-document-upload.spec.ts, not here —
-- pgTAP covers the SQL-function business rules and the fn_issue_offer
-- gate.
begin;
select plan(20);

select public.provision_tenant('test-upload-co', 'Upload Co', 'owner@uploadco.test');
select id as tenant_id from public.tenant where slug = 'test-upload-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select public.provision_tenant('test-upload-other-co', 'Upload Other Co', 'owner@uploadotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-upload-other-co' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.set_document_requirement(:'campus_id'::uuid, 1::smallint, 13::smallint, 'b_form'::public.document_type, true, 1::smallint);

select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate One', p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent One', p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry1_id \gset
select public.fn_submit_application(:'enquiry1_id'::uuid) as app1_id \gset

-- ── AC1: rejected both client- and server-side, no object stored ─────

select throws_ok(
  format('select public.create_admission_document(%L, %L, %L, %L, %L)', :'app1_id', 'b_form', 6000000, 'application/pdf', 'pdf'),
  'FILE_TOO_LARGE',
  'AC: a file over 5 MB is rejected server-side'
);
select throws_ok(
  format('select public.create_admission_document(%L, %L, %L, %L, %L)', :'app1_id', 'b_form', 100000, 'application/zip', 'zip'),
  'UNSUPPORTED_FILE_TYPE',
  'an unsupported mime type is rejected'
);
select is(
  (select count(*)::int from public.admission_document),
  0,
  'neither refused upload created a row'
);

-- ── AC4: a B-Form number is validated as 13 digits, 00000-0000000-0 ──

select throws_ok(
  format('select public.create_admission_document(%L, %L, %L, %L, %L, %L)', :'app1_id', 'b_form', 100000, 'application/pdf', 'pdf', '12345'),
  'new row for relation "admission_document" violates check constraint "chk_admission_document_bform"',
  'AC: a malformed B-Form number is rejected by the check constraint'
);

select (public.create_admission_document(:'app1_id'::uuid, 'b_form'::public.document_type, 100000, 'application/pdf', 'pdf', '42101-1234567-8')) as doc1_result \gset
select ((:'doc1_result')::jsonb ->> 'document_id')::uuid as doc1_id \gset
select ok(:'doc1_id' is not null, 'a valid upload succeeds');
select is(
  (select storage_path from public.admission_document where id = :'doc1_id'::uuid) like :'tenant_id' || '/' || :'app1_id' || '/b_form/%',
  true,
  'AC: the object path is tenant/application/doc_type/uuid — never the public application number'
);
select is(
  (select status from public.admission_document_submission where application_id = :'app1_id'::uuid and doc_type = 'b_form')::text,
  'uploaded',
  'the checklist submission status syncs to uploaded'
);

-- ── FR-B10's own stricter gate: uploaded-but-unverified is not enough
--    to issue an offer, even though FR-B09's own general checklist
--    completeness would already accept "uploaded to the required count" ─

select is(public.fn_application_docs_complete(:'app1_id'::uuid), false, 'an uploaded-but-unverified mandatory document is not enough to complete the docs gate');
select throws_ok(
  format('select public.fn_issue_offer(%L, 5000)', :'app1_id'),
  'DOCUMENTS_INCOMPLETE',
  'AC: fn_issue_offer refuses to issue while the mandatory document is unverified'
);

select public.verify_admission_document(:'doc1_id'::uuid);
select is(
  (select status from public.admission_document where id = :'doc1_id'::uuid)::text,
  'verified',
  'the document is now verified'
);
select is(public.fn_application_docs_complete(:'app1_id'::uuid), true, 'AC: verifying the only mandatory document completes the docs gate');

-- ── AC2: a rejected document (even a later re-upload) leaves the
--    checklist outstanding and blocks the offer again ────────────────

select (public.create_admission_document(:'app1_id'::uuid, 'b_form'::public.document_type, 90000, 'application/pdf', 'pdf')) as doc2_result \gset
select ((:'doc2_result')::jsonb ->> 'document_id')::uuid as doc2_id \gset
select public.reject_admission_document(:'doc2_id'::uuid, 'Scan is blurred, please re-upload.');
select is(
  (select status from public.admission_document_submission where application_id = :'app1_id'::uuid and doc_type = 'b_form')::text,
  'rejected',
  'AC: a rejected re-upload flips the checklist item back to outstanding'
);
select is(public.fn_application_docs_complete(:'app1_id'::uuid), false, 'AC: the docs gate closes again once the live submission is rejected');

select throws_ok(
  format('select public.reject_admission_document(%L, %L)', :'doc1_id', ''),
  'REASON_REQUIRED',
  'an empty rejection reason is refused'
);

-- ── AC5: a verified document can only be deleted by a Principal ──────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.delete_admission_document(%L)', :'doc1_id'),
  'FORBIDDEN',
  'AC: an Admissions Officer cannot delete a verified document'
);
select is(
  (select count(*)::int from public.admission_document where id = :'doc1_id'::uuid),
  1,
  'the refused delete left the verified document in place'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.delete_admission_document(:'doc1_id'::uuid);
select is(
  (select count(*)::int from public.admission_document where id = :'doc1_id'::uuid),
  0,
  'AC: a Principal can delete a verified document'
);

-- ── validation and tenant isolation ─────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.create_admission_document(%L, %L, %L, %L, %L)', :'app1_id', 'b_form', 100000, 'application/pdf', 'pdf'),
  'FORBIDDEN',
  'a role with no admissions access cannot upload a document'
);

reset role;
select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'owner@uploadotherco2.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json, 'sub', :'other_user_id')::text,
  true
);
select throws_ok(
  format('select public.create_admission_document(%L, %L, %L, %L, %L)', :'app1_id', 'b_form', 100000, 'application/pdf', 'pdf'),
  'APPLICATION_NOT_FOUND',
  'create_admission_document refuses a foreign-tenant application id'
);
select is(
  (select count(*)::int from public.admission_document),
  0,
  'AC/defense-in-depth: another tenant''s owner sees zero admission documents via RLS'
);

select * from finish();
rollback;
