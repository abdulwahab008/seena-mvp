-- pgTAP tests for the fn_available_seats fix: live admission offers must
-- count against seat availability exactly like confirmed enrolments do.
begin;
select plan(5);

select public.provision_tenant('test-seat-avail-co', 'Seat Avail Co', 'owner@seatavailco.test');
select id as tenant_id from public.tenant where slug = 'test-seat-avail-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class1_id', p_name => 'A', p_capacity => 1);

select public.create_enquiry(
  p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'First Applicant',
  p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent One',
  p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry1_id \gset
select public.fn_submit_application(:'enquiry1_id'::uuid) as app1_id \gset

select public.create_enquiry(
  p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Second Applicant',
  p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Two',
  p_phone => '03002222222', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry2_id \gset
select public.fn_submit_application(:'enquiry2_id'::uuid) as app2_id \gset

-- ── a live offer holds the seat: a second application cannot also be offered ──

select public.fn_issue_offer(:'app1_id'::uuid, 5000) as offer1_id \gset
select is(
  public.available_seats(:'class1_id'::uuid, :'session_id'::uuid, :'campus_id'::uuid)::int,
  0,
  'one section of capacity 1 with one live offer against it reads 0 seats available'
);
select throws_ok(
  format('select public.fn_issue_offer(%L, 5000)', :'app2_id'),
  'NO_SEATS_AVAILABLE',
  'a second application for the same, already-offered-out class is rejected — the live offer holds the seat'
);

-- ── an expired-but-not-yet-swept offer no longer holds the seat ────────
-- fn_expire_offers() has not run — status is still 'issued' — but the
-- clock has already run out, and availability must reflect that live.

reset role;
update public.admission_offer set expires_at = now() - interval '1 hour' where id = :'offer1_id';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  public.available_seats(:'class1_id'::uuid, :'session_id'::uuid, :'campus_id'::uuid)::int,
  1,
  'once the held offer''s expiry has passed, its seat counts as available again even before fn_expire_offers() runs'
);
select lives_ok(
  format('select public.fn_issue_offer(%L, 5000)', :'app2_id'),
  'the second application can now be offered the freed seat'
);
select is(
  public.available_seats(:'class1_id'::uuid, :'session_id'::uuid, :'campus_id'::uuid)::int,
  0,
  'the seat is held again by the second (now live) offer'
);

select * from finish();
rollback;
