-- pgTAP tests: nobody can hand out a role above their own, or lock a superior out.
--
-- invite_user() checked who the caller was and never what role was being granted, so a
-- Principal could invite an Owner (or a platform Super Admin) and accept the invitation.
-- assign_custom_role() let a Principal put a near-empty custom role on the Owner, who could
-- not clear it because clearing needs the permission that was just removed.
begin;
select plan(23);

select public.provision_tenant('test-role-ceiling', 'Role Ceiling School', 'owner@ceiling.test');
select id as tenant_id from public.tenant where slug = 'test-role-ceiling' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as owner_role_id       from public.role where tenant_id = :'tenant_id' and code = 'owner' \gset
select id as principal_role_id   from public.role where tenant_id = :'tenant_id' and code = 'principal' \gset
select id as super_admin_role_id from public.role where tenant_id = :'tenant_id' and code = 'super_admin' \gset
select id as hr_role_id          from public.role where tenant_id = :'tenant_id' and code = 'hr_manager' \gset

reset role;
select gen_random_uuid() as owner_user \gset
select gen_random_uuid() as principal_user \gset
select gen_random_uuid() as teacher_user \gset
select gen_random_uuid() as admin_user \gset
select gen_random_uuid() as hr_user \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role) values
  (:'owner_user',     'owner@ceiling.test',     'x', now(), 'authenticated', 'authenticated'),
  (:'principal_user', 'principal@ceiling.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'teacher_user',   'teacher@ceiling.test',   'x', now(), 'authenticated', 'authenticated'),
  (:'admin_user',     'admin@ceiling.test',     'x', now(), 'authenticated', 'authenticated'),
  (:'hr_user',        'hr@ceiling.test',        'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_user'::uuid,     :'tenant_id'::uuid, 'owner',           'Owner'),
  (:'principal_user'::uuid, :'tenant_id'::uuid, 'principal',       'Principal'),
  (:'teacher_user'::uuid,   :'tenant_id'::uuid, 'subject_teacher', 'Teacher'),
  (:'admin_user'::uuid,     :'tenant_id'::uuid, 'super_admin',     'Platform Admin'),
  (:'hr_user'::uuid,        :'tenant_id'::uuid, 'hr_manager',      'HR');

-- ── A Principal ──────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'role_id', :'principal_role_id',
  'campus_ids', json_build_array(:'campus_id'), 'sub', :'principal_user')::text, true);
set local role authenticated;

select throws_like(
  format('select public.invite_user(%L, %L, %L::uuid[])', 'new-owner@ceiling.test', 'owner', '{}'),
  '%FORBIDDEN%',
  'a principal cannot invite an owner'
);
select throws_like(
  format('select public.invite_user(%L, %L, %L::uuid[])', 'new-admin@ceiling.test', 'super_admin', '{}'),
  '%FORBIDDEN%',
  'a principal cannot invite a super admin'
);
select throws_like(
  format('select public.invite_user(%L, %L, %L::uuid[])', 'a-parent@ceiling.test', 'parent', '{}'),
  '%FORBIDDEN%',
  'a principal cannot invite a parent as staff'
);
select lives_ok(
  format('select public.invite_user(%L, %L, %L::uuid[])', 'new-accountant@ceiling.test', 'accountant', '{}'),
  'a principal can still invite an accountant'
);
select lives_ok(
  format('select public.invite_user(%L, %L, %L::uuid[])', 'second-principal@ceiling.test', 'principal', '{}'),
  'and a second principal'
);
select is(
  (select count(*)::int from public.tenant_invitation where tenant_id = :'tenant_id'::uuid
    and email in ('new-owner@ceiling.test', 'new-admin@ceiling.test', 'a-parent@ceiling.test')),
  0,
  'the refused invitations were not stored'
);

-- A custom role is a narrowing, so it can only go on someone ranked below the person assigning it.
select public.create_custom_role('Front Desk Lite', array['student.read']) as lite_role \gset
select throws_like(
  format('select public.assign_custom_role(%L::uuid, %L::uuid)', :'owner_user', :'lite_role'),
  '%FORBIDDEN%',
  'a principal cannot put a custom role on the owner'
);
select throws_like(
  format('select public.assign_custom_role(%L::uuid, %L::uuid)', :'admin_user', :'lite_role'),
  '%FORBIDDEN%',
  'nor on a super admin'
);
select throws_like(
  format('select public.assign_custom_role(%L::uuid, %L::uuid)', :'principal_user', :'lite_role'),
  '%FORBIDDEN%',
  'nor on themselves'
);
select lives_ok(
  format('select public.assign_custom_role(%L::uuid, %L::uuid)', :'teacher_user', :'lite_role'),
  'a principal can assign it to a teacher'
);
select lives_ok(
  format('select public.assign_custom_role(%L::uuid, NULL)', :'teacher_user'),
  'and clear it again'
);

-- The tables behind the role functions are not open to direct writes.
select throws_ok(
  format('insert into public.role_permission (role_id, permission_code) values (%L::uuid, %L)', :'lite_role', 'fee.collect'),
  '42501',
  null,
  'a principal cannot add a permission to a role by writing the table directly'
);
select throws_ok(
  format('insert into public.role (tenant_id, code, name, is_system) values (%L::uuid, %L, %L, false)', :'tenant_id', 'sneaky', 'Sneaky'),
  '42501',
  null,
  'nor create a role by writing the table directly'
);
reset role;

-- ── The Owner ────────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'role_id', :'owner_role_id',
  'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user')::text, true);
set local role authenticated;

select throws_like(
  format('select public.invite_user(%L, %L, %L::uuid[])', 'platform@ceiling.test', 'super_admin', '{}'),
  '%FORBIDDEN%',
  'an owner cannot invite a super admin'
);
select lives_ok(
  format('select public.invite_user(%L, %L, %L::uuid[])', 'co-owner@ceiling.test', 'owner', '{}'),
  'an owner can invite a second owner'
);
select lives_ok(
  format('select public.assign_custom_role(%L::uuid, %L::uuid)', :'principal_user', :'lite_role'),
  'an owner can narrow a principal with a custom role'
);
select throws_like(
  format('select public.assign_custom_role(%L::uuid, %L::uuid)', :'admin_user', :'lite_role'),
  '%FORBIDDEN%',
  'but not a super admin'
);
reset role;

-- ── A Super Admin ────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'super_admin', 'role_id', :'super_admin_role_id',
  'campus_ids', json_build_array(:'campus_id'), 'sub', :'admin_user')::text, true);
set local role authenticated;
select lives_ok(
  format('select public.invite_user(%L, %L, %L::uuid[])', 'another-admin@ceiling.test', 'super_admin', '{}'),
  'a super admin can invite any staff role'
);
select throws_like(
  format('select public.invite_user(%L, %L, %L::uuid[])', 'a-student@ceiling.test', 'student', '{}'),
  '%FORBIDDEN%',
  'but never a student account'
);
select lives_ok(
  format('select public.assign_custom_role(%L::uuid, NULL)', :'principal_user'),
  'a super admin can clear a custom role from anyone'
);
reset role;

-- ── Others still cannot invite at all ────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'role_id', :'hr_role_id',
  'campus_ids', json_build_array(:'campus_id'), 'sub', :'hr_user')::text, true);
set local role authenticated;
select throws_like(
  format('select public.invite_user(%L, %L, %L::uuid[])', 'hr-picked@ceiling.test', 'subject_teacher', '{}'),
  '%FORBIDDEN%',
  'an HR manager still cannot send invitations through invite_user'
);
reset role;

-- ── accept_invitation refuses a parent/student invitation even if one was written directly ──
insert into public.tenant_invitation (tenant_id, email, app_role, campus_ids)
values (:'tenant_id'::uuid, 'planted@ceiling.test', 'owner'::public.app_role, '{}') returning token as owner_token \gset
select gen_random_uuid() as planted_user \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'planted_user', 'planted@ceiling.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.tenant_invitation (tenant_id, email, app_role, campus_ids)
values (:'tenant_id'::uuid, 'planted@ceiling.test', 'parent'::public.app_role, '{}') returning token as parent_token \gset
delete from public.tenant_invitation where token = :'owner_token';
select set_config('request.jwt.claims', json_build_object('sub', :'planted_user', 'role', 'authenticated')::text, true);
set local role authenticated;
select throws_like(
  format('select public.accept_invitation(%L)', :'parent_token'),
  '%INVITE_ROLE_INVALID%',
  'an invitation carrying the parent role cannot be accepted'
);
reset role;
select is(
  (select count(*)::int from public.app_user where user_id = :'planted_user'::uuid),
  0,
  'and no app_user row was created for it'
);

select * from finish();
rollback;
