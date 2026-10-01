-- pgTAP tests for FR-I08: sealed paper custody and access audit.
--
--   AC1  A paper for a 09:00 slot with a 120-minute release offset: a teacher
--        asking at 06:30 is refused and a 'denied' access record is written.
--   AC2  The same teacher at 07:30 is authorised, and the record captures the
--        user id, role, IP and time. (The route turns "granted" into a 15-minute
--        signed URL.)
--   AC3  The Principal's access log lists every attempt for the paper in time
--        order with its outcome.
--   AC4  Nobody can delete an access record: there is no DELETE grant.
begin;
select plan(45);

select public.provision_tenant('test-sealed-co', 'Sealed Co', 'owner@sealed.test');
select id as tenant_id from public.tenant where slug = 'test-sealed-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select public.provision_tenant('test-sealed-other', 'Other Sealed Co', 'owner@othersealed.test');
select id as other_tenant_id from public.tenant where slug = 'test-sealed-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as outsider_uid \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@sealed.test', 'authenticated', 'authenticated', 'x'), (:'ec_uid', 'e@sealed.test', 'authenticated', 'authenticated', 'x'),
  (:'prin_uid', 'pr@sealed.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@sealed.test', 'authenticated', 'authenticated', 'x'),
  (:'outsider_uid', 'x@sealed.test', 'authenticated', 'authenticated', 'x'), (:'parent_uid', 'pa@sealed.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Rukhsana Bano'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'teach_uid', :'tenant_id', 'subject_teacher', 'Nadia Aslam'), (:'outsider_uid', :'tenant_id', 'subject_teacher', 'Outsider Teacher'), (:'parent_uid', :'tenant_id', 'parent', 'Parent');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_subject('PHY', 'Physics', 'طبیعیات') as s_phy \gset
select public.create_subject('CHE', 'Chemistry', 'کیمیا') as s_che \gset
select public.create_subject('BIO', 'Biology', 'حیاتیات') as s_bio \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_phy', 5::smallint) as cs_phy \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_che', 5::smallint) as cs_che \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_bio', 5::smallint) as cs_bio \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class9'::uuid, 'A', 45) as sec9 \gset
select public.assign_subject_teacher(:'sec9', :'s_phy', :'teach_uid', current_date - 30) as _t \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T1', 'First Term', 1::smallint, 100.00) as t1 \gset
select public.activate_exam_terms(:'session_id'::uuid, :'campus_id'::uuid) as _a \gset
select public.upsert_exam_subject(:'t1', :'cs_phy', '[{"component":"theory","max_marks":65,"pass_marks":23}]'::jsonb) as es_phy \gset
select public.upsert_exam_subject(:'t1', :'cs_che', '[{"component":"theory","max_marks":65,"pass_marks":23}]'::jsonb) as es_che \gset
select public.upsert_exam_subject(:'t1', :'cs_bio', '[{"component":"theory","max_marks":65,"pass_marks":23}]'::jsonb) as es_bio \gset

reset role;
insert into public.board_pattern_ref (tenant_id, code, name, board, total_marks, sections) values (:'tenant_id', 'P', 'Pattern', 'FBISE', 1, '[{"no":1,"name":"A","type":"mcq","count":1,"marks_each":1}]');
create function pg_temp.mkpaper(p_exam_subject uuid, p_status text, p_creator uuid) returns uuid language plpgsql as $$
declare v_es record; v_job uuid; v_paper uuid;
begin
  select tenant_id, campus_id into v_es from public.exam_subject where id = p_exam_subject;
  insert into public.paper_generation_job (tenant_id, campus_id, requested_by, exam_subject_id, board_pattern_id, pattern_snapshot, chapters, total_marks, status)
  values (v_es.tenant_id, v_es.campus_id, p_creator, p_exam_subject, (select id from public.board_pattern_ref where tenant_id = v_es.tenant_id limit 1), '{"sections":[]}', array['Ch.1'], 2, 'completed') returning id into v_job;
  insert into public.exam_paper (tenant_id, campus_id, job_id, exam_subject_id, title, total_marks, pattern_snapshot, created_by, status)
  values (v_es.tenant_id, v_es.campus_id, v_job, p_exam_subject, 'Paper', 2, '{}', p_creator, p_status) returning id into v_paper;
  insert into public.exam_paper_item (tenant_id, paper_id, section_no, question_no, question_type, marks, question_text)
  values (v_es.tenant_id, v_paper, 1, 1, 'mcq', 1, 'Secret question one'), (v_es.tenant_id, v_paper, 1, 2, 'mcq', 1, 'Secret question two');
  return v_paper;
end $$;
select pg_temp.mkpaper(:'es_phy'::uuid, 'published', :'ec_uid'::uuid) as paper \gset
select pg_temp.mkpaper(:'es_che'::uuid, 'published', :'ec_uid'::uuid) as paper_noslot \gset
-- A 09:00 paper whose slot is 150 minutes away: the 120-minute window opens in 30 minutes ("06:30").
insert into public.datesheet (tenant_id, campus_id, session_id, exam_term_id, title) values (:'tenant_id', :'campus_id', :'session_id', :'t1', 'DS');
insert into public.datesheet_slot (tenant_id, campus_id, datesheet_id, exam_subject_id, start_at, end_at)
select :'tenant_id', :'campus_id', d.id, :'es_phy', now() + interval '150 minutes', now() + interval '270 minutes' from public.datesheet d where d.tenant_id = :'tenant_id';

-- ── AC1: 06:30, refused and recorded ──────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.fn_request_paper_access(:'paper'::uuid, 'paper', '203.0.113.7') as r1 \gset
select is((:'r1'::jsonb ->> 'granted')::boolean, false, 'AC1: the teacher is refused before the release window');
select is(:'r1'::jsonb ->> 'reason', 'sealed', 'AC1: because the paper is sealed');
select ok((:'r1'::jsonb ->> 'path') is null, 'AC1: and no storage path is revealed');
select ok((:'r1'::jsonb ->> 'release_at') is not null, 'AC1: the answer says when it releases');
select is((select count(*) from public.exam_paper_access where exam_paper_id = :'paper'::uuid and outcome = 'denied'), 0::bigint, 'a teacher cannot read the access table directly');
reset role;
select is((select count(*) from public.exam_paper_access where exam_paper_id = :'paper'::uuid and outcome = 'denied' and reason = 'sealed' and user_id = :'teach_uid'::uuid), 1::bigint, 'AC1: an access record with outcome denied was written');

-- ── AC2: 07:30, authorised and recorded ───────────────────────────────────
update public.datesheet_slot set start_at = now() + interval '90 minutes', end_at = now() + interval '210 minutes' where exam_subject_id = :'es_phy'::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.fn_request_paper_access(:'paper'::uuid, 'key', '203.0.113.7') as r2 \gset
select is((:'r2'::jsonb ->> 'granted')::boolean, true, 'AC2: inside the window the same teacher is authorised');
select is(:'r2'::jsonb ->> 'path', :'tenant_id' || '/' || :'es_phy' || '/key-A.pdf', 'AC2: with the path of THIS paper''s own key');
reset role;
select is((select user_role from public.exam_paper_access where exam_paper_id = :'paper'::uuid and outcome = 'granted'), 'subject_teacher', 'AC2: the record captures the role');
select is((select user_id from public.exam_paper_access where exam_paper_id = :'paper'::uuid and outcome = 'granted'), :'teach_uid'::uuid, 'AC2: the user id');
select is((select host(ip) from public.exam_paper_access where exam_paper_id = :'paper'::uuid and outcome = 'granted'), '203.0.113.7', 'AC2: the IP');
select ok((select accessed_at > now() - interval '1 minute' from public.exam_paper_access where exam_paper_id = :'paper'::uuid and outcome = 'granted'), 'AC2: and the time');
select is((select kind from public.exam_paper_access where exam_paper_id = :'paper'::uuid and outcome = 'granted'), 'key', 'and which file was asked for');

-- ── who else, and the sealed questions ────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'outsider_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.fn_request_paper_access(:'paper'::uuid) ->> 'reason', 'role_not_allowed', 'a teacher who does not teach the subject is denied even inside the window');
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select is((public.fn_request_paper_access(:'paper'::uuid) ->> 'granted')::boolean, false, 'a parent is denied (and recorded)');
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.exam_paper_item where paper_id = :'paper'::uuid), 2::bigint, 'inside the window the exam controller can read the published paper''s questions');
select is((public.fn_request_paper_access(:'paper'::uuid) ->> 'reason'), 'window_open', 'and obtain its file');
reset role;
update public.datesheet_slot set start_at = now() + interval '150 minutes', end_at = now() + interval '270 minutes' where exam_subject_id = :'es_phy'::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.exam_paper_item where paper_id = :'paper'::uuid), 0::bigint, 'before the window the questions of a published paper are sealed even from the exam controller who created it');
select is(public.fn_request_paper_access(:'paper'::uuid) ->> 'reason', 'sealed', 'and so is the file');
select public.save_exam_settings(:'campus_id'::uuid, '{"paper_release_offset_minutes":240}'::jsonb);
select is(public.fn_request_paper_access(:'paper'::uuid) ->> 'reason', 'window_open', 'a longer release offset (240 minutes) opens the same paper sooner');
select is((select count(*) from public.exam_paper_item where paper_id = :'paper'::uuid), 2::bigint, 'and unseals its questions');
select public.save_exam_settings(:'campus_id'::uuid, '{"paper_release_offset_minutes":120}'::jsonb);
select is(public.fn_request_paper_access(:'paper_noslot'::uuid) ->> 'reason', 'no_exam_slot', 'a paper whose exam is not scheduled never releases');
select throws_ok(format($$ select public.fn_request_paper_access(%L, 'solution') $$, :'paper'), 'KIND_INVALID', 'only the paper or its key can be requested');

-- a draft stays with its requester and the exam office
reset role;
select pg_temp.mkpaper(:'es_bio'::uuid, 'draft', :'teach_uid'::uuid) as paper_draft \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.fn_request_paper_access(:'paper_draft'::uuid) ->> 'reason', 'draft', 'a draft is available to its requester at any time');
select is((select count(*) from public.exam_paper_item where paper_id = :'paper_draft'::uuid), 2::bigint, 'and readable by them');
select set_config('request.jwt.claims', json_build_object('sub', :'outsider_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.fn_request_paper_access(:'paper_draft'::uuid) ->> 'reason', 'role_not_allowed', 'but not by another teacher');

-- ── AC3: the principal''s log ─────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.fn_paper_access_log(:'paper'::uuid)), 7::bigint, 'AC3: the Principal sees every attempt for the paper (7)');
select is((select array_agg(outcome order by accessed_at) from public.fn_paper_access_log(:'paper'::uuid)), array['denied', 'granted', 'denied', 'denied', 'granted', 'denied', 'granted'], 'AC3: in time order with each outcome');
select is((select user_name from public.fn_paper_access_log(:'paper'::uuid) order by accessed_at limit 1), 'Nadia Aslam', 'AC3: naming the person');
select ok((select bool_and(accessed_at <= lead_at) from (select accessed_at, lead(accessed_at, 1, 'infinity') over (order by accessed_at, id) as lead_at from (select a.accessed_at, a.id from public.exam_paper_access a where a.exam_paper_id = :'paper'::uuid) q) z), 'AC3: strictly oldest first');
select is((select count(*) from public.exam_paper_access where exam_paper_id = :'paper'::uuid), 7::bigint, 'the Principal can also read the table directly');

-- ── AC4: append-only by revoked grants ────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ delete from public.exam_paper_access $$, '42501', null, 'AC4: an exam controller''s DELETE is rejected');
select throws_ok($$ update public.exam_paper_access set outcome = 'granted' $$, '42501', null, 'AC4: and so is an UPDATE (a denial cannot be rewritten as a grant)');
select throws_ok(format($$ insert into public.exam_paper_access (tenant_id, campus_id, exam_paper_id, user_id, user_role, kind, outcome, reason) values (%L, %L, %L, %L, 'x', 'paper', 'granted', 'forged') $$, :'tenant_id', :'campus_id', :'paper', :'ec_uid'), '42501', null, 'a client cannot insert a record either: only the access function writes them');
reset role;
select ok(not has_table_privilege('authenticated', 'public.exam_paper_access', 'DELETE'), 'AC4: no DELETE grant exists for authenticated');
select ok(not has_table_privilege('authenticated', 'public.exam_paper_access', 'UPDATE'), 'AC4: no UPDATE grant');
select ok(not has_table_privilege('authenticated', 'public.exam_paper_access', 'TRUNCATE'), 'AC4: no TRUNCATE grant');
select ok(not has_table_privilege('service_role', 'public.exam_paper_access', 'DELETE') and not has_table_privilege('service_role', 'public.exam_paper_access', 'UPDATE'), 'AC4: nor for service_role (revoked grants bind it; an RLS policy would not)');
set local role service_role;
select throws_ok($$ delete from public.exam_paper_access $$, '42501', null, 'AC4: a service-role delete is refused');
reset role;
select throws_ok($$ delete from public.exam_paper_access $$, '42501', 'the paper access log is append-only', 'even the table owner is stopped by the trigger');

-- ── the bucket, the ip, tenants ───────────────────────────────────────────
select is((select public from storage.buckets where id = 'exam-papers'), false, 'the exam-papers bucket is private');
select is((select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' and (qual like '%exam-papers%' or with_check like '%exam-papers%')), 0::bigint, 'with no policy on it at all: no direct client read');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.fn_request_paper_access(:'paper_draft'::uuid, 'paper', 'not-an-ip') as _x \gset
reset role;
select is((select ip from public.exam_paper_access order by accessed_at desc limit 1), null, 'a junk IP header is stored as "not recorded", never as a lie');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select throws_ok(format($$ select public.fn_request_paper_access(%L) $$, :'paper'), 'PAPER_NOT_FOUND', 'another school cannot ask for this paper (and writes no record)');
select is((select count(*) from public.exam_paper_access), 0::bigint, 'another school reads no access record');

select * from finish();
rollback;
