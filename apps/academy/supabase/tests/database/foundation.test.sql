-- pgTAP tests for the foundation migration: provision_tenant, archive_campus,
-- and — most importantly — that RLS actually fences one tenant off from
-- another. Run with `pnpm db:test` (wraps `supabase test db`, which runs
-- every file here inside a rolled-back transaction).
begin;
select plan(11);

-- ── provision_tenant (FR-A01) ────────────────────────────────────────────

select lives_ok(
  $$ select public.provision_tenant('test-beaconhouse', 'Beaconhouse Test', 'owner@beaconhouse.test') $$,
  'provision_tenant succeeds for a fresh, valid slug'
);

select is(
  (select status from public.tenant where slug = 'test-beaconhouse'),
  'active',
  'provisioned tenant transitions to active'
);

select is(
  (select count(*)::int from public.campus c join public.tenant t on t.id = c.tenant_id where t.slug = 'test-beaconhouse'),
  1,
  'provisioning seeds exactly one campus'
);

select is(
  (select count(*)::int from public.academic_session s join public.tenant t on t.id = s.tenant_id where t.slug = 'test-beaconhouse'),
  1,
  'provisioning seeds exactly one academic session, marked current'
);

select ok(
  (select is_current from public.academic_session s join public.tenant t on t.id = s.tenant_id where t.slug = 'test-beaconhouse'),
  'the seeded session is current'
);

select is(
  (select count(*)::int from public.tenant_invitation i join public.tenant t on t.id = i.tenant_id where t.slug = 'test-beaconhouse' and i.app_role = 'owner'),
  1,
  'provisioning creates exactly one owner invitation'
);

select throws_ok(
  $$ select public.provision_tenant('test-beaconhouse', 'Duplicate', 'x@y.test') $$,
  'TENANT_SLUG_TAKEN',
  'a repeat slug is rejected, including against an existing live tenant'
);

select throws_ok(
  $$ select public.provision_tenant('Not A Valid Slug!', 'X', 'x@y.test') $$,
  'TENANT_SLUG_INVALID',
  'a malformed slug is rejected before touching any table'
);

-- ── RLS: the property the whole architecture depends on ──────────────────
-- Capture both tenant ids as superuser BEFORE switching role — once we are
-- `authenticated`, a lookup query is itself subject to RLS, so doing this
-- lookup afterwards would silently return NULL and the test would prove
-- nothing (this bit us on the first pass: see AUDIT.md-adjacent commit).

select public.provision_tenant('test-city-school', 'City School Test', 'owner2@city.test');
select id as t1_id from public.tenant where slug = 'test-beaconhouse' \gset
select id as t2_id from public.tenant where slug = 'test-city-school' \gset

set local role authenticated;

select is(
  (select count(*)::int from public.tenant),
  0,
  'with no JWT claims set at all, RLS hides every tenant row (deny by default)'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'t1_id', 'app_role', 'owner', 'campus_ids', '[]'::json)::text,
  true
);

select is(
  (select array_agg(slug order by slug) from public.tenant),
  array['test-beaconhouse'],
  'authenticated as tenant A''s owner: SELECT * from tenant returns only tenant A, never tenant B'
);

select is(
  (select count(*)::int from public.tenant where id = :'t2_id'),
  0,
  'a direct WHERE id = <tenant B> lookup from tenant A''s session also returns nothing — RLS is not just a default-list filter'
);

select * from finish();
rollback;
