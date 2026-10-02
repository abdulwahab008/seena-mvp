-- pgTAP tests for FR-C03: roll number assignment and re-sequencing.
begin;
select plan(8);

select public.provision_tenant('test-roll-co', 'Roll Co', 'owner@rollco.test');
select id as tenant_id from public.tenant where slug = 'test-roll-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class6_id from public.class_level where tenant_id = :'tenant_id' and code = '6' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class6_id', p_name => 'A', p_capacity => 45) as section_a_id \gset
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class6_id', p_name => 'B', p_capacity => 45) as section_b_id \gset

-- Zainab, Bilal, Ahmed enrolled in that order (so roll assignment order,
-- 1/2/3, differs from alphabetical order: Ahmed, Bilal, Zainab).
select public.enrol_student(:'section_a_id'::uuid, (public.create_student(:'campus_id'::uuid, 'Zainab Iqbal', '2014-01-01'::date, 'female'))::uuid) as zainab_enrolment_id \gset
select public.enrol_student(:'section_a_id'::uuid, (public.create_student(:'campus_id'::uuid, 'Bilal Ahmed', '2014-01-01'::date, 'male'))::uuid) as bilal_enrolment_id \gset
select public.enrol_student(:'section_a_id'::uuid, (public.create_student(:'campus_id'::uuid, 'Ahmed Raza', '2014-01-01'::date, 'male'))::uuid) as ahmed_enrolment_id \gset

-- ── fn_assign_next_roll_no: sequential as each student joins ──────────

select public.fn_assign_next_roll_no(:'zainab_enrolment_id'::uuid);
select public.fn_assign_next_roll_no(:'bilal_enrolment_id'::uuid);
select public.fn_assign_next_roll_no(:'ahmed_enrolment_id'::uuid) as ahmed_roll \gset
select is(:'ahmed_roll'::int, 3, 'the 3rd student to join gets roll number 3, in join order');

-- ── manual duplicate is rejected by the unique index, scoped per section ─

select throws_ok(
  format('select public.fn_set_roll_no(%L, 1)', :'ahmed_enrolment_id'),
  'duplicate key value violates unique constraint "uq_roll_no"',
  'manually assigning roll 1 (already Zainab''s) in section A is rejected'
);
select public.enrol_student(:'section_b_id'::uuid, (public.create_student(:'campus_id'::uuid, 'Sana Malik', '2014-01-01'::date, 'female'))::uuid) as sana_enrolment_id \gset
select lives_ok(
  format('select public.fn_set_roll_no(%L, 1)', :'sana_enrolment_id'),
  'roll number 1 is independently valid in section B — uniqueness is per-section'
);

-- ── fn_resequence_roll_numbers: alphabetical, contiguous, logged ──────

select public.fn_resequence_roll_numbers(:'section_a_id'::uuid, :'session_id'::uuid, 'alphabetical');
select is(
  (select roll_no from public.enrolment where id = :'ahmed_enrolment_id'),
  1,
  'after alphabetical resequencing, Ahmed Raza (alphabetically first) is roll 1'
);
select is(
  (select roll_no from public.enrolment where id = :'bilal_enrolment_id'),
  2,
  'Bilal Ahmed is roll 2'
);
select is(
  (select roll_no from public.enrolment where id = :'zainab_enrolment_id'),
  3,
  'Zainab Iqbal, previously roll 1, is now roll 3 — contiguous 1..3, reassigned not just relabelled'
);
select is(
  (select count(*)::int from public.roll_number_change_log where enrolment_id = :'zainab_enrolment_id'),
  1,
  'the change from Zainab''s old roll (1) to her new one (3) is written to the change log'
);

-- ── a new student joining after resequencing gets the next number, ────
-- ── the existing three are untouched ───────────────────────────────

select public.enrol_student(:'section_a_id'::uuid, (public.create_student(:'campus_id'::uuid, 'Omar Sheikh', '2014-01-01'::date, 'male'))::uuid) as omar_enrolment_id \gset
select public.fn_assign_next_roll_no(:'omar_enrolment_id'::uuid);
select is(
  (select array_agg(roll_no order by roll_no) from public.enrolment where section_id = :'section_a_id' and status = 'active'),
  array[1, 2, 3, 4],
  'the new joiner becomes roll 4; the existing 1/2/3 are untouched'
);

select * from finish();
rollback;
