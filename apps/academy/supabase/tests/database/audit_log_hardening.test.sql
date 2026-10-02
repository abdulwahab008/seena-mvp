-- pgTAP tests for FR-A14: trigger-based capture, redaction, hard write
-- denial, and tenant-scoped read RLS on the now-partitioned audit_log.
begin;
select plan(9);

select public.provision_tenant('test-audit-co', 'Audit Co', 'owner@auditco.test');
select id as tenant_id from public.tenant where slug = 'test-audit-co' \gset

-- provision_tenant both inserts the tenant row and later flips its status to
-- 'active', so two audit rows exist for it; scope to the insert to get one.
select is(
  (select tenant_id::text from public.audit_log
    where table_name = 'tenant' and row_id = :'tenant_id'::uuid and action = 'insert'),
  :'tenant_id',
  'a tenant row''s own audit entry is scoped to its own id (no tenant_id column to fall back on)'
);

select is(
  (select after ->> 'token' from public.audit_log where table_name = 'tenant_invitation' and tenant_id = :'tenant_id'::uuid),
  '[redacted]',
  'tenant_invitation.token is redacted in the audit trail rather than the real bearer token'
);

-- ── update capture: changed_columns / before / after ──────────────────────

insert into auth.users (id, email) values (gen_random_uuid(), 'staff@auditco.test');
select id as user_id from auth.users where email = 'staff@auditco.test' \gset
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'user_id', :'tenant_id', 'subject_teacher', 'Staff One');

update public.app_user set full_name = 'Staff One Renamed' where user_id = :'user_id';

select is(
  (select changed_columns from public.audit_log
    where table_name = 'app_user' and row_id = :'user_id'::uuid and action = 'update'),
  array['full_name'],
  'updating full_name produces an audit row with exactly that column in changed_columns'
);
select is(
  (select before ->> 'full_name' from public.audit_log
    where table_name = 'app_user' and row_id = :'user_id'::uuid and action = 'update'),
  'Staff One',
  'before captures the pre-update value'
);
select is(
  (select after ->> 'full_name' from public.audit_log
    where table_name = 'app_user' and row_id = :'user_id'::uuid and action = 'update'),
  'Staff One Renamed',
  'after captures the post-update value'
);

-- ── hard write denial + tenant-scoped read RLS ────────────────────────────

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);

select throws_like(
  $$ delete from public.audit_log $$,
  '%permission denied%',
  'an authenticated user cannot delete audit_log rows, even their own tenant''s'
);
select throws_like(
  $$ update public.audit_log set action = 'insert' $$,
  '%permission denied%',
  'an authenticated user cannot update audit_log rows either'
);

select ok(
  (select count(*) from public.audit_log where tenant_id = :'tenant_id') > 0,
  'an owner can read their own tenant''s audit rows'
);

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher')::text, true);
select is(
  (select count(*)::int from public.audit_log where tenant_id = :'tenant_id'),
  0,
  'a subject_teacher (not owner/principal/super_admin) sees zero audit rows via RLS'
);

select * from finish();
rollback;
