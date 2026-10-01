-- pgTAP tests for FR-I06: question reuse cooldown.
--
--   AC1  A question used by Class 9 in the First Term, with a cooldown of 4 terms,
--        is flagged "used 1 term ago" in a Class 9 Mid Term draft; the flagged
--        count is the number of rows.
--   AC2  cooldown_mode = 'block' with 3 flagged questions: publication is refused
--        until the questions are replaced or an override reason is recorded.
--   AC3  A question used only for Class 10 raises no flag in a Class 9 draft.
--   AC4  An overridden publication stores the actor and the reason against the paper.
-- Plus: warn is the default, the cooldown window, text normalisation, and the
-- bank never being readable by a parent or a student.
begin;
select plan(36);

select public.provision_tenant('test-cooldown-co', 'Cooldown Co', 'owner@cooldown.test');
select id as tenant_id from public.tenant where slug = 'test-cooldown-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select id as class10 from public.class_level where tenant_id = :'tenant_id' and code = '10' \gset
select public.provision_tenant('test-cooldown-other', 'Other Cooldown Co', 'owner@othercooldown.test');
select id as other_tenant_id from public.tenant where slug = 'test-cooldown-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as student_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@cooldown.test', 'authenticated', 'authenticated', 'x'), (:'ec_uid', 'e@cooldown.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@cooldown.test', 'authenticated', 'authenticated', 'x'), (:'parent_uid', 'p@cooldown.test', 'authenticated', 'authenticated', 'x'),
  (:'student_uid', 's@cooldown.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Exam Controller'),
  (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher'), (:'parent_uid', :'tenant_id', 'parent', 'Parent'), (:'student_uid', :'tenant_id', 'student', 'Student');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_subject('PHY', 'Physics', 'طبیعیات') as s_phy \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_phy', 5::smallint) as cs9 \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class10', :'s_phy', 5::smallint) as cs10 \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T1', 'First Term', 1::smallint, 30.00) as t1 \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T2', 'Mid Term', 2::smallint, 30.00) as t2 \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T3', 'Final Term', 3::smallint, 40.00) as t3 \gset
select public.activate_exam_terms(:'session_id'::uuid, :'campus_id'::uuid) as _a \gset
select public.upsert_exam_subject(:'t1', :'cs9', '[{"component":"theory","max_marks":65,"pass_marks":23}]'::jsonb) as es9_t1 \gset
select public.upsert_exam_subject(:'t2', :'cs9', '[{"component":"theory","max_marks":65,"pass_marks":23}]'::jsonb) as es9_t2 \gset
select public.upsert_exam_subject(:'t3', :'cs9', '[{"component":"theory","max_marks":65,"pass_marks":23}]'::jsonb) as es9_t3 \gset
select public.upsert_exam_subject(:'t1', :'cs10', '[{"component":"theory","max_marks":65,"pass_marks":23}]'::jsonb) as es10_t1 \gset
select public.upsert_exam_subject(:'t2', :'cs10', '[{"component":"theory","max_marks":65,"pass_marks":23}]'::jsonb) as es10_t2 \gset

reset role;
insert into public.board_pattern_ref (tenant_id, code, name, board, total_marks, sections)
values (:'tenant_id', 'P', 'Pattern', 'FBISE', 1, '[{"no":1,"name":"A","type":"mcq","count":1,"marks_each":1}]');
-- A draft paper (job + paper + MCQ items) built directly: this FR is about what happens to a draft, not how it was generated.
create function pg_temp.mkdraft(p_exam_subject uuid, p_texts text[]) returns uuid language plpgsql as $$
declare
  v_es record; v_job uuid; v_paper uuid; i int;
begin
  select tenant_id, campus_id into v_es from public.exam_subject where id = p_exam_subject;
  insert into public.paper_generation_job (tenant_id, campus_id, requested_by, exam_subject_id, board_pattern_id, pattern_snapshot, chapters, total_marks, status)
  values (v_es.tenant_id, v_es.campus_id, (select user_id from public.app_user where app_role = 'exam_controller' and tenant_id = v_es.tenant_id limit 1), p_exam_subject,
          (select id from public.board_pattern_ref where tenant_id = v_es.tenant_id limit 1), '{"sections":[]}', array['Ch.1'], cardinality(p_texts), 'completed') returning id into v_job;
  insert into public.exam_paper (tenant_id, campus_id, job_id, exam_subject_id, title, total_marks, pattern_snapshot, created_by)
  values (v_es.tenant_id, v_es.campus_id, v_job, p_exam_subject, 'Draft', cardinality(p_texts), '{}',
          (select user_id from public.app_user where app_role = 'exam_controller' and tenant_id = v_es.tenant_id limit 1)) returning id into v_paper;
  for i in 1..cardinality(p_texts) loop
    insert into public.exam_paper_item (tenant_id, paper_id, section_no, question_no, question_type, marks, question_text) values (v_es.tenant_id, v_paper, 1, i, 'mcq', 1, p_texts[i]);
  end loop;
  return v_paper;
end $$;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
reset role;
-- First Term: Class 9 sat A1-A5 and B1-B3 (Q-1043 is A1); Class 10 sat C1.
select pg_temp.mkdraft(:'es9_t1'::uuid, array['A1 What is velocity?', 'A2 Define force.', 'A3 State Newton''s first law.', 'A4 What is work?', 'A5 Define power.', 'B1 Unit of energy?', 'B2 Define momentum.', 'B3 What is inertia?']) as p9_t1 \gset
select pg_temp.mkdraft(:'es10_t1'::uuid, array['C1 Define pressure.']) as p10_t1 \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((public.publish_exam_paper(:'p9_t1'::uuid) ->> 'flagged_count')::int, 0, 'the first paper of a class has nothing to be flagged against');
select public.publish_exam_paper(:'p10_t1'::uuid);
select is((select count(*) from public.question_bank_item where tenant_id = :'tenant_id'), 9::bigint, 'publishing puts every question in the bank');
select is((select count(*) from public.question_usage where exam_paper_id = :'p9_t1'::uuid and class_level_id = :'class9'::uuid), 8::bigint, 'and records Class 9''s use of each of the 8');
-- (a published paper's questions are sealed from clients until its exam window opens - FR-I08 - so read the links as the owner of the data)
reset role;
select is((select count(*) from public.exam_paper_item where paper_id = :'p9_t1'::uuid and bank_item_id is not null), 8::bigint, 'the paper''s questions are linked to their bank items');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select status from public.exam_paper where id = :'p9_t1'::uuid), 'published', 'the paper is published');
select throws_ok(format($$ select public.publish_exam_paper(%L) $$, :'p9_t1'), 'PAPER_NOT_DRAFT', 'a published paper cannot be published again');

-- ── AC1 / AC3: a Class 9 Mid Term draft ───────────────────────────────────
reset role;
select pg_temp.mkdraft(:'es9_t2'::uuid, array['a1   what is VELOCITY?', 'A2 Define force.', 'A3 State Newton''s first law.', 'C1 Define pressure.', 'F1 A brand new question.']) as da \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.fn_question_reuse_check(:'da'::uuid)), 3::bigint, 'AC1: three questions are flagged (the total flagged count)');
select is((select count(*) from public.fn_question_reuse_check(:'da'::uuid) where terms_ago = 1 and last_used_term = 'First Term'), 3::bigint, 'AC1: each "used 1 term ago", in the First Term');
select is((select count(*) from public.fn_question_reuse_check(:'da'::uuid) f join public.exam_paper_item i on i.id = f.item_id where i.question_text like 'a1 %'), 1::bigint, 'AC1: a re-typed question (case and spacing differ) is still recognised');
select is((select count(*) from public.fn_question_reuse_check(:'da'::uuid) f join public.exam_paper_item i on i.id = f.item_id where i.question_text like 'C1 %'), 0::bigint, 'AC3: a question used only for Class 10 raises no flag for Class 9');
select is((select count(*) from public.fn_question_reuse_check(:'da'::uuid) f join public.exam_paper_item i on i.id = f.item_id where i.question_text like 'F1 %'), 0::bigint, 'and a new question is not flagged');

-- ── the cooldown window ───────────────────────────────────────────────────
select public.save_exam_settings(:'campus_id'::uuid, '{"question_cooldown_terms":0}'::jsonb);
select is((select count(*) from public.fn_question_reuse_check(:'da'::uuid)), 0::bigint, 'a cooldown of 0 terms flags nothing');
select public.save_exam_settings(:'campus_id'::uuid, '{"question_cooldown_terms":4}'::jsonb);
select is((select count(*) from public.fn_question_reuse_check(:'da'::uuid)), 3::bigint, 'a cooldown of 4 flags the three again');

-- ── warn is the default: a flagged paper publishes ────────────────────────
reset role;
select pg_temp.mkdraft(:'es10_t2'::uuid, array['C1 Define pressure.', 'C2 Define density.']) as d10 \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select cooldown_mode from public.exam_settings where campus_id = :'campus_id'::uuid), 'warn', 'the default mode is warn, not block');
select public.publish_exam_paper(:'d10'::uuid) as warn_result \gset
select is((:'warn_result'::jsonb ->> 'flagged_count')::int, 1, 'warn mode: the one flagged question does not stop publication');
select is((select count(*) from public.paper_publish_override where exam_paper_id = :'d10'::uuid), 0::bigint, 'and needs no override record');

-- ── AC2: block mode ───────────────────────────────────────────────────────
select public.save_exam_settings(:'campus_id'::uuid, '{"cooldown_mode":"block"}'::jsonb);
select throws_ok(format($$ select public.publish_exam_paper(%L) $$, :'da'), 'COOLDOWN_BLOCKED', 'AC2: block mode refuses a paper with 3 flagged questions');
select is((select status from public.exam_paper where id = :'da'::uuid), 'draft', 'AC2: it stays a draft');
select throws_ok(format($$ select public.publish_exam_paper(%L, 'ok') $$, :'da'), 'OVERRIDE_REASON_TOO_SHORT', 'a one-word override reason is not a reason');
select public.replace_paper_question(f.item_id, 'Replacement for ' || f.item_id::text || ' about heat.') from public.fn_question_reuse_check(:'da'::uuid) f;
select is((select count(*) from public.fn_question_reuse_check(:'da'::uuid)), 0::bigint, 'AC2: replacing the flagged questions clears the flags');
select is((public.publish_exam_paper(:'da'::uuid) ->> 'flagged_count')::int, 0, 'AC2: and the paper then publishes in block mode, with no override');
select is((select count(*) from public.paper_publish_override where exam_paper_id = :'da'::uuid), 0::bigint, 'no override is recorded for a clean publish');

-- ── AC2 / AC4: override with a reason ─────────────────────────────────────
reset role;
select pg_temp.mkdraft(:'es9_t3'::uuid, array['B1 Unit of energy?', 'B2 Define momentum.', 'B3 What is inertia?', 'G1 Another new question.']) as db \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.fn_question_reuse_check(:'db'::uuid) where terms_ago = 2), 3::bigint, 'questions used two terms ago are flagged "used 2 terms ago"');
select public.save_exam_settings(:'campus_id'::uuid, '{"question_cooldown_terms":1}'::jsonb);
select is((select count(*) from public.fn_question_reuse_check(:'db'::uuid)), 0::bigint, 'with a cooldown of 1 term a question used two terms ago is free');
select public.save_exam_settings(:'campus_id'::uuid, '{"question_cooldown_terms":4}'::jsonb);
select throws_ok(format($$ select public.publish_exam_paper(%L) $$, :'db'), 'COOLDOWN_BLOCKED', 'block mode refuses the final-term paper too');
select public.publish_exam_paper(:'db'::uuid, 'Board-style questions the HOD wants repeated in the final') as ov \gset
select is((:'ov'::jsonb ->> 'overridden')::boolean, true, 'AC2: with an override reason it publishes');
select is((select overridden_by from public.paper_publish_override where exam_paper_id = :'db'::uuid), :'ec_uid'::uuid, 'AC4: the override actor is stored against the paper');
select is((select reason from public.paper_publish_override where exam_paper_id = :'db'::uuid), 'Board-style questions the HOD wants repeated in the final', 'AC4: and the reason');
select is((select flagged_count from public.paper_publish_override where exam_paper_id = :'db'::uuid), 3, 'AC4: with the number of questions overridden');
select is((select jsonb_array_length(flagged) from public.paper_publish_override where exam_paper_id = :'db'::uuid), 3, 'AC4: and which ones');

-- ── the bank is staff-only ────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok((select count(*) from public.question_bank_item) > 0 and (select count(*) from public.question_usage) > 0, 'a teacher reads the bank and its usage');
select throws_ok(format($$ select public.publish_exam_paper(%L) $$, :'d10'), 'FORBIDDEN', 'a teacher cannot publish');
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.question_bank_item) + (select count(*) from public.question_usage) + (select count(*) from public.paper_publish_override), 0::bigint, 'a parent reads no bank item, usage or override');
select throws_ok(format($$ select * from public.fn_question_reuse_check(%L) $$, :'da'), 'FORBIDDEN', 'and cannot run the check');
select set_config('request.jwt.claims', json_build_object('sub', :'student_uid', 'tenant_id', :'tenant_id', 'app_role', 'student', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.question_bank_item) + (select count(*) from public.question_usage), 0::bigint, 'a student reads nothing from the bank');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.question_bank_item) + (select count(*) from public.question_usage) + (select count(*) from public.paper_publish_override), 0::bigint, 'another school sees none of it');

select * from finish();
rollback;
