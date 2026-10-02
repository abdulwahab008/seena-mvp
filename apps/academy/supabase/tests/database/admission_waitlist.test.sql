-- pgTAP tests for FR-B07: waitlist with automatic promotion.
--
-- AC "two seats released within the same second by two different
-- transactions... two distinct applicants promoted, never twice" isn't
-- exercised directly — guaranteed by the advisory lock keyed on
-- (campus, session, class), the same untestable-in-a-single-connection
-- caveat already documented for every other race this codebase closes
-- this way (FR-K10, FR-K16, module_k_accounting_review_fixes).
begin;
select plan(21);

select public.provision_tenant('test-waitlist-co', 'Waitlist Co', 'owner@waitlistco.test');
select id as tenant_id from public.tenant where slug = 'test-waitlist-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class6_id from public.class_level where tenant_id = :'tenant_id' and code = '6' \gset
select id as class7_id from public.class_level where tenant_id = :'tenant_id' and code = '7' \gset

select public.provision_tenant('test-waitlist-other-co', 'Waitlist Other Co', 'owner@waitlistotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-waitlist-other-co' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- A single-seat class 9 section, and an unrelated, still-empty class 10
-- section for the "empty waitlist is a no-op" AC.
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class6_id', p_name => 'A', p_capacity => 1) as section9_id \gset
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class7_id', p_name => 'A', p_capacity => 1) as section10_id \gset

-- Applicant 1 takes the only seat.
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Applicant One', p_dob => '2015-01-01'::date, p_class_applied_id => :'class6_id', p_parent_name => 'Parent One', p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry1_id \gset
select public.fn_submit_application(:'enquiry1_id'::uuid) as app1_id \gset
select public.fn_issue_offer(:'app1_id'::uuid, 5000) as offer1_id \gset

-- Applicants 2-4 queue up on the waitlist, in order.
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Applicant Two', p_dob => '2015-01-01'::date, p_class_applied_id => :'class6_id', p_parent_name => 'Parent Two', p_phone => '03002222222', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry2_id \gset
select public.fn_submit_application(:'enquiry2_id'::uuid) as app2_id \gset
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Applicant Three', p_dob => '2015-01-01'::date, p_class_applied_id => :'class6_id', p_parent_name => 'Parent Three', p_phone => '03003333333', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry3_id \gset
select public.fn_submit_application(:'enquiry3_id'::uuid) as app3_id \gset
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Applicant Four', p_dob => '2015-01-01'::date, p_class_applied_id => :'class6_id', p_parent_name => 'Parent Four', p_phone => '03004444444', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry4_id \gset
select public.fn_submit_application(:'enquiry4_id'::uuid) as app4_id \gset

select throws_ok(
  format('select public.fn_issue_offer(%L, 5000)', :'app2_id'),
  'NO_SEATS_AVAILABLE',
  'sanity: the seat really is taken — a second offer for the same single-seat class is refused'
);

select public.join_waitlist(:'app2_id'::uuid) as w2_id \gset
select public.join_waitlist(:'app3_id'::uuid) as w3_id \gset
select public.join_waitlist(:'app4_id'::uuid) as w4_id \gset
select is(
  (select array_agg(position order by position) from public.admission_waitlist where application_id in (:'app2_id'::uuid, :'app3_id'::uuid, :'app4_id'::uuid)),
  array[1, 2, 3],
  'three applicants queue at positions 1, 2, 3 in join order'
);
select throws_ok(
  format('select public.join_waitlist(%L)', :'app2_id'),
  'ALREADY_WAITLISTED',
  'the same application cannot join the same waitlist twice'
);

-- ── AC1: a released seat promotes position 1 and closes up the rest ────

reset role;
update public.admission_offer set status = 'lapsed' where id = :'offer1_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select is(
  (select status from public.admission_waitlist where application_id = :'app2_id'::uuid),
  'offer_pending'::public.waitlist_status,
  'AC: the offer lapsing auto-promotes position 1 (applicant 2) to offer_pending'
);
select is(
  (select position from public.admission_waitlist where application_id = :'app2_id'::uuid),
  null::int,
  'a promoted row no longer holds a queue position'
);
select is(
  (select position from public.admission_waitlist where application_id = :'app3_id'::uuid), 1,
  'AC: applicant 3 renumbers from position 2 down to 1 — contiguous, no gap'
);
select is(
  (select position from public.admission_waitlist where application_id = :'app4_id'::uuid), 2,
  'AC: applicant 4 renumbers from position 3 down to 2'
);

-- Promoting again immediately finds the seat already held by the
-- offer_pending row above (fn_available_seats counts it) — not a second
-- free seat to hand out.
select (public.fn_promote_waitlist(:'campus_id'::uuid, :'session_id'::uuid, :'class6_id'::uuid) ->> 'reason') as no_seats_reason \gset
select is(:'no_seats_reason'::text, 'NO_SEATS_AVAILABLE', 'a still-pending promotion continues to hold its seat — no second promotion for the same one seat');

-- ── AC4: an empty waitlist with a genuinely free seat is a no-op ───────

select (public.fn_promote_waitlist(:'campus_id'::uuid, :'session_id'::uuid, :'class7_id'::uuid) ->> 'reason') as empty_reason \gset
select is(:'empty_reason'::text, 'WAITLIST_EMPTY', 'AC: an empty waitlist with a free seat promotes no one and raises no error');

-- ── AC3: a manual withdrawal closes up lower positions and leaves an
--    audit trail ────────────────────────────────────────────────────────

select public.remove_from_waitlist(:'w3_id'::uuid, 'Found a spot at another school');
select is(
  (select status from public.admission_waitlist where id = :'w3_id'::uuid),
  'withdrawn'::public.waitlist_status,
  'the removed entry is marked withdrawn, not deleted'
);
select is(
  (select removal_reason from public.admission_waitlist where id = :'w3_id'::uuid),
  'Found a spot at another school',
  'the removal reason is stored'
);
select is(
  (select position from public.admission_waitlist where application_id = :'app4_id'::uuid), 1,
  'AC: applicant 4 closes up from position 2 to 1 once applicant 3 withdraws'
);
select is(
  (
    select count(*)::int from public.audit_log
     where table_name = 'admission_waitlist' and row_id = :'w3_id'::uuid and action = 'update'
       and after ->> 'removal_reason' = 'Found a spot at another school'
  ),
  1,
  'AC: the manual removal produced an audit row carrying the reason (w3 also has an earlier audit row from the promotion''s renumbering — this checks the removal-specific one)'
);

select throws_ok(
  format('select public.remove_from_waitlist(%L, %L)', :'w4_id', ''),
  'REMOVAL_REASON_REQUIRED',
  'an empty removal reason is rejected'
);
select throws_ok(
  format('select public.remove_from_waitlist(%L, %L)', :'w3_id', 'already withdrawn'),
  'NOT_WAITING',
  'an already-withdrawn entry cannot be removed again'
);

-- ── validation and tenant isolation ─────────────────────────────────

select throws_ok(
  format('select public.join_waitlist(%L)', :'app1_id'),
  'APPLICATION_NOT_WAITLISTABLE',
  'an already-offered application cannot join the waitlist'
);
select throws_ok(
  'select public.remove_from_waitlist(gen_random_uuid(), ''reason'')',
  'WAITLIST_ENTRY_NOT_FOUND',
  'removing a non-existent waitlist entry is refused'
);

reset role;
select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'owner@waitlistotherco2.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json, 'sub', :'other_user_id')::text,
  true
);
select throws_ok(
  format('select public.join_waitlist(%L)', :'app4_id'),
  'APPLICATION_NOT_FOUND',
  'join_waitlist refuses a foreign-tenant application id'
);
select throws_ok(
  format('select public.remove_from_waitlist(%L, %L)', :'w4_id', 'reason'),
  'WAITLIST_ENTRY_NOT_FOUND',
  'remove_from_waitlist refuses a foreign-tenant waitlist entry id'
);
select is(
  (select count(*)::int from public.admission_waitlist),
  0,
  'AC/defense-in-depth: another tenant''s owner sees zero waitlist rows via RLS despite several existing in the first tenant'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.join_waitlist(%L)', :'app4_id'),
  'FORBIDDEN',
  'a role with no admissions access cannot join a waitlist'
);

select * from finish();
rollback;
