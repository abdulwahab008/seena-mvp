-- pgTAP tests for FR-S08: asynchronous Excel export (queue, scope, dedupe, retention).
begin;
select plan(35);

select public.provision_tenant('test-export-co', 'Export Co', 'owner@exportco.test');
select id as tenant_id from public.tenant where slug = 'test-export-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'B', 'Campus B') returning id as campus_b \gset
select public.provision_tenant('test-export-other', 'Other Export Co', 'owner@otherexportco.test');
select id as other_tenant_id from public.tenant where slug = 'test-export-other' \gset

-- The queue is global: park anything another run left behind so only this test's jobs are claimable.
update public.report_export_job set status = 'failed', attempts = 3 where status in ('queued', 'running');
select gen_random_uuid() as principal \gset
select gen_random_uuid() as accountant \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'principal', 'p@exportco.test', 'authenticated', 'authenticated', 'x'), (:'accountant', 'a@exportco.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'principal', :'tenant_id', 'principal', 'Principal Tariq'), (:'accountant', :'tenant_id', 'accountant', 'Ali Accountant');

select set_config('t.campus_a', :'campus_a', false), set_config('t.campus_b', :'campus_b', false), set_config('t.session', :'session_id', false), set_config('t.class', :'class1_id', false);
create temp table kid (campus text, n int, enrol_id uuid);
grant all on kid to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
do $$
declare
  v_sec uuid; v_stu uuid; i int; c text;
begin
  foreach c in array array['a', 'b'] loop
    v_sec := public.create_section(current_setting('t.campus_' || c)::uuid, current_setting('t.session')::uuid, current_setting('t.class')::uuid, 'S' || c, 20);
    for i in 1..(case c when 'a' then 3 else 1 end) loop
      v_stu := public.create_student(current_setting('t.campus_' || c)::uuid, 'Export Kid ' || c || i, '2015-01-01'::date, 'male');
      insert into kid values (c, i, public.enrol_student(v_sec, v_stu));
      perform public.link_guardian(v_stu, public.fn_find_or_create_guardian(p_name_en => 'Guardian ' || c || i, p_cnic => '35202-100000' || i || '-1', p_phone_e164 => '+92300555000' || i),
                                   'father'::public.guardian_relationship, true, true);
    end loop;
  end loop;
end $$;
reset role;

select has_table('public', 'report_export_job', 'report_export_job exists');
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('public.report_export_job'::regclass, 'public.report_dataset'::regclass, 'public.user_notification'::regclass)), 'RLS on the job, dataset and notification tables');
select is(has_function_privilege('authenticated', 'public.claim_export_job()', 'execute'), false, 'a client cannot claim jobs');
select is(has_function_privilege('service_role', 'public.export_job_page(uuid,int,int)', 'execute'), true, 'the worker can read pages');

-- ── requesting ────────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'accountant', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok($$ select public.request_report_export('students', '{}'::jsonb, 'Quarterly board registration paperwork') $$, 'DATASET_NOT_AVAILABLE', 'an accountant cannot export the student list');

select set_config('request.jwt.claims', json_build_object('sub', :'principal', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok($$ select public.request_report_export('students', '{}'::jsonb, 'short') $$, 'REASON_REQUIRED_FOR_PII_EXPORT', 'the student list carries CNIC, so a reason is mandatory');
select public.request_report_export('students', '{}'::jsonb, 'Quarterly board registration paperwork', '203.0.113.9') as req1 \gset
select is((:'req1'::jsonb ->> 'deduplicated')::boolean, false, 'the first request queues a new job');
select public.request_report_export('students', '{}'::jsonb, 'Quarterly board registration paperwork') as req2 \gset
select is((:'req2'::jsonb ->> 'job_id'), (:'req1'::jsonb ->> 'job_id'), 'AC: an identical request within 60 seconds returns the same job id');
select is((:'req2'::jsonb ->> 'deduplicated')::boolean, true, 'and says it was deduplicated');
select isnt((public.request_report_export('students', '{"class_level_id":"00000000-0000-0000-0000-000000000001"}'::jsonb, 'Quarterly board registration paperwork') ->> 'job_id'), (:'req1'::jsonb ->> 'job_id'), 'different parameters are a different job');
reset role;

select is((select count(*)::int from public.report_export_job where requested_by = :'principal' and params = '{}'::jsonb), 1, 'AC: no second file is generated for the duplicate');
select is((select count(*)::int from public.report_audit where report_key = 'students' and user_id = :'principal'), 2, 'each real request is audited once (duplicates are not)');
select is((select contains_pii from public.report_audit where report_key = 'students' limit 1), true, 'and flagged as PII');
select is((select status from public.report_export_job where id = (:'req1'::jsonb ->> 'job_id')::uuid), 'queued', 'the job starts queued — nothing ran inline');

-- ── worker: claim, read as the requester, complete ────────────────────────
set local role service_role;
select job_id as claimed from public.claim_export_job() limit 1 \gset
select is(:'claimed'::uuid, (:'req1'::jsonb ->> 'job_id')::uuid, 'the worker claims the oldest queued job');
select is((select count(*)::int from public.claim_export_job()), 1, 'a second claim gets the other queued job, not the running one');
select is((select count(*)::int from public.claim_export_job()), 0, 'and then nothing is left to claim');
select jsonb_array_length(public.export_job_page(:'claimed'::uuid, 0, 100)) as all_rows \gset
select public.export_job_page(:'claimed'::uuid, 1, 1) as one_row \gset
reset role;

select is(:'all_rows'::int, 3, 'AC: the export holds the 3 students of the requester''s campus — campus B''s student is excluded');
select is(jsonb_array_length(:'one_row'::jsonb), 1, 'paging by offset and limit works');
select ok((:'one_row'::jsonb -> 0 ->> 'guardian_cnic') like '35202-%', 'the requester asked for the CNIC column and it is in the data');

-- ── completion, notification, failure, stale reclaim ──────────────────────
set local role service_role;
select public.complete_export_job(:'claimed'::uuid, 3, :'tenant_id' || '/' || :'principal' || '/job.xlsx');
reset role;
select is((select status from public.report_export_job where id = :'claimed'::uuid), 'done', 'AC: the job completes');
select ok((select expires_at between now() + interval '29 days' and now() + interval '31 days' from public.report_export_job where id = :'claimed'::uuid), 'the file is kept for 30 days');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'principal', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.user_notification where kind = 'report_export_ready' and link = '/reports/exports'), 1, 'AC: the requester has an in-app notification with the link');
select is((select downloadable from public.v_report_export_job where id = :'claimed'::uuid), true, 'the job is downloadable');
select ok(not exists (select 1 from information_schema.columns where table_name = 'v_report_export_job' and column_name in ('claims', 'storage_path')), 'the client view never exposes the claims snapshot or the storage path');
select set_config('request.jwt.claims', json_build_object('sub', :'accountant', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.user_notification), 0, 'another user sees no one else''s notifications');
select is((select count(*)::int from public.report_export_job), 0, 'nor their jobs');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.report_export_job), 2, 'the owner sees every job in the school');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.report_export_job), 0, 'another school sees none');
reset role;

set local role service_role;
select public.fail_export_job((select id from public.report_export_job where tenant_id = :'tenant_id' and status = 'running'), 'renderer crashed');
reset role;
select is((select status from public.report_export_job where error = 'renderer crashed'), 'queued', 'a first failure goes back to the queue for a retry');
update public.report_export_job set attempts = 3, status = 'running' where error = 'renderer crashed';
set local role service_role;
select public.fail_export_job((select id from public.report_export_job where error = 'renderer crashed'), 'renderer crashed again');
reset role;
select is((select status from public.report_export_job where error = 'renderer crashed again'), 'failed', 'after 3 attempts it fails for good');
select is((select count(*)::int from public.user_notification where kind = 'report_export_failed'), 1, 'and the requester is told');

update public.report_export_job set status = 'running', started_at = now() - interval '11 minutes', attempts = 1 where error = 'renderer crashed again';
set local role service_role;
select is((select count(*)::int from public.claim_export_job()), 1, 'a job whose worker died (running > 10 min) is reclaimed');
reset role;

-- ── retention ─────────────────────────────────────────────────────────────
update public.report_export_job set expires_at = now() - interval '1 day' where id = :'claimed'::uuid;
set local role service_role;
select is((select count(*)::int from public.export_jobs_to_purge() where job_id = :'claimed'::uuid), 1, 'AC: an expired file is listed for purging');
select public.mark_export_purged(:'claimed'::uuid);
reset role;
select is((select status || '/' || coalesce(storage_path, 'null') from public.report_export_job where id = :'claimed'::uuid), 'expired/null', 'once purged the path is gone — a surviving link has nothing to serve (HTTP 410)');

select * from finish();
rollback;
