-- pgTAP tests for FR-H13: syllabus coverage report for parents.
begin;
select plan(21);

select public.provision_tenant('test-psc-co', 'Parent Syllabus Co', 'owner@psc.test');
select id as tenant_id from public.tenant where slug = 'test-psc-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-psc-other', 'Other PSC Co', 'owner@otherpsc.test');
select id as other_tenant_id from public.tenant where slug = 'test-psc-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@psc.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@psc.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@psc.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Physics Teacher');
insert into public.subject (tenant_id, code, name_en, name_ur) values (:'tenant_id', 'PHY', 'Physics', 'طبیعیات');
select id as phy from public.subject where tenant_id = :'tenant_id' and code = 'PHY' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as sec \gset
select public.create_student(:'campus_id'::uuid, 'Parent Kid', '2015-01-01'::date, 'male') as s1 \gset
select public.enrol_student(:'sec'::uuid, :'s1'::uuid) as e1 \gset
select public.create_student(:'campus_id'::uuid, 'Stranger Kid', '2015-02-01'::date, 'female') as s2 \gset
select public.enrol_student(:'sec'::uuid, :'s2'::uuid) as e2 \gset
select public.fn_find_or_create_guardian(p_name_en => 'Kid Father', p_phone_e164 => '+923008880001') as g1 \gset
select public.link_guardian(:'s1'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
select public.fn_find_or_create_guardian(p_name_en => 'Stranger Father', p_phone_e164 => '+923008880002') as g2 \gset
select public.link_guardian(:'s2'::uuid, :'g2'::uuid, 'father'::public.guardian_relationship, true, true);
reset role;
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as parent2_uid \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role) values
  (:'parent_uid', '923008880001', now(), 'x', 'authenticated', 'authenticated'), (:'parent2_uid', '923008880002', now(), 'x', 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'parent_uid' where id = :'g1';
update public.guardian set auth_user_id = :'parent2_uid' where id = :'g2';
insert into public.section_subject_teacher (tenant_id, campus_id, session_id, section_id, subject_id, staff_id, effective_from) values
  (:'tenant_id', :'campus_id', :'session_id', :'sec', :'phy', :'teach_uid', current_date - 60);

-- Nine Physics chapters; chapter 3 has an Urdu title.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_syllabus(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'phy'::uuid, 'FBISE'::public.board,
  (select jsonb_agg(jsonb_build_object('title', 'Chapter ' || n, 'title_ur', case when n = 3 then 'باب تین' end, 'planned_periods', 6) order by n) from generate_series(1, 9) n));
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, id, 'completed', '2026-09-01', '2026-09-20', 5) from public.syllabus_unit where tenant_id = :'tenant_id' and sequence in (1, 2);
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, id, 'in_progress', '2026-09-21', null, 2) from public.syllabus_unit where tenant_id = :'tenant_id' and sequence = 3;

-- ── AC3: the flag is off by default -> zero rows, not an error ───────────
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*) from public.v_parent_syllabus_coverage), 0::bigint, 'AC3: with parent_syllabus_visibility disabled the query returns zero rows');
select is((select bool_and(not enabled) from public.my_children_syllabus_visibility()), true, 'AC3: and the portal can tell the parent it is not shared');

-- ── the Principal turns it on ─────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.set_campus_feature_flag(%L, 'parent_syllabus_visibility', true) $$, :'campus_id'), 'FORBIDDEN', 'a teacher cannot turn the flag on');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_campus_feature_flag(:'campus_id'::uuid, 'parent_syllabus_visibility', true);
select is((select enabled from public.campus_feature_flag where campus_id = :'campus_id' and flag_key = 'parent_syllabus_visibility'), true, 'the Principal enables parent_syllabus_visibility');

-- ── AC1: nine chapters with covered / pending and completion dates ───────
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*) from public.v_parent_syllabus_coverage where student_id = :'s1'::uuid), 9::bigint, 'AC1: Class 1 Physics lists 9 chapters');
select is((select count(*) from public.v_parent_syllabus_coverage where status = 'covered'), 2::bigint, 'AC1: two are covered');
select is((select count(*) from public.v_parent_syllabus_coverage where status = 'pending'), 7::bigint, 'AC1: seven are pending, including the one still in progress');
select is((select completed_on from public.v_parent_syllabus_coverage where unit_sequence = 1), '2026-09-20'::date, 'AC1: a covered chapter shows its completion date');
select is((select count(*) from public.v_parent_syllabus_coverage where status = 'pending' and completed_on is not null), 0::bigint, 'AC1: pending chapters carry no date');

-- ── AC2: no teacher-identifying or performance columns ───────────────────
select is((select array_agg(column_name::text order by ordinal_position) from information_schema.columns where table_schema = 'public' and table_name = 'v_parent_syllabus_coverage'),
          array['student_id', 'subject_id', 'subject_name_en', 'subject_name_ur', 'unit_sequence', 'title', 'title_ur', 'status', 'completed_on'], 'AC2: the view exposes only chapter, status and completion date columns');
select is((select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'v_parent_syllabus_coverage'
            and column_name in ('periods_used', 'updated_by', 'variance_pct', 'teacher_id')), 0::bigint, 'AC2: periods_used, updated_by, variance_pct and teacher_id are absent');
select is((select count(*) from public.syllabus_coverage), 0::bigint, 'AC2: a parent reading syllabus_coverage directly gets no rows (and so cannot reach periods_used)');
select is((select count(*) from public.syllabus_coverage_history), 0::bigint, 'nor the history');
select ok((select reloptions::text like '%security_invoker=true%' from pg_class where oid = 'public.v_parent_syllabus_coverage'::regclass), 'the view is security_invoker');

-- ── AC4: Urdu title with English fallback data ───────────────────────────
select is((select title_ur from public.v_parent_syllabus_coverage where unit_sequence = 3), 'باب تین', 'AC4: the Urdu title is returned when populated');
select is((select title_ur from public.v_parent_syllabus_coverage where unit_sequence = 4), null, 'AC4: it is null otherwise, so the page falls back to the English title');
select is((select title from public.v_parent_syllabus_coverage where unit_sequence = 4), 'Chapter 4', 'and the English title is always present');

-- ── isolation ────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'parent2_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*) from public.v_parent_syllabus_coverage where student_id = :'s1'::uuid), 0::bigint, 'another family''s parent cannot see this child''s coverage');
select is((select count(*) from public.v_parent_syllabus_coverage where student_id = :'s2'::uuid), 9::bigint, 'but sees their own child''s class');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_campus_feature_flag(:'campus_id'::uuid, 'parent_syllabus_visibility', false);
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*) from public.v_parent_syllabus_coverage), 0::bigint, 'AC3: switching the flag off hides everything again');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.campus_feature_flag), 0::bigint, 'another school sees no flags');

select * from finish();
rollback;
