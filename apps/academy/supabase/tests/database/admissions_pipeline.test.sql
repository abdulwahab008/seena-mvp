-- pgTAP tests for FR-B08 (submit application), FR-B15 (issue offer with
-- hard expiry) and FR-B16 (offer response and auto-lapse).
begin;
select plan(13);

select public.provision_tenant('test-pipeline-co', 'Pipeline Co', 'owner@pipelineco.test');
select id as tenant_id from public.tenant where slug = 'test-pipeline-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select id as class9_id from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_enquiry(
  p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Class 1 Applicant',
  p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent One',
  p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as class1_enquiry_id \gset
select public.create_enquiry(
  p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Class 9 Applicant',
  p_dob => '2012-01-01'::date, p_class_applied_id => :'class9_id', p_parent_name => 'Parent Two',
  p_phone => '03002222222', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as class9_enquiry_id \gset

-- ── B08: group required for classes 9-12, cleared for classes below ────

select throws_ok(
  format('select public.fn_submit_application(%L)', :'class9_enquiry_id'),
  'Group is required for classes 9-12',
  'submitting a class 9 application with no group is rejected'
);

select public.fn_submit_application(:'class9_enquiry_id'::uuid, 'pre_medical') as class9_app_id \gset
select is(
  (select group_applied::text from public.admission_application where id = :'class9_app_id'),
  'pre_medical',
  'a class 9 application with a group is accepted and the group is stored'
);

select public.fn_submit_application(:'class1_enquiry_id'::uuid, 'pre_medical') as class1_app_id \gset
select is(
  (select group_applied from public.admission_application where id = :'class1_app_id'),
  null,
  'a group supplied for a class 1 application is cleared — group only applies to classes 9-12'
);

select is(
  (select status from public.admission_enquiry where id = :'class1_enquiry_id'),
  'converted',
  'the source enquiry becomes converted once its application is submitted'
);

-- ── B15: no seats available ─────────────────────────────────────────

select throws_ok(
  format('select public.fn_issue_offer(%L, 5000)', :'class1_app_id'),
  'NO_SEATS_AVAILABLE',
  'issuing an offer with zero sections (zero capacity) for the class is rejected'
);

-- Capacity 2, not 1: the "second offer for the same application" test
-- below must reach the uq_offer_active_per_application constraint, not get
-- pre-empted by NO_SEATS_AVAILABLE (fn_available_seats now also counts
-- live offers — see offer_aware_seat_availability.test.sql for that).
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class1_id', p_name => 'A', p_capacity => 2) as section_a_id \gset
select public.fn_issue_offer(:'class1_app_id'::uuid, 5000) as offer_id \gset
select is(
  (select status from public.admission_application where id = :'class1_app_id'),
  'offered'::public.application_status,
  'once a seat exists, the offer is issued and the application status becomes offered'
);

-- ── B15: expiry is an absolute Karachi end-of-day timestamp ────────

select is(
  (select (expires_at at time zone 'Asia/Karachi')::time from public.admission_offer where id = :'offer_id'),
  '23:59:59'::time,
  'the 7-day-validity offer expires at 23:59:59 Karachi time, not the time-of-day it was issued'
);

-- ── B15: a second offer for the same application is rejected ─────────

select throws_ok(
  format('select public.fn_issue_offer(%L, 5000)', :'class1_app_id'),
  'duplicate key value violates unique constraint "uq_offer_active_per_application"',
  'a second active offer for the same application is rejected'
);

-- ── B16: decline requires a reason ──────────────────────────────────

select throws_ok(
  format($$ select public.fn_respond_to_offer(%L, 'declined') $$, :'offer_id'),
  'DECLINE_REASON_REQUIRED',
  'declining without a reason from the fixed list is rejected'
);

-- ── B16: accept, guarded by status = issued ─────────────────────────

select public.fn_respond_to_offer(:'offer_id'::uuid, 'accepted');
select is(
  (select status from public.admission_offer where id = :'offer_id'),
  'accepted'::public.offer_status,
  'accepting the offer records it'
);
select throws_ok(
  format($$ select public.fn_respond_to_offer(%L, 'declined', 'fee_too_high') $$, :'offer_id'),
  'OFFER_NOT_RESPONDABLE',
  'an already-accepted offer cannot also be declined — the status=issued guard blocks it'
);

-- ── B16: fn_expire_offers lapses only what is actually overdue ────────

select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class9_id', p_name => 'A', p_capacity => 1) as section_class9_id \gset
select public.fn_issue_offer(:'class9_app_id'::uuid, 6000) as class9_offer_id \gset
-- fn_expire_offers is granted to service_role only (it's meant to be
-- invoked by a scheduler, not a logged-in user) — superuser exercises it
-- the same way service_role would, since both bypass grant checks.
reset role;
update public.admission_offer set expires_at = now() - interval '1 hour' where id = :'class9_offer_id';
select public.fn_expire_offers();
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select status from public.admission_offer where id = :'class9_offer_id'),
  'lapsed'::public.offer_status,
  'an offer past its expiry is lapsed by fn_expire_offers'
);
select is(
  (select status from public.admission_application where id = :'class9_app_id'),
  'lapsed'::public.application_status,
  'the application lapses along with its offer'
);

select * from finish();
rollback;
