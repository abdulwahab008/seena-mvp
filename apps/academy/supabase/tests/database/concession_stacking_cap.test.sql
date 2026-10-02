-- pgTAP tests for FR-K08: concession stacking cap and expiry.
begin;
select plan(14);

select public.provision_tenant('test-stacking-co', 'Stacking Co', 'owner@stackingco.test');
select id as tenant_id from public.tenant where slug = 'test-stacking-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as principal_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_id', 'principal@stackingco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_id', :'tenant_id', 'principal', 'Principal One');

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

-- ── AC: with no fee_policy row, only the per-line-gross clamp applies —
--    a 6,000 PKR fixed award against a 5,000 PKR line clamps to 5,000 ──

select public.create_concession_scheme(
  'FIXED-BIG', 'Oversized Fixed Award', 'بڑی رقم', 'fixed_amount', 6000, array[:'tuition_id']::uuid[]
) as fixed_scheme_id \gset
select public.create_student(:'campus_id'::uuid, 'Student B Fixed', '2015-01-01'::date, 'female') as student_b_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_b_id'::uuid) as enrol_b_id \gset
select public.request_concession_award(
  :'enrol_b_id'::uuid, :'fixed_scheme_id'::uuid, 6000, date_trunc('month', current_date)::date, (date_trunc('month', current_date) + interval '6 months')::date
) as award_fixed_id \gset
select public.decide_concession_award(:'award_fixed_id'::uuid, true);

select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, date_trunc('month', current_date)::date, false) as gen_b_result \gset
select concession_paisa, net_paisa from public.fee_challan_line
  where challan_id = (select id from public.fee_challan where enrolment_id = :'enrol_b_id') \gset
select is(
  :'concession_paisa'::bigint, 500000::bigint,
  'AC: with no stacking policy, a 600000-paisa fixed award against a 500000-paisa line clamps to the line''s own gross'
);
select is(:'net_paisa'::bigint, 0::bigint, 'the line''s net is never negative — clamped to exactly 0, not -100000');

-- ── set the tenant-wide stacking cap ────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  'select public.set_fee_policy(50, false)',
  'FORBIDDEN',
  'an accountant cannot set fee policy — Owner/Super Admin only'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.set_fee_policy(50, false);
select is(
  (select max_stacked_concession_pct from public.fee_policy where tenant_id = :'tenant_id'),
  50.00::numeric,
  'the policy row is created on first call'
);
select public.set_fee_policy(60, false);
select is(
  (select count(*)::int from public.fee_policy where tenant_id = :'tenant_id'),
  1,
  'a second call upserts — still exactly one policy row per tenant'
);
select public.set_fee_policy(50, false);

-- ── AC: 30% + 40% stacked on TUITION, capped at 50% of the line ────────

select public.create_concession_scheme(
  'SIB30', 'Sibling 30%', 'بہن بھائی 30%', 'percentage', 30, array[:'tuition_id']::uuid[], p_approver_role => 'principal'
) as sib_scheme_id \gset
select public.create_concession_scheme(
  'MERIT40', 'Merit 40%', 'میرٹ 40%', 'percentage', 40, array[:'tuition_id']::uuid[], p_approver_role => 'principal'
) as merit_scheme_id \gset

select public.create_student(:'campus_id'::uuid, 'Student A Stacked', '2015-01-01'::date, 'male') as student_a_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_a_id'::uuid) as enrol_a_id \gset
-- Deliberately short-dated (expires 15 Aug, not year-end): still covers
-- the August billing period used below, and lets the expiry section
-- later expire it without a raw UPDATE — editing effective_to on an
-- approved award through anything other than creation would trip
-- FR-K06's own "editing resets to pending" trigger, which is correct
-- behaviour but not what this test is exercising.
select public.request_concession_award(
  :'enrol_a_id'::uuid, :'sib_scheme_id'::uuid, 30, date_trunc('month', current_date)::date, (date_trunc('month', current_date)::date + 14)
) as award_sib_id \gset
select public.request_concession_award(
  :'enrol_a_id'::uuid, :'merit_scheme_id'::uuid, 40, date_trunc('month', current_date)::date, (date_trunc('month', current_date) + interval '6 months')::date
) as award_merit_id \gset
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', :'principal_id', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id')
  )::text,
  true
);
select public.decide_concession_award(:'award_sib_id'::uuid, true);
select public.decide_concession_award(:'award_merit_id'::uuid, true);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, date_trunc('month', current_date)::date, false) as gen_a_result \gset
select id as line_a_id, concession_paisa as concession_a, net_paisa as net_a, applied_award_ids
  from public.fee_challan_line where challan_id = (select id from public.fee_challan where enrolment_id = :'enrol_a_id') \gset
select is(
  :'concession_a'::bigint, 250000::bigint,
  'AC: 30% + 40% (350000 paisa raw) is capped at 50% of the 500000-paisa line, exactly 250000'
);
select is(:'net_a'::bigint, 250000::bigint, 'net payable is the remaining 250000');
select is(
  (:'applied_award_ids'::text like '%' || :'award_sib_id' || '%') and (:'applied_award_ids'::text like '%' || :'award_merit_id' || '%'),
  true,
  'AC: the challan line references both award ids that contributed to the capped concession'
);

-- ── expiry ──────────────────────────────────────────────────────────

select throws_ok(
  format('select public.expire_due_concessions(%L)', (date_trunc('month', current_date)::date + 19)),
  'permission denied for function expire_due_concessions',
  'an authenticated owner cannot call expire_due_concessions directly — it is service_role only'
);

reset role;
select public.expire_due_concessions((date_trunc('month', current_date)::date + 19)) as expired_count \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
-- >=, not =: expire_due_concessions() is cross-tenant by construction
-- (see the migration header) — in this shared local dev database, an
-- already-committed award left behind by an unrelated e2e run with its
-- own past effective_to would legitimately also expire in the same
-- call. The award-scoped assertions right below are the real proof for
-- this AC; this one only proves ours wasn't missed.
select cmp_ok(:'expired_count'::int, '>=', 1, 'AC: at least this test''s own award (past its effective_to) is expired');
select is(
  (select status::text from public.concession_award where id = :'award_sib_id'),
  'expired',
  'AC: the sibling award''s status is flipped to expired'
);
select is(
  (select status::text from public.concession_award where id = :'award_merit_id'),
  'approved',
  'the merit award, still within its effective window, is untouched'
);
select is(
  (
    select count(*)::int from public.audit_log
     where table_name = 'concession_award' and row_id = :'award_sib_id'
       and 'status' = any(changed_columns) and after ->> 'status' = 'expired'
  ),
  1,
  'AC: the expiry is recorded — the existing audit trigger logs the pending->approved transition too, ' ||
  'but exactly one row captures this specific approved->expired change, no separate table needed'
);

reset role;
select public.expire_due_concessions((date_trunc('month', current_date)::date + 20)) as expired_again_count \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
-- Award-scoped, not the raw count (which, like above, is a cross-tenant
-- total): the merit award specifically is still 'approved' after this
-- second call — proof that a re-run doesn't touch an award that isn't
-- due, which is what "finds nothing new to expire" actually means for
-- this test's own data.
select is(
  (select status::text from public.concession_award where id = :'award_merit_id'),
  'approved',
  're-running the expiry job a day later still leaves the not-yet-due merit award untouched'
);

select * from finish();
rollback;
