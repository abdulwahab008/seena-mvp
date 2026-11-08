begin;
select plan(5);

select public.provision_tenant('test-rename-class-a', 'Rename Class A', 'owner@renameclassa.test');
select public.provision_tenant('test-rename-class-b', 'Rename Class B', 'owner@renameclassb.test');
select id as tenant_a from public.tenant where slug = 'test-rename-class-a' \gset
select id as tenant_b from public.tenant where slug = 'test-rename-class-b' \gset
select id as nur_a from public.class_level where tenant_id = :'tenant_a' and code = 'NUR' \gset
select id as nur_b from public.class_level where tenant_id = :'tenant_b' and code = 'NUR' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_a', 'app_role', 'principal')::text, true);

select lives_ok(format('select public.rename_class_level(%L, %L)', :'nur_a', '  Seena Junior '), 'a principal can rename a class');
select throws_like(format('select public.rename_class_level(%L, %L)', :'nur_b', 'Hijack'), '%CLASS_NOT_FOUND%', 'another school''s class cannot be renamed');
select throws_like(format('select public.rename_class_level(%L, %L)', :'nur_a', '  '), '%NAME_INVALID%', 'a blank name is rejected');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_a', 'app_role', 'subject_teacher')::text, true);
select throws_like(format('select public.rename_class_level(%L, %L)', :'nur_a', 'Nope'), '%FORBIDDEN%', 'a teacher cannot rename a class');

reset role;
select results_eq(
  format('select name_en || ''/'' || code from public.class_level where id in (%L, %L) order by tenant_id = %L desc', :'nur_a', :'nur_b', :'tenant_a'),
  $$ values ('Seena Junior/NUR'), ('Nursery/NUR') $$,
  'only the name changed, trimmed, and only in the caller''s school'
);

select * from finish();
rollback;
