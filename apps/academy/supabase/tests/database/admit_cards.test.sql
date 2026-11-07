begin;
select plan(6);

select public.provision_tenant('test-admit-co', 'Admit Co', 'owner@admit.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'owner_uid', 'o@admit.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'owner_uid', :'tenant_id', 'owner', 'Owner');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_subject(c, 'Subject ' || c, 'مضمون') from unnest(array['SA', 'SB']) c;
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', s.id, 4::smallint) from public.subject s where s.tenant_id = :'tenant_id';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class9'::uuid, 'A', 60) as sec_a \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T1', 'First Term', 1::smallint, 100.00) as term1 \gset
select public.activate_exam_terms(:'session_id'::uuid, :'campus_id'::uuid) as _a \gset
select public.upsert_exam_subject(:'term1', cs.id, '[{"component":"theory","max_marks":100,"pass_marks":33}]'::jsonb) from public.class_subject cs where cs.tenant_id = :'tenant_id';
select es.id as es_sa from public.exam_subject es join public.class_subject cs on cs.id = es.class_subject_id join public.subject s on s.id = cs.subject_id where es.tenant_id = :'tenant_id' and s.code = 'SA' \gset
select es.id as es_sb from public.exam_subject es join public.class_subject cs on cs.id = es.class_subject_id join public.subject s on s.id = cs.subject_id where es.tenant_id = :'tenant_id' and s.code = 'SB' \gset
select public.create_student(:'campus_id'::uuid, 'Admit Kid', '2011-01-01'::date, 'male') as kid \gset
select public.enrol_student(:'sec_a'::uuid, :'kid'::uuid);
select public.save_exam_hall(:'campus_id'::uuid, 'H1', 'Main Hall', 5, 5) as h1 \gset
select public.create_datesheet(:'campus_id'::uuid, :'term1'::uuid, 'First Term datesheet') as ds \gset
select public.save_datesheet_slot(:'ds'::uuid, :'es_sa'::uuid, '2026-12-08'::date, '09:00'::time, '11:00'::time, :'h1'::uuid) ->> 'slot_id' as slot_sa \gset
select public.save_datesheet_slot(:'ds'::uuid, :'es_sb'::uuid, '2026-12-09'::date, '09:00'::time, '11:00'::time, :'h1'::uuid) ->> 'slot_id' as slot_sb \gset

select throws_ok(format($$ select public.admit_card_batch(%L, %L) $$, :'term1', :'sec_a'), '55000', null, 'admit cards need a published datesheet');
select public.publish_datesheet(:'ds'::uuid, 'First issue');
select public.fn_generate_seating_plan(:'slot_sa'::uuid);

select public.admit_card_batch(:'term1', :'sec_a') as batch \gset
select is(jsonb_array_length(:'batch'::jsonb -> 'students'), 1, 'one slip per student in the section');
select is(jsonb_array_length(:'batch'::jsonb -> 'students' -> 0 -> 'papers'), 2, 'each slip lists every paper of the class');
select is(:'batch'::jsonb -> 'students' -> 0 -> 'papers' -> 0 ->> 'seat', 'R1-S1', 'a seated paper shows the seat');
select is(:'batch'::jsonb -> 'students' -> 0 -> 'papers' -> 0 ->> 'hall', 'Main Hall', 'and the hall');

select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.admit_card_batch(%L, %L) $$, :'term1', :'sec_a'), '42501', 'FORBIDDEN', 'an accountant cannot print admit cards');

select * from finish();
rollback;
