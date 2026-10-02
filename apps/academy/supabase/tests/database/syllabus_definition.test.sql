-- pgTAP tests for FR-H08: annual syllabus definition per class and subject.
begin;
select plan(28);

select public.provision_tenant('test-syllabus-co', 'Syllabus Co', 'owner@syllabus.test');
select id as tenant_id from public.tenant where slug = 'test-syllabus-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select starts_on as s1_start from public.academic_session where id = :'session_id'::uuid \gset
select id as class9_id from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select public.provision_tenant('test-syllabus-other', 'Other Syllabus Co', 'owner@othersyllabus.test');
select id as other_tenant_id from public.tenant where slug = 'test-syllabus-other' \gset
insert into public.academic_session (tenant_id, name, starts_on, ends_on) values (:'tenant_id', 'Next year', (:'s1_start'::date + interval '1 year')::date, (:'s1_start'::date + interval '2 years' - interval '1 day')::date) returning id as session2_id \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@syllabus.test', 'authenticated', 'authenticated', 'x'), (:'ec_uid', 'e@syllabus.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@syllabus.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Exam Controller'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');
insert into public.subject (tenant_id, code, name_en, name_ur) values (:'tenant_id', 'PHY', 'Physics', 'طبیعیات');
select id as phy from public.subject where tenant_id = :'tenant_id' and code = 'PHY' \gset
insert into public.subject (tenant_id, code, name_en, name_ur) values (:'other_tenant_id', 'PHY', 'Physics', 'طبیعیات');
select id as other_phy from public.subject where tenant_id = :'other_tenant_id' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── AC1: nine chapters in one save ────────────────────────────────────────
select public.save_syllabus(:'campus_id'::uuid, :'session_id'::uuid, :'class9_id'::uuid, :'phy'::uuid, 'FBISE'::public.board,
  (select jsonb_agg(jsonb_build_object('title', 'Chapter ' || n, 'title_ur', 'باب ' || n, 'planned_periods', 8 + n, 'target_month', to_char(date_trunc('month', :'s1_start'::date) + make_interval(months => n), 'YYYY-MM-01'),
     'topics', jsonb_build_array(jsonb_build_object('title', 'Topic ' || n || '.1', 'planned_periods', 4), jsonb_build_object('title', 'Topic ' || n || '.2', 'planned_periods', 4))) order by n) from generate_series(1, 9) n)) as saved \gset
select is(:'saved'::int, 9, 'AC1: nine chapters are saved');
select is((select string_agg(sequence::text, ',' order by sequence) from public.syllabus_unit where board = 'FBISE' and tenant_id = :'tenant_id'), '1,2,3,4,5,6,7,8,9', 'AC1: sequences run 1 to 9 with no gap or duplicate');
select is((select count(*) from public.syllabus_topic where tenant_id = :'tenant_id'), 18::bigint, 'and each chapter has its two topics');
select throws_ok(format($$ select public.save_syllabus(%L, %L, %L, %L, 'FBISE', '[{"title":"X"}]'::jsonb) $$, :'campus_id', :'session_id', :'class9_id', :'phy'), 'SYLLABUS_ALREADY_EXISTS', 'saving a second FBISE syllabus for the same class and subject is refused');

-- ── AC2: another board coexists ───────────────────────────────────────────
select public.save_syllabus(:'campus_id'::uuid, :'session_id'::uuid, :'class9_id'::uuid, :'phy'::uuid, 'PUNJAB'::public.board,
  (select jsonb_agg(jsonb_build_object('title', 'Punjab unit ' || n) order by n) from generate_series(1, 7) n)) as saved2 \gset
select is((select count(*) from public.syllabus_unit where board = 'PUNJAB' and tenant_id = :'tenant_id'), 7::bigint, 'AC2: a Punjab Board syllabus with a different chapter count exists beside the FBISE one');
select is((select count(*) from public.syllabus_unit where board = 'FBISE' and tenant_id = :'tenant_id'), 9::bigint, 'and the FBISE one is untouched');

-- ── AC3: reorder 5 -> 2 in one transaction ────────────────────────────────
select id as u5 from public.syllabus_unit where board = 'FBISE' and sequence = 5 and tenant_id = :'tenant_id' \gset
select public.reorder_syllabus_units((
  select array_agg(id order by case when sequence = 5 then 2 when sequence between 2 and 4 then sequence + 1 else sequence end) from public.syllabus_unit where board = 'FBISE' and tenant_id = :'tenant_id'
)) as reordered \gset
select is((select sequence from public.syllabus_unit where id = :'u5'::uuid), 2, 'AC3: the moved unit is now second');
select is((select string_agg(sequence::text, ',' order by sequence) from public.syllabus_unit where board = 'FBISE' and tenant_id = :'tenant_id'), '1,2,3,4,5,6,7,8,9', 'AC3: every sequence is renumbered contiguously with no gaps');
select is((select string_agg(title, ',' order by sequence) from public.syllabus_unit where board = 'FBISE' and tenant_id = :'tenant_id' and sequence <= 5), 'Chapter 1,Chapter 5,Chapter 2,Chapter 3,Chapter 4', 'and the others shifted down one place');
select throws_ok(format($$ select public.reorder_syllabus_units(array[%L]::uuid[]) $$, :'u5'), 'ORDER_MUST_LIST_EVERY_UNIT_OF_ONE_SYLLABUS', 'a partial order is refused');
select throws_ok(format($$ select public.reorder_syllabus_units(array[%L, %L]::uuid[]) $$, :'u5', :'u5'), 'DUPLICATE_UNIT', 'so is a duplicated id');

-- ── adding and deleting keep the numbering contiguous ─────────────────────
select public.add_syllabus_unit(:'campus_id'::uuid, :'session_id'::uuid, :'class9_id'::uuid, :'phy'::uuid, 'FBISE'::public.board, 'Inserted at three', null, 6, null, 3) as inserted \gset
select is((select sequence from public.syllabus_unit where id = :'inserted'::uuid), 3, 'a unit can be inserted at a position');
select is((select max(sequence) from public.syllabus_unit where board = 'FBISE' and tenant_id = :'tenant_id'), 10, 'pushing the later ones down');
select public.delete_syllabus_unit(:'inserted'::uuid);
select is((select string_agg(sequence::text, ',' order by sequence) from public.syllabus_unit where board = 'FBISE' and tenant_id = :'tenant_id'), '1,2,3,4,5,6,7,8,9', 'deleting it closes the gap');

-- ── topics ────────────────────────────────────────────────────────────────
select public.add_syllabus_topic(:'u5'::uuid, 'Inserted first', null, 2, 1) as tnew \gset
select is((select string_agg(title, ',' order by sequence) from public.syllabus_topic where syllabus_unit_id = :'u5'::uuid), 'Inserted first,Topic 5.1,Topic 5.2', 'a topic can be inserted first');
select public.reorder_syllabus_topics(:'u5'::uuid, (select array_agg(id order by title desc) from public.syllabus_topic where syllabus_unit_id = :'u5'::uuid));
select is((select string_agg(title, ',' order by sequence) from public.syllabus_topic where syllabus_unit_id = :'u5'::uuid), 'Topic 5.2,Topic 5.1,Inserted first', 'topics can be reordered');
select public.delete_syllabus_topic(:'tnew'::uuid);
select is((select string_agg(sequence::text, ',' order by sequence) from public.syllabus_topic where syllabus_unit_id = :'u5'::uuid), '1,2', 'and deleting one closes its gap');

-- ── AC4: clone to the next session ────────────────────────────────────────
select public.clone_syllabus_to_session(:'campus_id'::uuid, :'session_id'::uuid, :'session2_id'::uuid, :'class9_id'::uuid, :'phy'::uuid) as cloned \gset
select is(:'cloned'::int, 16, 'AC4: all 16 units (9 FBISE and 7 Punjab) are cloned');
select is((select count(*) from public.syllabus_topic t join public.syllabus_unit u on u.id = t.syllabus_unit_id where u.session_id = :'session2_id'::uuid), 18::bigint, 'AC4: with their topics');
select is((select string_agg(title, ',' order by sequence) from public.syllabus_unit where session_id = :'session2_id'::uuid and board = 'FBISE' and sequence <= 3), 'Chapter 1,Chapter 5,Chapter 2', 'AC4: titles and sequences keep their order');
select is((select planned_periods from public.syllabus_unit where session_id = :'session2_id'::uuid and board = 'FBISE' and title = 'Chapter 5'), 13, 'AC4: planned periods are copied');
select is((select target_month from public.syllabus_unit where session_id = :'session2_id'::uuid and board = 'FBISE' and title = 'Chapter 1'), (date_trunc('month', :'s1_start'::date) + interval '13 months')::date, 'AC4: the target month moves a year on with the new session');
select ok((select bool_and(c.source_unit_id = o.id) from public.syllabus_unit c join public.syllabus_unit o on o.id = c.source_unit_id where c.session_id = :'session2_id'::uuid and o.session_id = :'session_id'::uuid), 'the copies point back at their originals (lineage)');
select throws_ok(format($$ select public.clone_syllabus_to_session(%L, %L, %L, %L, %L) $$, :'campus_id', :'session_id', :'session2_id', :'class9_id', :'phy'), 'TARGET_SYLLABUS_EXISTS', 'cloning again over an existing syllabus is refused');

-- ── access and isolation ──────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select cmp_ok((select count(*) from public.syllabus_unit), '>', 0::bigint, 'a teacher can read the syllabus');
select throws_ok(format($$ select public.add_syllabus_unit(%L, %L, %L, %L, 'FBISE', 'Sneaky') $$, :'campus_id', :'session_id', :'class9_id', :'phy'), 'FORBIDDEN', 'but cannot change it');
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.add_syllabus_unit(%L, %L, %L, %L, 'FBISE', 'Foreign subject') $$, :'campus_id', :'session_id', :'class9_id', :'other_phy'), 'SUBJECT_NOT_FOUND', 'another school''s subject cannot be used');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.syllabus_unit), 0::bigint, 'another school sees none of it');

select * from finish();
rollback;
