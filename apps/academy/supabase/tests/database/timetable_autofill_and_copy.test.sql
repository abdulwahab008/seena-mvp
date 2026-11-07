begin;
select plan(8);

select public.provision_tenant('test-tt-autofill', 'Autofill Co', 'owner@ttautofill.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, encrypted_password, aud, role) values
  (:'owner_uid', 'o@ttautofill.test', 'x', 'authenticated', 'authenticated'), (:'teacher_uid', 't@ttautofill.test', 'x', 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'teacher_uid', :'tenant_id', 'subject_teacher', 'Physics Teacher');
insert into public.bell_template (tenant_id, campus_id, shift, code, name, is_default) values (:'tenant_id', :'campus_id', 'MORNING', 'STD', 'Standard', true) returning id as bell_id \gset
insert into public.bell_period (bell_template_id, segment_ordinal, period_no, kind, start_time, end_time)
select :'bell_id', n, n, 'TEACHING', make_time(7 + n, 0, 0), make_time(7 + n, 40, 0) from generate_series(1, 4) n;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as sec_a \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 40) as sec_b \gset
select public.create_subject('PHY', 'Physics', 'فزکس') as physics \gset
select public.create_subject('CHEM', 'Chemistry', 'کیمسٹری') as chem \gset
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'physics'::uuid, 5::smallint);
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'chem'::uuid, 4::smallint);
select public.create_staff_teachable_subject(:'teacher_uid'::uuid, :'physics'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);
select public.assign_subject_teacher(:'sec_a'::uuid, :'physics'::uuid, :'teacher_uid'::uuid, current_date - 30);
select public.assign_subject_teacher(:'sec_b'::uuid, :'physics'::uuid, :'teacher_uid'::uuid, current_date - 30);
select public.create_timetable_version(:'campus_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'Draft') as version_id \gset

select is(public.autofill_section_timetable(:'version_id', :'sec_a'), '{"placed": 9, "unplaced": []}'::jsonb, 'every weekly period is placed');
reset role;
select is((select count(*)::int from public.timetable_slot where section_id = :'sec_a' and subject_id = :'physics' and staff_id = :'teacher_uid'), 5,
  'physics gets its five periods with the section''s physics teacher');
select is((select max(n) from (select count(*) n from public.timetable_slot where section_id = :'sec_a' and subject_id = :'physics' group by weekday) x)::int, 1,
  'spread one a day rather than bunched');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text, true);
select is(public.autofill_section_timetable(:'version_id', :'sec_a'), '{"placed": 0, "unplaced": []}'::jsonb, 'running it again places nothing twice');

-- Copying A to B: physics would double-book the same teacher, so only chemistry copies.
select is(public.copy_section_timetable(:'version_id', :'sec_a', :'sec_b'), '{"copied": 4, "skipped": 5}'::jsonb,
  'a copy skips cells that would double-book a teacher');
select throws_ok(format($$ select public.copy_section_timetable(%L, %L, %L) $$, :'version_id', :'sec_a', :'sec_a'), '22023', 'SAME_SECTION', 'a section is not copied onto itself');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_uid')::text, true);
select throws_ok(format($$ select public.autofill_section_timetable(%L, %L) $$, :'version_id', :'sec_b'), '42501', null, 'a teacher cannot fill the timetable');
reset role;
update public.timetable_version set status = 'PUBLISHED', published_at = now() where id = :'version_id';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text, true);
select throws_ok(format($$ select public.autofill_section_timetable(%L, %L) $$, :'version_id', :'sec_b'), '55000', 'VERSION_IMMUTABLE', 'a published timetable is never touched');

select * from finish();
rollback;
