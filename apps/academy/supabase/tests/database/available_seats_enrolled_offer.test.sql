-- pgTAP tests: an accepted offer holds a seat only until it becomes an enrolment.
-- Regression: fn_available_seats() counted the enrolment AND its (still 'accepted') offer, so every
-- admitted student used two seats (capacity 1 + one enrolled student reported -1 seats left).
begin;
select plan(4);

select public.provision_tenant('test-seat-count-co', 'Seat Count Co', 'owner@seatcountco.test');
select id as tenant_id from public.tenant where slug = 'test-seat-count-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class1_id', p_name => 'A', p_capacity => 3) as section_id \gset

-- Helper: an accepted offer for a fresh enquiry, admission fee PKR 25,000.
create function pg_temp.new_accepted_offer(p_phone text, p_child_name text default 'Candidate')
returns uuid language plpgsql as $$
declare
  v_enquiry_id uuid; v_app_id uuid; v_offer_id uuid;
  v_campus_id uuid; v_session_id uuid; v_class1_id uuid;
begin
  select id into v_campus_id from public.campus where tenant_id = app.auth_tenant_id() limit 1;
  select id into v_session_id from public.academic_session where tenant_id = app.auth_tenant_id() limit 1;
  select id into v_class1_id from public.class_level where tenant_id = app.auth_tenant_id() and code = '1' limit 1;

  v_enquiry_id := public.create_enquiry(p_campus_id => v_campus_id, p_session_id => v_session_id, p_child_name => p_child_name, p_dob => '2020-01-01'::date, p_class_applied_id => v_class1_id, p_parent_name => 'A Parent', p_phone => p_phone, p_whatsapp_opt_in => false, p_source => 'walk_in');
  v_app_id := public.fn_submit_application(v_enquiry_id);
  v_offer_id := public.fn_issue_offer(v_app_id, 25000);
  perform public.fn_respond_to_offer(v_offer_id, 'accepted'::public.offer_status);
  return v_offer_id;
end;
$$;


select is(public.available_seats(:'class1_id'::uuid, :'session_id'::uuid, :'campus_id'::uuid), 3, 'an empty class of 3 has 3 seats');

select pg_temp.new_accepted_offer('03005550001', 'Seat Child One') as offer1_id \gset
select is(public.available_seats(:'class1_id'::uuid, :'session_id'::uuid, :'campus_id'::uuid), 2, 'an accepted offer holds exactly one seat');

select public.record_admission_fee_payment(:'offer1_id'::uuid, 2500000, 'cash') as payment1_id \gset
select public.fn_enrol_from_offer(:'offer1_id'::uuid, 'female'::public.gender, p_payment_id => :'payment1_id'::uuid, p_section_id => :'section_id'::uuid) as enrol1 \gset
select is(public.available_seats(:'class1_id'::uuid, :'session_id'::uuid, :'campus_id'::uuid), 2, 'REGRESSION: once enrolled, that student still uses ONE seat (not two)');

select pg_temp.new_accepted_offer('03005550002', 'Seat Child Two') as offer2_id \gset
select public.record_admission_fee_payment(:'offer2_id'::uuid, 2500000, 'cash') as payment2_id \gset
select public.fn_enrol_from_offer(:'offer2_id'::uuid, 'male'::public.gender, p_payment_id => :'payment2_id'::uuid, p_section_id => :'section_id'::uuid) as enrol2 \gset
select pg_temp.new_accepted_offer('03005550003', 'Seat Child Three') as offer3_id \gset
select is(public.available_seats(:'class1_id'::uuid, :'session_id'::uuid, :'campus_id'::uuid), 0, 'two enrolled + one accepted offer fills a class of 3 exactly (0 left, never negative)');

select * from finish();
rollback;
