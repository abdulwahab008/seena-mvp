begin;
select plan(5);

select public.provision_tenant('test-dash-co', 'Dash Co', 'owner@dashco.test');
select id as tenant_id from public.tenant where slug = 'test-dash-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Birthday Child', (app.fn_karachi_today() - interval '8 years')::date, 'female') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrolment_id \gset
select public.post_ledger_entry(:'enrolment_id'::uuid, 'charge', 500000::bigint, 'debit');
select public.write_off_bad_debt(:'enrolment_id'::uuid, 100000::bigint, 'Moved away');
select public.add_fee_commitment(:'enrolment_id'::uuid, app.fn_karachi_today(), 200000::bigint);

select is((public.dashboard_summary() ->> 'receivable_paisa')::bigint, 400000::bigint, 'receivable is the fee ledger balance after the write-off');
select is((public.dashboard_summary() ->> 'bad_debt_month_paisa')::bigint, 100000::bigint, 'this month''s bad debts are counted');
select is(jsonb_array_length(public.dashboard_summary() -> 'commitments_today'), 1, 'today''s promise is listed');
select is(public.dashboard_summary() -> 'birthdays_today' -> 0 ->> 'name', 'Birthday Child', 'a student born on this day is listed');

select set_config('request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((public.dashboard_summary() ->> 'receivable_paisa')::bigint, 0::bigint, 'a teacher sees no fee figures');

select * from finish();
rollback;
