begin;
select plan(9);

select public.provision_tenant('test-hifz-co', 'Hifz Co', 'owner@hifz.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as qari_uid \gset
select gen_random_uuid() as other_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@hifz.test', 'authenticated', 'authenticated', 'x'),
  (:'qari_uid', 'q@hifz.test', 'authenticated', 'authenticated', 'x'),
  (:'other_uid', 't@hifz.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'qari_uid', :'tenant_id', 'subject_teacher', 'Qari Sahib'), (:'other_uid', :'tenant_id', 'subject_teacher', 'Other');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_student(:'campus_id'::uuid, 'Hafiz Kid', '2014-01-01'::date, 'male') as kid \gset
select public.save_halqa(:'campus_id', 'Halqa Abu Bakr', 'hifz', :'qari_uid') as halqa \gset
select public.save_halqa(:'campus_id', 'Halqa Umar', 'hifz', null) as halqa2 \gset
select public.set_halqa_member(:'halqa', :'kid', true);
select is((select count(*)::int from public.halqa_member where student_id = :'kid' and left_on is null), 1, 'a student joins a halqa');

select set_config('request.jwt.claims', json_build_object('sub', :'qari_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select lives_ok(format($$ select public.record_hifz_lesson(%L, %L, current_date, 'sabaq', 3::smallint, 3::smallint, 'Al-Baqarah 1-10', 7::smallint, 2::smallint, 1::smallint, 'good') $$, :'halqa', :'kid'), 'the halqa''s teacher records today''s sabaq');
select lives_ok(format($$ select public.record_hifz_lesson(%L, %L, current_date, 'sabaq', 3::smallint, 4::smallint, 'Al-Baqarah 1-15', 9::smallint, 1::smallint, 0::smallint, 'excellent') $$, :'halqa', :'kid'), 'saving again corrects the same day''s lesson');
select is((select count(*)::int from public.hifz_lesson where student_id = :'kid'), 1, 'one sabaq per student per day');
select is((select highest_para from public.halqa_progress(:'halqa')), 4::smallint, 'progress shows the highest para reached');
select throws_ok(format($$ select public.save_halqa(%L, 'X', 'hifz', null) $$, :'campus_id'), '42501', 'FORBIDDEN', 'a teacher cannot create halqas');

select set_config('request.jwt.claims', json_build_object('sub', :'other_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.record_hifz_lesson(%L, %L, current_date, 'sabqi', null, null, null, null, 0::smallint, 0::smallint, null) $$, :'halqa', :'kid'), '42501', 'FORBIDDEN', 'another teacher cannot record for this halqa');

select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_halqa_member(:'halqa2', :'kid', true);
select is((select halqa_id from public.halqa_member where student_id = :'kid' and left_on is null), :'halqa2'::uuid, 'moving to another halqa ends the old membership');

select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.hifz_lesson), 0, 'parents cannot read lesson records directly');

select * from finish();
rollback;
