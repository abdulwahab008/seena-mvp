begin;
select plan(16);

select public.provision_tenant('test-results-extra', 'Results Extra Co', 'owner@resultsextra.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class_id from public.class_level where tenant_id = :'tenant_id' and code = '5' \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
values (:'tenant_id', :'campus_id', :'session_id', :'class_id', '5-A', 30) returning id as section_id \gset
insert into public.exam_term (tenant_id, campus_id, session_id, code, name, sequence)
values (:'tenant_id', :'campus_id', :'session_id', 'MID', 'Mid Term', 1) returning id as term_id \gset
insert into public.subject (tenant_id, code, name_en) values (:'tenant_id', 'MATH', 'Mathematics') returning id as subject_id \gset
insert into public.class_subject (tenant_id, campus_id, session_id, class_level_id, subject_id, weekly_periods)
values (:'tenant_id', :'campus_id', :'session_id', :'class_id', :'subject_id', 5) returning id as class_subject_id \gset
insert into public.exam_subject (tenant_id, campus_id, exam_term_id, class_subject_id)
values (:'tenant_id', :'campus_id', :'term_id', :'class_subject_id') returning id as exam_subject_id \gset

-- Three students: Ayesha passes, Bilal fails maths, Hina's result is withheld for fees.
create temp table kid (name text primary key, student_id uuid, enrol_id uuid, phone text);
insert into kid (name, phone) values ('Ayesha', '+923001111111'), ('Bilal', '+923002222222'), ('Hina', '+923003333333');
update kid set student_id = gen_random_uuid(), enrol_id = gen_random_uuid();
insert into public.student (id, tenant_id, campus_id, gr_number, name_en, dob, gender, status)
select student_id, :'tenant_id', :'campus_id', 'GR-' || name, name, '2015-01-01', 'female', 'active' from kid;
insert into public.enrolment (id, tenant_id, campus_id, session_id, class_level_id, section_id, student_id, status)
select enrol_id, :'tenant_id', :'campus_id', :'session_id', :'class_id', :'section_id', student_id, 'active' from kid;
with g as (
  insert into public.guardian (tenant_id, name_en, phone_e164) select :'tenant_id', 'Parent of ' || name, phone from kid returning id, phone_e164
)
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_academic, receives_billing)
select :'tenant_id', k.student_id, g.id, 'mother', true, true, true from kid k join g on g.phone_e164 = k.phone;
insert into public.subject_result (tenant_id, campus_id, exam_term_id, section_id, exam_subject_id, enrolment_id, subject_id, obtained, max_marks, is_pass, is_blocked)
select :'tenant_id', :'campus_id', :'term_id', :'section_id', :'exam_subject_id', enrol_id, :'subject_id',
       case name when 'Ayesha' then 92 when 'Bilal' then 20 else 70 end, 100, name <> 'Bilal', name = 'Hina' from kid;
insert into public.result_position (tenant_id, campus_id, exam_term_id, class_level_id, section_id, enrolment_id,
  total_obtained, total_max, rank_in_section, rank_in_class, ranked_out_of, ranked_out_of_class, is_ranked, exclusion_reason, rank_policy)
select :'tenant_id', :'campus_id', :'term_id', :'class_id', :'section_id', enrol_id,
       case name when 'Ayesha' then 92 when 'Bilal' then 20 else 70 end, 100,
       case name when 'Ayesha' then 1 when 'Bilal' then 2 end, case name when 'Ayesha' then 1 when 'Bilal' then 2 end,
       case when name <> 'Hina' then 2 end, case when name <> 'Hina' then 2 end, name <> 'Hina', case when name = 'Hina' then 'withheld' end, 'include_all'
  from kid;
select enrol_id as ayesha from kid where name = 'Ayesha' \gset
select enrol_id as bilal from kid where name = 'Bilal' \gset
select student_id as bilal_student from kid where name = 'Bilal' \gset

select gen_random_uuid() as uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'uid', 'exams@resultsextra.test', 'authenticated', 'authenticated', 'x');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- Results by SMS.
select is(public.queue_result_messages(:'term_id', :'section_id'), '{"queued": 2, "no_phone": 0}'::jsonb, 'one message per student, none for a withheld result');
reset role;
select is((select body from public.message where idempotency_key = 'result:' || :'term_id' || ':' || :'ayesha'),
  'Assalam o Alaikum. Ayesha''s Mid Term result: 92/100 (92.0%), position 1 of 2.', 'the message gives marks, percentage and position');
select matches((select body from public.message where idempotency_key = 'result:' || :'term_id' || ':' || :'bilal'),
  'needs to improve in 1 subject\.$', 'and names how many subjects need work');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((public.queue_result_messages(:'term_id', :'section_id') ->> 'queued')::int, 0, 'sending again queues nothing twice');

-- Re-checks.
select public.request_result_recheck(:'term_id', :'bilal', :'subject_id', 50000, 'Parent says question 4 was not marked') as recheck_id \gset
select is((select marks_before from public.result_recheck where id = :'recheck_id'), 20.00, 'the request records the marks at the time');
select throws_ok(format($$ select public.request_result_recheck(%L, %L, %L, 0, 'again') $$, :'term_id', :'bilal', :'subject_id'),
  '23505', null, 'one open re-check per subject');
select throws_ok(format($$ select public.decide_result_recheck(%L, true, null, 'x') $$, :'recheck_id'), '22023', 'MARKS_REQUIRED', 'a changed outcome needs the new marks');
select public.decide_result_recheck(:'recheck_id', true, 34, 'Question 4 marked: +14');
select is((select status || ' ' || marks_after from public.result_recheck where id = :'recheck_id'), 'changed 34.00', 'the outcome is recorded');
select throws_ok(format($$ select public.decide_result_recheck(%L, false, null, null) $$, :'recheck_id'), '55000', 'RECHECK_DECIDED', 'a decided re-check is final');

-- External (board) results.
select public.save_external_result(:'bilal_student', 'BISE Lahore', 'SSC Part I', 2026, '123456', 410, 550, 'B');
select public.save_external_result(:'bilal_student', 'BISE Lahore', 'SSC Part I', 2026, '123456', 415, 550, 'B');
select is((select count(*)::int || ' ' || max(obtained) from public.external_result), '1 415.00', 're-entering a board result corrects it');
select throws_ok(format($$ select public.save_external_result(%L, 'BISE', 'SSC', 2026, '1', 600, 550, null) $$, :'bilal_student'),
  '23514', null, 'marks cannot exceed the total');

-- Behaviour ratings.
select public.ensure_behaviour_traits();
select is((select count(*)::int from public.behaviour_trait), 5, 'standard traits are added once');
select public.ensure_behaviour_traits();
select id as punctuality from public.behaviour_trait where name = 'Punctuality' \gset
select is(public.save_behaviour_ratings(:'term_id', jsonb_build_array(jsonb_build_object('enrolment_id', :'ayesha', 'trait_id', :'punctuality', 'rating', 'A'))), 1, 'a rating is saved');
select public.save_behaviour_ratings(:'term_id', jsonb_build_array(jsonb_build_object('enrolment_id', :'ayesha', 'trait_id', :'punctuality', 'rating', '')));
select is((select count(*)::int from public.behaviour_rating), 0, 'an empty rating clears it');

-- Permissions.
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.queue_result_messages(%L, %L) $$, :'term_id', :'section_id'), '42501', 'FORBIDDEN', 'a subject teacher cannot send results');
select is((select count(*)::int from public.result_recheck), 0, 'or read the re-check register');

select * from finish();
rollback;
