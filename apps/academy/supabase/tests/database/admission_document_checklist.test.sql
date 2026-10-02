-- pgTAP tests for FR-B09: versioned document checklist per class.
begin;
select plan(20);

select public.provision_tenant('test-checklist-co', 'Checklist Co', 'owner@checklistco.test');
select id as tenant_id from public.tenant where slug = 'test-checklist-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select id as class6_id from public.class_level where tenant_id = :'tenant_id' and code = '6' \gset
select ordinal as class6_ordinal from public.class_level where id = :'class6_id' \gset

select public.provision_tenant('test-checklist-other-co', 'Checklist Other Co', 'owner@checklistotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-checklist-other-co' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── AC2: a class band with nothing configured never requests that
--    document ────────────────────────────────────────────────────────

select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Class One Child', p_dob => '2021-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent One', p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry1_id \gset
select public.fn_submit_application(:'enquiry1_id'::uuid) as app1_id \gset
select is(
  (select checklist_snapshot from public.admission_application where id = :'app1_id'::uuid),
  '[]'::jsonb,
  'AC: Class 1 (nothing configured for it) submits with an empty checklist snapshot — transfer_certificate is never requestable'
);
select ((public.fn_checklist_completeness(:'app1_id'::uuid))->>'complete')::boolean as app1_complete_trivial \gset
select is(:'app1_complete_trivial'::boolean, true, 'an empty checklist is trivially complete');

-- ── AC1: a later configuration change never retroactively re-flags an
--    already-submitted application ──────────────────────────────────

select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Early Bird', p_dob => '2015-01-01'::date, p_class_applied_id => :'class6_id', p_parent_name => 'Parent Two', p_phone => '03002222222', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry2_id \gset
select public.fn_submit_application(:'enquiry2_id'::uuid) as app2_id \gset
select is(
  (select checklist_snapshot from public.admission_application where id = :'app2_id'::uuid),
  '[]'::jsonb,
  'before any requirement exists, a class 6 submission also gets an empty snapshot'
);

-- Now transfer_certificate becomes mandatory for classes covering class 6,
-- effective immediately.
select public.set_document_requirement(:'campus_id'::uuid, :'class6_ordinal'::smallint, :'class6_ordinal'::smallint, 'transfer_certificate'::public.document_type, true, 1::smallint) as req_id \gset

select is(
  (select checklist_snapshot from public.admission_application where id = :'app2_id'::uuid),
  '[]'::jsonb,
  'AC: the already-submitted application''s frozen snapshot is untouched by the later rule change'
);
select ((public.fn_checklist_completeness(:'app2_id'::uuid))->>'complete')::boolean as app2_still_complete \gset
select is(
  :'app2_still_complete'::boolean, true,
  'AC: re-checking the earlier application after the change still reports complete — never retroactively flagged incomplete'
);

-- A NEW submission for the same class, after the rule, picks it up.
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Late Bird', p_dob => '2015-01-01'::date, p_class_applied_id => :'class6_id', p_parent_name => 'Parent Three', p_phone => '03003333333', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry3_id \gset
select public.fn_submit_application(:'enquiry3_id'::uuid) as app3_id \gset
select is(
  jsonb_array_length((select checklist_snapshot from public.admission_application where id = :'app3_id'::uuid)),
  1,
  'a submission made after the rule takes effect picks up the new requirement'
);
select ((public.fn_checklist_completeness(:'app3_id'::uuid))->>'complete')::boolean as app3_incomplete \gset
select is(:'app3_incomplete'::boolean, false, 'AC-adjacent: the new application is incomplete until the now-mandatory document is provided');

select throws_ok(
  format('select public.set_document_requirement(%L, 5::smallint, 3::smallint, %L)', :'campus_id', 'transfer_certificate'),
  'INVALID_ORDINAL_RANGE',
  'a min ordinal greater than the max is rejected'
);
select throws_ok(
  format('select public.set_document_requirement(%L, 1::smallint, 5::smallint, %L, true, 0::smallint)', :'campus_id', 'transfer_certificate'),
  'MIN_COUNT_MUST_BE_POSITIVE',
  'a min_count of 0 is rejected'
);

-- ── AC3: an under-count upload is incomplete with an exact missing
--    count ────────────────────────────────────────────────────────────

select public.set_document_requirement(:'campus_id'::uuid, :'class6_ordinal'::smallint, :'class6_ordinal'::smallint, 'passport_photo'::public.document_type, true, 3::smallint) as photo_req_id \gset
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Photo Child', p_dob => '2015-01-01'::date, p_class_applied_id => :'class6_id', p_parent_name => 'Parent Four', p_phone => '03004444444', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry4_id \gset
select public.fn_submit_application(:'enquiry4_id'::uuid) as app4_id \gset

select public.set_document_submission(:'app4_id'::uuid, 'passport_photo'::public.document_type, 'uploaded'::public.doc_status, 2::smallint);
select public.set_document_submission(:'app4_id'::uuid, 'transfer_certificate'::public.document_type, 'verified'::public.doc_status);

select (public.fn_checklist_completeness(:'app4_id'::uuid)) as completeness4 \gset
select is(
  ((:'completeness4')::jsonb ->> 'complete')::boolean, false,
  'AC: 2 of 3 required photos is incomplete'
);
select is(
  ((:'completeness4')::jsonb -> 'missing' -> 0 ->> 'missing')::int, 1,
  'AC: the missing count reads exactly 1 (3 required, 2 uploaded)'
);

-- ── AC4: a document promised within 30 days counts as satisfied, and a
--    follow-up task is created for the deadline ────────────────────────

select public.set_document_submission(:'app3_id'::uuid, 'transfer_certificate'::public.document_type, 'promised'::public.doc_status, null, (current_date + 20));
select ((public.fn_checklist_completeness(:'app3_id'::uuid))->>'complete')::boolean as app3_now_complete \gset
select is(:'app3_now_complete'::boolean, true, 'AC: a document promised within 30 days counts as satisfied for checklist purposes');
select is(
  (select count(*)::int from public.admission_followup where enquiry_id = :'enquiry3_id'::uuid and due_at::date = (current_date + 20)),
  1,
  'AC: promising a document creates a follow-up task for the deadline'
);

select throws_ok(
  format('select public.set_document_submission(%L, %L, %L)', :'app3_id', 'transfer_certificate', 'promised'),
  'PROMISED_DEADLINE_REQUIRED',
  'promising a document with no deadline is rejected'
);
select throws_ok(
  format('select public.set_document_submission(%L, %L, %L, null, %L)', :'app3_id', 'transfer_certificate', 'promised', (current_date + 45)),
  'PROMISED_DEADLINE_TOO_FAR',
  'a promised deadline more than 30 days out is rejected'
);

-- ── validation and tenant isolation ─────────────────────────────────

select throws_ok(
  format('select public.fn_preview_checklist(%L, %L)', :'campus_id', gen_random_uuid()),
  'CLASS_LEVEL_NOT_FOUND',
  'previewing a bogus class level id is refused'
);

reset role;
select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'owner@checklistotherco2.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'), 'sub', :'other_user_id')::text,
  true
);
select throws_ok(
  format('select public.fn_checklist_completeness(%L)', :'app3_id'),
  'APPLICATION_NOT_FOUND',
  'fn_checklist_completeness refuses a foreign-tenant application id'
);
select throws_ok(
  format('select public.set_document_submission(%L, %L, %L)', :'app3_id', 'transfer_certificate', 'verified'),
  'APPLICATION_NOT_FOUND',
  'set_document_submission refuses a foreign-tenant application id'
);
select is(
  (select count(*)::int from public.admission_document_requirement),
  0,
  'AC/defense-in-depth: another tenant''s owner sees zero document requirements via RLS'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.set_document_requirement(%L, 1::smallint, 5::smallint, %L)', :'campus_id', 'transfer_certificate'),
  'FORBIDDEN',
  'a role with no admissions access cannot configure document requirements'
);

select * from finish();
rollback;
