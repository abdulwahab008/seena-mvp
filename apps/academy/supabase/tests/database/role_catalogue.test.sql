-- pgTAP tests for FR-A10: role/permission catalogue, seed_tenant_roles,
-- has_permission, and the system-role-immutability trigger.
begin;
select plan(10);

-- ── templates ──────────────────────────────────────────────────────────

select is(
  (select count(*)::int from public.role where tenant_id is null and is_system),
  (select count(*)::int from unnest(enum_range(null::public.app_role))),
  'exactly one global template role exists per app_role enum value'
);

-- ── seeding via provision_tenant ──────────────────────────────────────────

select public.provision_tenant('test-roles-co', 'Roles Co', 'owner@rolesco.test');
select id as tenant_id from public.tenant where slug = 'test-roles-co' \gset

select is(
  (select count(*)::int from public.role where tenant_id = :'tenant_id' and is_system),
  (select count(*)::int from unnest(enum_range(null::public.app_role))),
  'provisioning a tenant seeds one system role per app_role value'
);

-- ── system role immutability ──────────────────────────────────────────────

select id as owner_role_id from public.role where tenant_id = :'tenant_id' and code = 'owner' \gset

select throws_ok(
  format('delete from public.role where id = %L', :'owner_role_id'),
  'ROLE_IMMUTABLE',
  'deleting a system role is rejected'
);
select throws_ok(
  format($$ update public.role set code = 'not-owner' where id = %L $$, :'owner_role_id'),
  'ROLE_IMMUTABLE',
  'renaming a system role''s code is rejected'
);
select lives_ok(
  format($$ update public.role set name = 'Owner (renamed)' where id = %L $$, :'owner_role_id'),
  'updating a non-immutable field (name) on a system role is allowed'
);

-- ── granting a new permission across all existing tenants in one statement ─

insert into public.permission (code, module, label) values ('fee.waiver.approve', 'fees', 'Approve fee waiver');
insert into public.role_permission (role_id, permission_code)
select id, 'fee.waiver.approve' from public.role where code in ('owner', 'accountant') and tenant_id is not null;

select is(
  (select count(*)::int from public.role_permission where permission_code = 'fee.waiver.approve'),
  (select count(*)::int from public.role where code in ('owner', 'accountant') and tenant_id is not null),
  'the new permission is granted to owner+accountant in every tenant, one row per role'
);
select is(
  (select count(*)::int from public.role_permission rp
     join public.role r on r.id = rp.role_id
    where rp.permission_code = 'fee.waiver.approve' and r.code not in ('owner', 'accountant')),
  0,
  'no other role code received the new permission'
);

-- ── has_permission() reads the JWT role_id claim ──────────────────────────

-- role_permission's RLS is tenant-scoped, so tenant_id must ride along with
-- role_id in the claims here exactly as the real hook always issues them
-- together.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'role_id', :'owner_role_id')::text, true);
select is(app.has_permission('fee.waiver.approve'), true, 'has_permission is true for a role that was granted the code');
select is(app.has_permission('not.a.real.permission'), false, 'has_permission is false for a code the role was never granted');

select id as teacher_role_id from public.role where tenant_id = :'tenant_id' and code = 'subject_teacher' \gset
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'role_id', :'teacher_role_id')::text, true);
select is(app.has_permission('fee.waiver.approve'), false, 'has_permission is false for a different role that was not granted the code');

select * from finish();
rollback;
