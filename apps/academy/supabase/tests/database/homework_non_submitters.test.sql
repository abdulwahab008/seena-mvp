-- pgTAP tests for FR-H07: non-submission list and follow-up.
begin;
select plan(21);

select public.provision_tenant('test-hwnon-co', 'Homework Non Submit Co', 'owner@hwnon.test');
select id as tenant_id from public.tenant where slug = 'test-hwnon-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-hwnon-other', 'Other Non Submit Co', 'owner@otherhwnon.test');
select id as other_tenant_id from public.tenant where slug = 'test-hwnon-other' \gset
select set_config('t.campus', :'campus_id', false), set_config('t.section', 'pending', false);

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as teach2_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@hwnon.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@hwnon.test', 'authenticated', 'authenticated', 'x'), (:'teach2_uid', 't2@hwnon.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Homework Teacher'), (:'teach2_uid', :'tenant_id', 'subject_teacher', 'Unrelated Teacher');
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
declare i int; v_s uuid; v_g uuid;
begin
  for i in 1..40 loop
    v_s := public.create_student(current_setting('t.campus')::uuid, 'Pending Kid ' || lpad(i::text, 2, '0'), '2015-01-01'::date, 'male');
    insert into kid values (i, public.enrol_student(current_setting('t.section')::uuid, v_s), v_s);
    if i > 34 then
      v_g := public.fn_find_or_create_guardian(p_name_en => 'Parent ' || i, p_phone_e164 => '+9230099900' || lpad(i::text, 2, '0'));
      perform public.link_guardian(v_s, v_g, 'father'::public.guardian_relationship, true, true);
    end if;
  end loop;
end $$;
reset role;

-- due yesterday: 34 submitted, kid 35 only a draft, kids 36-40 nothing; kid 36 is on approved leave for the whole window
insert into public.homework (tenant_id, campus_id, session_id, section_id, subject_id, teacher_id, title, assigned_date, due_date, status, published_at)
values (:'tenant_id', :'campus_id', :'session_id', :'sec', :'subj', :'teach_uid', 'Chapter 5 questions', current_date - 4, current_date - 1, 'published', now() - interval '4 days') returning id as hw \gset
insert into public.homework_submission (tenant_id, campus_id, session_id, homework_id, enrolment_id, submission_text, status, submitted_at)
select :'tenant_id', :'campus_id', :'session_id', :'hw', enrol_id, 'done', case when n <= 34 then 'submitted' else 'draft' end, case when n <= 34 then now() end from kid where n <= 35;
insert into public.student_leave_application (tenant_id, campus_id, session_id, enrolment_id, applied_by_user_id, applied_via, from_date, to_date, reason_category, status)
values (:'tenant_id', :'campus_id', :'session_id', (select enrol_id from kid where n = 36), :'owner_uid', 'office', current_date - 10, current_date + 3, 'medical', 'approved');
-- kid 37 had leave for only part of the window: not flagged
insert into public.student_leave_application (tenant_id, campus_id, session_id, enrolment_id, applied_by_user_id, applied_via, from_date, to_date, reason_category, status)
values (:'tenant_id', :'campus_id', :'session_id', (select enrol_id from kid where n = 37), :'owner_uid', 'office', current_date - 2, current_date, 'family', 'approved');

-- ── AC1 and AC2: the list ─────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.homework_non_submitters(:'hw'::uuid)), 6::bigint, 'AC1: of 40 enrolled students with 34 submissions, exactly 6 are listed (a draft is not a submission)');
select ok((select bool_and(gr_number is not null) from public.homework_non_submitters(:'hw'::uuid)), 'AC1: each listed with a GR number');
select is((select guardian_phone from public.homework_non_submitters(:'hw'::uuid) where student_name = 'Pending Kid 38'), '+923009990038', 'AC1: and the guardian mobile');
select is((select on_leave from public.homework_non_submitters(:'hw'::uuid) where student_name = 'Pending Kid 36'), true, 'AC2: a student on approved leave for the whole window is flagged');
select is((select on_leave from public.homework_non_submitters(:'hw'::uuid) where student_name = 'Pending Kid 37'), false, 'but not one who was away for part of it');
select set_config('request.jwt.claims', json_build_object('sub', :'teach2_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select * from public.homework_non_submitters(%L) $$, :'hw'), 'FORBIDDEN', 'a teacher who does not teach this cannot see the list or the guardians'' numbers');
select throws_ok(format($$ select public.notify_non_submitters(%L, array[%L]::uuid[]) $$, :'hw', (select enrol_id from kid where n = 38)), 'FORBIDDEN', 'nor notify');

-- ── AC3: dispatch, once per day ───────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.notify_non_submitters(:'hw'::uuid, (select array_agg(enrol_id) from kid where n between 35 and 40)) as run1 \gset
select is((:'run1'::jsonb ->> 'queued')::int, 5, 'the default dispatch queues 5 messages');
select is((:'run1'::jsonb ->> 'on_leave')::int, 1, 'and leaves out the student on leave');
select public.notify_non_submitters(:'hw'::uuid, (select array_agg(enrol_id) from kid where n between 35 and 40)) as run2 \gset
select is((:'run2'::jsonb ->> 'queued')::int, 0, 'AC3: running the dispatch again the same day queues nothing');
select is((:'run2'::jsonb ->> 'duplicates')::int, 5, 'and reports the 5 already notified');
select is((public.notify_non_submitters(:'hw'::uuid, array[(select enrol_id from kid where n = 36)], true) ->> 'queued')::int, 1, 'including the on-leave student explicitly queues the sixth');
reset role;
select is((select count(*) from public.message where tenant_id = :'tenant_id' and idempotency_key like 'hw_missing:%'), 6::bigint, 'AC3: six messages in all');
select ok((select min(scheduled_at) > now() + interval '10 minutes' from public.message where tenant_id = :'tenant_id' and idempotency_key like 'hw_missing:%'), 'they are scheduled after absentee alerts, which queue immediately');
select ok((select body like '%Pending Kid 38%' and body like '%Chapter 5 questions%' from public.message where tenant_id = :'tenant_id' and recipient_phone = '+923009990038' and idempotency_key like 'hw_missing:%'), 'each names the student and the assignment');

-- ── AC4: before the due date it is informational ──────────────────────────
insert into public.homework (tenant_id, campus_id, session_id, section_id, subject_id, teacher_id, title, assigned_date, due_date, status, published_at)
values (:'tenant_id', :'campus_id', :'session_id', :'sec', :'subj', :'teach_uid', 'Not due yet', current_date, current_date + 3, 'published', now()) returning id as hw2 \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.homework_non_submitters(:'hw2'::uuid)), 40::bigint, 'AC4: before the due date everyone is a current non-submitter, listed for information');
select throws_ok(format($$ select public.notify_non_submitters(%L, array[%L]::uuid[]) $$, :'hw2', (select enrol_id from kid where n = 38)), 'NOT_YET_DUE', 'AC4: notifying is refused until the due date has passed');

-- ── daily cap per campus ──────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_homework_notification_cap(7);
reset role;
insert into public.homework (tenant_id, campus_id, session_id, section_id, subject_id, teacher_id, title, assigned_date, due_date, status, published_at)
values (:'tenant_id', :'campus_id', :'session_id', :'sec', :'subj', :'teach_uid', 'Second overdue', current_date - 4, current_date - 1, 'published', now() - interval '4 days') returning id as hw3 \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.notify_non_submitters(%L, (select array_agg(enrol_id) from kid where n between 38 and 40)) $$, :'hw3'), 'DAILY_CAP_REACHED', 'the daily cap for the campus stops a dispatch that would exceed it (6 used of 7, 3 requested)');
select is((select count(*) from public.message where idempotency_key like 'hw_missing:' || :'hw3' || '%'), 0::bigint, 'and queued nothing from it');

-- ── isolation ─────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select throws_ok(format($$ select * from public.homework_non_submitters(%L) $$, :'hw'), 'FORBIDDEN', 'another school cannot list this homework''s students');
select is((select count(*) from public.homework_notification), 0::bigint, 'and sees none of its notifications');

select * from finish();
rollback;
