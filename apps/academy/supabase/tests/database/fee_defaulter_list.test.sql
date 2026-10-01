-- pgTAP tests for FR-K25: defaulter list with ageing buckets.
begin;
select plan(19);

select public.provision_tenant('test-defaulter-co', 'Defaulter Co', 'owner@defaulterco.test');
select id as tenant_id from public.tenant where slug = 'test-defaulter-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-defaulter-other', 'Other Defaulter Co', 'owner@otherdefaulterco.test');
select id as other_tenant_id from public.tenant where slug = 'test-defaulter-other' \gset

select set_config('t.campus', :'campus_id', false), set_config('t.session', :'session_id', false), set_config('t.class', :'class1_id', false);
create temp table kid (n int primary key, enrol_id uuid, student_id uuid);
grant all on kid to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
do $$
declare i int; v_stu uuid;
begin
  for i in 1..4 loop
    v_stu := public.create_student(current_setting('t.campus')::uuid, 'Defaulter Kid ' || i, '2015-01-01'::date, 'male');
    insert into kid values (i, public.enrol_student((select id from public.class_section where campus_id = current_setting('t.campus')::uuid limit 1), v_stu), v_stu);
  end loop;
end $$;
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date + interval '1 month')::date + 14), false);
select public.fn_find_or_create_guardian(p_name_en => 'Kid 1 Parent', p_phone_e164 => '+923005550001') as g1 \gset
select public.link_guardian((select student_id from kid where n = 1), :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.record_payment((select enrol_id from kid where n = 2), 200000::bigint, 'cash'::public.fee_payment_mode, 'k25-partial', current_date);
select public.record_payment((select enrol_id from kid where n = 4), 1000000::bigint, 'cash'::public.fee_payment_mode, 'k25-paid', current_date);
reset role;

-- Kid 1: oldest unpaid challan due 65 days ago.            -> 61-90
-- Kid 2: due 100 days ago (part-paid) and 10 days ago.     -> 90+, measured from the OLDEST, balances summed
-- Kid 3: due 20 days ago, with an approved hardship award.  -> 1-30, flagged
-- Kid 4: both challans paid.                                -> not a defaulter
update public.fee_challan set due_date = current_date - 65 where enrolment_id = (select enrol_id from kid where n = 1) and billing_period = date_trunc('month', current_date)::date;
update public.fee_challan set due_date = current_date + 30 where enrolment_id = (select enrol_id from kid where n = 1) and billing_period <> date_trunc('month', current_date)::date;
update public.fee_challan set due_date = current_date - 100 where enrolment_id = (select enrol_id from kid where n = 2) and billing_period = date_trunc('month', current_date)::date;
update public.fee_challan set due_date = current_date - 10 where enrolment_id = (select enrol_id from kid where n = 2) and billing_period <> date_trunc('month', current_date)::date;
update public.fee_challan set due_date = current_date - 20 where enrolment_id = (select enrol_id from kid where n = 3) and billing_period = date_trunc('month', current_date)::date;
update public.fee_challan set due_date = current_date + 30 where enrolment_id = (select enrol_id from kid where n = 3) and billing_period <> date_trunc('month', current_date)::date;
insert into public.concession_scheme (tenant_id, code, name_en, name_ur, category, calc_type, value, applicable_head_ids) values (:'tenant_id', 'HARD', 'Hardship waiver', 'Hardship waiver', 'hardship', 'percentage', 100, array[:'tuition_id'::uuid]) returning id as scheme_id \gset
insert into public.concession_award (tenant_id, campus_id, enrolment_id, scheme_id, calc_type, value, effective_from, effective_to, status)
values (:'tenant_id', :'campus_id', (select enrol_id from kid where n = 3), :'scheme_id', 'percentage', 100, current_date - 60, current_date + 60, 'approved');

select has_materialized_view('app', 'mv_fee_defaulter', 'mv_fee_defaulter exists');
select has_index('app', 'mv_fee_defaulter', 'mv_fee_defaulter_uq', 'AC: the unique index on enrolment_id exists');
select ok((select reloptions::text like '%security_invoker=true%' from pg_class where oid = 'public.v_fee_defaulter'::regclass), 'the wrapping view is security_invoker');
select is(has_function_privilege('authenticated', 'public.refresh_fee_defaulters()', 'execute'), false, 'a client cannot trigger the rebuild');

select public.refresh_fee_defaulters() as n_rows \gset
select ok(:'n_rows'::int >= 3, 'the daily rebuild runs');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select bucket from public.v_fee_defaulter where enrolment_id = (select enrol_id from kid where n = 1)), '61-90', 'AC: a student whose oldest unpaid challan was due 65 days ago is in the 61-90 bucket only');
select is((select days_overdue from public.v_fee_defaulter where enrolment_id = (select enrol_id from kid where n = 1)), 65, 'with 65 days overdue');
select is((select count(*)::int from public.v_fee_defaulter where enrolment_id = (select enrol_id from kid where n = 1)), 1, 'and appears once, not in every bucket it has passed through');
select is((select bucket || '/' || days_overdue from public.v_fee_defaulter where enrolment_id = (select enrol_id from kid where n = 2)), '90+/100', 'days overdue are measured from the OLDEST unpaid challan, not the biggest balance');
select is((select outstanding_paisa from public.v_fee_defaulter where enrolment_id = (select enrol_id from kid where n = 2)), 800000::bigint, 'the outstanding sums every unpaid balance (3,000 left on the old one + 5,000 on the newer)');
select is((select has_active_concession from public.v_fee_defaulter where enrolment_id = (select enrol_id from kid where n = 3)), true, 'AC: an approved hardship concession is flagged so staff do not chase');
select is((select count(*)::int from public.v_fee_defaulter where enrolment_id = (select enrol_id from kid where n = 4)), 0, 'a fully paid student is not a defaulter');
select is((select guardian_phone from public.v_fee_defaulter where enrolment_id = (select enrol_id from kid where n = 1)), '+923005550001', 'the guardian phone is carried for the reminder');

select is((select sum(outstanding_paisa)::bigint from public.fn_defaulter_bucket_totals()), (select sum(outstanding_paisa)::bigint from public.v_fee_defaulter), 'AC: the bucket totals sum to the campus receivable to the paisa');
select is((select students from public.fn_defaulter_bucket_totals() where bucket = '1-30'), 1, 'one student in 1-30');
select is((select outstanding_paisa from public.fn_defaulter_bucket_totals(null, false) where bucket = '1-30'), 0::bigint, 'excluding hardship drops the flagged student from the totals');
select is((select count(*)::int from public.v_fee_defaulter where bucket = '90+'), 1, 'AC: a bucket filter returns only the matching students');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.v_fee_defaulter), 0, 'a teacher sees no defaulters');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.v_fee_defaulter), 0, 'another school sees none, even claiming this campus');
reset role;

select * from finish();
rollback;
