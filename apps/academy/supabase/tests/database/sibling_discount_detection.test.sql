-- pgTAP tests for FR-K07: sibling detection and discount proposal.
begin;
select plan(17);

select public.provision_tenant('test-sibling-disc-co', 'Sibling Disc Co', 'owner@siblingdiscco.test');
select id as tenant_id from public.tenant where slug = 'test-sibling-disc-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset

select public.create_concession_scheme(
  'SIB2ND', 'Sibling 2nd Child', 'دوسرا بہن بھائی', 'percentage', 10, array[:'tuition_id']::uuid[]
) as scheme2_id \gset
select public.create_concession_scheme(
  'SIB3RD', 'Sibling 3rd Child', 'تیسرا بہن بھائی', 'percentage', 15, array[:'tuition_id']::uuid[]
) as scheme3_id \gset
select public.set_sibling_discount_scheme(2::smallint, :'scheme2_id'::uuid);
select public.set_sibling_discount_scheme(3::smallint, :'scheme3_id'::uuid);

select public.fn_find_or_create_guardian(p_name_en => 'Common Father', p_cnic => '35202-1234567-8') as father_id \gset

-- Three siblings, admitted in order (eldest first) — created_at now uses
-- clock_timestamp() (fixed while verifying this exact FR), so admission
-- order is reliably distinct even within one pgTAP transaction.
select public.create_student(:'campus_id'::uuid, 'Eldest Child', '2012-01-01'::date, 'male') as eldest_id \gset
select public.link_guardian(:'eldest_id'::uuid, :'father_id'::uuid, 'father', true, true);
select public.enrol_student(:'section_id'::uuid, :'eldest_id'::uuid) as enrol_eldest_id \gset

select public.create_student(:'campus_id'::uuid, 'Middle Child', '2014-01-01'::date, 'female') as middle_id \gset
-- Guardian CNIC recorded with dashes stripped, per the AC's own example —
-- app.fn_normalize_pk_id() must still resolve this to the same family.
select public.link_guardian(:'middle_id'::uuid, (public.fn_find_or_create_guardian(p_name_en => 'Common Father', p_cnic => '3520212345678')), 'father', true, true);
select public.enrol_student(:'section_id'::uuid, :'middle_id'::uuid) as enrol_middle_id \gset

select public.create_student(:'campus_id'::uuid, 'Youngest Child', '2016-01-01'::date, 'male') as youngest_id \gset
select public.link_guardian(:'youngest_id'::uuid, :'father_id'::uuid, 'father', true, true);
select public.enrol_student(:'section_id'::uuid, :'youngest_id'::uuid) as enrol_youngest_id \gset

-- A lone, unrelated student — no sibling group should ever form for them.
select public.create_student(:'campus_id'::uuid, 'Only Child', '2013-01-01'::date, 'female') as only_id \gset
select public.fn_find_or_create_guardian(p_name_en => 'Different Father', p_cnic => '42101-9876543-2') as other_father_id \gset
select public.link_guardian(:'only_id'::uuid, :'other_father_id'::uuid, 'father', true, true);
select public.enrol_student(:'section_id'::uuid, :'only_id'::uuid) as enrol_only_id \gset

select public.detect_sibling_groups(:'campus_id'::uuid, :'session_id'::uuid) as scan1_result \gset

select is((:'scan1_result'::jsonb ->> 'groups_found')::int, 1, 'exactly one sibling group is found — the lone student never matches');
select is(
  (:'scan1_result'::jsonb ->> 'proposals_created')::int, 2,
  'AC: 2 draft awards are proposed for a 3-sibling family — none for the eldest'
);

select is(
  (select count(*)::int from public.concession_award where enrolment_id = :'enrol_eldest_id'),
  0,
  'AC: the eldest (rank 1) gets no proposed award at all'
);
select is(
  (select value from public.concession_award where enrolment_id = :'enrol_middle_id' and status = 'pending'),
  10::numeric,
  'AC: the middle child (rank 2) gets a draft award at the configured 10%'
);
select is(
  (select value from public.concession_award where enrolment_id = :'enrol_youngest_id' and status = 'pending'),
  15::numeric,
  'AC: the youngest (rank 3) gets a draft award at the configured 15%'
);
select is(
  (select status::text from public.concession_award where enrolment_id = :'enrol_middle_id'),
  'pending',
  'the proposal starts pending — never auto-approved'
);
select is(
  (select count(*)::int from public.sibling_group where guardian_cnic_norm = '35202-1234567-8'),
  1,
  'the detected group is cached, keyed on the normalised CNIC'
);
select is(
  (select array_length(member_enrolment_ids, 1) from public.sibling_group where guardian_cnic_norm = '35202-1234567-8'),
  3,
  'all three siblings are recorded as members of the cached group'
);

-- ── AC: re-scanning creates no duplicate drafts ────────────────────────

select public.detect_sibling_groups(:'campus_id'::uuid, :'session_id'::uuid) as scan2_result \gset
select is(
  (:'scan2_result'::jsonb ->> 'proposals_created')::int, 0,
  'AC: scanning again with the same pending drafts already in place proposes nothing new'
);
select is(
  (select count(*)::int from public.concession_award where enrolment_id = :'enrol_middle_id'),
  1,
  'still exactly one award for the middle child — no duplicate'
);

-- ── AC: the eldest withdraws — ranks shift on the next scan, the old
--    rank''s award is flagged for review rather than silently changed ──

reset role;
update public.enrolment set status = 'left' where id = :'enrol_eldest_id';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.detect_sibling_groups(:'campus_id'::uuid, :'session_id'::uuid) as scan3_result \gset
select is(
  (:'scan3_result'::jsonb ->> 'groups_found')::int, 1,
  'the family is still a group of 2 once the eldest drops out of the active roster'
);
select is(
  (:'scan3_result'::jsonb ->> 'proposals_created')::int, 0,
  'no NEW proposal is created for either remaining sibling — both already hold an award, just under the wrong rank now'
);
select is(
  jsonb_array_length(:'scan3_result'::jsonb -> 'needs_review'), 2,
  -- Both remaining siblings are now mismatched: the middle child is rank
  -- 1 (no longer eligible at all, but still holds the old 10% draft) and
  -- the youngest is rank 2 (should be 10%, but still holds the old 15%
  -- rank-3 draft) — AC: flagged for re-ranking, not silently rewritten.
  'AC: both remaining siblings'' existing awards no longer match their shifted ranks, so both are flagged'
);
select is(
  (select value from public.concession_award where enrolment_id = :'enrol_middle_id' and status = 'pending'),
  10::numeric,
  'the middle child''s existing 10% draft is untouched — flagged, not auto-revised'
);
select is(
  (select value from public.concession_award where enrolment_id = :'enrol_youngest_id' and status = 'pending'),
  15::numeric,
  'the youngest''s existing 15% draft (their old rank-3 rate) is likewise untouched — flagged, not auto-revised'
);
select is(
  (select count(*)::int from public.concession_award where enrolment_id = :'enrol_youngest_id'),
  1,
  'still exactly one award for the youngest — flagging never creates a second, competing proposal'
);

-- ── access control ──────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.detect_sibling_groups(%L, %L)', :'campus_id', :'session_id'),
  'FORBIDDEN',
  'a teacher cannot run the sibling detection scan'
);

select * from finish();
rollback;
