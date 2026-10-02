-- pgTAP tests for FR-E03 (section capacity enforcement) and FR-C02
-- (section allotment with balancing).
begin;
select plan(11);

select public.provision_tenant('test-enrolment-co', 'Enrolment Co', 'owner@enrolmentco.test');
select id as tenant_id from public.tenant where slug = 'test-enrolment-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class6_id from public.class_level where tenant_id = :'tenant_id' and code = '6' \gset
select id as class7_id from public.class_level where tenant_id = :'tenant_id' and code = '7' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- A 2-seat section to make the boundary cheap to hit.
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class6_id', p_name => 'A', p_capacity => 2) as section_a_id \gset
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class6_id', p_name => 'B', p_capacity => 3) as section_b_id \gset

select public.create_student(:'campus_id'::uuid, 'Student One', '2014-01-01'::date, 'male') as s1 \gset
select public.create_student(:'campus_id'::uuid, 'Student Two', '2014-01-01'::date, 'female') as s2 \gset
select public.create_student(:'campus_id'::uuid, 'Student Three', '2014-01-01'::date, 'male') as s3 \gset

-- ── capacity boundary: exactly `capacity` succeeds, the next fails ────

select lives_ok(format('select public.enrol_student(%L, %L)', :'section_a_id', :'s1'), 'the 1st enrolment into a 2-seat section succeeds');
select lives_ok(format('select public.enrol_student(%L, %L)', :'section_a_id', :'s2'), 'the 2nd enrolment fills the section exactly to capacity');
select throws_ok(
  format('select public.enrol_student(%L, %L)', :'section_a_id', :'s3'),
  'SECTION_FULL',
  'the 3rd enrolment into a full 2-seat section is rejected'
);
select is(
  (select count(*)::int from public.enrolment where section_id = :'section_a_id' and status = 'active'),
  2,
  'the full section still holds exactly 2 active enrolments, not 3'
);

-- ── Principal override: bypasses SECTION_FULL, flagged and attributed ──

select public.enrol_student(:'section_a_id'::uuid, :'s3'::uuid, 'sibling of existing student') as override_enrolment_id \gset
select is(
  (select over_capacity from public.enrolment where id = :'override_enrolment_id'),
  true,
  'a Principal override enrols over capacity and is flagged over_capacity=true'
);
select is(
  (select override_reason from public.enrolment where id = :'override_enrolment_id'),
  'sibling of existing student',
  'the override reason is stored on the enrolment row'
);

-- ── gender restriction ──────────────────────────────────────────────
-- Class 7, not 6: the auto-balance test below picks the class-6 section
-- with the most free seats, and an empty gender-restricted section would
-- otherwise win that pick and blow up on the (all-male) seed data.

select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class7_id', p_name => 'Girls', p_capacity => 10, p_gender_restriction => 'female') as girls_section_id \gset
select public.create_student(:'campus_id'::uuid, 'Male Student', '2014-01-01'::date, 'male') as male_student_id \gset
select throws_ok(
  format('select public.enrol_student(%L, %L)', :'girls_section_id', :'male_student_id'),
  'SECTION_GENDER_RESTRICTED',
  'a male student cannot be enrolled into a girls-only section'
);

-- ── fn_assign_section: mid-session move is time-boxed, not overwritten ─

select public.fn_assign_section(:'override_enrolment_id'::uuid, :'section_b_id'::uuid, '2026-10-12'::date, 'requested by parent');
select is(
  (select section_id from public.enrolment where id = :'override_enrolment_id'),
  :'section_b_id',
  'the enrolment now points at the new section'
);
select is(
  (select to_date from public.section_membership_history
    where enrolment_id = :'override_enrolment_id' and section_id = :'section_a_id'),
  '2026-10-11'::date,
  'the prior membership in section A is end-dated the day before the move, not deleted'
);
select is(
  (select from_date from public.section_membership_history
    where enrolment_id = :'override_enrolment_id' and section_id = :'section_b_id'),
  '2026-10-12'::date,
  'a new open-ended membership row starts on the move date in section B'
);

-- ── fn_auto_balance_sections: 9 students fill 30/31/32 to 34/34/34 ────

select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class6_id', p_name => 'X', p_capacity => 40) as section_x_id \gset
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class6_id', p_name => 'Y', p_capacity => 40) as section_y_id \gset
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class6_id', p_name => 'Z', p_capacity => 40) as section_z_id \gset

-- Seed X/Y/Z to 30/31/32 active students each via a bare loop (no gender
-- restriction on these three, so gender doesn't matter for the seed).
select public.enrol_student(:'section_x_id'::uuid, (public.create_student(:'campus_id'::uuid, 'Seed X ' || g, '2014-01-01'::date, 'male'))::uuid)
  from generate_series(1, 30) as g;
select public.enrol_student(:'section_y_id'::uuid, (public.create_student(:'campus_id'::uuid, 'Seed Y ' || g, '2014-01-01'::date, 'male'))::uuid)
  from generate_series(1, 31) as g;
select public.enrol_student(:'section_z_id'::uuid, (public.create_student(:'campus_id'::uuid, 'Seed Z ' || g, '2014-01-01'::date, 'male'))::uuid)
  from generate_series(1, 32) as g;

select array_agg((public.create_student(:'campus_id'::uuid, 'Balance ' || g, '2014-01-01'::date, 'male'))::uuid) as new_student_ids
  from generate_series(1, 9) as g \gset
select public.fn_auto_balance_sections(:'class6_id'::uuid, :'session_id'::uuid, :'new_student_ids'::uuid[]);

select is(
  (
    select array_agg(active_count order by name)
      from public.v_section_seat_availability
     where section_id in (:'section_x_id', :'section_y_id', :'section_z_id')
  ),
  array[34, 34, 34]::bigint[],
  '9 new students greedily fill the emptiest section each time, turning 30/31/32 into 34/34/34'
);

select * from finish();
rollback;
