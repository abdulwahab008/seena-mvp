-- pgTAP tests for create_campus (FR-A02): code uniqueness within a tenant,
-- and that a non-owner cannot create one.
begin;
select plan(4);

select public.provision_tenant('test-multi-campus', 'Multi Campus Co', 'owner@multicampus.test');
select id as tenant_id from public.tenant where slug = 'test-multi-campus' \gset

set local role authenticated;

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json)::text,
  true
);

select lives_ok(
  $$ select public.create_campus('DHA', 'DHA Campus', 'Lahore') $$,
  'an owner can create a second campus with a fresh code'
);

select throws_ok(
  $$ select public.create_campus('MAIN', 'Duplicate of the seeded campus', null) $$,
  'CAMPUS_CODE_TAKEN',
  'a code that collides with the auto-seeded MAIN campus is rejected — case-insensitively by design (upper(code))'
);

select throws_ok(
  $$ select public.create_campus('dha', 'Lowercase collision', null) $$,
  'CAMPUS_CODE_TAKEN',
  'code uniqueness is case-insensitive: "dha" collides with the just-created "DHA"'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', '[]'::json)::text,
  true
);
select throws_ok(
  $$ select public.create_campus('XYZ', 'Should be forbidden', null) $$,
  'FORBIDDEN',
  'a subject_teacher cannot create a campus'
);

select * from finish();
rollback;
