-- pgTAP tests for FR-H09: syllabus mapping to exam paper generation.
begin;
select plan(25);

select public.provision_tenant('test-paper-co', 'Paper Co', 'owner@paper.test');
select id as tenant_id from public.tenant where slug = 'test-paper-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-paper-other', 'Other Paper Co', 'owner@otherpaper.test');
select id as other_tenant_id from public.tenant where slug = 'test-paper-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@paper.test', 'authenticated', 'authenticated', 'x'), (:'ec_uid', 'e@paper.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@paper.test', 'authenticated', 'authenticated', 'x'), (:'parent_uid', 'pa@paper.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Exam Controller'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Physics Teacher');
insert into public.subject (tenant_id, code, name_en, name_ur) values (:'tenant_id', 'PHY', 'Physics', 'طبیعیات'), (:'tenant_id', 'MTH', 'Maths', 'ریاضی');
select id as phy from public.subject where tenant_id = :'tenant_id' and code = 'PHY' \gset
select id as mth from public.subject where tenant_id = :'tenant_id' and code = 'MTH' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as sec \gset
reset role;
insert into public.section_subject_teacher (tenant_id, campus_id, session_id, section_id, subject_id, staff_id, effective_from) values
  (:'tenant_id', :'campus_id', :'session_id', :'sec', :'phy', :'teach_uid', current_date - 60);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_syllabus(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'phy'::uuid, 'FBISE'::public.board,
  '[{"title":"Motion","topics":[{"title":"Speed"},{"title":"Velocity"}]},{"title":"Force","topics":[{"title":"Newton"}]},{"title":"Energy","topics":[{"title":"Work"}]},{"title":"Heat"},{"title":"Waves","topics":[{"title":"Sound"}]}]'::jsonb);
select public.save_syllabus(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'mth'::uuid, 'FBISE'::public.board, '[{"title":"Algebra"}]'::jsonb);
select array_agg(id order by sequence) as phy_units from public.syllabus_unit where tenant_id = :'tenant_id' and subject_id = :'phy' \gset
select id as u1 from public.syllabus_unit where tenant_id = :'tenant_id' and subject_id = :'phy' and sequence = 1 \gset
select id as u2 from public.syllabus_unit where tenant_id = :'tenant_id' and subject_id = :'phy' and sequence = 2 \gset
select id as u3 from public.syllabus_unit where tenant_id = :'tenant_id' and subject_id = :'phy' and sequence = 3 \gset
select id as u4 from public.syllabus_unit where tenant_id = :'tenant_id' and subject_id = :'phy' and sequence = 4 \gset
select id as u5 from public.syllabus_unit where tenant_id = :'tenant_id' and subject_id = :'phy' and sequence = 5 \gset
select id as alg from public.syllabus_unit where tenant_id = :'tenant_id' and subject_id = :'mth' \gset
select id as t_speed from public.syllabus_topic where tenant_id = :'tenant_id' and title = 'Speed' \gset
select id as t_newton from public.syllabus_topic where tenant_id = :'tenant_id' and title = 'Newton' \gset

-- Units 1-3 completed, 4 in progress, 5 not started.
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, :'u1'::uuid, 'completed');
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, :'u2'::uuid, 'completed');
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, :'u3'::uuid, 'completed');
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, :'u4'::uuid, 'in_progress');
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, :'u5'::uuid, 'not_started');

select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── AC1: an untaught chapter blocks the request ──────────────────────────
select throws_ok(format($$ select public.submit_exam_paper_request(%L::uuid[], 'Term 1 paper') $$, array[:'u1', :'u2', :'u3', :'u4', :'u5']::text),
  '22023', 'Chapter 5 Waves has not been taught yet — remove it or update coverage', 'AC1: unit 5 not_started is rejected with the chapter named');
select is((select count(*) from public.exam_paper_request), 0::bigint, 'AC1: and no request row is created');
select is(public.validate_paper_scope(array[:'u1', :'u5']::uuid[]) -> 'untaught' -> 0 ->> 'sequence', '5', 'validate_paper_scope reports the untaught unit');
select is((public.validate_paper_scope(array[:'u1', :'u2']::uuid[]) ->> 'ok')::boolean, true, 'and is ok when everything has been started');
select is(public.validate_paper_scope(array[:'u5', :'u1']::uuid[], :'sec'::uuid) ->> 'message', 'Chapter 5 Waves has not been taught yet — remove it or update coverage', 'with a section given, that section''s coverage is read');
select throws_ok(format($$ select public.validate_paper_scope(array[%L, %L]::uuid[]) $$, :'u1', :'alg'), 'UNITS_MUST_SHARE_ONE_SYLLABUS', 'units from another subject cannot be mixed in');

-- ── AC2: units 1-4 -> the worker receives exactly those 4 ids ────────────
select public.submit_exam_paper_request(array[:'u4', :'u3', :'u2', :'u1']::uuid[], 'Term 1 paper') as req \gset
select is((select cardinality(scope_unit_ids) from public.exam_paper_request where id = :'req'::uuid), 4, 'AC2: the request stores the 4 unit ids');
select is((select untaught_override from public.exam_paper_request where id = :'req'::uuid), false, 'and no override');
reset role;
select set_config('request.jwt.claims', '', true);
set local role service_role;
select payload as claimed from public.claim_exam_paper_request() \gset
reset role;
select is(jsonb_array_length(:'claimed'::jsonb -> 'metadata_filter' -> 'syllabus_unit_id'), 4, 'AC2: the worker payload carries a 4-unit metadata filter');
select is((select array_agg(x order by x) from jsonb_array_elements_text(:'claimed'::jsonb -> 'metadata_filter' -> 'syllabus_unit_id') x), (select array_agg(u::text order by u::text) from unnest(array[:'u1', :'u2', :'u3', :'u4']::uuid[]) u), 'and they are exactly units 1 to 4');
select is((select status from public.exam_paper_request where id = :'req'::uuid), 'generating', 'claiming marks the request generating');

-- Provenance: only in-scope units may be cited.
set local role service_role;
select throws_ok(format($$ select public.record_generated_paper(%L, jsonb_build_array(jsonb_build_object('question_text', 'What is a wave?', 'syllabus_unit_id', %L))) $$, :'req', :'u5'),
  'QUESTION_OUTSIDE_SCOPE', 'AC2: a question citing unit 5 (outside the scope) is refused');
select throws_ok(format($$ select public.record_generated_paper(%L, jsonb_build_array(jsonb_build_object('question_text', 'Define speed', 'syllabus_unit_id', %L, 'syllabus_topic_id', %L))) $$, :'req', :'u1', :'t_newton'),
  'TOPIC_NOT_IN_UNIT', 'a topic must belong to the cited unit');
select public.record_generated_paper(:'req'::uuid, jsonb_build_array(
  jsonb_build_object('question_text', 'Define speed.', 'marks', 2, 'syllabus_unit_id', :'u1', 'syllabus_topic_id', :'t_speed'),
  jsonb_build_object('question_text', 'State Newton''s first law.', 'marks', 3, 'syllabus_unit_id', :'u2', 'syllabus_topic_id', :'t_newton'),
  jsonb_build_object('question_text', 'What is heat?', 'marks', 2, 'syllabus_unit_id', :'u4'))) as nq \gset
reset role;
select is(:'nq'::int, 3, 'a valid paper of 3 questions is recorded');
select is((select status from public.exam_paper_request where id = :'req'::uuid), 'generated', 'and the request becomes generated');
select is((select count(*) from public.exam_paper_question q where q.paper_request_id = :'req'::uuid
            and q.syllabus_unit_id <> all (array[:'u1', :'u2', :'u3', :'u4']::uuid[])), 0::bigint, 'AC2: the paper''s question provenance references only the requested units');

-- ── AC3: each question shows its unit and topic ──────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select u.sequence || ' ' || u.title || ' / ' || coalesce(t.title, '-') from public.exam_paper_question q join public.syllabus_unit u on u.id = q.syllabus_unit_id
             left join public.syllabus_topic t on t.id = q.syllabus_topic_id where q.paper_request_id = :'req'::uuid and q.sequence = 2), '2 Force / Newton', 'AC3: a question opens with its source unit and topic');

-- ── AC4: override ────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.submit_exam_paper_request(%L::uuid[], 'Teacher override', null, true) $$, array[:'u1', :'u5']::text), 'OVERRIDE_REQUIRES_EXAM_CONTROLLER', 'AC4: a teacher cannot override');
select lives_ok(format($$ select public.submit_exam_paper_request(%L::uuid[], 'Teacher quiz') $$, array[:'u1', :'u2']::text), 'but a teacher can request a paper over taught chapters');
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.submit_exam_paper_request(array[:'u1', :'u5']::uuid[], 'Full syllabus', null, true) as req2 \gset
select is((select untaught_override::text || ':' || (override_by = :'ec_uid'::uuid)::text from public.exam_paper_request where id = :'req2'::uuid), 'true:true', 'AC4: an exam controller''s explicit override proceeds and is recorded with who confirmed it');
select ok((select override_at is not null from public.exam_paper_request where id = :'req2'::uuid), 'with the time');

-- ── many-to-many unit <-> textbook chapter ───────────────────────────────
select public.link_unit_source_chapter(:'u1'::uuid, 'Physics 9', 'Ch 2 Kinematics');
select public.link_unit_source_chapter(:'u2'::uuid, 'Physics 9', 'Ch 2 Kinematics');
select public.link_unit_source_chapter(:'u1'::uuid, 'Physics 9', 'Ch 3 Dynamics');
select is((select count(*) from public.syllabus_unit_source_chapter where tenant_id = :'tenant_id'), 3::bigint, 'one textbook chapter can serve two units and one unit can span two chapters');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.link_unit_source_chapter(%L, 'x', 'y') $$, :'u1'), 'FORBIDDEN', 'a teacher cannot edit the chapter mapping');

-- ── isolation and worker-only functions ──────────────────────────────────
select throws_ok($$ select public.claim_exam_paper_request() $$, '42501', null, 'signed-in users cannot call the worker functions');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.exam_paper_request) + (select count(*) from public.exam_paper_question) + (select count(*) from public.syllabus_unit_source_chapter), 0::bigint, 'another school sees no requests, questions or mappings');

select * from finish();
rollback;
