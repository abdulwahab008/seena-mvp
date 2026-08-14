-- pgTAP tests for FR-A11: custom role creation.
--
-- The four acceptance criteria, plus the two things the FR's Notes call out
-- as the places this goes wrong: the superset assertion must hold against a
-- direct call (not just a filtered picker), and a permission removal must
-- reach an already-signed-in holder without them logging out.
--
-- Also asserted here, because it is the honest boundary of the feature in
-- this schema: a custom role is intersected with the holder's base app_role,
-- so it can narrow what the enum-gated policies already allow but can never
-- widen it.
begin;
select plan(41);

-- ── fixtures (superuser, before any `set local role authenticated`) ──────

select public.provision_tenant('test-customrole-co', 'Custom Role Co', 'owner@customrole.test');
select public.provision_tenant('test-otherrole-co', 'Other Role Co', 'owner@otherrole.test');
select id as tenant_id from public.tenant where slug = 'test-customrole-co' \gset
select id as tenant_b_id from public.tenant where slug = 'test-otherrole-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

select id as owner_role_id     from public.role where tenant_id = :'tenant_id' and code = 'owner' \gset
select id as principal_role_id from public.role where tenant_id = :'tenant_id' and code = 'principal' \gset
select id as teacher_role_id   from public.role where tenant_id = :'tenant_id' and code = 'subject_teacher' \gset
select id as b_owner_role_id   from public.role where tenant_id = :'tenant_b_id' and code = 'owner' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as principal_uid \gset
select gen_random_uuid() as teacher_uid \gset
select gen_random_uuid() as b_owner_uid \gset

insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role) values
  (:'owner_uid',     'o@customrole.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'principal_uid', 'p@customrole.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'teacher_uid',   't@customrole.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'b_owner_uid',   'o@otherrole.test',  'x', now(), 'authenticated', 'authenticated');

insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid',     :'tenant_id',   'owner',           'A Owner'),
  (:'principal_uid', :'tenant_id',   'principal',       'A Principal'),
  (:'teacher_uid',   :'tenant_id',   'subject_teacher', 'A Teacher'),
  (:'b_owner_uid',   :'tenant_b_id', 'owner',           'B Owner');

insert into public.user_campus (user_id, tenant_id, campus_id)
values (:'teacher_uid', :'tenant_id', :'campus_id');

-- Seven holders for AC2's "held by 7 users".
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
select gen_random_uuid(), 'holder' || i || '@customrole.test', 'x', now(), 'authenticated', 'authenticated'
  from generate_series(1, 7) i;
insert into public.app_user (user_id, tenant_id, app_role, full_name)
select id, :'tenant_id', 'subject_teacher', 'Holder ' || email
  from auth.users where email like 'holder%@customrole.test';

-- Error-shape probe: throws_ok only sees the message, and AC2 requires the
-- failure to *list* the holder count, which travels in DETAIL.
create function pg_temp.probe(p_sql text)
returns text
language plpgsql
as $$
declare v_detail text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics v_detail = pg_exception_detail;
  return sqlerrm || '|' || coalesce(v_detail, '');
end;
$$;

-- ── the published catalogue (FR-A10 left public.permission empty) ────────

select cmp_ok(
  (select count(*)::int from public.permission), '>=', 30,
  'the permission catalogue is published, not empty'
);
select is(
  (select count(*)::int from public.role_permission rp
     join public.role r on r.id = rp.role_id
    where r.tenant_id = :'tenant_id' and r.code = 'owner'
      and rp.permission_code = 'tenant.billing.manage'),
  1,
  'the owner system role holds tenant.billing.manage'
);
select is(
  (select count(*)::int from public.role_permission rp
     join public.role r on r.id = rp.role_id
    where r.tenant_id = :'tenant_id' and r.code = 'principal'
      and rp.permission_code = 'tenant.billing.manage'),
  0,
  'the principal system role does not hold tenant.billing.manage (AC1 premise)'
);

-- ── AC1: a Principal cannot grant a permission they do not hold ─────────

set local role authenticated;
select set_config('request.jwt.claims', json_build_object(
  'sub', :'principal_uid', 'tenant_id', :'tenant_id',
  'app_role', 'principal', 'role_id', :'principal_role_id')::text, true);

select is(app.has_permission('role.manage'), true, 'a Principal holds role.manage');
select is(
  app.has_permission('tenant.billing.manage'), false,
  'a Principal does not hold tenant.billing.manage'
);

select throws_ok(
  $$ select public.create_custom_role('Coordinator', array['student.read', 'tenant.billing.manage']) $$,
  '42501', 'PERMISSION_ESCALATION',
  'AC1: a direct call granting a permission the caller lacks is refused, not merely hidden in the picker'
);
select is(
  pg_temp.probe($$ select public.create_custom_role('Coordinator', array['student.read', 'tenant.billing.manage']) $$),
  'PERMISSION_ESCALATION|tenant.billing.manage',
  'AC1: the refusal names the offending permission'
);
select is(
  (select count(*)::int from public.role where tenant_id = :'tenant_id' and lower(code) = 'coordinator'),
  0,
  'AC1: the refused role was not created'
);

-- The same call, minus the permission the caller lacks, is allowed.
select public.create_custom_role(
  'Coordinator',
  array['student.read', 'student.delete', 'attendance.read', 'exam.read']
) as coord_role_id \gset

select is(
  (select is_system from public.role where id = :'coord_role_id'), false,
  'a created custom role is not a system role'
);
select is(
  (select tenant_id from public.role where id = :'coord_role_id'), :'tenant_id'::uuid,
  'a created custom role belongs to the creating tenant'
);
select is(
  (select action from public.role_change_log where role_id = :'coord_role_id'), 'create',
  'creation is written to role_change_log'
);

-- ── input validation ────────────────────────────────────────────────────

select throws_ok(
  $$ select public.create_custom_role('Bad', array['not.a.real.permission']) $$,
  '23503', 'PERMISSION_UNKNOWN',
  'a permission code outside the catalogue is refused'
);
select throws_ok(
  $$ select public.create_custom_role('Principal', array['student.read']) $$,
  '23505', 'ROLE_CODE_RESERVED',
  'a custom role may not take an app_role enum value as its code'
);
select throws_ok(
  $$ select public.create_custom_role('coordinator', array['student.read']) $$,
  '23505', 'ROLE_CODE_TAKEN',
  'role codes are unique per tenant, case-insensitively'
);

-- ── AC4: custom roles do not leak across tenants ────────────────────────

select set_config('request.jwt.claims', json_build_object(
  'sub', :'b_owner_uid', 'tenant_id', :'tenant_b_id',
  'app_role', 'owner', 'role_id', :'b_owner_role_id')::text, true);

select is(
  (select count(*)::int from public.role where lower(code) = 'coordinator'), 0,
  'AC4: tenant B does not see tenant A''s Coordinator'
);
select is(
  (select count(*)::int from public.role_change_log), 0,
  'AC4: tenant B does not see tenant A''s role change log'
);

-- ── RLS: writing a role requires role.manage ────────────────────────────

select set_config('request.jwt.claims', json_build_object(
  'sub', :'teacher_uid', 'tenant_id', :'tenant_id',
  'app_role', 'subject_teacher', 'role_id', :'teacher_role_id')::text, true);

select is(app.has_permission('role.manage'), false, 'a Subject Teacher does not hold role.manage');
select throws_ok(
  format($$ insert into public.role (tenant_id, code, name) values (%L, 'sneak', 'Sneak') $$, :'tenant_id'),
  '42501', null,
  'role_write_requires_role_manage blocks a direct insert by a caller without role.manage'
);
select throws_ok(
  format($$ insert into public.role_permission (role_id, permission_code) values (%L, 'fee.collect') $$, :'coord_role_id'),
  '42501', null,
  'role_permission writes are blocked for a caller without role.manage'
);
select throws_ok(
  $$ select public.create_custom_role('Sneak', array['student.read']) $$,
  '42501', 'FORBIDDEN',
  'create_custom_role refuses a caller without role.manage'
);

-- ── assignment: claims epoch, the JWT hook, and the base-role ceiling ────

set local role postgres;
select claims_version as teacher_cv_before from public.app_user where user_id = :'teacher_uid' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object(
  'sub', :'principal_uid', 'tenant_id', :'tenant_id',
  'app_role', 'principal', 'role_id', :'principal_role_id')::text, true);
select lives_ok(
  format($$ select public.assign_custom_role(%L, %L) $$, :'teacher_uid', :'coord_role_id'),
  'a role manager can assign a custom role'
);

set local role postgres;
select is(
  (select claims_version from public.app_user where user_id = :'teacher_uid'),
  :'teacher_cv_before'::int + 1,
  'assigning a custom role bumps claims_version (FR-A13 epoch), so the stale role_id claim is rejected'
);
select is(
  (select app_role::text from public.app_user where user_id = :'teacher_uid'), 'subject_teacher',
  'assigning a custom role leaves the base app_role — the enum gates are untouched'
);

select public.custom_access_token_hook(
  jsonb_build_object('user_id', :'teacher_uid', 'claims', '{}'::jsonb)
) as hook_custom \gset
select is(
  ((:'hook_custom')::jsonb -> 'claims' ->> 'role_id')::uuid, :'coord_role_id'::uuid,
  'the JWT hook stamps the assigned custom role as role_id'
);
select is(
  (:'hook_custom')::jsonb -> 'claims' ->> 'app_role', 'subject_teacher',
  'the JWT hook still stamps the base app_role alongside it'
);

-- The holder's live claim set, as the hook would issue it.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object(
  'sub', :'teacher_uid', 'tenant_id', :'tenant_id',
  'app_role', 'subject_teacher', 'role_id', :'coord_role_id')::text, true);

select is(
  app.has_permission('student.read'), true,
  'a custom role grants a permission its holder''s base app_role also has'
);
select is(
  app.has_permission('student.delete'), false,
  'a custom role cannot widen: subject_teacher has no student.delete, so the bundle''s copy is inert'
);

-- ── AC3: removing a permission reaches a signed-in holder immediately ────
-- Give the same bundle to a holder whose base role does hold student.delete,
-- so the removal is observable rather than masked by the ceiling above.

set local role authenticated;
select set_config('request.jwt.claims', json_build_object(
  'sub', :'principal_uid', 'tenant_id', :'tenant_id',
  'app_role', 'principal', 'role_id', :'coord_role_id')::text, true);

select is(
  app.has_permission('student.delete'), true,
  'AC3 premise: the holder has student.delete through the custom role'
);

select set_config('request.jwt.claims', json_build_object(
  'sub', :'principal_uid', 'tenant_id', :'tenant_id',
  'app_role', 'principal', 'role_id', :'principal_role_id')::text, true);
select lives_ok(
  format(
    $$ select public.update_custom_role(%L, 'Coordinator', array['student.read', 'attendance.read', 'exam.read']) $$,
    :'coord_role_id'
  ),
  'a role manager can edit a custom role''s permissions'
);

-- Same session, same token, no re-login: the permission list is never a
-- claim, so has_permission() sees the removal on the very next statement.
select set_config('request.jwt.claims', json_build_object(
  'sub', :'principal_uid', 'tenant_id', :'tenant_id',
  'app_role', 'principal', 'role_id', :'coord_role_id')::text, true);
select is(
  app.has_permission('student.delete'), false,
  'AC3: the removed permission is gone on the holder''s next request, without logging out'
);

set local role postgres;
select is(
  (select removed from public.role_change_log
    where role_id = :'coord_role_id' and action = 'update'),
  '["student.delete"]'::jsonb,
  'AC3: the removal is recorded in role_change_log'
);

-- ── AC2: deletion blocked while held, then bulk reassignment ────────────

update public.app_user
   set custom_role_id = :'coord_role_id'
 where user_id in (select id from auth.users where email like 'holder%@customrole.test');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object(
  'sub', :'principal_uid', 'tenant_id', :'tenant_id',
  'app_role', 'principal', 'role_id', :'principal_role_id')::text, true);

select is(
  public.custom_role_holder_count(:'coord_role_id'), 8,
  'the holder count sees all holders (7 fixtures plus the teacher assigned earlier)'
);

-- Put it at exactly the AC's 7 by clearing the teacher.
select public.assign_custom_role(:'teacher_uid', null);
select is(public.custom_role_holder_count(:'coord_role_id'), 7, 'AC2 premise: the role is held by 7 users');

select throws_ok(
  format($$ select public.delete_custom_role(%L) $$, :'coord_role_id'),
  '42501', 'ROLE_IN_USE',
  'AC2: deleting a held custom role is refused'
);
select is(
  pg_temp.probe(format($$ select public.delete_custom_role(%L) $$, :'coord_role_id')),
  'ROLE_IN_USE|7',
  'AC2: the refusal lists the 7 holders'
);

select is(
  public.reassign_role_holders(:'coord_role_id', null), 7,
  'AC2: bulk reassignment moves all 7 holders off the role'
);
select lives_ok(
  format($$ select public.delete_custom_role(%L) $$, :'coord_role_id'),
  'AC2: deletion succeeds once nobody holds the role'
);

set local role postgres;
select isnt(
  (select deleted_at from public.role where id = :'coord_role_id'), null,
  'deletion is a soft delete — the role row and its change log survive'
);

set local role authenticated;
select lives_ok(
  $$ select public.create_custom_role('Coordinator', array['student.read']) $$,
  'the name frees up after deletion (role_code_uniq ignores soft-deleted rows)'
);
select id as coord2_role_id from public.role
 where tenant_id = :'tenant_id' and lower(code) = 'coordinator' and deleted_at is null \gset

-- ── escalation via assignment, not just creation ────────────────────────

set local role postgres;
insert into public.role (tenant_id, code, name, is_system) values (:'tenant_id', 'bursar', 'Bursar', false)
returning id as bursar_role_id \gset
insert into public.role_permission (role_id, permission_code)
values (:'bursar_role_id', 'tenant.billing.manage'), (:'bursar_role_id', 'student.read');

set local role authenticated;
select throws_ok(
  format($$ select public.assign_custom_role(%L, %L) $$, :'teacher_uid', :'bursar_role_id'),
  '42501', 'PERMISSION_ESCALATION',
  'a Principal cannot assign a role richer than themselves'
);
select throws_ok(
  format($$ select public.reassign_role_holders(%L, %L) $$, :'coord2_role_id', :'bursar_role_id'),
  '42501', 'PERMISSION_ESCALATION',
  'a Principal cannot bulk-move holders onto a role richer than themselves'
);

select * from finish();
rollback;
