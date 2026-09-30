-- pgTAP tests for the Module K independent-review fixes
-- (20260731210000_module_k_review_fixes.sql).
--
-- Bug #4 (generate_challans() aborting the whole batch on a concurrent
-- unique_violation) isn't covered here: reproducing it needs two
-- genuinely concurrent connections racing the same insert, which a
-- single-connection pgTAP transaction can't simulate — the same
-- limitation already noted for FR-K10's own concurrency claim. The full
-- suite passing unchanged after adding the exception block is the
-- available evidence that the fix doesn't regress the (fully tested)
-- sequential-rerun idempotency path.
begin;
select plan(9);

select public.provision_tenant('test-k-review-fix-co', 'K Review Fix Co', 'owner@kreviewfixco.test');
select id as tenant_id from public.tenant where slug = 'test-k-review-fix-co' \gset
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

select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency) as tuition_line_id \gset
select public.publish_fee_structure(:'structure_id'::uuid);

-- ── fix #2: a second, unrelated draft can no longer be created once a
--    structure is already published for this campus+session ──────────

select throws_ok(
  format('select public.create_draft_structure(%L, %L)', :'campus_id', :'session_id'),
  'PUBLISHED_STRUCTURE_EXISTS_USE_NEXT_VERSION',
  'a second, unrelated draft is refused — closes the regulator-cap bypass this review found'
);
select public.create_next_structure_version(:'structure_id'::uuid, (current_date + 30)::date) as v2_id \gset
select is(
  (select supersedes_id from public.fee_structure where id = :'v2_id'),
  :'structure_id'::uuid,
  'the correct path, create_next_structure_version(), still works and correctly links supersedes_id'
);

-- ── fix #3: add_structure_line() rejects a foreign-tenant class/head ───

reset role;
select public.provision_tenant('test-k-review-fix-other-co', 'K Review Fix Other Co', 'owner@kreviewfixotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-k-review-fix-other-co' \gset
select id as other_class1_id from public.class_level where tenant_id = :'other_tenant_id' and code = '1' \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select throws_ok(
  format(
    'select public.add_structure_line(%L, %L, %L, 100000, ''monthly''::public.fee_frequency)',
    :'v2_id', :'other_class1_id', :'tuition_id'
  ),
  'CLASS_LEVEL_NOT_FOUND',
  'a class_id belonging to a different tenant is rejected'
);

-- ── fix #1: a negative concession value is rejected, both at request-
--    time and edit-time, and the table itself now enforces it too ────

select public.create_concession_scheme(
  'NEGTEST', 'Negative Test Scheme', 'منفی ٹیسٹ', 'percentage', 10, array[:'tuition_id']::uuid[]
) as scheme_id \gset
select public.create_student(:'campus_id'::uuid, 'Value Test Student', '2015-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrol_id \gset

select throws_ok(
  format(
    'select public.request_concession_award(%L, %L, -5, current_date, current_date + 30)',
    :'enrol_id', :'scheme_id'
  ),
  'VALUE_MUST_BE_NONNEGATIVE',
  'AC: a negative concession value is rejected at request-time, before it can ever reach a challan'
);

select public.request_concession_award(
  :'enrol_id'::uuid, :'scheme_id'::uuid, 5, current_date, current_date + 30
) as award_id \gset
select throws_ok(
  format('select public.edit_concession_award(%L, -1)', :'award_id'),
  'VALUE_MUST_BE_NONNEGATIVE',
  'a negative value is also rejected on edit, not just on the initial request'
);

reset role;
select throws_ok(
  format('update public.concession_award set value = -1 where id = %L', :'award_id'),
  'new row for relation "concession_award" violates check constraint "ck_concession_award_value_nonnegative"',
  'the table-level CHECK is the real backstop — it holds even against a direct write that bypasses both RPCs'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── fix #5: admissions_officer, widened onto request_concession_award()
--    by FR-K07, is confirmed still able to call it directly too ──────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.request_concession_award(
  :'enrol_id'::uuid, :'scheme_id'::uuid, 8, current_date, current_date + 60
) as award2_id \gset
select is(
  (select status::text from public.concession_award where id = :'award2_id'),
  'pending',
  'an admissions_officer can request a concession award directly, not just via the sibling-detection scan'
);

-- ── sanity: the whole flow still produces a correct, capped challan ────

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, date_trunc('month', current_date)::date, false) as gen_result \gset
select is(
  (:'gen_result'::jsonb ->> 'generated')::int, 1,
  'the fixes did not regress ordinary challan generation'
);
select is(
  (select count(*)::int from public.fee_challan_line where net_paisa < 0),
  0,
  'no negative net line was ever produced — the whole point of catching negative concession values upstream'
);

select * from finish();
rollback;
