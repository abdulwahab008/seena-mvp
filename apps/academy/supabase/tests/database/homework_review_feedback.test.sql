-- pgTAP tests for FR-H06: teacher review and feedback on submissions.
begin;
select plan(28);

select public.provision_tenant('test-hwrev-co', 'Homework Review Co', 'owner@hwrev.test');
select id as tenant_id from public.tenant where slug = 'test-hwrev-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-hwrev-other', 'Other Review Co', 'owner@otherhwrev.test');
select id as other_tenant_id from public.tenant where slug = 'test-hwrev-other' \gset
select set_config('t.campus', :'campus_id', false), set_config('t.section', 'pending', false);

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as teach2_uid \gset
select gen_random_uuid() as teach3_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@hwrev.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@hwrev.test', 'authenticated', 'authenticated', 'x'),
  (:'teach2_uid', 't2@hwrev.test', 'authenticated', 'authenticated', 'x'), (:'teach3_uid', 't3@hwrev.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Author Teacher'),
  (:'teach2_uid', :'tenant_id', 'subject_teacher', 'Colleague Teacher'), (:'teach3_uid', :'tenant_id', 'subject_teacher', 'Unrelated Teacher');
insert into public.subject (tenant_id, code, name_en, name_ur) values (:'tenant_id', 'SCI', 'Science', 'سائنس');
select id as subj from public.subject where tenant_id = :'tenant_id' and code = 'SCI' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 60) as sec \gset
select set_config('t.section', :'sec', false);
create temp table kid (n int primary key, enrol_id uuid, student_id uuid);
grant all on kid to authenticated;
do $$
declare i int; v_s uuid;
begin
  for i in 1..42 loop
    v_s := public.create_student(current_setting('t.campus')::uuid, 'Review Kid ' || i, '2015-01-01'::date, 'male');
    insert into kid values (i, public.enrol_student(current_setting('t.section')::uuid, v_s), v_s);
  end loop;
end $$;
select public.fn_find_or_create_guardian(p_name_en => 'Review Father', p_phone_e164 => '+923003330001') as g1 \gset
select public.link_guardian((select student_id from kid where n = 1), :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
reset role;
select gen_random_uuid() as par1 \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role) values (:'par1', '923003330001', now(), 'x', 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'par1' where id = :'g1'::uuid;
insert into public.section_subject_teacher (tenant_id, campus_id, session_id, section_id, subject_id, staff_id, effective_from)
values (:'tenant_id', :'campus_id', :'session_id', :'sec', :'subj', :'teach2_uid', current_date - 30);
insert into public.homework (tenant_id, campus_id, session_id, section_id, subject_id, teacher_id, title, due_date, status, published_at, max_score)
values (:'tenant_id', :'campus_id', :'session_id', :'sec', :'subj', :'teach_uid', 'Review me', current_date + 2, 'published', now(), 10) returning id as hw \gset
-- 41 submitted submissions (kids 1..41) and one draft (kid 42)
insert into public.homework_submission (tenant_id, campus_id, session_id, homework_id, enrolment_id, submission_text, status, submitted_at)
select :'tenant_id', :'campus_id', :'session_id', :'hw', enrol_id, 'work ' || n, case when n <= 41 then 'submitted' else 'draft' end, case when n <= 41 then now() end from kid;
select id as sub1 from public.homework_submission where enrolment_id = (select enrol_id from kid where n = 1) \gset
select id as sub42 from public.homework_submission where enrolment_id = (select enrol_id from kid where n = 42) \gset

-- ── AC1: score against max_score ──────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.check_submission(%L, 'good', 'ok', 11) $$, :'sub1'), 'SCORE_EXCEEDS_MAX', 'AC1: a score of 11 against a maximum of 10 is rejected');
select throws_ok(format($$ select public.check_submission(%L, 'good', 'ok', -1) $$, :'sub1'), 'SCORE_NEGATIVE', 'a negative score is rejected');
select throws_ok(format($$ select public.check_submission(%L, null, 'ok') $$, :'sub1'), 'FEEDBACK_REQUIRED', 'a feedback code is mandatory');
select throws_ok(format($$ select public.check_submission(%L, 'brilliant', 'ok') $$, :'sub1'), 'FEEDBACK_REQUIRED', 'and must be one of the five');
select throws_ok(format($$ select public.check_submission(%L, 'good', %L) $$, :'sub1', repeat('x', 501)), 'REMARK_TOO_LONG', 'the remark is capped at 500 characters');
select throws_ok(format($$ select public.check_submission(%L, 'good') $$, :'sub42'), 'SUBMISSION_NOT_SUBMITTED', 'a draft that was never submitted cannot be checked');
select is((select count(*) from public.homework_submission where status = 'checked'), 0::bigint, 'nothing was checked by the failed attempts');
select public.check_submission(:'sub1'::uuid, 'good', 'Neat work', 8);
select is((select score from public.homework_submission where id = :'sub1'::uuid), 8.00, 'a valid score within the maximum is saved');

-- ── AC2: a colleague on the same section and subject ──────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach2_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.check_submission((select id from public.homework_submission where enrolment_id = (select enrol_id from kid where n = 2)), 'excellent', 'Top marks');
select is((select checked_by from public.homework_submission where enrolment_id = (select enrol_id from kid where n = 2)), :'teach2_uid'::uuid, 'AC2: checked_by records the colleague');
select isnt((select checked_by from public.homework_submission where enrolment_id = (select enrol_id from kid where n = 2)), (select teacher_id from public.homework where id = :'hw'::uuid), 'distinct from the assignment''s own teacher');
select set_config('request.jwt.claims', json_build_object('sub', :'teach3_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.check_submission(%L, 'good') $$, :'sub1'), 'FORBIDDEN', 'a teacher not assigned to this section and subject cannot check');
select is((select count(*) from public.homework_submission), 0::bigint, 'and cannot even see its submissions');
select throws_ok(format($$ select public.set_homework_max_score(%L, 20) $$, :'hw'), 'FORBIDDEN', 'nor change its maximum score');

-- ── AC5: editing a checked submission keeps the history ───────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.check_submission(:'sub1'::uuid, 'satisfactory', 'Improve handwriting', 6);
select is((select feedback_remark from public.homework_submission where id = :'sub1'::uuid), 'Improve handwriting', 'AC5: the remark can be edited after checking');
select is((select feedback_remark || '/' || feedback_code || '/' || score::text from public.homework_feedback_history where submission_id = :'sub1'::uuid), 'Neat work/good/8.00', 'AC5: the previous feedback is retained in history');
select is((select count(*) from public.homework_feedback_history where submission_id = (select id from public.homework_submission where enrolment_id = (select enrol_id from kid where n = 2))), 0::bigint, 'a first check leaves no history');

-- ── AC4: bulk check ───────────────────────────────────────────────────────
select public.bulk_check_submissions(:'hw'::uuid, (select array_agg(id) from public.homework_submission where status = 'submitted'), 'good', 'Well done') as bulked \gset
select is(:'bulked'::int, 39, 'AC4: every remaining submitted submission is updated in one call');
reset role;
select is((select count(*) from public.homework_submission where homework_id = :'hw'::uuid and status = 'checked' and checked_by = :'teach_uid'::uuid and checked_at is not null), 40::bigint, 'AC4: each records checked_by and checked_at (39 bulk plus the one checked by hand)');
select is((select count(*) from public.homework_submission where homework_id = :'hw'::uuid and status = 'draft'), 1::bigint, 'the draft is left alone');
select is((select score from public.homework_submission where id = :'sub1'::uuid), 6.00, 'a bulk check keeps scores entered by hand');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.bulk_check_submissions(%L, '{}'::uuid[], 'good') $$, :'hw'), 'SUBMISSIONS_MUST_BE_1_TO_300', 'an empty selection is refused');
select public.bulk_check_submissions(:'hw'::uuid, array[:'sub1'::uuid], 'needs_improvement', 'Redo page 3');
select is((select count(*) from public.homework_feedback_history where submission_id = :'sub1'::uuid), 2::bigint, 're-checking in bulk also keeps the earlier feedback');

-- ── max score management ──────────────────────────────────────────────────
select throws_ok(format($$ select public.set_homework_max_score(%L, 5) $$, :'hw'), 'EXISTING_SCORE_EXCEEDS_MAX', 'the maximum cannot be lowered below a score already given');
select public.set_homework_max_score(:'hw'::uuid, null);
select throws_ok(format($$ select public.check_submission(%L, 'good', null, 3) $$, :'sub1'), 'SCORE_NOT_ENABLED', 'with no maximum set, scores are not accepted');

-- ── what the parent sees, and cannot change ───────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'par1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select feedback_code || '/' || feedback_remark from public.homework_submission where id = :'sub1'::uuid), 'needs_improvement/Redo page 3', 'the parent sees the badge and remark');
update public.homework_submission set feedback_code = 'excellent' where id = :'sub1'::uuid;
select is((select feedback_code from public.homework_submission where id = :'sub1'::uuid), 'needs_improvement', 'and cannot change the feedback');
select is((select count(*) from public.homework_feedback_history), 2::bigint, 'the parent can see the history of their own child''s submission');
reset role;
select is((select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'homework_submission'), 1::bigint, 'AC3: submissions are published to realtime so the student''s page updates at once');

select * from finish();
rollback;
