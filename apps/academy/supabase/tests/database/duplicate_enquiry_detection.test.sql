-- pgTAP tests for FR-B03: detect and merge duplicate enquiries.
begin;
select plan(18);

select public.provision_tenant('test-dup-enquiry-co', 'Dup Enquiry Co', 'owner@dupenquiryco.test');
select id as tenant_id from public.tenant where slug = 'test-dup-enquiry-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select public.provision_tenant('test-dup-enquiry-other-co', 'Dup Enquiry Other Co', 'owner@dupenquiryotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-dup-enquiry-other-co' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset
select id as other_session_id from public.academic_session where tenant_id = :'other_tenant_id' \gset
select id as other_class1_id from public.class_level where tenant_id = :'other_tenant_id' and code = '1' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.create_campus('SOUTH', 'Campus South', null) as _unused \gset
select id as campus_south from public.campus where tenant_id = :'tenant_id' and code = 'SOUTH' \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id', :'campus_south'))::text,
  true
);

-- ── AC1: an exact phone match surfaces the existing enquiry ────────────

select public.create_enquiry(
  p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Muhammad Ali',
  p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent One',
  p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry1_id \gset

select public.create_enquiry(
  p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'M. Ali',
  p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent One',
  p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry2_id \gset

select id as dup1_found_id from public.fn_find_duplicate_enquiries(
  p_phone => '03001111111', p_exclude_enquiry_id => :'enquiry2_id'::uuid
) \gset
select is(
  :'dup1_found_id'::uuid, :'enquiry1_id'::uuid,
  'AC: submitting a second enquiry with the same phone number surfaces the existing one, before the workflow considers the save complete'
);

-- A follow-up on the loser, to prove it re-parents on merge.
select public.create_followup(:'enquiry2_id'::uuid, now() + interval '1 day', 'call'::public.followup_channel) as followup_id \gset

-- ── AC2: merging re-parents follow-ups, marks the loser 'merged', and
--    sets merged_into_id — never deletes the loser ─────────────────────

select public.fn_merge_enquiry(:'enquiry1_id'::uuid, :'enquiry2_id'::uuid);
select is(
  (select enquiry_id from public.admission_followup where id = :'followup_id'::uuid),
  :'enquiry1_id'::uuid,
  'AC: the loser''s follow-up re-parents to the survivor'
);
select is(
  (select status::text from public.admission_enquiry where id = :'enquiry2_id'::uuid),
  'merged',
  'AC: the loser''s status becomes merged'
);
select is(
  (select merged_into_id from public.admission_enquiry where id = :'enquiry2_id'::uuid),
  :'enquiry1_id'::uuid,
  'AC: merged_into_id points at the survivor'
);
select is(
  (select count(*)::int from public.admission_enquiry where id = :'enquiry2_id'::uuid),
  1,
  'the loser is never hard-deleted — first-touch source attribution survives'
);
select throws_ok(
  format('select public.fn_merge_enquiry(%L, %L)', :'enquiry1_id', :'enquiry2_id'),
  'ENQUIRY_NOT_OPEN',
  'an already-merged enquiry cannot be merged again'
);

-- ── AC3: "Not a duplicate" persists both rows and the pair never
--    resurfaces ─────────────────────────────────────────────────────────

select public.create_enquiry(
  p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'John Smith',
  p_dob => '2019-06-15'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Two',
  p_phone => '03002222222', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry3_id \gset
select public.create_enquiry(
  p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Jon Smith',
  p_dob => '2019-06-15'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Three',
  p_phone => '03003333333', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry4_id \gset

select id as dup2_found_id from public.fn_find_duplicate_enquiries(
  p_name => 'Jon Smith', p_dob => '2019-06-15'::date, p_exclude_enquiry_id => :'enquiry4_id'::uuid
) \gset
select is(
  :'dup2_found_id'::uuid, :'enquiry3_id'::uuid,
  'a fuzzy name match with a matching DOB (different phone, different parent) still surfaces as a candidate'
);

select public.fn_dismiss_duplicate_enquiry(:'enquiry3_id'::uuid, :'enquiry4_id'::uuid);
select is(
  (select count(*)::int from public.admission_enquiry where id in (:'enquiry3_id'::uuid, :'enquiry4_id'::uuid) and status = 'open'),
  2,
  'AC: after choosing "Not a duplicate", both rows persist as open'
);
select is(
  (select count(*)::int from public.fn_find_duplicate_enquiries(p_name => 'Jon Smith', p_dob => '2019-06-15'::date, p_exclude_enquiry_id => :'enquiry4_id'::uuid)),
  0,
  'AC: the dismissed pair never resurfaces as a suggestion again'
);

-- ── AC4: a cross-campus merge is refused for an Admissions Officer and
--    requires a Principal (or above) ────────────────────────────────────

select public.create_enquiry(
  p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Cross Campus Child',
  p_dob => '2020-03-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Four',
  p_phone => '03004444444', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry5_id \gset
select public.create_enquiry(
  p_campus_id => :'campus_south', p_session_id => :'session_id', p_child_name => 'Cross Campus Child',
  p_dob => '2020-03-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Four',
  p_phone => '03004444444', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry6_id \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id', :'campus_south'))::text,
  true
);
select throws_ok(
  format('select public.fn_merge_enquiry(%L, %L)', :'enquiry5_id', :'enquiry6_id'),
  'CROSS_CAMPUS_MERGE_REQUIRES_PRINCIPAL',
  'AC: an Admissions Officer cannot merge two enquiries sitting on different campuses'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id', :'campus_south'))::text,
  true
);
select lives_ok(
  format('select public.fn_merge_enquiry(%L, %L)', :'enquiry5_id', :'enquiry6_id'),
  'AC: a Principal can approve the same cross-campus merge'
);
select is(
  (select status::text from public.admission_enquiry where id = :'enquiry6_id'::uuid),
  'merged',
  'the cross-campus merge, once approved by a Principal, completes normally'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id', :'campus_south'))::text,
  true
);

-- ── tenant isolation ──────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'))::text,
  true
);
select public.create_enquiry(
  p_campus_id => :'other_campus_id', p_session_id => :'other_session_id', p_child_name => 'Other Tenant Child',
  p_dob => '2020-01-01'::date, p_class_applied_id => :'other_class1_id', p_parent_name => 'Other Parent',
  p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as other_tenant_enquiry_id \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id', :'campus_south'))::text,
  true
);
select is(
  (select count(*)::int from public.fn_find_duplicate_enquiries(p_phone => '03001111111')),
  1,
  'fn_find_duplicate_enquiries never returns a foreign tenant''s matching row for the same phone number — only this tenant''s own (enquiry1)'
);
select throws_ok(
  format('select public.fn_merge_enquiry(%L, %L)', :'other_tenant_enquiry_id', :'enquiry1_id'),
  'SURVIVOR_NOT_FOUND',
  'fn_merge_enquiry refuses a foreign-tenant survivor id'
);
select throws_ok(
  format('select public.fn_merge_enquiry(%L, %L)', :'enquiry1_id', :'other_tenant_enquiry_id'),
  'LOSER_NOT_FOUND',
  'fn_merge_enquiry refuses a foreign-tenant loser id'
);
select throws_ok(
  format('select public.fn_dismiss_duplicate_enquiry(%L, %L)', :'enquiry1_id', :'enquiry1_id'),
  'SAME_ENQUIRY',
  'dismissing an enquiry against itself is rejected'
);

-- ── role checks ───────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  'select public.fn_find_duplicate_enquiries(p_phone => ''03001111111'')',
  'FORBIDDEN',
  'a role with no admissions access cannot search for duplicate enquiries'
);
select throws_ok(
  format('select public.fn_merge_enquiry(%L, %L)', :'enquiry1_id', :'enquiry3_id'),
  'FORBIDDEN',
  'a role with no admissions access cannot merge enquiries'
);

select * from finish();
rollback;
