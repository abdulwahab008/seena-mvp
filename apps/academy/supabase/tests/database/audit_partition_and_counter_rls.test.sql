-- pgTAP tests for 20260731999000_audit_partition_and_counter_rls.sql.
--
-- Every assertion here attacks the objects the way the defects were
-- actually found — by NAMING them directly as a signed-in role — because
-- that is precisely the path the rest of the suite never takes:
-- audit_log_hardening.test.sql and audit_trail_export.test.sql both reach
-- audit_log through the partitioned parent, and every counter test reaches
-- a counter through a SECURITY DEFINER allocator that runs as postgres and
-- bypasses RLS by definition. Both holes were wide open with all 130 test
-- files passing.
--
-- Two roles matter and both are exercised: `authenticated`, which is every
-- application role including super_admin (they all reach the database as
-- the same Postgres role), and `service_role`, which holds BYPASSRLS and
-- every DML grant so that RLS is never the last word for it — the triggers
-- are, and it is the triggers that speak the message.
--
-- The partition name is derived from now() rather than hard-coded:
-- create_audit_partition() names partitions for the calendar month, so a
-- literal 'audit_log_2026_08' would start failing the moment the clock
-- rolls into September.
begin;
select plan(41);

select public.provision_tenant('test-part-rls-co', 'Partition RLS Co', 'owner@partrls.test');
select id as tenant_id from public.tenant where slug = 'test-part-rls-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' and is_current limit 1 \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' order by ordinal limit 1 \gset

insert into public.campus (tenant_id, code, name) values (:'tenant_id'::uuid, 'NORTH', 'North Campus')
returning id as campus_b \gset

-- A second tenant, so "cross-tenant read" is a claim this test can
-- actually falsify rather than assume.
select public.provision_tenant('test-part-rls-other', 'Other Co', 'owner@partrlsother.test');
select id as other_tenant_id from public.tenant where slug = 'test-part-rls-other' \gset

-- The partition that actually holds the rows written above.
select 'audit_log_' || to_char(date_trunc('month', now()), 'YYYY_MM') as live_partition \gset

-- ═══════════════════════════════════════════════════════════════════════
-- The allocators still allocate (run first, so the counters below hold
-- real values that the tamper attempts have something to fail against)
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a', :'campus_b'))::text,
  true
);

select public.create_staff(:'campus_a'::uuid, 'First Teacher', 'female', p_cnic => '4210112340011') as staff1 \gset
select public.create_staff(:'campus_a'::uuid, 'Second Teacher', 'male', p_cnic => '4210112340022') as staff2 \gset

select is(
  (select array_agg(employee_code order by employee_code) from public.staff where id in (:'staff1'::uuid, :'staff2'::uuid)),
  array['SA-MAIN-0001', 'SA-MAIN-0002'],
  'app.fn_next_employee_code() still allocates, and still allocates consecutively'
);

select public.create_enquiry(
  p_campus_id => :'campus_a', p_session_id => :'session_id', p_child_name => 'First Applicant',
  p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent One',
  p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry1 \gset
select public.create_enquiry(
  p_campus_id => :'campus_a', p_session_id => :'session_id', p_child_name => 'Second Applicant',
  p_dob => '2020-02-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Two',
  p_phone => '03002222222', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry2 \gset

select public.fn_submit_application(:'enquiry1'::uuid) as app1 \gset
select public.fn_submit_application(:'enquiry2'::uuid) as app2 \gset

select is(
  (select array_agg(application_no order by application_no) from public.admission_application where id in (:'app1'::uuid, :'app2'::uuid)),
  array['APP-' || to_char(now(), 'YYYY') || '-00001', 'APP-' || to_char(now(), 'YYYY') || '-00002'],
  'fn_submit_application() still allocates, and still allocates consecutively'
);

reset role;
select is(
  (select next_seq from public.application_no_counter where campus_id = :'campus_a'::uuid and session_id = :'session_id'::uuid),
  3,
  'application_no_counter is where two allocations left it'
);
select is(
  (select next_value from public.employee_code_counter where campus_id = :'campus_a'::uuid),
  3::bigint,
  'employee_code_counter is where two allocations left it'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Defect 1: a named audit_log partition, attacked as authenticated
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a', :'campus_b'))::text,
  true
);

-- This is the exact statement that returned 3020 cross-tenant rows before
-- this migration.
select throws_like(
  format($$ select count(*) from public.%I $$, :'live_partition'),
  '%permission denied%',
  'an authenticated user cannot SELECT from an audit_log partition by name — the read that bypassed the parent''s RLS entirely'
);
select throws_like(
  format($$ update public.%I set action = 'insert' $$, :'live_partition'),
  '%permission denied%',
  'nor UPDATE one, so the hash chain cannot be rewritten row by row'
);
select throws_like(
  format($$ delete from public.%I $$, :'live_partition'),
  '%permission denied%',
  'nor DELETE from one'
);
select throws_like(
  format($$ truncate public.%I $$, :'live_partition'),
  '%permission denied%',
  'nor TRUNCATE one, which would erase the evidence the chain is verified against'
);
select throws_like(
  $$ truncate public.audit_log $$,
  '%permission denied%',
  'nor TRUNCATE the parent, which FR-A14''s revoke of insert/update/delete never covered'
);
select throws_like(
  $$ select count(*) from public.audit_log_default $$,
  '%permission denied%',
  'the DEFAULT partition — created inline by FR-A14, never through create_audit_partition() — is closed too'
);

-- ── the parent still works, and still scopes ────────────────────────────

select ok(
  (select count(*) from public.audit_log where tenant_id = :'tenant_id') > 0,
  'an owner still reads their own tenant''s audit rows through the parent'
);
select is(
  (select count(*)::int from public.audit_log where tenant_id = :'other_tenant_id'),
  0,
  'and still sees none of the other tenant''s, which naming a partition directly used to hand over in full'
);

-- Campus scope, the property FR-T14 added and the one a per-partition
-- policy copy would have had to be kept in sync with.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'))::text,
  true
);
select ok(
  (select count(*) from public.audit_log where campus_id = :'campus_a'::uuid) > 0,
  'a Principal still reads audit rows for their own campus through the parent'
);
select is(
  (select count(*)::int from public.audit_log where campus_id = :'campus_b'::uuid),
  0,
  'and still none for a campus outside their scope — parent-routed reads campus-scope exactly as before'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Defect 1: the same objects, attacked as service_role
-- ═══════════════════════════════════════════════════════════════════════
-- service_role bypasses RLS and holds every grant, so for it the revoke is
-- not the control — the TRUNCATE trigger is. And that trigger has to exist
-- on the partition itself: a BEFORE TRUNCATE trigger on a partitioned
-- parent does not propagate to its partitions the way a row-level trigger
-- does, so a parent-only guard would have let this through.

reset role;
set local role service_role;

select throws_ok(
  format($$ truncate public.%I $$, :'live_partition'),
  '42501',
  'audit_log is append-only',
  'a caller that bypasses RLS entirely cannot TRUNCATE a partition either — the trigger on the partition itself refuses, by name'
);
select throws_ok(
  $$ truncate public.audit_log $$,
  '42501',
  'audit_log is append-only',
  'nor the parent, which would have emptied every partition in one statement'
);
select throws_ok(
  $$ truncate public.audit_log_default $$,
  '42501',
  'audit_log is append-only',
  'nor the DEFAULT partition'
);
reset role;

-- ── the write path is untouched ─────────────────────────────────────────

select is(
  (select count(*)::int from public.audit_log where tenant_id = :'tenant_id' and table_name = 'staff' and action = 'insert'),
  2,
  'app.tg_audit_row() still logs through the parent — tuple routing into a partition does not consult the partition''s own grants'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a', :'campus_b'))::text,
  true
);
select public.create_staff(:'campus_b'::uuid, 'Third Teacher', 'female', p_cnic => '4210112340033') as staff3 \gset
reset role;

select is(
  (select count(*)::int from public.audit_log where tenant_id = :'tenant_id' and table_name = 'staff' and action = 'insert'),
  3,
  'a write made after the revoke still lands in the log'
);
select is(
  (select status::text from public.run_audit_chain_verification(:'tenant_id'::uuid)),
  'ok',
  'run_audit_chain_verification() still walks the chain and still finds it intact'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Defect 1: a NEW partition is secure by construction
-- ═══════════════════════════════════════════════════════════════════════
-- Fixing only the partitions that exist today would regress the next time
-- the month rolled over, so the securing is inside create_audit_partition()
-- itself. This proves the seam, not the four rows it happened to repair.

select public.create_audit_partition('2029-07-01'::date);

select is(
  (select relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'audit_log_2029_07'),
  true,
  'a partition created after this migration has RLS enabled without anyone remembering to ask'
);
select is(
  (select count(*)::int from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'audit_log_2029_07' and grantee in ('authenticated', 'anon')),
  0,
  'and holds no grant at all for authenticated or anon, despite Supabase''s default privileges having just handed it seven'
);
select is(
  (select count(*)::int from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'audit_log_2029_07' and t.tgname = 'trg_audit_log_partition_no_truncate'),
  1,
  'and carries its own TRUNCATE guard, which the parent''s does not propagate to it'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner')::text,
  true
);
select throws_like(
  $$ select count(*) from public.audit_log_2029_07 $$,
  '%permission denied%',
  'and is unreadable by name, same as the four this migration retro-fitted'
);
reset role;

-- ═══════════════════════════════════════════════════════════════════════
-- Defect 2: the counters, attacked as authenticated
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'super_admin')::text,
  true
);

select is(
  (select count(*)::int from public.application_no_counter),
  0,
  'a Super Admin of another tenant sees zero application_no_counter rows — the cross-tenant read is closed'
);
select is(
  (select count(*)::int from public.employee_code_counter),
  0,
  'and zero employee_code_counter rows, though both tables hold rows for the tenant next door'
);
select lives_ok(
  $$ update public.application_no_counter set next_seq = 1 $$,
  'a direct UPDATE is filtered out by RLS before it can touch a row'
);
select lives_ok(
  $$ update public.employee_code_counter set next_value = 1 $$,
  'and so is a direct rewind of the employee-code counter'
);
-- These two originally asserted the statement trigger's message, because
-- authenticated still held the TRUNCATE privilege and the trigger was the
-- only thing that could refuse. 20260731999100 revoked TRUNCATE from
-- authenticated schema-wide, so the refusal now happens a layer earlier,
-- on privilege. The trigger is still what refuses service_role, and that
-- is asserted in the service_role block below.
select throws_like(
  $$ truncate public.application_no_counter $$,
  '%permission denied%',
  'TRUNCATE, which no policy would ever have seen, is refused before any trigger is reached'
);
select throws_like(
  $$ truncate public.employee_code_counter cascade $$,
  '%permission denied%',
  'and so is TRUNCATE ... CASCADE'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Defect 2: the counters, attacked as service_role
-- ═══════════════════════════════════════════════════════════════════════

reset role;
set local role service_role;

select throws_ok(
  $$ truncate public.application_no_counter $$,
  '42501',
  'number counters cannot be truncated',
  'service_role keeps the TRUNCATE privilege by design, so the statement trigger is what refuses it'
);
select throws_ok(
  $$ truncate public.employee_code_counter cascade $$,
  '42501',
  'number counters cannot be truncated',
  'and it refuses TRUNCATE ... CASCADE the same way'
);
select throws_ok(
  format($$ update public.application_no_counter set next_seq = 1 where campus_id = %L $$, :'campus_a'),
  '42501',
  'application number counters are advanced only by fn_submit_application()',
  'rewinding application numbers — which would mint duplicates — is refused by the trigger, by name'
);
select throws_ok(
  format($$ update public.application_no_counter set next_seq = next_seq + 1 where campus_id = %L $$, :'campus_a'),
  '42501',
  'application number counters are advanced only by fn_submit_application()',
  'and so is an increment of exactly one that does not come from the allocator — the allow-list is a call-stack check, not a magic value'
);
select throws_ok(
  format($$ delete from public.application_no_counter where campus_id = %L $$, :'campus_a'),
  '42501',
  'application number counters are advanced only by fn_submit_application()',
  'and deleting the row, which would restart the series at one'
);
select throws_ok(
  format($$ insert into public.application_no_counter (campus_id, session_id, next_seq) values (%L, %L, 500) $$,
         :'campus_b', :'session_id'),
  '42501',
  'application number counters are advanced only by fn_submit_application()',
  'a series cannot be seeded part-way up, so it always begins at one'
);
select throws_ok(
  format($$ update public.employee_code_counter set next_value = 1 where campus_id = %L $$, :'campus_a'),
  '42501',
  'employee code counters are advanced only by app.fn_next_employee_code()',
  'rewinding employee codes — which payroll and provident-fund history reference for life — is refused the same way'
);
select throws_ok(
  format($$ delete from public.employee_code_counter where campus_id = %L $$, :'campus_a'),
  '42501',
  'employee code counters are advanced only by app.fn_next_employee_code()',
  'and so is deleting an employee-code counter row'
);
reset role;

-- A campus whose counters have been advanced can no longer be cascaded
-- away, the same posture FR-T02 already takes for certificate serials: no
-- application role holds a DELETE policy on campus to begin with, and
-- orphaning a live number series is worse than refusing the delete.
select throws_ok(
  format($$ delete from public.campus where id = %L $$, :'campus_a'),
  '42501',
  null,
  'the DELETE refusal covers an FK cascade from campus too'
);

select is(
  (select next_seq from public.application_no_counter where campus_id = :'campus_a'::uuid and session_id = :'session_id'::uuid),
  3,
  'after every attempt above, application_no_counter still reads what the allocator left'
);
select is(
  (select next_value from public.employee_code_counter where campus_id = :'campus_a'::uuid),
  3::bigint,
  'and so does employee_code_counter'
);

select * from finish();
rollback;
