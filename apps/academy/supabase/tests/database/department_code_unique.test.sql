begin;
select plan(4);

select public.provision_tenant('test-dept-co', 'Dept Co', 'owner@dept.test') as tenant_id \gset
select gen_random_uuid() as uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'uid', 'hr@dept.test', 'authenticated', 'authenticated', 'x');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'principal')::text, true);
select public.upsert_department('sci', 'Science') ->> 'id' as sci_id \gset
select public.upsert_department('ENG', 'English') ->> 'id' as eng_id \gset

select throws_ok($$ select public.upsert_department('SCI', 'Sciences again') $$, '23505', 'DEPARTMENT_CODE_EXISTS', 'creating a department with a used code is refused');
select is((select name_en from public.department where id = :'sci_id'), 'Science', 'and the existing department keeps its name');
select throws_ok(format($$ select public.upsert_department('SCI', 'English', null, %L) $$, :'eng_id'), '23505', 'DEPARTMENT_CODE_EXISTS', 'an edit cannot take another department''s code');
select is(public.upsert_department('SCI', 'Natural Science', null, :'sci_id') ->> 'code', 'SCI', 'a department can be edited keeping its own code');

select * from finish();
rollback;
