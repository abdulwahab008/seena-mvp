-- pgTAP tests for archive_campus (FR-A02): a non-owner is forbidden, an
-- owner outside the tenant is forbidden, and the owning tenant's owner
-- succeeds and it actually archives (not just returns ok).
begin;
select plan(4);

-- All setup (as superuser, RLS does not apply) happens before any role
-- switch below — see the note in foundation.test.sql for why order matters.
select public.provision_tenant('test-archive-co', 'Archive Co', 'owner@archiveco.test');
select public.provision_tenant('test-archive-other', 'Other Co', 'owner@other.test');
select id as tenant_id from public.tenant where slug = 'test-archive-co' \gset
select id as other_tenant_id from public.tenant where slug = 'test-archive-other' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

set local role authenticated;

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.archive_campus(%L::uuid)', :'campus_id'),
  'FORBIDDEN',
  'a subject_teacher cannot archive a campus'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json)::text,
  true
);
select throws_ok(
  format('select public.archive_campus(%L::uuid)', :'campus_id'),
  'FORBIDDEN',
  'an owner of a DIFFERENT tenant cannot archive this campus'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select lives_ok(
  format('select public.archive_campus(%L::uuid)', :'campus_id'),
  'the owning tenant''s owner can archive the campus'
);

select is(
  (select status::text from public.campus where id = :'campus_id'),
  'archived',
  'the campus row is actually marked archived, not just a no-op success'
);

select * from finish();
rollback;
