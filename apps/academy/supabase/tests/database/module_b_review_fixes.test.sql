-- pgTAP tests for the Module B (Admissions) independent-review fixes
-- (20260731300000_module_b_review_fixes.sql).
begin;
select plan(9);

select public.provision_tenant('test-b-review-fix-co', 'B Review Fix Co', 'owner@breviewfixco.test');
select id as tenant_id from public.tenant where slug = 'test-b-review-fix-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select public.provision_tenant('test-b-review-fix-other-co', 'B Review Fix Other Co', 'owner@breviewfixotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-b-review-fix-other-co' \gset

select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'otheruser@breviewfixotherco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'admissions_officer', 'Other Tenant Officer');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class1_id', p_name => 'A', p_capacity => 1);

-- ── fix #1: fn_respond_to_offer() now requires an admissions role ──────

select public.create_enquiry(
  p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Offer Response Child',
  p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent One',
  p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry_id \gset
select public.fn_submit_application(:'enquiry_id'::uuid) as app_id \gset
select public.fn_issue_offer(:'app_id'::uuid, 5000) as offer_id \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format($$ select public.fn_respond_to_offer(%L, 'accepted'::public.offer_status) $$, :'offer_id'),
  'FORBIDDEN',
  'AC: a role with no admissions access can no longer accept or decline an offer on the school''s behalf'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select lives_ok(
  format($$ select public.fn_respond_to_offer(%L, 'accepted'::public.offer_status) $$, :'offer_id'),
  'the fix does not regress an ordinary, authorized offer response'
);

-- ── fix #2: an accepted offer still holds the seat ──────────────────────

select public.create_enquiry(
  p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Second Applicant',
  p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Two',
  p_phone => '03002222222', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry2_id \gset
select public.fn_submit_application(:'enquiry2_id'::uuid) as app2_id \gset

select is(
  public.available_seats(:'class1_id'::uuid, :'session_id'::uuid, :'campus_id'::uuid)::int,
  0,
  'AC: the seat stays held once the offer is accepted, not just while it was merely issued'
);
select throws_ok(
  format('select public.fn_issue_offer(%L, 5000)', :'app2_id'),
  'NO_SEATS_AVAILABLE',
  'AC: a second application cannot be offered the same, already-accepted seat — this is the exact double-booking the bug allowed'
);

-- ── fix #3: create_followup() rejects a foreign-tenant assignee ────────

select throws_ok(
  format(
    $$ select public.create_followup(%L, now() + interval '1 day', 'call'::public.followup_channel, %L) $$,
    :'enquiry_id', :'other_user_id'
  ),
  'ASSIGNEE_NOT_FOUND',
  'create_followup() refuses to assign a follow-up to a different tenant''s user'
);

-- ── fix #3b (defense in depth): my_overdue_followups() is tenant-scoped
--    even against a row that bypasses the RPC entirely ─────────────────

reset role;
insert into public.admission_followup (tenant_id, campus_id, enquiry_id, channel, due_at, assigned_to, created_by)
values (:'tenant_id', :'campus_id', :'enquiry_id', 'call', now() - interval '1 hour', :'other_user_id', null);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'admissions_officer', 'campus_ids', '[]'::json, 'sub', :'other_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.my_overdue_followups()),
  0,
  'my_overdue_followups() never hands back a foreign tenant''s row even for a direct-inserted one bypassing create_followup() entirely'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── fix #4: fn_submit_application() refuses a non-open enquiry ─────────

select throws_ok(
  format('select public.fn_submit_application(%L)', :'enquiry_id'),
  'ENQUIRY_NOT_OPEN',
  'AC: submitting a second application against an already-converted enquiry is refused'
);

-- ── fix #5: fn_close_enquiry() refuses a non-open enquiry ──────────────

select throws_ok(
  format($$ select public.fn_close_enquiry(%L, 'lost'::public.enquiry_status) $$, :'enquiry_id'),
  'ENQUIRY_NOT_OPEN',
  'AC: an already-converted enquiry can no longer be force-closed as lost'
);

-- Sanity: closing a genuinely still-open enquiry still works.
select public.create_enquiry(
  p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Still Open Child',
  p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Three',
  p_phone => '03003333333', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as open_enquiry_id \gset
select public.fn_close_enquiry(:'open_enquiry_id'::uuid, 'lost'::public.enquiry_status);
select is(
  (select status::text from public.admission_enquiry where id = :'open_enquiry_id'),
  'lost',
  'the fix does not regress closing a genuinely open enquiry as lost'
);

select * from finish();
rollback;
