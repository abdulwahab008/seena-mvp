-- pgTAP tests: enrolment is never blocked by billing, even outside a user request.
--
-- enrolment_ai_build_fee_plan used to depend on the caller's JWT tenant, so a
-- service-role / claim-less insert (data migration, back-filled history) failed
-- with ENROLMENT_NOT_FOUND from inside the trigger. The trigger now keys off
-- the row's own tenant; the public RPC stays caller-scoped.
begin;
select plan(7);

select public.provision_tenant('test-feeplan-sys-co', 'Fee Plan Sys Co', 'owner@feeplansys.test');
select id as tenant_id from public.tenant where slug = 'test-feeplan-sys-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-feeplan-sys-rival', 'Fee Plan Sys Rival', 'owner@feeplansysrival.test');
select id as rival_id from public.tenant where slug = 'test-feeplan-sys-rival' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'System Zero', '2015-01-01'::date, 'male') as student0_id \gset
select public.create_student(:'campus_id'::uuid, 'System One', '2015-01-01'::date, 'female') as student1_id \gset
select public.create_student(:'campus_id'::uuid, 'System Two', '2015-01-01'::date, 'female') as student2_id \gset

-- ── system context: no JWT claims at all (what service_role looks like) ──
reset role;
select set_config('request.jwt.claims', '', true);
select is(app.auth_tenant_id(), null, 'precondition: no caller tenant in this context');

select lives_ok(
  format($$ insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id)
            values (%L, %L, %L, %L, %L, %L) $$, :'tenant_id', :'campus_id', :'session_id', :'student0_id', :'class1_id', :'section_id'),
  'a claim-less enrolment insert is not blocked when no fee structure is published'
);
select is((select count(*)::int from public.fee_plan where tenant_id = :'tenant_id'), 0, '... and builds no plan (nothing to snapshot)');

-- Publish a structure (as the owner), then enrol again with no claims.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);

reset role;
select set_config('request.jwt.claims', '', true);
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id)
values (:'tenant_id', :'campus_id', :'session_id', :'student1_id', :'class1_id', :'section_id')
returning id as enrolment1_id \gset
select is(
  (select count(*)::int from public.fee_plan_line l join public.fee_plan p on p.id = l.plan_id where p.enrolment_id = :'enrolment1_id'),
  1,
  'a claim-less enrolment into a campus with a published structure still gets its fee plan snapshot'
);

-- ── the public RPC keeps its caller-scoped behaviour ─────────────────────
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id)
values (:'tenant_id', :'campus_id', :'session_id', :'student2_id', :'class1_id', :'section_id')
returning id as enrolment2_id \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'rival_id', 'app_role', 'owner', 'campus_ids', json_build_array())::text, true);
select throws_ok(
  format($$ select public.build_fee_plan(%L) $$, :'enrolment2_id'),
  'ENROLMENT_NOT_FOUND',
  'build_fee_plan still refuses another tenant''s enrolment'
);

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(
  public.build_fee_plan(:'enrolment2_id'::uuid),
  (select id from public.fee_plan where enrolment_id = :'enrolment2_id'),
  'build_fee_plan is idempotent for the caller''s own enrolment and returns the existing plan'
);
select throws_ok(
  format($$ select app.build_fee_plan_for(%L, %L) $$, :'enrolment2_id', :'tenant_id'),
  '42501',
  null,
  'the internal builder is not callable by an API role'
);

select * from finish();
rollback;
