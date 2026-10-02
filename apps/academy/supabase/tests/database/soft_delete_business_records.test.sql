-- pgTAP tests for FR-A15 (soft delete of business records), scoped to
-- student + enrolment (+ fee_challan as enrolment's direct dependent).
begin;
select plan(26);

select public.provision_tenant('test-softdelete-co', 'Soft Delete Co', 'owner@softdeleteco.test');
select id as tenant_id from public.tenant where slug = 'test-softdelete-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class6_id from public.class_level where tenant_id = :'tenant_id' and code = '6' \gset

-- A second campus, for the campus-scope-guard test below. Also a real
-- app_user (with an auth.users row) for the owner role, so auth.uid() —
-- and therefore deleted_by — actually resolves to something, the same
-- convention admission_document_upload.test.sql uses.
reset role;
insert into public.campus (tenant_id, code, name) values (:'tenant_id'::uuid, 'NORTH', 'North Campus') returning id as north_campus_id \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner-user@softdeleteco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id'::uuid, 'owner', 'Owner');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class6_id', p_name => 'A', p_capacity => 10) as section_a_id \gset

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: post-delete invisibility + class-strength count correctness
-- ═══════════════════════════════════════════════════════════════════════

select public.create_student(:'campus_id'::uuid, 'Ali Khan', '2015-03-01'::date, 'male') as ali_id \gset
select public.create_student(:'campus_id'::uuid, 'Sara Ahmed', '2015-06-15'::date, 'female') as sara_id \gset
select public.enrol_student(:'section_a_id'::uuid, :'ali_id'::uuid) as ali_enrolment_id \gset
select public.enrol_student(:'section_a_id'::uuid, :'sara_id'::uuid) as sara_enrolment_id \gset

select is(
  (select active_count from public.v_section_seat_availability where section_id = :'section_a_id'),
  2::bigint,
  'before any delete, the section holds 2 active enrolments'
);

select public.soft_delete('student', :'ali_id'::uuid);

-- Owner also matches the recycle-bin-read policy (AC2, below), so the
-- invisibility guarantee below is proven from a non-owner, campus-scoped
-- role instead — Principal, who could have performed the delete itself,
-- but is not exempted from the "gone from ordinary views" rule by it.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select count(*)::int from public.student where id = :'ali_id'),
  0,
  'AC1: a plain student query (RLS-governed) no longer returns the deleted student'
);
select is(
  (select active_count from public.v_section_seat_availability where section_id = :'section_a_id'),
  1::bigint,
  'AC1: class strength (active_count) drops by exactly 1 after the student is soft-deleted'
);
select is(
  (select count(*)::int from public.enrolment where id = :'ali_enrolment_id'),
  0,
  'AC1: the cascaded enrolment is also invisible to a plain query'
);

-- The row is not gone — this is soft delete, not hard delete.
reset role;
select is(
  (select deleted_at is not null from public.student where id = :'ali_id'),
  true,
  'the student row still physically exists, with deleted_at set'
);
select is(
  (select deleted_by from public.student where id = :'ali_id') is not null,
  true,
  'deleted_by is recorded on the soft-deleted student'
);
select is(
  (select deleted_at is not null from public.enrolment where id = :'ali_enrolment_id'),
  true,
  'the cascaded enrolment row also has deleted_at set, not hard-deleted'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: Recycle Bin — Owner sees deleted_by/deleted_at + can restore;
-- a non-owner role sees nothing there even though the row exists
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select count(*)::int from public.student where deleted_at is not null and id = :'ali_id'),
  1,
  'AC2: an Owner querying the recycle-bin shape (deleted_at is not null) sees the deleted student'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select count(*)::int from public.student where deleted_at is not null and id = :'ali_id'),
  0,
  'a non-owner role gets zero rows from the recycle-bin shape, even for a row it could delete'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select public.restore_record('student', :'ali_id'::uuid);
select is(
  (select count(*)::int from public.student where id = :'ali_id' and deleted_at is null),
  1,
  'AC2: after restore, the student is back in the ordinary (non-recycle-bin) view'
);
select is(
  (select active_count from public.v_section_seat_availability where section_id = :'section_a_id'),
  2::bigint,
  'restoring the student brings class strength back up by 1'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: GR number reuse rejection
-- ═══════════════════════════════════════════════════════════════════════

select gr_number as ali_gr from public.student where id = :'ali_id' \gset
select public.soft_delete('student', :'ali_id'::uuid);

-- Rewind the sequence back to reissue the same number a fresh admission
-- would otherwise get next (the "migrating from a paper register" path
-- set_gr_sequence's own header documents).
select public.set_gr_sequence(:'campus_id'::uuid, 'MAIN', 1::bigint, 6::smallint);
select throws_ok(
  format($$ select public.create_student(%L, 'Reuse Attempt', '2015-01-01'::date, 'male') $$, :'campus_id'),
  'GR_NUMBER_IN_USE',
  'AC3: admitting a new student into a GR number still held by a soft-deleted student is rejected'
);
-- Sequence restored so later tests in this file get fresh, non-colliding numbers.
select public.set_gr_sequence(:'campus_id'::uuid, 'MAIN', 100::bigint, 6::smallint);
select public.restore_record('student', :'ali_id'::uuid);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: restoring an enrolment reinstates its challans, no duplicate
-- ═══════════════════════════════════════════════════════════════════════

select public.create_student(:'campus_id'::uuid, 'Bilal Tariq', '2015-01-01'::date, 'male') as bilal_id \gset
select public.enrol_student(:'section_a_id'::uuid, :'bilal_id'::uuid) as bilal_enrolment_id \gset

reset role;
insert into public.fee_challan (
  tenant_id, campus_id, enrolment_id, session_id, billing_period, challan_no, due_date, gross_paisa, net_paisa, status
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'bilal_enrolment_id'::uuid, :'session_id'::uuid,
  date_trunc('month', current_date)::date, 'CHK-TEST-0001', current_date + 10, 500000, 500000, 'unpaid'
) returning id as bilal_challan_id \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select is(
  (select count(*)::int from public.fee_challan where enrolment_id = :'bilal_enrolment_id'),
  1,
  'the enrolment starts with exactly one unpaid challan'
);

select public.soft_delete('enrolment', :'bilal_enrolment_id'::uuid);
select is(
  (select count(*)::int from public.fee_challan where enrolment_id = :'bilal_enrolment_id'),
  0,
  'AC4: soft-deleting the enrolment hides its unpaid challan too'
);

select public.restore_record('enrolment', :'bilal_enrolment_id'::uuid);
select is(
  (select count(*)::int from public.fee_challan where enrolment_id = :'bilal_enrolment_id'),
  1,
  'AC4: restoring the enrolment brings back exactly one challan — no duplicate generated'
);
select is(
  (select id from public.fee_challan where enrolment_id = :'bilal_enrolment_id'),
  :'bilal_challan_id',
  'AC4: it is the SAME challan row, not a freshly generated one'
);
select is(
  (select status::text from public.fee_challan where enrolment_id = :'bilal_enrolment_id'),
  'unpaid',
  'AC4: the challan is restored to its pre-delete status (still unpaid)'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC5: 91-day purge — held (financial reference) vs purged (none)
-- ═══════════════════════════════════════════════════════════════════════

-- Held: bilal's enrolment has a fee_challan referencing it.
select public.soft_delete('enrolment', :'bilal_enrolment_id'::uuid);
reset role;
update public.enrolment set deleted_at = now() - interval '92 days' where id = :'bilal_enrolment_id';

-- Purged: a fresh student+enrolment with zero financial records at all.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);
select public.create_student(:'campus_id'::uuid, 'No Money Trail', '2015-01-01'::date, 'female') as clean_student_id \gset
select public.enrol_student(:'section_a_id'::uuid, :'clean_student_id'::uuid) as clean_enrolment_id \gset
select gr_number as clean_gr from public.student where id = :'clean_student_id' \gset
select public.soft_delete('student', :'clean_student_id'::uuid);

reset role;
update public.student set deleted_at = now() - interval '92 days' where id = :'clean_student_id';
update public.enrolment set deleted_at = now() - interval '92 days' where id = :'clean_enrolment_id';

select public.purge_soft_deleted_records(91::int) as purge_result \gset

select is(
  (select count(*)::int from public.enrolment where id = :'bilal_enrolment_id'),
  1,
  'AC5: the enrolment with a referencing fee_challan is retained, not hard-deleted'
);
select is(
  (select count(*)::int from public.purge_hold where table_name = 'enrolment' and row_id = :'bilal_enrolment_id'),
  1,
  'AC5: the retained enrolment is flagged in purge_hold'
);
select is(
  (select count(*)::int from public.student where id = :'clean_student_id'),
  0,
  'AC5: the student with no financial trail is hard-deleted by the purge job'
);
select is(
  (select count(*)::int from public.enrolment where id = :'clean_enrolment_id'),
  0,
  'AC5: its enrolment (also with no financial trail) is hard-deleted too'
);
select is(
  (select count(*)::int from public.gr_ledger where gr_number = :'clean_gr' and campus_id = :'campus_id'),
  1,
  'AC5: the permanent GR ledger entry survives the purge (student_id detached, not the row deleted)'
);
select is(
  (select student_id from public.gr_ledger where gr_number = :'clean_gr' and campus_id = :'campus_id'),
  null,
  'the surviving GR ledger row has its student_id nulled out, not dangling'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Role / campus-scope guards
-- ═══════════════════════════════════════════════════════════════════════

select public.create_student(:'campus_id'::uuid, 'Guard Target', '2015-01-01'::date, 'male') as guard_target_id \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.soft_delete(%L, %L)', 'student', :'guard_target_id'),
  'FORBIDDEN',
  'a subject teacher cannot soft-delete a student'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'north_campus_id'))::text,
  true
);
select throws_ok(
  format('select public.soft_delete(%L, %L)', 'student', :'guard_target_id'),
  'FORBIDDEN',
  'a principal scoped only to the North campus cannot soft-delete a student at MAIN'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.soft_delete('student', :'guard_target_id'::uuid);
select throws_ok(
  format('select public.restore_record(%L, %L)', 'student', :'guard_target_id'),
  'FORBIDDEN',
  'AC2: restore is Owner/Super Admin only — a Principal cannot restore even though they could delete'
);

select * from finish();
rollback;
