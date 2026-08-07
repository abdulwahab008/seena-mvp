-- pgTAP tests for FR-D03 (teachable subject and grade matrix).
begin;
select plan(21);

select public.provision_tenant('test-teachscope-co', 'Teach Scope Co', 'owner@teachscopeco.test');
select id as tenant_id from public.tenant where slug = 'test-teachscope-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner@teachscopeco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id', 'owner', 'E2E Owner');

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@teachscopeco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'subject_teacher', 'Physics Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select id as class9_id from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select id as class10_id from public.class_level where tenant_id = :'tenant_id' and code = '10' \gset
select id as class11_id from public.class_level where tenant_id = :'tenant_id' and code = '11' \gset

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code not in ('9', '10', '11');
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class9_id'::uuid, 'A', 40) as section9_id \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class11_id'::uuid, 'A', 40) as section11_id \gset

select public.create_subject('PHY', 'Physics', 'فزکس') as physics_id \gset
select public.create_subject('MATH', 'Mathematics', 'ریاضی') as math_id \gset
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class9_id'::uuid, :'physics_id'::uuid, 5::smallint) as cs9 \gset
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class11_id'::uuid, :'physics_id'::uuid, 5::smallint) as cs11 \gset

select public.create_bell_template(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'Regular',
  jsonb_build_array(jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40')),
  true
) as template_id \gset
select public.create_timetable_version(:'campus_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'Draft v1') as version_id \gset

-- Teacher approved for Physics, grades 9-10 only.
select public.create_staff_teachable_subject(:'teacher_user_id'::uuid, :'physics_id'::uuid, :'class9_id'::uuid, :'class10_id'::uuid) as grant_id \gset

-- ── can_teach ─────────────────────────────────────────────────────────

select ok(
  public.can_teach(:'teacher_user_id'::uuid, :'physics_id'::uuid, :'class9_id'::uuid),
  'can_teach: Physics for grade 9 is within the approved range'
);
select ok(
  not public.can_teach(:'teacher_user_id'::uuid, :'physics_id'::uuid, :'class11_id'::uuid),
  'can_teach: Physics for grade 11 is outside the approved 9-10 range'
);
select ok(
  not public.can_teach(:'teacher_user_id'::uuid, :'math_id'::uuid, :'class9_id'::uuid),
  'can_teach: an unapproved subject is never teachable regardless of grade'
);

-- ── AC #1: TEACH_SCOPE_VIOLATION on a direct write, no override ────────

select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(%L, %L, 1::smallint, 1::smallint, %L, %L) $$,
    :'version_id', :'section11_id', :'physics_id', :'teacher_user_id'
  ),
  'TEACH_SCOPE_VIOLATION',
  'AC: assigning a teacher to a grade outside their approved range is rejected'
);
select is(
  (select count(*)::int from public.timetable_slot where timetable_version_id = :'version_id'::uuid and section_id = :'section11_id'::uuid),
  0,
  'the rejected write never created a slot row'
);

-- ── AC #2: same write, with an override reason, succeeds and is recorded ──

select public.upsert_timetable_slot(
  :'version_id'::uuid, :'section11_id'::uuid, 1::smallint, 1::smallint, :'physics_id'::uuid, :'teacher_user_id'::uuid,
  null, null, null, null, 'temporary cover until replacement joins'
) as override_slot_id \gset
select is(
  (select staff_id from public.timetable_slot where id = :'override_slot_id'::uuid),
  :'teacher_user_id'::uuid,
  'AC: with an override reason, the out-of-scope slot saves'
);
select is(
  (select count(*)::int from public.teach_scope_override where assignment_type = 'timetable_slot' and assignment_id = :'override_slot_id'::uuid),
  1,
  'AC: exactly one teach_scope_override row is recorded for this slot'
);
select is(
  (select approved_by from public.teach_scope_override where assignment_id = :'override_slot_id'::uuid),
  :'owner_user_id'::uuid,
  'AC: the override row records the approving principal-tier user''s id'
);
select is(
  (select reason from public.teach_scope_override where assignment_id = :'override_slot_id'::uuid),
  'temporary cover until replacement joins',
  'AC: the override row records the supplied reason'
);

-- Overwriting the same cell without staff (removing the override
-- assignment) cleans up the now-irrelevant override row.
select public.upsert_timetable_slot(:'version_id'::uuid, :'section11_id'::uuid, 1::smallint, 1::smallint, :'physics_id'::uuid) as cleared_slot_id \gset
select is(
  (select count(*)::int from public.teach_scope_override where assignment_id = :'cleared_slot_id'::uuid),
  0,
  'reassigning the cell with no teacher clears the now-stale override row'
);

-- A validly in-scope slot (grade 9, under the still-active 9-10 grant,
-- no override involved) — this is the one AC #4's revocation exception
-- gets exercised against below.
select public.upsert_timetable_slot(:'version_id'::uuid, :'section9_id'::uuid, 1::smallint, 1::smallint, :'physics_id'::uuid, :'teacher_user_id'::uuid) as valid_slot_id \gset

-- ── AC #3: stream-scoped approval (Commerce group only) ─────────────────

select public.create_stream('COMMERCE', 'Commerce', 'کامرس', 'FBISE'::public.board, 11::smallint) as commerce_id \gset
select public.create_stream('PRE_ENG', 'Pre-Engineering', 'پری انجینئرنگ', 'FBISE'::public.board, 11::smallint) as pre_eng_id \gset

reset role;
select gen_random_uuid() as math_teacher_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'math_teacher_id', 'mathteacher@teachscopeco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'math_teacher_id', :'tenant_id', 'subject_teacher', 'Commerce Math Teacher');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);
select public.create_staff_teachable_subject(:'math_teacher_id'::uuid, :'math_id'::uuid, :'class11_id'::uuid, :'class11_id'::uuid, :'commerce_id'::uuid) as commerce_grant_id \gset

select ok(
  public.can_teach(:'math_teacher_id'::uuid, :'math_id'::uuid, :'class11_id'::uuid, :'commerce_id'::uuid),
  'AC: a Commerce-only Mathematics approval covers Commerce grade 11'
);
select ok(
  not public.can_teach(:'math_teacher_id'::uuid, :'math_id'::uuid, :'class11_id'::uuid, :'pre_eng_id'::uuid),
  'AC: the same Commerce-only approval does NOT cover Pre-Engineering grade 11 — group_id must match'
);

-- ── AC #4: revocation surfaces exceptions, never cascade-deletes ────────

select public.revoke_staff_teachable_subject(:'grant_id'::uuid);
select is(
  (select count(*)::int from public.staff_teachable_subject where id = :'grant_id'::uuid),
  0,
  'the grant itself is gone after revocation'
);
select is(
  (select count(*)::int from public.timetable_slot where id = :'valid_slot_id'::uuid),
  1,
  'AC: revoking the grant never deletes a timetable slot that referenced it'
);
select is(
  (select count(*)::int from public.v_teach_scope_exception where slot_id = :'valid_slot_id'::uuid),
  1,
  'AC: the now-unapproved grade-9 slot (no override) appears on the exception worklist'
);

-- Re-granting a fresh 9-only approval covers this same slot again — the
-- exception clears without touching the row.
select public.create_staff_teachable_subject(:'teacher_user_id'::uuid, :'physics_id'::uuid, :'class9_id'::uuid, :'class9_id'::uuid) as grant9_id \gset
select is(
  (select count(*)::int from public.v_teach_scope_exception where slot_id = :'valid_slot_id'::uuid),
  0,
  'a fresh matching grant clears the exception for the same slot, with no write to it at all'
);

-- A separate freshly-written grade-9 slot never appears as an exception either.
select public.upsert_timetable_slot(:'version_id'::uuid, :'section9_id'::uuid, 2::smallint, 1::smallint, :'physics_id'::uuid, :'teacher_user_id'::uuid) as slot9_id \gset
select is(
  (select count(*)::int from public.v_teach_scope_exception where slot_id = :'slot9_id'::uuid),
  0,
  'the in-scope grade-9 slot never appears on the exception worklist'
);

-- ── authorization ─────────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select throws_ok(
  format(
    $$ select public.create_staff_teachable_subject(%L, %L, %L, %L) $$,
    :'teacher_user_id', :'math_id', :'class9_id', :'class9_id'
  ),
  'FORBIDDEN',
  'a subject teacher cannot grant themselves a teachable-subject approval'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- ── validation ────────────────────────────────────────────────────────────

select throws_ok(
  format(
    $$ select public.create_staff_teachable_subject(%L, %L, %L, %L) $$,
    :'teacher_user_id', :'physics_id', :'class11_id', :'class9_id'
  ),
  'GRADE_RANGE_INVALID',
  'a "from" grade after the "to" grade is rejected'
);
select throws_ok(
  format(
    $$ select public.create_staff_teachable_subject(gen_random_uuid(), %L, %L, %L) $$,
    :'physics_id', :'class9_id', :'class9_id'
  ),
  'STAFF_NOT_FOUND',
  'an unknown staff id is rejected'
);

-- ── RLS ──────────────────────────────────────────────────────────────────

reset role;
select public.provision_tenant('test-teachscope-other', 'Other Teach Scope Co', 'owner@otherteachscope.test');
select id as other_tenant_id from public.tenant where slug = 'test-teachscope-other' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'), 'sub', gen_random_uuid())::text,
  true
);
select is(
  (select count(*)::int from public.staff_teachable_subject where staff_id = :'teacher_user_id'::uuid),
  0,
  'a different tenant entirely cannot see this tenant''s teachable-subject grants'
);

select * from finish();
rollback;
