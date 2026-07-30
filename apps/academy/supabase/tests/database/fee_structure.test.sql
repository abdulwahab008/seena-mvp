-- pgTAP tests for FR-K02: fee structure per class per session.
begin;
select plan(12);

select public.provision_tenant('test-fee-struct-co', 'Fee Struct Co', 'owner@feestructco.test');
select id as tenant_id from public.tenant where slug = 'test-fee-struct-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select id as class6_id from public.class_level where tenant_id = :'tenant_id' and code = '6' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- Keeps the mandatory-head coverage check's surface small and deterministic:
-- only class 1 and class 6 stay active, matching the AC's own class-6 example.
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code not in ('1', '6');

select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select id as lab_id from public.fee_head where tenant_id = :'tenant_id' and code = 'LAB' \gset

select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select is(
  (select status::text from public.fee_structure where id = :'structure_id'),
  'draft',
  'a new structure starts in draft'
);

-- amount_paisa is bigint paisa: Rs 5,000 is stored as 500000, never 5000.00.
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000, 'monthly') as line1_id \gset
select throws_ok(
  format('select public.add_structure_line(%L, %L, %L, 500000, %L)', :'structure_id', :'class1_id', :'tuition_id', 'monthly'),
  'duplicate key value violates unique constraint "fee_structure_line_uq"',
  'a second class-wide line for the same (class, head) is rejected'
);

select throws_ok(
  format('select public.publish_fee_structure(%L)', :'structure_id'),
  'MANDATORY_HEAD_COVERAGE_GAP',
  'publishing is blocked while class 6 has no TUITION line'
);

select public.add_structure_line(:'structure_id'::uuid, :'class6_id'::uuid, :'tuition_id'::uuid, 400000, 'monthly');

-- Group-specific LAB: only Pre-Medical is charged, matching the AC's
-- class-9-groups example (any active class here demonstrates the same
-- group_code mechanism).
select public.add_structure_line(
  :'structure_id'::uuid, :'class6_id'::uuid, :'lab_id'::uuid, 120000::bigint, 'quarterly'::public.fee_frequency, 'pre_medical', 585::smallint
) as lab_line_id \gset
select is(
  (select amount_paisa from public.fee_structure_line where id = :'lab_line_id'),
  120000::bigint,
  'a group-specific LAB line stores its own amount'
);
select is(
  (select count(*)::int from public.fee_structure_line
    where structure_id = :'structure_id' and class_id = :'class6_id' and fee_head_id = :'lab_id' and group_code is null),
  0,
  'no class-wide LAB line exists for class 6 — only the Pre-Medical-specific one'
);
select is(
  (select billing_month_mask from public.fee_structure_line where id = :'lab_line_id'),
  585::smallint,
  'the billing month mask (Apr/Jul/Oct/Jan) is stored exactly as given'
);

select public.publish_fee_structure(:'structure_id'::uuid);
select is(
  (select status::text from public.fee_structure where id = :'structure_id'),
  'published',
  'publishing succeeds once every active class has its mandatory head covered'
);
select isnt(
  (select published_at from public.fee_structure where id = :'structure_id'),
  null,
  'published_at is recorded'
);

select throws_ok(
  format('select public.add_structure_line(%L, %L, %L, 100000, %L)', :'structure_id', :'class1_id', :'lab_id', 'monthly'),
  'STRUCTURE_NOT_DRAFT',
  'a published structure can no longer have lines added'
);

-- Publishing a second structure for the same campus+session supersedes the first.
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure2_id \gset
select public.add_structure_line(:'structure2_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 550000, 'monthly');
select public.add_structure_line(:'structure2_id'::uuid, :'class6_id'::uuid, :'tuition_id'::uuid, 450000, 'monthly');
select public.publish_fee_structure(:'structure2_id'::uuid);
select is(
  (select status::text from public.fee_structure where id = :'structure_id'),
  'superseded',
  'the previously published structure is superseded once a new one publishes'
);

select throws_ok(
  format('select public.add_structure_line(%L, %L, %L, 100000, %L)', gen_random_uuid(), :'class1_id', :'tuition_id', 'monthly'),
  'STRUCTURE_NOT_FOUND',
  'a bogus structure_id is rejected'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.create_draft_structure(%L, %L)', :'campus_id', :'session_id'),
  'FORBIDDEN',
  'a subject teacher cannot create a fee structure'
);

select * from finish();
rollback;
