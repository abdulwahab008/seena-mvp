-- pgTAP tests for FR-T14: audit trail export for inspection.
--
-- Coverage: hash-chain computation (AC2), chain-verification detecting a
-- directly-tampered row (AC2), campus-scoped RLS returning zero rows for
-- an out-of-scope campus rather than an error (AC3), and the export
-- itself landing in audit_log with actor + filter parameters (AC1). Plus
-- request_audit_export's own validation/role gates and audit_export_job's
-- read RLS, since a broken gate there would silently defeat the rest.
begin;
select plan(31);

select public.provision_tenant('test-audit-export-co', 'Audit Export Co', 'owner@auditexportco.test');
select id as tenant_id from public.tenant where slug = 'test-audit-export-co' \gset
select id as main_campus_id from public.campus where tenant_id = :'tenant_id' \gset

-- A second campus, plus real auth.users/app_user rows for Owner and
-- Principal — the same convention soft_delete_business_records.test.sql
-- and admission_document_upload.test.sql use, so auth.uid() (and
-- therefore audit_log.actor_user_id / audit_export_job.requested_by)
-- resolves to something real rather than null.
reset role;
insert into public.campus (tenant_id, code, name) values (:'tenant_id'::uuid, 'NORTH', 'North Campus') returning id as north_campus_id \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner-user@auditexportco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id'::uuid, 'owner', 'Owner');

select gen_random_uuid() as principal_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_user_id', 'principal-user@auditexportco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_user_id', :'tenant_id'::uuid, 'principal', 'Principal');

-- ═══════════════════════════════════════════════════════════════════════
-- AC2 (part 1): hash-chain computation
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select prev_hash from public.audit_log where tenant_id = :'tenant_id'::uuid order by occurred_at, id limit 1),
  null,
  'the first audit row ever written for a fresh tenant chains onto GENESIS (prev_hash is null)'
);
select is(
  (select row_hash is not null from public.audit_log where tenant_id = :'tenant_id'::uuid order by occurred_at, id limit 1),
  true,
  'the first audit row still gets a real row_hash'
);
select is(
  (
    select bool_and(row_hash = app.fn_audit_row_hash(
      lagged_prev_hash, tenant_id, campus_id, occurred_at, actor_user_id, actor_role::text, action::text, table_name, row_id,
      before, after, changed_columns
    ))
    from (
      select *, lag(row_hash) over (order by occurred_at, id) as lagged_prev_hash
        from public.audit_log where tenant_id = :'tenant_id'::uuid
    ) chained
  ),
  true,
  'every audit row''s row_hash matches recomputing app.fn_audit_row_hash from its own stored fields plus the previous row''s hash'
);
select is(
  (
    select bool_and(prev_hash is not distinct from lagged_prev_hash)
    from (
      select *, lag(row_hash) over (order by occurred_at, id) as lagged_prev_hash
        from public.audit_log where tenant_id = :'tenant_id'::uuid
    ) chained
  ),
  true,
  'every audit row''s prev_hash equals the immediately preceding row''s row_hash — the chain is actually linked, not just individually valid'
);
select ok(
  (select count(*)::int from public.audit_log where tenant_id = :'tenant_id'::uuid) >= 3,
  'provisioning produced more than one chained row (tenant, campus, session) to chain across'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2 (part 2): chain verification detects a row tampered with directly
-- in SQL — the scenario is a superuser/DBA bypassing the app layer
-- entirely (authenticated already can't UPDATE audit_log at all, per
-- audit_log_hardening.test.sql), so this runs as postgres (reset role,
-- above), exactly like that.
-- ═══════════════════════════════════════════════════════════════════════

select id as tamper_id, occurred_at as tamper_occurred_at
  from public.audit_log where tenant_id = :'tenant_id'::uuid order by occurred_at, id limit 1 offset 1 \gset

update public.audit_log
   set after = jsonb_set(coalesce(after, '{}'::jsonb), '{tampered_by_test}', 'true'::jsonb)
 where id = :'tamper_id'::uuid;

select status, broken_audit_log_id, broken_occurred_at, rows_checked
  from public.run_audit_chain_verification(:'tenant_id'::uuid) \gset

select is(:'status'::text, 'broken'::text, 'chain verification flags a directly-tampered row as broken, not ok');
select is(:'broken_audit_log_id'::text, :'tamper_id'::text, 'chain verification flags the exact tampered row''s audit_log id');
select is(:'broken_occurred_at'::text, :'tamper_occurred_at'::text, 'chain verification flags the tampered row''s own timestamp');
select ok(:'rows_checked'::int >= 1, 'chain verification reports at least one row checked before stopping at the break');

select ok(
  (select count(*)::int from public.audit_chain_verification where tenant_id = :'tenant_id'::uuid and status = 'broken') = 1,
  'the broken verdict is itself persisted as a row for the nightly job to have produced'
);

-- Undo the tamper and re-verify clean, so later assertions in this file
-- aren't reading a permanently-corrupted chain.
update public.audit_log
   set after = after - 'tampered_by_test'
 where id = :'tamper_id'::uuid;

select is(
  (select status::text from public.run_audit_chain_verification(:'tenant_id'::uuid) limit 1),
  'ok',
  'once the tamper is undone, verification reports ok again'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'main_campus_id'), 'sub', :'principal_user_id')::text,
  true
);
select throws_like(
  format('select * from public.run_audit_chain_verification(%L)', :'tenant_id'),
  '%FORBIDDEN%',
  'a Principal cannot run chain verification — Owner/Super Admin only'
);
reset role;

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: a Principal scoped to one campus gets zero rows (not an error) for
-- another campus's audit trail — proven directly against audit_log's own
-- RLS, the exact mechanism apps/academy/app/(app)/audit-export/actions.ts
-- relies on for the export's row fetch.
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'sub', :'owner_user_id')::text,
  true
);
select public.create_student(:'north_campus_id'::uuid, 'North Student', '2015-01-01'::date, 'female') as north_student_id \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'main_campus_id'), 'sub', :'principal_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.audit_log where table_name = 'student' and row_id = :'north_student_id'::uuid),
  0,
  'AC3: a Principal scoped to Main campus gets zero rows for a student audit event on North campus — RLS, not an authorisation error'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'north_campus_id'), 'sub', :'principal_user_id')::text,
  true
);
select ok(
  (select count(*)::int from public.audit_log where table_name = 'student' and row_id = :'north_student_id'::uuid) > 0,
  'positive control: a Principal actually scoped to North campus DOES see that same student''s audit row'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'sub', :'owner_user_id')::text,
  true
);
select ok(
  (select count(*)::int from public.audit_log where table_name = 'student' and row_id = :'north_student_id'::uuid) > 0,
  'an Owner (tenant-wide) sees the North campus student audit row regardless of any campus scope'
);
reset role;

-- ═══════════════════════════════════════════════════════════════════════
-- request_audit_export: validation, role gate, and AC3's own "a foreign
-- campus request is not rejected at request time" design point
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'sub', :'owner_user_id')::text,
  true
);

select throws_like(
  $$ select public.request_audit_export('2026-06-30'::date, '2026-01-01'::date, array['fee_challan']) $$,
  '%INVALID_DATE_RANGE%',
  'a to-date before the from-date is rejected'
);
select throws_like(
  $$ select public.request_audit_export('2026-01-01'::date, '2026-06-30'::date, array[]::text[]) $$,
  '%NO_ENTITIES_SELECTED%',
  'an empty entity list is rejected'
);
select throws_like(
  format('select public.request_audit_export(%L::date, %L::date, array[%L], %L::uuid)', '2026-01-01', '2026-06-30', 'fee_challan', gen_random_uuid()),
  '%CAMPUS_NOT_FOUND%',
  'a campus id that does not exist in this tenant is rejected'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'sub', :'principal_user_id')::text,
  true
);
select throws_like(
  $$ select public.request_audit_export('2026-01-01'::date, '2026-06-30'::date, array['fee_challan']) $$,
  '%FORBIDDEN%',
  'a subject_teacher cannot request an audit export at all'
);

-- AC3's own literal wording: a Principal requesting a campus outside
-- their own scope is NOT rejected here — the request itself succeeds.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'main_campus_id'), 'sub', :'principal_user_id')::text,
  true
);
select lives_ok(
  format('select public.request_audit_export(%L::date, %L::date, array[%L], %L::uuid)', '2026-01-01', '2026-06-30', 'student', :'north_campus_id'),
  'AC3: a Principal requesting an export for a campus outside their own JWT scope still gets a real job, not FORBIDDEN'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: the export itself lands in audit_log with actor + filter params
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'sub', :'owner_user_id')::text,
  true
);
select public.request_audit_export('2026-01-01'::date, '2026-06-30'::date, array['fee_challan', 'certificate_issue']) as export_job_id \gset

select is(
  (select count(*)::int from public.audit_log where table_name = 'audit_export_job' and row_id = :'export_job_id'::uuid and action = 'insert'),
  1,
  'AC1: requesting an export writes exactly one audit_log row for the job itself'
);
select is(
  (select after ->> 'requested_by' from public.audit_log where table_name = 'audit_export_job' and row_id = :'export_job_id'::uuid and action = 'insert'),
  :'owner_user_id',
  'AC1: the export''s own audit row records who requested it'
);
select is(
  (select after ->> 'from_date' from public.audit_log where table_name = 'audit_export_job' and row_id = :'export_job_id'::uuid and action = 'insert'),
  '2026-01-01',
  'AC1: the export''s own audit row records the from_date filter'
);
select is(
  (select after ->> 'to_date' from public.audit_log where table_name = 'audit_export_job' and row_id = :'export_job_id'::uuid and action = 'insert'),
  '2026-06-30',
  'AC1: the export''s own audit row records the to_date filter'
);
select is(
  (select after -> 'table_names' from public.audit_log where table_name = 'audit_export_job' and row_id = :'export_job_id'::uuid and action = 'insert'),
  '["fee_challan", "certificate_issue"]'::jsonb,
  'AC1: the export''s own audit row records the requested entities, including certificate_issue (no table yet — this is still a legitimate filter parameter)'
);

select public.complete_audit_export(
  :'export_job_id'::uuid, 0::bigint, '{"row_count": 0, "files": []}'::jsonb, :'tenant_id' || '/' || :'export_job_id', 'https://example.test/signed', 24
);
select is(
  (select count(*)::int from public.audit_log where table_name = 'audit_export_job' and row_id = :'export_job_id'::uuid and action = 'update'),
  1,
  'AC1: completing the export produces its own audit row too (action=update)'
);
select is(
  (select status::text from public.audit_export_job where id = :'export_job_id'::uuid),
  'completed',
  'complete_audit_export actually marks the job completed'
);
select ok(
  (select download_expires_at from public.audit_export_job where id = :'export_job_id'::uuid) > now() + interval '23 hours',
  'the signed download link is recorded with roughly a 24-hour expiry'
);

-- Only the requester (or Owner/Super Admin) may complete/fail a job —
-- another authenticated user in the same tenant cannot.
select gen_random_uuid() as stranger_user_id \gset
reset role;
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'stranger_user_id', 'stranger@auditexportco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'stranger_user_id', :'tenant_id'::uuid, 'principal', 'Stranger Principal');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'main_campus_id'), 'sub', :'stranger_user_id')::text,
  true
);
select throws_like(
  format('select public.fail_audit_export(%L::uuid, %L)', :'export_job_id', 'boom'),
  '%FORBIDDEN%',
  'a different Principal (not the requester, not Owner/Super Admin) cannot fail someone else''s export job'
);

-- audit_export_job read RLS: the stranger sees nothing (didn't request
-- it, isn't Owner/Super Admin); Owner sees it regardless of who asked.
select is(
  (select count(*)::int from public.audit_export_job where id = :'export_job_id'::uuid),
  0,
  'a non-owning Principal cannot even see another user''s export job via RLS'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'sub', :'owner_user_id')::text,
  true
);
select ok(
  (select count(*)::int from public.audit_export_job where tenant_id = :'tenant_id'::uuid) >= 2,
  'an Owner sees every export job in their tenant, including the Principal-requested one'
);

select * from finish();
rollback;
