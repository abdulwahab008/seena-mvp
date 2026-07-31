-- pgTAP tests for the Module E (Academic Setup) independent-review fixes
-- (20260731310000_module_e_review_fixes.sql).
--
-- The concurrency fixes (copy_class_subject_map's ON CONFLICT DO NOTHING,
-- create_section's unique_violation handler, assign_subject_teacher's
-- exclusion_violation handler, swap_class_level_ordinals' row locks)
-- can't be exercised as genuine races in a single-connection pgTAP
-- transaction — the same limitation already documented for every other
-- advisory-lock/race fix in this codebase (FR-K10, FR-K16,
-- module_k_accounting_review_fixes). Where a fix's OBSERVABLE behavior
-- (idempotent re-application, a specific named error) is testable
-- sequentially, it is tested below; the underlying lock/exception-handler
-- mechanics are verified by direct code review, not by this file.
begin;
select plan(23);

select public.provision_tenant('test-e-review-fix-co', 'E Review Fix Co', 'owner@ereviewfixco.test');
select id as tenant_id from public.tenant where slug = 'test-e-review-fix-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9_id from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select id as class10_id from public.class_level where tenant_id = :'tenant_id' and code = '10' \gset
select id as class11_id from public.class_level where tenant_id = :'tenant_id' and code = '11' \gset

select public.provision_tenant('test-e-review-fix-other-co', 'E Review Fix Other Co', 'owner@ereviewfixotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-e-review-fix-other-co' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset
select id as other_session_id from public.academic_session where tenant_id = :'other_tenant_id' \gset
select id as other_class9_id from public.class_level where tenant_id = :'other_tenant_id' and code = '9' \gset

select gen_random_uuid() as other_staff_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_staff_id', 'staff@ereviewfixotherco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_staff_id', :'other_tenant_id', 'class_teacher', 'Other Tenant Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'))::text,
  true
);
select public.create_subject('PHY', 'Physics', 'طبیعیات') as other_subject_id \gset
select public.create_stream('PREMED', 'Pre-Medical', null, 'FBISE', 0::smallint) as other_stream_id \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.create_subject('PHY', 'Physics', 'طبیعیات') as phy_id \gset

select gen_random_uuid() as own_staff_id \gset
reset role;
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'own_staff_id', 'teacher@ereviewfixco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'own_staff_id', :'tenant_id', 'class_teacher', 'Own Tenant Teacher');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── fix #1: copy_class_subject_map() tenant scoping + idempotent re-run ─

select throws_ok(
  format(
    $$ select public.copy_class_subject_map(%L, %L, %L, %L) $$,
    :'class9_id', :'class10_id', :'session_id', :'other_campus_id'
  ),
  'CAMPUS_NOT_FOUND',
  'AC: a foreign-tenant campus_id is refused, not silently read from/written into'
);
select throws_ok(
  format(
    $$ select public.copy_class_subject_map(%L, %L, %L, %L) $$,
    :'class9_id', :'class10_id', :'other_session_id', :'campus_id'
  ),
  'SESSION_NOT_FOUND',
  'AC: a foreign-tenant session_id is refused'
);
select throws_ok(
  format(
    $$ select public.copy_class_subject_map(%L, %L, %L, %L) $$,
    :'other_class9_id', :'class10_id', :'session_id', :'campus_id'
  ),
  'CLASS_LEVEL_NOT_FOUND',
  'AC: a foreign-tenant p_from_class_level_id is refused — the exact cross-tenant read the bug allowed'
);
select throws_ok(
  format(
    $$ select public.copy_class_subject_map(%L, %L, %L, %L) $$,
    :'class9_id', :'other_class9_id', :'session_id', :'campus_id'
  ),
  'CLASS_LEVEL_NOT_FOUND',
  'AC: a foreign-tenant p_to_class_level_id is refused — the exact cross-tenant write the bug allowed'
);

select public.upsert_class_subject(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class9_id', p_subject_id => :'phy_id', p_weekly_periods => 6::smallint);
select public.copy_class_subject_map(:'class9_id'::uuid, :'class10_id'::uuid, :'session_id'::uuid, :'campus_id'::uuid) as copy_result_1 \gset
select is(
  (:'copy_result_1')::jsonb,
  '{"created": 1, "skipped": 0}'::jsonb,
  'a same-tenant copy still works and reports 1 created'
);
select public.copy_class_subject_map(:'class9_id'::uuid, :'class10_id'::uuid, :'session_id'::uuid, :'campus_id'::uuid) as copy_result_2 \gset
select is(
  (:'copy_result_2')::jsonb,
  '{"created": 0, "skipped": 1}'::jsonb,
  'AC: re-running the same copy is idempotent (ON CONFLICT DO NOTHING) — proxy for the TOCTOU fix, since a concurrent duplicate would hit the same conflict path'
);

-- ── fix #2: create_section() tenant scoping ──────────────────────────────

select throws_ok(
  format(
    $$ select public.create_section(p_campus_id => %L, p_session_id => %L, p_class_level_id => %L, p_name => 'X', p_capacity => 30) $$,
    :'campus_id', :'other_session_id', :'class9_id'
  ),
  'SESSION_NOT_FOUND',
  'AC: create_section refuses a foreign-tenant session_id even when campus_id is genuinely the caller''s own'
);
select throws_ok(
  format(
    $$ select public.create_section(p_campus_id => %L, p_session_id => %L, p_class_level_id => %L, p_name => 'X', p_capacity => 30) $$,
    :'campus_id', :'session_id', :'other_class9_id'
  ),
  'CLASS_LEVEL_NOT_FOUND',
  'AC: create_section refuses a foreign-tenant class_level_id'
);

-- ── fix #3: upsert_class_subject() tenant scoping + upper-bound check ───

select throws_ok(
  format(
    $$ select public.upsert_class_subject(p_campus_id => %L, p_session_id => %L, p_class_level_id => %L, p_subject_id => %L, p_weekly_periods => 5::smallint) $$,
    :'campus_id', :'other_session_id', :'class9_id', :'phy_id'
  ),
  'SESSION_NOT_FOUND',
  'upsert_class_subject refuses a foreign-tenant session_id'
);
select throws_ok(
  format(
    $$ select public.upsert_class_subject(p_campus_id => %L, p_session_id => %L, p_class_level_id => %L, p_subject_id => %L, p_weekly_periods => 5::smallint) $$,
    :'campus_id', :'session_id', :'other_class9_id', :'phy_id'
  ),
  'CLASS_LEVEL_NOT_FOUND',
  'upsert_class_subject refuses a foreign-tenant class_level_id'
);
select throws_ok(
  format(
    $$ select public.upsert_class_subject(p_campus_id => %L, p_session_id => %L, p_class_level_id => %L, p_subject_id => %L, p_weekly_periods => 5::smallint) $$,
    :'campus_id', :'session_id', :'class9_id', :'other_subject_id'
  ),
  'SUBJECT_NOT_FOUND',
  'upsert_class_subject refuses a foreign-tenant subject_id — the row would otherwise dangle-reference a subject the caller''s tenant can''t even see'
);
select throws_ok(
  format(
    $$ select public.upsert_class_subject(p_campus_id => %L, p_session_id => %L, p_class_level_id => %L, p_subject_id => %L, p_weekly_periods => 5::smallint, p_stream_id => %L) $$,
    :'campus_id', :'session_id', :'class9_id', :'phy_id', :'other_stream_id'
  ),
  'STREAM_NOT_FOUND',
  'upsert_class_subject refuses a foreign-tenant stream_id'
);
select throws_ok(
  format(
    $$ select public.upsert_class_subject(p_campus_id => %L, p_session_id => %L, p_class_level_id => %L, p_subject_id => %L, p_weekly_periods => 13::smallint) $$,
    :'campus_id', :'session_id', :'class11_id', :'phy_id'
  ),
  'WEEKLY_PERIODS_OUT_OF_RANGE',
  'AC: 13 weekly periods (over the 12-period ceiling) is refused with the function''s own named error, not a raw constraint-violation message'
);

-- ── fix #4/5: assign_class_teacher() / assign_subject_teacher() staff and
--    subject tenant scoping, plus the assistant-role duplicate gap ──────

select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class9_id', p_name => 'A', p_capacity => 40) as section_id \gset

select throws_ok(
  format('select public.assign_class_teacher(%L, %L, %L::date)', :'section_id', :'other_staff_id', '2026-08-01'),
  'STAFF_NOT_FOUND',
  'AC: assign_class_teacher refuses a foreign-tenant staff_id — no employment relationship to this tenant exists'
);

select throws_ok(
  format('select public.assign_subject_teacher(%L, %L, %L, %L::date)', :'section_id', :'other_subject_id', :'own_staff_id', '2026-08-01'),
  'SUBJECT_NOT_FOUND',
  'assign_subject_teacher refuses a foreign-tenant subject_id'
);
select throws_ok(
  format('select public.assign_subject_teacher(%L, %L, %L, %L::date)', :'section_id', :'phy_id', :'other_staff_id', '2026-08-01'),
  'STAFF_NOT_FOUND',
  'assign_subject_teacher refuses a foreign-tenant staff_id'
);

select public.assign_subject_teacher(:'section_id'::uuid, :'phy_id'::uuid, :'own_staff_id'::uuid, '2026-08-01'::date, 'assistant') as assistant_alloc_1 \gset
select throws_ok(
  format(
    $$ select public.assign_subject_teacher(%L, %L, %L, '2026-08-01'::date, 'assistant') $$,
    :'section_id', :'phy_id', :'own_staff_id'
  ),
  'SUBJECT_TEACHER_ALREADY_ACTIVE',
  'AC: assigning the SAME staff as assistant twice for the same section+subject+date is refused, not silently duplicated'
);
select lives_ok(
  format(
    $$ select public.assign_subject_teacher(%L, %L, %L, '2026-09-01'::date, 'assistant') $$,
    :'section_id', :'phy_id', :'own_staff_id'
  ),
  'AC: re-assigning the same staff as assistant from a LATER date succeeds — this is a legitimate re-assignment, not a duplicate'
);
select is(
  (select effective_to from public.section_subject_teacher where id = (:'assistant_alloc_1')::uuid),
  '2026-08-31'::date,
  'the later re-assignment auto-closed the first assistant row the day before, mirroring the primary role''s own behavior'
);

-- ── fix #6: set_section_stream() tenant scoping ──────────────────────────

select throws_ok(
  format('select public.set_section_stream(%L, %L)', :'section_id', :'other_stream_id'),
  'STREAM_NOT_FOUND',
  'AC: set_section_stream refuses a foreign-tenant stream_id'
);

-- ── fix #7/#8: delete_stream() / delete_class_level() in-use checks are
--    tenant-scoped, not global, AND never leak a raw FK-violation ───────
--
-- A foreign tenant's dangling reference (only reachable via direct DB
-- access now that fixes #2/#3/#6 close the app-level path that used to
-- create one) still physically holds the row via a real FK with no ON
-- DELETE clause — the DELETE itself cannot succeed either way. What the
-- fix actually changes: the caller's own tenant is never falsely told
-- "your data is using this" (the exists-check no longer matches a
-- foreign tenant's row), and the DELETE's own FK failure is caught and
-- re-raised as the function's clean, named error instead of leaking a
-- raw "violates foreign key constraint ..." message.

select public.create_stream('OWNSTR', 'Own Stream', null, 'FBISE', 0::smallint) as own_stream_id \gset

reset role;
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity, stream_id)
values (:'other_tenant_id', :'other_campus_id', :'other_session_id', :'other_class9_id', 'DANGLING-STREAM-REF', 40, :'own_stream_id');
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
values (:'other_tenant_id', :'other_campus_id', :'other_session_id', :'class11_id', 'DANGLING-CLASSLEVEL-REF', 40);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select throws_ok(
  format('select public.delete_stream(%L)', :'own_stream_id'),
  'STREAM_IN_USE',
  'AC: a foreign tenant''s dangling reference still blocks deletion (the FK is real) but surfaces the clean named error, not a raw constraint-violation message'
);
select throws_ok(
  format('select public.delete_class_level(%L)', :'class11_id'),
  'CLASS_LEVEL_IN_USE',
  'AC: same for delete_class_level — a raw FK-violation never leaks past the function'
);

-- ── fix #9: create_subject() alternate_of_subject_id tenant scoping ─────

select throws_ok(
  format($$ select public.create_subject('ISL', 'Islamiyat', 'اسلامیات', 'CORE', true, null, %L) $$, :'other_subject_id'),
  'ALTERNATE_SUBJECT_NOT_FOUND',
  'AC: create_subject refuses a foreign-tenant p_alternate_of_subject_id'
);

select * from finish();
rollback;
