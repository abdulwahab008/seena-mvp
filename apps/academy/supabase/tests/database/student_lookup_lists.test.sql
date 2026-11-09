begin;
select plan(14);

select public.provision_tenant('test-lookups', 'Lookups Co', 'owner@lookups.test') as tenant_id \gset
select public.provision_tenant('test-lookups-other', 'Other Co', 'owner@lookups-other.test') as other_tenant \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender, status)
values (:'tenant_id', :'campus_id', 'GR-L1', 'Ali Raza', '2015-01-01', 'male', 'active') returning id as ali \gset
insert into public.guardian (tenant_id, name_en, phone_e164) values (:'tenant_id', 'Raza Ahmed', '+923001112222') returning id as raza \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id', :'ali', :'raza', 'father', true, true);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select public.save_student_lookup('category', 'Orphan') as orphan \gset
select public.save_student_lookup('region', 'Gulshan') as gulshan \gset
select public.save_student_lookup('profession', 'Doctor') as doctor \gset
select public.save_student_lookup('school', 'City Grammar', 'Gulberg') as city \gset
select is((select area from public.student_lookup where id = :'city'), 'Gulberg', 'a nearby school keeps its area');
select throws_ok($$ select public.save_student_lookup('category', ' orphan ') $$, '23505', 'LOOKUP_DUPLICATE', 'names are unique per list, ignoring case');
select lives_ok($$ select public.save_student_lookup('region', 'Orphan') $$, 'the same name may appear in another list');
select throws_ok($$ select public.save_student_lookup('colour', 'Red') $$, '22023', 'KIND_INVALID', 'only the four lists exist');

select public.save_student_lookup('category', 'Orphan child', null, :'orphan');
select is((select name from public.student_lookup where id = :'orphan'), 'Orphan child', 'an entry can be renamed');
select public.set_student_lookup_active(:'orphan', false);
select is((select is_active from public.student_lookup where id = :'orphan'), false, 'and deactivated');

select public.set_student_lookups(:'ali', :'orphan', :'gulshan', :'city');
select is((select category_id::text || region_id::text || previous_school_id::text from public.student where id = :'ali'),
          :'orphan' || :'gulshan' || :'city', 'the student links a category, region and previous school');
select throws_ok(format($$ select public.set_student_lookups(%L, %L, null, null) $$, :'ali', :'gulshan'), 'P0002', 'LOOKUP_NOT_FOUND', 'a region cannot be used as a category');

select public.set_guardian_profession(:'raza', :'doctor');
select is((select profession_id from public.guardian where id = :'raza'), :'doctor'::uuid, 'the guardian links a profession');
select throws_ok(format($$ select public.set_guardian_profession(%L, %L) $$, :'raza', :'city'), 'P0002', 'LOOKUP_NOT_FOUND', 'a school is not a profession');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.save_student_lookup('category', 'Hafiz') $$, '42501', 'FORBIDDEN', 'a teacher cannot edit the lists');
select throws_ok(format($$ select public.set_student_lookups(%L, null, null, null) $$, :'ali'), '42501', 'FORBIDDEN', 'or a student''s links');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'other_tenant', 'app_role', 'owner')::text, true);
select is((select count(*)::int from public.student_lookup), 0, 'another school sees none of the lists');
select throws_ok(format($$ select public.set_student_lookup_active(%L, true) $$, :'orphan'), 'P0002', 'LOOKUP_NOT_FOUND', 'or changes them');

select * from finish();
rollback;
