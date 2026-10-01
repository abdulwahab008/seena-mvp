-- pgTAP tests for FR-H11: syllabus coverage tracking.
begin;
select plan(22);

select public.provision_tenant('test-cover-co', 'Cover Co', 'owner@cover.test');
select id as tenant_id from public.tenant where slug = 'test-cover-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-cover-other', 'Other Cover Co', 'owner@othercover.test');
select id as other_tenant_id from public.tenant where slug = 'test-cover-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as t1_uid \gset
select gen_random_uuid() as t2_uid \gset
select gen_random_uuid() as t3_uid \gset
select gen_random_uuid() as prin_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@cover.test', 'authenticated', 'authenticated', 'x'), (:'ec_uid', 'e@cover.test', 'authenticated', 'authenticated', 'x'),
  (:'t1_uid', 't1@cover.test', 'authenticated', 'authenticated', 'x'), (:'t2_uid', 't2@cover.test', 'authenticated', 'authenticated', 'x'),
  (:'t3_uid', 't3@cover.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@cover.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Exam Controller'),
  (:'t1_uid', :'tenant_id', 'subject_teacher', 'Teacher One'), (:'t2_uid', :'tenant_id', 'subject_teacher', 'Teacher Two'),
  (:'t3_uid', :'tenant_id', 'subject_teacher', 'Teacher Three'), (:'prin_uid', :'tenant_id', 'principal', 'Principal');
insert into public.subject (tenant_id, code, name_en, name_ur) values (:'tenant_id', 'PHY', 'Physics', 'طبیعیات'), (:'tenant_id', 'MTH', 'Maths', 'ریاضی');
select id as phy from public.subject where tenant_id = :'tenant_id' and code = 'PHY' \gset
select id as mth from public.subject where tenant_id = :'tenant_id' and code = 'MTH' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as sec \gset
reset role;
insert into public.section_subject_teacher (tenant_id, campus_id, session_id, section_id, subject_id, staff_id, role, effective_from) values
  (:'tenant_id', :'campus_id', :'session_id', :'sec', :'phy', :'t1_uid', 'primary', current_date - 60),
  (:'tenant_id', :'campus_id', :'session_id', :'sec', :'phy', :'t2_uid', 'assistant', current_date - 60);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
-- Nine units: one of 12 periods and eight of 6 = 60 periods.
select public.save_syllabus(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'phy'::uuid, 'FBISE'::public.board,
  (select jsonb_agg(jsonb_build_object('title', 'Unit ' || n, 'planned_periods', case when n = 1 then 12 else 6 end) order by n) from generate_series(1, 9) n));
select public.save_syllabus(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'mth'::uuid, 'FBISE'::public.board, '[{"title":"Algebra","planned_periods":10}]'::jsonb);
select id as u1 from public.syllabus_unit where tenant_id = :'tenant_id' and subject_id = :'phy' and sequence = 1 \gset
select id as u2 from public.syllabus_unit where tenant_id = :'tenant_id' and subject_id = :'phy' and sequence = 2 \gset
select id as u3 from public.syllabus_unit where tenant_id = :'tenant_id' and subject_id = :'phy' and sequence = 3 \gset
select id as u4 from public.syllabus_unit where tenant_id = :'tenant_id' and subject_id = :'phy' and sequence = 4 \gset
select id as u5 from public.syllabus_unit where tenant_id = :'tenant_id' and subject_id = :'phy' and sequence = 5 \gset
select id as alg from public.syllabus_unit where tenant_id = :'tenant_id' and subject_id = :'mth' \gset

select set_config('request.jwt.claims', json_build_object('sub', :'t1_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── AC1: completed with no start date ─────────────────────────────────────
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, :'u1'::uuid, 'completed', null, '2026-10-12', 12) as c1 \gset
select is((select started_on from public.syllabus_coverage where id = :'c1'::uuid), '2026-10-12'::date, 'AC1: started_on defaults to completed_on');
select is((select note from public.syllabus_coverage where id = :'c1'::uuid), 'start date inferred', 'AC1: and the note ''start date inferred'' is stored');

-- ── AC2: completion cannot precede start ──────────────────────────────────
select throws_ok(format($$ select public.set_syllabus_coverage(%L, %L, %L, 'completed', '2026-10-10', '2026-10-05') $$, :'sec', :'phy', :'u2'),
  '23514', 'Completion date cannot precede start date', 'AC2: completed before started is rejected with the message');
select is((select count(*) from public.syllabus_coverage where syllabus_unit_id = :'u2'::uuid), 0::bigint, 'and nothing is saved');
select lives_ok(format($$ select public.set_syllabus_coverage(%L, %L, %L, 'completed', '2026-10-01', '2026-10-05') $$, :'sec', :'phy', :'u2'), 'a proper range is saved');
select is((select note from public.syllabus_coverage where syllabus_unit_id = :'u2'::uuid), null, 'an explicit start date carries no inference note');

-- ── AC3: completed -> in_progress clears the date and is recorded ────────
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, :'u1'::uuid, 'in_progress');
select is((select completed_on from public.syllabus_coverage where id = :'c1'::uuid), null, 'AC3: moving back to in_progress clears completed_on');
select is((select status::text from public.syllabus_coverage where id = :'c1'::uuid), 'in_progress', 'and the status is in_progress');
select is((select old_status::text || '>' || new_status::text || ' by ' || (changed_by = :'t1_uid'::uuid)::text from public.syllabus_coverage_history
            where coverage_id = :'c1'::uuid order by changed_at desc limit 1), 'completed>in_progress by true', 'AC3: the transition is in the coverage history with the acting user');
select is((select start_inferred from public.syllabus_coverage where id = :'c1'::uuid), true, 'the inferred start date stays flagged while in progress');

-- ── AC4: weighting by planned periods ─────────────────────────────────────
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, :'u1'::uuid, 'completed', null, '2026-10-12');
select is(public.coverage_pct(:'sec'::uuid, :'phy'::uuid), 30.00::numeric, 'units 1 (12 periods) and 2 (6 periods) done = 18 of 60 = 30%');
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, :'u2'::uuid, 'not_started');
select is(public.coverage_pct(:'sec'::uuid, :'phy'::uuid), 20.00::numeric, 'AC4: a 12-period unit out of 60 contributes 20%, not 11.1%');
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, :'u2'::uuid, 'completed', '2026-10-13', '2026-10-14');
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, :'u3'::uuid, 'completed', '2026-10-15', '2026-10-16');
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, :'u4'::uuid, 'completed', '2026-10-17', '2026-10-18');
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, :'u5'::uuid, 'in_progress', '2026-10-19');
select is(public.coverage_pct(:'sec'::uuid, :'phy'::uuid), 50.00::numeric, 'AC4: 4 completed (12+6+6+6) and 1 in progress = 30 of 60 = 50%, not 4/9 = 44.4%');
select is(public.coverage_pct(:'sec'::uuid, :'mth'::uuid), 0.00::numeric, 'a syllabus with no coverage rows is 0%');

-- ── AC5: two teachers on one subject, last write wins, both in history ───
select set_config('request.jwt.claims', json_build_object('sub', :'t2_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, :'u5'::uuid, 'completed', '2026-10-19', '2026-10-25');
select is((select status::text from public.syllabus_coverage where syllabus_unit_id = :'u5'::uuid), 'completed', 'AC5: the last write wins');
select is((select count(distinct changed_by) from public.syllabus_coverage_history h join public.syllabus_coverage c on c.id = h.coverage_id where c.syllabus_unit_id = :'u5'::uuid), 2::bigint,
  'AC5: both teachers'' writes appear in the coverage history');
select is((select count(*) from public.syllabus_coverage_history h join public.syllabus_coverage c on c.id = h.coverage_id where c.syllabus_unit_id = :'u5'::uuid), 2::bigint, 'one history row per write');

-- ── guards ────────────────────────────────────────────────────────────────
select throws_ok(format($$ select public.set_syllabus_coverage(%L, %L, %L, 'completed') $$, :'sec', :'phy', :'alg'), 'UNIT_NOT_IN_SYLLABUS', 'a unit of another subject is refused');
select set_config('request.jwt.claims', json_build_object('sub', :'t3_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.set_syllabus_coverage(%L, %L, %L, 'completed') $$, :'sec', :'phy', :'u3'), 'FORBIDDEN', 'a teacher not assigned to the section and subject cannot record coverage');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.syllabus_coverage), 5::bigint, 'the Principal reads all coverage rows of the campus');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.syllabus_coverage) + (select count(*) from public.syllabus_coverage_history), 0::bigint, 'another school sees no coverage');
reset role;
select throws_ok(format($$ update public.syllabus_coverage set completed_on = '2000-01-01' where syllabus_unit_id = %L $$, :'u2'), '23514', null, 'chk_coverage_dates also blocks a bad range written around the function');

select * from finish();
rollback;
