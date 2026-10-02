-- pgTAP tests for FR-G17: attendance-linked fee concession eligibility feed.
begin;
select plan(28);

select public.provision_tenant('test-eligibility-co', 'Eligibility Co', 'owner@eligibility.test');
select id as tenant_id from public.tenant where slug = 'test-eligibility-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@eligibility.test', 'authenticated', 'authenticated', 'x'), (:'acct_uid', 'a@eligibility.test', 'authenticated', 'authenticated', 'x'),
  (:'prin_uid', 'p@eligibility.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@eligibility.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'acct_uid', :'tenant_id', 'accountant', 'Accountant'),
  (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 850000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.create_concession_scheme('MERIT', 'Merit Scholarship', 'میرٹ', 'percentage', 50, array[:'tuition_id']::uuid[], 'merit') as scheme_id \gset
select public.create_student(:'campus_id'::uuid, 'Merit A', '2015-01-01'::date, 'male') as sa \gset
select public.enrol_student(:'section_id'::uuid, :'sa'::uuid) as ea \gset
select public.create_student(:'campus_id'::uuid, 'Merit B', '2015-01-02'::date, 'female') as sb \gset
select public.enrol_student(:'section_id'::uuid, :'sb'::uuid) as eb \gset
select public.create_student(:'campus_id'::uuid, 'Merit C', '2015-01-03'::date, 'male') as sc \gset
select public.enrol_student(:'section_id'::uuid, :'sc'::uuid) as ec \gset
select public.create_student(:'campus_id'::uuid, 'Merit D', '2015-01-04'::date, 'female') as sd \gset
select public.enrol_student(:'section_id'::uuid, :'sd'::uuid) as ed \gset

select throws_ok(format($$ select public.set_scheme_min_attendance(%L, 120) $$, :'scheme_id'), 'PERCENTAGE_OUT_OF_RANGE', 'a threshold above 100% is refused');
select public.set_scheme_min_attendance(:'scheme_id'::uuid, 90);
select public.request_concession_award(e, :'scheme_id'::uuid, 50, date_trunc('month', current_date)::date, (date_trunc('month', current_date) + interval '6 months')::date)
  from (values (:'ea'::uuid), (:'eb'::uuid), (:'ec'::uuid), (:'ed'::uuid)) v(e);
reset role;
select id as award_a from public.concession_award where enrolment_id = :'ea'::uuid \gset
select id as award_b from public.concession_award where enrolment_id = :'eb'::uuid \gset
select id as award_c from public.concession_award where enrolment_id = :'ec'::uuid \gset
select id as award_d from public.concession_award where enrolment_id = :'ed'::uuid \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.decide_concession_award(id, true) from public.concession_award where tenant_id = :'tenant_id';
reset role;

-- last month's attendance summaries (the month that is complete when this month's challan is cut)
select extract(year from (date_trunc('month', current_date) - interval '1 month'))::int as py, extract(month from (date_trunc('month', current_date) - interval '1 month'))::int as pm \gset
select extract(year from current_date)::int as cy, extract(month from current_date)::int as cm \gset
insert into public.attendance_month_summary (tenant_id, campus_id, session_id, enrolment_id, year, month, working_days, present_days, absent_days, late_count, half_day_count, leave_days, attendance_pct, computed_at)
select :'tenant_id', :'campus_id', :'session_id', e, :'py'::int, :'pm'::int, 26, 24, 2, 0, 0, 0, pct, now()
  from (values (:'ea'::uuid, 89.99::numeric), (:'eb'::uuid, 90.00::numeric), (:'ec'::uuid, 87.40::numeric)) v(e, pct);

-- ── AC1 ───────────────────────────────────────────────────────────────────
select app.fn_reevaluate_eligibility(:'campus_id'::uuid, :'cy'::int, :'cm'::int) as ev \gset
select is((:'ev'::jsonb ->> 'evaluated')::int, 4, 'every approved threshold award is evaluated');
select is((select eligible from public.attendance_eligibility_flag where award_id = :'award_a'::uuid), false, 'AC1: 89.99% against 90% is not eligible');
select is((select reason_code from public.attendance_eligibility_flag where award_id = :'award_a'::uuid), 'below_threshold', 'AC1: with reason below_threshold');
select is((select eligible from public.attendance_eligibility_flag where award_id = :'award_b'::uuid), true, '90.00% meets a 90% threshold');
select is((select reason_code from public.attendance_eligibility_flag where award_id = :'award_d'::uuid), 'no_attendance_data', 'a student with no attendance data is not penalised');
select is((select eligible from public.attendance_eligibility_flag where award_id = :'award_d'::uuid), true, 'and stays eligible');

-- ── AC2: challan omits the concession and carries the note ────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, date_trunc('month', current_date)::date, false);
reset role;
select is((select concession_paisa from public.fee_challan where enrolment_id = :'ea'::uuid), 0::bigint, 'AC2: the ineligible student''s concession line is omitted');
select is((select concession_paisa from public.fee_challan where enrolment_id = :'eb'::uuid), 425000::bigint, 'an eligible student keeps the 50% concession');
select is((select concession_paisa from public.fee_challan where enrolment_id = :'ed'::uuid), 425000::bigint, 'and so does one with no attendance data');
select is((select note from public.fee_challan where enrolment_id = :'ec'::uuid), 'Merit concession withheld: attendance 87.4% below required 90%', 'AC2: the challan carries the withheld note');
select is((select note from public.fee_challan where enrolment_id = :'eb'::uuid), null, 'an eligible challan carries no note');
select is((select count(*) from public.attendance_eligibility_flag where award_id = :'award_c'::uuid), 1::bigint, 'the flag the challan used is on record');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(app.fn_challan_payload((select id from public.fee_challan where enrolment_id = :'ec'::uuid)) ->> 'note', 'Merit concession withheld: attendance 87.4% below required 90%', 'the printed challan carries the note');

-- ── AC3: a later correction opens a task, never touches the challan ───────
select net_paisa as net_before from public.fee_challan where enrolment_id = :'ea'::uuid \gset
select id as chal_a from public.fee_challan where enrolment_id = :'ea'::uuid \gset
update public.attendance_month_summary set attendance_pct = 90.20 where enrolment_id = :'ea'::uuid and year = :'py'::int and month = :'pm'::int;
select app.fn_reevaluate_eligibility(:'campus_id'::uuid, :'cy'::int, :'cm'::int) as ev2 \gset
select is((:'ev2'::jsonb ->> 'tasks')::int, 1, 'AC3: raising attendance to 90.2% after the challan was issued opens one adjustment task');
select is((select old_flag::text || '>' || new_flag::text || '/' || status from public.attendance_eligibility_adjustment where award_id = :'award_a'::uuid), 'false>true/open', 'the task records the old and new flag');
select is((select challan_id from public.attendance_eligibility_adjustment where award_id = :'award_a'::uuid), :'chal_a'::uuid, 'and points at the issued challan');
select is((select net_paisa from public.fee_challan where id = :'chal_a'::uuid), :'net_before'::bigint, 'AC3: the issued challan is not mutated');
select app.fn_reevaluate_eligibility(:'campus_id'::uuid, :'cy'::int, :'cm'::int);
select is((select count(*) from public.attendance_eligibility_adjustment where award_id = :'award_a'::uuid), 1::bigint, 'recomputing again does not duplicate the task');
update public.attendance_month_summary set attendance_pct = 85.00 where enrolment_id = :'ea'::uuid and year = :'py'::int and month = :'pm'::int;
select app.fn_reevaluate_eligibility(:'campus_id'::uuid, :'cy'::int, :'cm'::int);
select is((select status from public.attendance_eligibility_adjustment where award_id = :'award_a'::uuid), 'resolved', 'if the flag goes back to what the challan used the task closes itself');

-- ── AC4: the accountant sees the flag, never the attendance ───────────────
insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status)
values (:'tenant_id', :'campus_id', :'session_id', :'section_id', :'ea', current_date - 40, 'present');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.v_attendance_concession_eligibility where billing_year = :'cy'::int and billing_month = :'cm'::int), 4::bigint, 'AC4: an accountant sees the four flags');
select is((select attendance_pct from public.v_attendance_concession_eligibility where award_id = :'award_c'::uuid), 87.40, 'with the percentage');
select is((select count(*) from public.attendance_day), 0::bigint, 'AC4: and SELECT on attendance_day returns zero rows');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select cmp_ok((select count(*) from public.attendance_day), '>', 0::bigint, 'the Owner still reads attendance');

-- ── refresh entry point ───────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.refresh_attendance_eligibility(%L, %s, %s) $$, :'campus_id', :'cy', :'cm'), 'FORBIDDEN', 'an accountant cannot trigger the refresh');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((public.refresh_attendance_eligibility(:'campus_id'::uuid, :'cy'::int, :'cm'::int) ->> 'evaluated')::int, 4, 'a Principal refreshes the month, recomputing last month''s attendance first');
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.resolve_eligibility_adjustment(%L) $$, gen_random_uuid()), 'TASK_NOT_FOUND', 'resolving an unknown task is refused');
reset role;
update public.attendance_month_summary set attendance_pct = 95.00 where enrolment_id = :'ea'::uuid and year = :'py'::int and month = :'pm'::int;
select app.fn_reevaluate_eligibility(:'campus_id'::uuid, :'cy'::int, :'cm'::int);
select id as task_id from public.attendance_eligibility_adjustment where award_id = :'award_a'::uuid and status = 'open' \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.resolve_eligibility_adjustment(:'task_id'::uuid, 'Credited 4,250 on the next challan');
select is((select status || '/' || resolved_by::text from public.attendance_eligibility_adjustment where id = :'task_id'::uuid), 'resolved/' || :'acct_uid', 'the Accountant resolves the task and is recorded');

select * from finish();
rollback;
