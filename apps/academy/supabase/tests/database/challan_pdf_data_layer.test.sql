-- pgTAP tests for FR-K11: three-copy bank challan PDF (data layer).
begin;
select plan(13);

select public.provision_tenant('test-challan-pdf-co', 'Challan PDF Co', 'owner@challanpdfco.test');
select id as tenant_id from public.tenant where slug = 'test-challan-pdf-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset

select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select id as exam_id from public.fee_head where tenant_id = :'tenant_id' and code = 'EXAM' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency) as tuition_line_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'exam_id'::uuid, 300000::bigint, 'monthly'::public.fee_frequency) as exam_line_id \gset
select public.publish_fee_structure(:'structure_id'::uuid);

select public.create_student(:'campus_id'::uuid, 'Payload Student', '2015-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrol_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, '2026-08-01'::date, false) as gen_result \gset
select id as challan_id, challan_no from public.fee_challan where enrolment_id = :'enrol_id' \gset

-- ── template config ──────────────────────────────────────────────────

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format(
    'select public.set_challan_template(%L, ''MCB Bank'', ''ABC School Trust'', ''1234567890'')',
    :'campus_id'
  ),
  'FORBIDDEN',
  'an accountant cannot configure the bank challan template — Owner/Super Admin only'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.set_challan_template(
  :'campus_id'::uuid, 'MCB Bank', 'ABC School Trust', '1234567890',
  p_footer_note_en => 'Please pay before the due date.'
);
select is(
  (select bank_name from public.challan_template where campus_id = :'campus_id'),
  'MCB Bank',
  'the template is saved'
);
select public.set_challan_template(:'campus_id'::uuid, 'HBL Bank', 'ABC School Trust', '1234567890');
select is(
  (select count(*)::int from public.challan_template where campus_id = :'campus_id'),
  1,
  'a second call upserts — still exactly one template row per campus'
);

-- ── render payload ──────────────────────────────────────────────────

select public.build_challan_render_payload(:'challan_id'::uuid) as payload \gset

select is(
  :'payload'::jsonb ->> 'challan_no', :'challan_no',
  'the payload''s challan_no matches the real challan'
);
select is(
  :'payload'::jsonb ->> 'barcode_value', :'challan_no',
  'AC: barcode_value is exactly the challan_no a Code-128 scan must decode back to'
);
select is(
  (:'payload'::jsonb -> 'bank' ->> 'bank_name'),
  'HBL Bank',
  'the payload reflects the currently-configured template, not a stale copy'
);
select is(
  jsonb_array_length(:'payload'::jsonb -> 'lines'),
  2,
  'both fee lines (TUITION and EXAM) are present in the payload'
);
select is(
  (:'payload'::jsonb ->> 'net_paisa')::bigint,
  800000::bigint,
  'AC: the payload''s net payable is exact to the paisa (500000 + 300000)'
);
select is(
  (
    select coalesce(sum((line ->> 'net_paisa')::bigint), 0)::bigint
      from jsonb_array_elements(:'payload'::jsonb -> 'lines') as line
  ),
  (:'payload'::jsonb ->> 'net_paisa')::bigint,
  'AC: the sum of the individual lines'' net figures equals the header net figure to the paisa — no rounding drift'
);
select is(
  :'payload'::jsonb -> 'copies',
  '["bank", "school", "student"]'::jsonb,
  'AC: one payload for all three copies — "identical across all three copies" is structural, not three renderers agreeing by luck'
);
select is(
  (:'payload'::jsonb -> 'student' ->> 'name_en'),
  'Payload Student',
  'the student identity is embedded in the payload'
);

select throws_ok(
  format('select public.build_challan_render_payload(%L)', gen_random_uuid()),
  'CHALLAN_NOT_FOUND',
  'an unknown challan id is rejected'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.build_challan_render_payload(%L)', :'challan_id'),
  'FORBIDDEN',
  'a teacher cannot build a challan render payload'
);

select * from finish();
rollback;
