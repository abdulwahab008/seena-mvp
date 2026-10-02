-- pgTAP tests for FR-K04: per-student fee plan snapshot.
begin;
select plan(13);

select public.provision_tenant('test-fee-plan-co', 'Fee Plan Co', 'owner@feeplanco.test');
select id as tenant_id from public.tenant where slug = 'test-fee-plan-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as principal_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_id', 'principal@feeplanco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_id', :'tenant_id', 'principal', 'Principal One');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- Keeps the mandatory-head coverage check's surface to just class 1.
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Student Zero', '2015-01-01'::date, 'male') as student0_id \gset

-- ── no published structure yet: enrolling never blocks, and builds no plan ──

select public.enrol_student(:'section_id'::uuid, :'student0_id'::uuid) as enrolment0_id \gset
select is(
  (select count(*)::int from public.fee_plan where enrolment_id = :'enrolment0_id'),
  0,
  'enrolling before any fee structure is published creates no fee plan — and does not block the enrolment'
);

-- ── build the structure: TUITION (mandatory) and TRANSPORT, class 1 only ──

select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select id as transport_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TRANSPORT' \gset

select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency) as tuition_line_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'transport_id'::uuid, 200000::bigint, 'monthly'::public.fee_frequency) as transport_line_id \gset
select public.publish_fee_structure(:'structure_id'::uuid);

-- ── a student with no transport opt-in gets only the TUITION line ──────

select public.create_student(:'campus_id'::uuid, 'Student One', '2015-01-01'::date, 'female') as student1_id \gset
select public.enrol_student(:'section_id'::uuid, :'student1_id'::uuid) as enrolment1_id \gset
select public.fee_plan.id as plan1_id from public.fee_plan where enrolment_id = :'enrolment1_id' \gset

select is(
  (select count(*)::int from public.fee_plan_line where plan_id = :'plan1_id'),
  1,
  'a student with no transport opt-in gets exactly one fee plan line (TUITION only)'
);
select is(
  (select fee_head_id from public.fee_plan_line where plan_id = :'plan1_id'),
  :'tuition_id'::uuid,
  'the one line is TUITION'
);
select is(
  (select source_structure_line_id from public.fee_plan_line where plan_id = :'plan1_id'),
  :'tuition_line_id'::uuid,
  'the line records exactly which structure line it was snapshotted from'
);

-- ── a student with an active transport route also gets the TRANSPORT line ──

select public.create_student(:'campus_id'::uuid, 'Student Two', '2015-01-01'::date, 'male') as student2_id \gset
reset role;
insert into public.student_transport (tenant_id, campus_id, student_id, session_id, opt_in, route_id)
values (:'tenant_id', :'campus_id', :'student2_id', :'session_id', true, gen_random_uuid());
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.enrol_student(:'section_id'::uuid, :'student2_id'::uuid) as enrolment2_id \gset
select public.fee_plan.id as plan2_id from public.fee_plan where enrolment_id = :'enrolment2_id' \gset
select is(
  (select count(*)::int from public.fee_plan_line where plan_id = :'plan2_id'),
  2,
  'a student with an active transport route gets both TUITION and TRANSPORT lines'
);

-- ── override gate: FORBIDDEN, then pending, unapplied until approved ───

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format($$ select public.propose_fee_plan_override(%L, 400000, 'board approved staff rate') $$, (select id from public.fee_plan_line where plan_id = :'plan1_id')),
  'FORBIDDEN',
  'a subject teacher cannot propose a fee plan override'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select id as tuition_plan_line_id from public.fee_plan_line where plan_id = :'plan1_id' \gset
select public.propose_fee_plan_override(:'tuition_plan_line_id'::uuid, 400000::bigint, 'board approved staff rate');
select is(
  (select override_status::text from public.fee_plan_line where id = :'tuition_plan_line_id'),
  'pending_approval',
  'a proposed override enters pending_approval'
);
select is(
  (select amount_paisa from public.fee_plan_line where id = :'tuition_plan_line_id'),
  500000::bigint,
  'amount_paisa is unchanged while the override is pending — never used until approved'
);

select throws_ok(
  format('select public.decide_fee_plan_override(%L, true)', :'tuition_plan_line_id'),
  'FORBIDDEN',
  'an accountant cannot approve their own proposed override — only a principal can'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', :'principal_id', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id')
  )::text,
  true
);
select public.decide_fee_plan_override(:'tuition_plan_line_id'::uuid, true);
select is(
  (select amount_paisa from public.fee_plan_line where id = :'tuition_plan_line_id'),
  400000::bigint,
  'approval applies the proposed amount — the only function ever allowed to move amount_paisa after the initial snapshot'
);
select isnt(
  (select approved_by from public.fee_plan_line where id = :'tuition_plan_line_id'),
  null,
  'the approver is recorded'
);

-- ── removal end-dates, never deletes ────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select id as transport_plan_line_id from public.fee_plan_line where plan_id = :'plan2_id' and fee_head_id = :'transport_id' \gset
select public.remove_fee_plan_line(:'transport_plan_line_id'::uuid, 'family relocated, no longer needs the bus');
select isnt(
  (select effective_to from public.fee_plan_line where id = :'transport_plan_line_id'),
  null,
  'removal end-dates the line rather than deleting it'
);
select throws_ok(
  format('select public.remove_fee_plan_line(%L)', :'transport_plan_line_id'),
  'ALREADY_REMOVED',
  'removing an already-removed line is rejected'
);

select * from finish();
rollback;
