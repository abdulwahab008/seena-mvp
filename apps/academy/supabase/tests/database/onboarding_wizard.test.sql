-- pgTAP tests for FR-A03: assisted onboarding wizard.
begin;
select plan(28);

select public.provision_tenant('test-onboard-co', 'Onboard Co', 'owner@onboardco.test');
select id as tenant_id from public.tenant where slug = 'test-onboard-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset

select public.provision_tenant('test-onboard-other-co', 'Onboard Other Co', 'owner@onboardotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-onboard-other-co' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset

-- No app_user row is needed for this: the 'sub' claim below is what
-- auth.uid() reads, independent of any app_user table lookup, same as
-- every other pgTAP test in this suite that stamps a *_by column.
select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner-sub@onboardco.test', 'x', now(), 'authenticated', 'authenticated');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- ── seeding at provisioning ──────────────────────────────────────────────

select is(
  (select count(*)::int from public.onboarding_progress where tenant_id = :'tenant_id'),
  7,
  'AC: provision_tenant seeds exactly 7 onboarding steps'
);
select is(
  (select count(*)::int from public.onboarding_progress where tenant_id = :'tenant_id' and status = 'pending'),
  7,
  'all 7 steps start pending'
);
select is(
  (select distinct steps_total from public.v_onboarding_summary where tenant_id = :'tenant_id'),
  7,
  'v_onboarding_summary reports 7 steps total'
);
select is(
  (select distinct steps_resolved from public.v_onboarding_summary where tenant_id = :'tenant_id'),
  0,
  'v_onboarding_summary reports 0 resolved before anything is marked'
);

-- ── preset catalogue ─────────────────────────────────────────────────────

select ok(
  (select count(*)::int from public.class_structure_preset where code = 'nursery_kg_1_10') = 1,
  'AC: the Nursery/KG/1-10 preset exists in the catalogue'
);
select is(
  (select jsonb_array_length(class_rows) from public.class_structure_preset where code = 'nursery_kg_1_10'),
  12,
  'AC: the preset produces exactly 12 class rows'
);

-- ── complete_onboarding_step ─────────────────────────────────────────────

select public.complete_onboarding_step('campus_details', 'done');
select is(
  (select status::text from public.onboarding_progress where tenant_id = :'tenant_id' and step_key = 'campus_details'),
  'done',
  'marking a step done persists its status'
);
select is(
  (select completed_by from public.onboarding_progress where tenant_id = :'tenant_id' and step_key = 'campus_details'),
  :'owner_user_id'::uuid,
  'completed_by is stamped with the acting user'
);
select isnt(
  (select completed_at from public.onboarding_progress where tenant_id = :'tenant_id' and step_key = 'campus_details'),
  null,
  'completed_at is stamped'
);
select is(
  (select distinct steps_resolved from public.v_onboarding_summary where tenant_id = :'tenant_id'),
  1,
  'steps_resolved is 1 after marking one step done'
);

select public.complete_onboarding_step('fee_heads', 'skipped');
select is(
  (select status::text from public.onboarding_progress where tenant_id = :'tenant_id' and step_key = 'fee_heads'),
  'skipped',
  'AC: a step can be explicitly skipped rather than done'
);
select is(
  (select distinct steps_resolved from public.v_onboarding_summary where tenant_id = :'tenant_id'),
  2,
  'AC: a skipped step still counts toward the resolved total, same as the "6/7" checklist example'
);

select throws_ok(
  $$ select public.complete_onboarding_step('branding', 'pending') $$,
  'ONBOARDING_STATUS_INVALID',
  'a step cannot be explicitly reset back to pending'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  $$ select public.complete_onboarding_step('branding', 'done') $$,
  'FORBIDDEN',
  'a class teacher cannot progress the onboarding checklist'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- ── apply_class_preset ───────────────────────────────────────────────────

select public.apply_class_preset(:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, 'nursery_kg_1_10') as preset_result \gset
select is(
  (:'preset_result'::jsonb ->> 'class_count')::int,
  12,
  'AC: applying the preset touches 12 class rows'
);
select is(
  (:'preset_result'::jsonb ->> 'sections_created')::int,
  12,
  'AC: applying the preset creates one default section per class'
);
select is(
  (select count(*)::int from public.class_level where tenant_id = :'tenant_id' and is_active = true),
  12,
  'exactly the 12 preset classes are active'
);
select is(
  (select is_active from public.class_level where tenant_id = :'tenant_id' and code = '11'),
  false,
  'AC: a class outside the chosen preset (11) is deactivated, not deleted'
);
select is(
  (select count(*)::int from public.class_section cs join public.class_level cl on cl.id = cs.class_level_id
    where cl.tenant_id = :'tenant_id' and cs.name = 'A'),
  12,
  'one "A" section exists per active preset class'
);

select public.apply_class_preset(:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, 'nursery_kg_1_10') as rerun_result \gset
select is(
  (:'rerun_result'::jsonb ->> 'sections_created')::int,
  0,
  'AC: re-applying the same preset is idempotent — no new sections on the second run'
);
select is(
  (select count(*)::int from public.class_section cs join public.class_level cl on cl.id = cs.class_level_id
    where cl.tenant_id = :'tenant_id' and cs.name = 'A'),
  12,
  'the section count is unchanged after the idempotent re-run'
);

select public.apply_class_preset(:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, 'nursery_kg_1_12') as widen_result \gset
select is(
  (select is_active from public.class_level where tenant_id = :'tenant_id' and code = '11'),
  true,
  'switching to a wider preset re-activates the previously-dropped class'
);
select is(
  (:'widen_result'::jsonb ->> 'sections_created')::int,
  2,
  'widening the preset creates default sections only for the newly-included classes (11, 12)'
);

select throws_ok(
  format($$ select public.apply_class_preset(%L, %L, %L, 'does_not_exist') $$, :'tenant_id', :'campus_id', :'session_id'),
  'PRESET_NOT_FOUND',
  'an unknown preset code is rejected'
);
select throws_ok(
  format($$ select public.apply_class_preset(%L, %L, %L, 'nursery_kg_1_10') $$, :'tenant_id', :'other_campus_id', :'session_id'),
  'CAMPUS_NOT_FOUND',
  'a campus belonging to a different tenant is rejected'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format($$ select public.apply_class_preset(%L, %L, %L, 'nursery_kg_1_10') $$, :'tenant_id', :'campus_id', :'session_id'),
  'FORBIDDEN',
  'a class teacher cannot apply a class structure preset'
);

-- ── cross-tenant isolation ───────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'))::text,
  true
);
select is(
  (select count(*)::int from public.onboarding_progress where tenant_id = :'tenant_id'),
  0,
  'AC: a different tenant''s owner cannot read this tenant''s onboarding progress'
);
select is(
  (select count(*)::int from public.onboarding_progress where tenant_id = :'other_tenant_id'),
  7,
  'sanity: the other tenant has its own independent 7-step checklist'
);

select * from finish();
rollback;
