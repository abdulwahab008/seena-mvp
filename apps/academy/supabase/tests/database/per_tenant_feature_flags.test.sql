-- pgTAP tests for FR-A17: per-tenant feature flags.
--
-- Covers the four database-side acceptance criteria: plan-default resolution
-- with no override (AC1), a Super Admin toggle taking effect with no redeploy
-- and no re-login (AC2), a direct call to a disabled module refused with
-- FEATURE_DISABLED and no row written (AC3), and data surviving a disable and
-- reappearing on re-enable (AC4).
--
-- AC5 ("the flag service is unreachable → last-known-good cached set, and the
-- failure is logged") has no database half: the flags ARE the database, so
-- there is no separate service to be unreachable. Its cache-and-log behaviour
-- lives in the app's resolver and is covered by lib/features.test.ts.
--
-- The gated module used throughout is Expenses, because expense_head is
-- tenant-scoped, is seeded at provisioning (so AC4 has pre-existing data to
-- retain), and is written through a SECURITY DEFINER RPC — which is exactly
-- the path an RLS-only gate would leave open.
begin;
select plan(30);

-- ── fixtures ────────────────────────────────────────────────────────────

select public.provision_tenant('test-flags-co', 'Flags Co', 'owner@flags.test');
select public.provision_tenant('test-flags-b-co', 'Flags B Co', 'owner@flagsb.test');
select id as tenant_id from public.tenant where slug = 'test-flags-co' \gset
select id as tenant_b_id from public.tenant where slug = 'test-flags-b-co' \gset

select gen_random_uuid() as super_uid \gset
select gen_random_uuid() as owner_uid \gset

insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role) values
  (:'super_uid', 'super@flags.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'owner_uid', 'o@flags.test',     'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'super_uid', :'tenant_id', 'super_admin', 'Platform Admin'),
  (:'owner_uid', :'tenant_id', 'owner',       'Flags Owner');

select public.seed_default_expense_heads(:'tenant_id');
select count(*)::int as head_count_before from public.expense_head where tenant_id = :'tenant_id' \gset

select cmp_ok(
  :'head_count_before'::int, '>', 0,
  'AC4 premise: the tenant has expense data before any flag is touched'
);

-- ── AC1: plan default, with no override ─────────────────────────────────

set local role authenticated;
select set_config('request.jwt.claims', json_build_object(
  'sub', :'super_uid', 'tenant_id', :'tenant_id', 'app_role', 'super_admin')::text, true);

select lives_ok(
  format($$ select public.set_tenant_plan(%L, 'basic') $$, :'tenant_id'),
  'a Super Admin can put a tenant on a plan'
);

select set_config('request.jwt.claims', json_build_object(
  'sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);

select is(
  public.resolved_features() ->> 'module.transport', 'false',
  'AC1: on the Basic plan with no override, module.transport resolves false'
);
select is(
  public.resolved_features() ->> 'module.homework', 'true',
  'AC1: Basic still includes module.homework'
);
select is(
  app.feature_enabled('module.transport'), false,
  'AC1: app.feature_enabled agrees with the resolved set'
);

-- A tenant on no plan at all falls through to the platform default, so
-- nothing that shipped before this migration changes behaviour.
select is(
  app.feature_enabled_for(:'tenant_b_id', 'module.transport'), true,
  'a tenant with no subscription falls through to the platform default'
);
select is(
  app.feature_enabled('no.such.flag'), false,
  'a code that is in no catalogue resolves false — a typo in a gate closes the module'
);

-- ── AC2: a Super Admin toggle takes effect with no re-login ─────────────

select is(
  public.resolved_features() ->> 'exams.ai_paper_generation', 'false',
  'AC2 premise: the beta feature is off for this tenant'
);
select throws_ok(
  format($$ select public.set_tenant_feature(%L, 'exams.ai_paper_generation', true) $$, :'tenant_id'),
  '42501', 'FORBIDDEN',
  'AC2: an Owner cannot switch a feature on for their own tenant'
);

select set_config('request.jwt.claims', json_build_object(
  'sub', :'super_uid', 'tenant_id', :'tenant_id', 'app_role', 'super_admin')::text, true);
select lives_ok(
  format($$ select public.set_tenant_feature(%L, 'exams.ai_paper_generation', true) $$, :'tenant_id'),
  'AC2: a Super Admin can switch a feature on for a tenant'
);
select throws_ok(
  format($$ select public.set_tenant_feature(%L, 'no.such.flag', true) $$, :'tenant_id'),
  '23503', 'FEATURE_UNKNOWN',
  'switching on a code outside the catalogue is refused'
);

-- Back to the Owner's own claim set — the same one they held before the
-- toggle, not a re-minted token.
select set_config('request.jwt.claims', json_build_object(
  'sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);
select is(
  public.resolved_features() ->> 'exams.ai_paper_generation', 'true',
  'AC2: the Owner sees the feature on their very next read, without logging out'
);

set local role postgres;
select is(
  (select claims_version from public.app_user where user_id = :'owner_uid'), 1,
  'a flag change does not bump claims_version — flags are never a claim, so no token goes stale'
);

-- ── resolution order: override beats plan beats platform default ────────

set local role authenticated;
select set_config('request.jwt.claims', json_build_object(
  'sub', :'super_uid', 'tenant_id', :'tenant_id', 'app_role', 'super_admin')::text, true);

select public.set_tenant_feature(:'tenant_id', 'module.transport', true);
select is(
  app.feature_enabled('module.transport'), true,
  'a tenant override beats the plan default'
);
select public.set_tenant_feature(:'tenant_id', 'module.transport', null);
select is(
  app.feature_enabled('module.transport'), false,
  'clearing the override falls back to the plan default'
);

select is(
  (select count(*)::int from public.tenant_subscription
    where tenant_id = :'tenant_id' and valid_to is null),
  1,
  'a tenant has exactly one live subscription'
);
select public.set_tenant_plan(:'tenant_id', 'premium');
select is(
  (select count(*)::int from public.tenant_subscription
    where tenant_id = :'tenant_id' and valid_to is null),
  1,
  'changing plan closes the previous subscription rather than adding a second live one'
);
select is(
  (select count(*)::int from public.tenant_subscription where tenant_id = :'tenant_id'),
  2,
  'the previous subscription is retained as history'
);

-- ── AC3: a disabled module refuses a direct call and writes nothing ─────

select public.set_tenant_plan(:'tenant_id', 'basic');
select is(app.feature_enabled('module.expenses'), false, 'AC3 premise: Basic withholds module.expenses');

select set_config('request.jwt.claims', json_build_object(
  'sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);

select throws_ok(
  format(
    $$ insert into public.expense_head (tenant_id, code, name_en, name_ur)
       values (%L, 'SNEAK', 'Sneak', 'Sneak') $$,
    :'tenant_id'
  ),
  '42501', 'FEATURE_DISABLED',
  'AC3: a direct write to a disabled module is refused with FEATURE_DISABLED (PostgREST 403)'
);

-- The half an RLS-only gate would miss: create_expense_head is SECURITY
-- DEFINER, so RLS does not run for it at all.
select throws_ok(
  $$ select public.create_expense_head('SNEAK2', 'Sneak Two', 'Sneak Two') $$,
  '42501', 'FEATURE_DISABLED',
  'AC3: the module''s SECURITY DEFINER RPC is refused too — the gate is not UI-only'
);

set local role postgres;
select is(
  (select count(*)::int from public.expense_head
    where tenant_id = :'tenant_id' and code in ('SNEAK', 'SNEAK2')),
  0,
  'AC3: no row was created by either refused call'
);

-- ── AC4: disabling hides data, never deletes it ─────────────────────────

select is(
  (select count(*)::int from public.expense_head where tenant_id = :'tenant_id'),
  :'head_count_before'::int,
  'AC4: every pre-existing row survives the module being switched off'
);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object(
  'sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);
select is(
  (select count(*)::int from public.expense_head), 0,
  'AC4: the rows are invisible to the tenant while the module is off'
);

select set_config('request.jwt.claims', json_build_object(
  'sub', :'super_uid', 'tenant_id', :'tenant_id', 'app_role', 'super_admin')::text, true);
select public.set_tenant_feature(:'tenant_id', 'module.expenses', true);

select set_config('request.jwt.claims', json_build_object(
  'sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);
select is(
  (select count(*)::int from public.expense_head), :'head_count_before'::int,
  'AC4: re-enabling brings the same rows back, unchanged'
);
select lives_ok(
  $$ select public.create_expense_head('BACK', 'Back On', 'Back On') $$,
  'AC4: the module is writable again once re-enabled'
);

-- ── tenant isolation ────────────────────────────────────────────────────

select is(
  app.feature_enabled_for(:'tenant_b_id', 'module.expenses'), true,
  'tenant A''s plan and overrides do not touch tenant B'
);
select is(
  public.resolved_features(:'tenant_b_id'), '{}'::jsonb,
  'a non-Super-Admin asking for another tenant''s flags gets nothing back'
);
select is(
  (select count(*)::int from public.tenant_feature_override where tenant_id = :'tenant_b_id'),
  0,
  'a tenant sees no other tenant''s override rows'
);

select set_config('request.jwt.claims', json_build_object(
  'sub', :'super_uid', 'tenant_id', :'tenant_id', 'app_role', 'super_admin')::text, true);
select is(
  public.resolved_features(:'tenant_b_id') ->> 'module.expenses', 'true',
  'a Super Admin can resolve another tenant''s flags — that is the console they toggle from'
);

select * from finish();
rollback;
