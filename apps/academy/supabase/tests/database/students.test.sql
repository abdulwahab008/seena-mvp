-- pgTAP tests for FR-C01 (GR number allocation) and FR-C04 (student
-- profile).
begin;
select plan(11);

select public.provision_tenant('test-student-co', 'Student Co', 'owner@studentco.test');
select id as tenant_id from public.tenant where slug = 'test-student-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── GR allocation: sequential, gapless, prefixed with the campus code ───

select public.create_student(:'campus_id'::uuid, 'Ali Khan', '2015-03-01'::date, 'male') as ali_id \gset
select is(
  (select gr_number from public.student where id = :'ali_id'),
  'MAIN-000001',
  'the first student at campus MAIN gets GR MAIN-000001'
);

select public.create_student(:'campus_id'::uuid, 'Sara Ahmed', '2015-06-15'::date, 'female') as sara_id \gset
select is(
  (select gr_number from public.student where id = :'sara_id'),
  'MAIN-000002',
  'the second student gets the next gapless number, MAIN-000002'
);

-- ── GR number is immutable ───────────────────────────────────────────
-- student has no UPDATE policy for authenticated at all yet (no update_*
-- function exists in this batch), so RLS alone would already block this.
-- Testing as superuser isolates what the AC actually asks for: the trigger
-- itself is the safety net, independent of RLS — the same reasoning as
-- "including Super Admin" in the AC text.
reset role;
select throws_ok(
  format('update public.student set gr_number = %L where id = %L', 'MAIN-999999', :'ali_id'),
  'GR_NUMBER_IMMUTABLE',
  'a BEFORE UPDATE trigger blocks changing gr_number, even for a superuser'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select gr_number from public.student where id = :'ali_id'),
  'MAIN-000001',
  'the GR number is unchanged after the blocked update attempt'
);

-- ── set_gr_sequence: seeding from a paper register ─────────────────────

select public.set_gr_sequence(:'campus_id'::uuid, 'LHR', 8451::bigint, 6::smallint);
select public.create_student(:'campus_id'::uuid, 'Bilal Tariq', '2016-01-20'::date, 'male') as bilal_id \gset
select is(
  (select gr_number from public.student where id = :'bilal_id'),
  'LHR-008451',
  'after seeding the sequence to 8451 with prefix LHR, the next allocation returns LHR-008451'
);

-- ── B-Form normalization and validation ─────────────────────────────

select public.create_student(:'campus_id'::uuid, 'Hina Yousaf', '2014-09-09'::date, 'female', p_b_form_no => '3520212345678') as hina_id \gset
select is(
  (select b_form_no from public.student where id = :'hina_id'),
  '35202-1234567-8',
  'a B-Form typed as 13 raw digits is normalised to dashed format on save'
);

select throws_ok(
  format(
    $$ select public.create_student(%L, 'Bad Bform', '2014-01-01'::date, 'male', p_b_form_no => '12345') $$,
    :'campus_id'
  ),
  'BFORM_INVALID_FORMAT',
  'a B-Form that does not resolve to 13 digits is rejected'
);

-- ── B-Form duplicate detection + Principal override ────────────────

select throws_ok(
  format(
    $$ select public.create_student(%L, 'Duplicate Bform', '2014-01-01'::date, 'male', p_b_form_no => '35202-1234567-8') $$,
    :'campus_id'
  ),
  'BFORM_DUPLICATE',
  'reusing Hina''s B-Form number for a new student is rejected without an override reason'
);

select public.create_student(
  :'campus_id'::uuid, 'Duplicate Bform Override', '2014-01-01'::date, 'male',
  p_b_form_no => '35202-1234567-8', p_bform_override_reason => 'Family confirms shared guardianship error on NADRA form'
) as override_id \gset
select is(
  (select b_form_no from public.student where id = :'override_id'),
  '35202-1234567-8',
  'a Principal override with a reason lets the duplicate B-Form save through'
);

-- ── DOB sanity ────────────────────────────────────────────────────────

-- throws_ok's 3-arg form matches on the literal message text, not the
-- SQLSTATE — this is the table CHECK constraint's own default message
-- (create_student has no custom DOB validation of its own).
select throws_ok(
  format(
    $$ select public.create_student(%L, 'Future Child', (current_date + interval '1 day')::date, 'male') $$,
    :'campus_id'
  ),
  'new row for relation "student" violates check constraint "chk_dob_reasonable"',
  'a date of birth in the future is rejected by the DB check constraint'
);

-- ── role gate ─────────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format($$ select public.create_student(%L, 'Unauthorized Student', '2014-01-01'::date, 'male') $$, :'campus_id'),
  'FORBIDDEN',
  'a subject teacher cannot create a student record'
);

select * from finish();
rollback;
