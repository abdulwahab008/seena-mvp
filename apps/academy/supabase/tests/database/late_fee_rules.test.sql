-- pgTAP tests for FR-K12: configurable late fee rules.
begin;
select plan(17);

select public.provision_tenant('test-late-fee-co', 'Late Fee Co', 'owner@latefeeco.test');
select id as tenant_id from public.tenant where slug = 'test-late-fee-co' \gset
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
select public.publish_fee_structure(:'structure_id'::uuid);

-- ── student 1: billing period 2026-07 -> due_date lands on 2026-08-10,
--    a plain Monday — the exact date the AC's own examples use ─────────

select public.create_student(:'campus_id'::uuid, 'Student One', '2015-01-01'::date, 'male') as student1_id \gset
select public.enrol_student(:'section_id'::uuid, :'student1_id'::uuid) as enrol1_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, '2026-07-01'::date, false) as gen1_result \gset
select id as challan1_id, due_date as challan1_due from public.fee_challan where enrolment_id = :'enrol1_id' \gset
select is(:'challan1_due'::text, '2026-08-10', 'sanity: K09''s own due-date formula lands exactly on 10 August for a July billing period');

select public.create_late_fee_rule(
  :'campus_id'::uuid, :'session_id'::uuid, 'per_day'::public.late_fee_basis,
  p_grace_days => 3, p_amount_paisa => 5000, p_cap_paisa => 100000, p_effective_from => '2026-01-01'::date
) as rule1_id \gset

select is(public.compute_late_fee(:'challan1_id'::uuid, '2026-08-09'::date), 0::bigint, 'the day before the due date, nothing has accrued yet');
select is(
  public.compute_late_fee(:'challan1_id'::uuid, '2026-08-20'::date), 35000::bigint,
  'AC: unpaid on 20 August is 350 PKR — 10 days late minus 3 grace days = 7 chargeable days at 50 PKR/day'
);
select is(
  public.compute_late_fee(:'challan1_id'::uuid, '2026-09-20'::date), 100000::bigint,
  'AC: by 20 September the uncapped amount (38 chargeable days x 50 PKR) is clamped to the 1,000 PKR cap'
);

-- ── holiday/Sunday due-date shifting, isolated from the numbers above via
--    a second, manually-dated challan for the same student ─────────────

reset role;
insert into public.fee_challan (
  tenant_id, campus_id, enrolment_id, session_id, billing_period, challan_no, due_date, gross_paisa, net_paisa
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'enrol1_id'::uuid, :'session_id'::uuid, '2026-08-01'::date, '999999999901', '2026-08-16'::date, 500000, 500000
) returning id as challan3_id \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select is(
  public.compute_late_fee(:'challan3_id'::uuid, '2026-08-22'::date), 10000::bigint,
  'due_date 16 Aug is a Sunday, so it shifts to 17 Aug — as of 22 Aug that''s 5 days late minus 3 grace = 2 chargeable days'
);
select public.add_holiday('2026-08-17'::date, 'Test Holiday', :'campus_id'::uuid);
select is(
  public.compute_late_fee(:'challan3_id'::uuid, '2026-08-22'::date), 5000::bigint,
  'AC: registering 17 Aug as a gazetted holiday shifts the due date again, to 18 Aug — one fewer chargeable day (2 -> 1), 5000 not 10000'
);

-- ── student 2: TUITION + EXAM, for the percentage-basis and exemption ACs ──

reset role;
insert into public.fee_structure_line (structure_id, class_id, fee_head_id, amount_paisa, frequency)
values (:'structure_id'::uuid, :'class1_id'::uuid, :'exam_id'::uuid, 300000, 'monthly'::public.fee_frequency);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_student(:'campus_id'::uuid, 'Student Two', '2015-01-01'::date, 'female') as student2_id \gset
select public.enrol_student(:'section_id'::uuid, :'student2_id'::uuid) as enrol2_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, '2026-09-01'::date, false) as gen2_result \gset
select id as challan2_id, net_paisa as challan2_net from public.fee_challan where enrolment_id = :'enrol2_id' \gset
select is(:'challan2_net'::bigint, 800000::bigint, 'sanity: student 2''s challan totals PKR 8,000 across TUITION and EXAM');

select public.create_concession_scheme(
  'HARDSHIP', 'Hardship', 'مالی مشکلات', 'percentage', 0, array[:'tuition_id']::uuid[], p_category => 'hardship'
) as scheme_id \gset

select public.create_late_fee_rule(
  :'campus_id'::uuid, :'session_id'::uuid, 'percentage'::public.late_fee_basis,
  p_grace_days => 0, p_percentage => 2, p_applicable_head_ids => array[:'tuition_id']::uuid[],
  p_exempt_concession_categories => array['hardship'], p_effective_from => '2026-10-01'::date
) as rule2_id \gset

select is(
  public.compute_late_fee(:'challan2_id'::uuid, '2026-10-11'::date), 10000::bigint,
  'from 1 Oct onward the newer percentage rule is in force — a per_day pick under the old rule would have given 0 here ' ||
  '(1 day late, 3-day grace), so this can''t pass by numeric coincidence'
);
select is(
  public.compute_late_fee(:'challan2_id'::uuid, '2026-10-15'::date), 10000::bigint,
  'AC: a 2% rule on TUITION only, against a PKR 5,000 TUITION line, is 100 PKR — the EXAM line is not touched'
);

-- ── exemption: an approved hardship award zeroes the same computation ──

select public.request_concession_award(
  :'enrol2_id'::uuid, :'scheme_id'::uuid, 0, '2026-09-01'::date, '2026-12-31'::date
) as award_id \gset
select public.decide_concession_award(:'award_id'::uuid, true);
select is(
  public.compute_late_fee(:'challan2_id'::uuid, '2026-10-15'::date), 0::bigint,
  'AC: once the student holds an approved hardship-category award, the same challan/date accrues 0 late fee'
);

-- ── access control and input validation ──────────────────────────────

select throws_ok(
  format('select public.compute_late_fee(%L, %L)', gen_random_uuid(), '2026-08-20'::date),
  'CHALLAN_NOT_FOUND',
  'an unknown challan id is rejected'
);
select throws_ok(
  format(
    'select public.create_late_fee_rule(%L, %L, ''percentage''::public.late_fee_basis)',
    :'campus_id', :'session_id'
  ),
  'PERCENTAGE_REQUIRED',
  'a percentage-basis rule with no percentage value is rejected'
);
select throws_ok(
  format(
    'select public.create_late_fee_rule(%L, %L, ''per_day''::public.late_fee_basis)',
    :'campus_id', :'session_id'
  ),
  'AMOUNT_REQUIRED',
  'a per_day-basis rule with no amount is rejected'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format(
    'select public.create_late_fee_rule(%L, %L, ''flat''::public.late_fee_basis, p_amount_paisa => 10000)',
    :'campus_id', :'session_id'
  ),
  'FORBIDDEN',
  'a teacher cannot configure late fee rules'
);
select throws_ok(
  format('select public.compute_late_fee(%L, %L)', :'challan1_id', '2026-08-20'::date),
  'FORBIDDEN',
  'a teacher cannot even preview a late fee computation'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  public.compute_late_fee(:'challan1_id'::uuid, '2026-08-20'::date), 35000::bigint,
  'an accountant can preview the computation — read-only, no config permission needed'
);
select throws_ok(
  format(
    'select public.create_late_fee_rule(%L, %L, ''flat''::public.late_fee_basis, p_amount_paisa => 10000)',
    :'campus_id', :'session_id'
  ),
  'FORBIDDEN',
  'an accountant cannot configure late fee rules — that''s Owner/Super Admin only, per the FR''s own actor list'
);

select * from finish();
rollback;
