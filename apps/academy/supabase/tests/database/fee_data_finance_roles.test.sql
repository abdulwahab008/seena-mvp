-- pgTAP tests: fee data is for the people who handle fees.
--
-- A class teacher, librarian or nurse could read every family's challans, ledger, payments and
-- receipts (and their fee plans, the fee structure and concession awards), download any challan
-- PDF and read any student's balance, because the core fee tables only asked for "a campus the
-- caller is assigned to". They now require super admin, owner, principal or accountant.
begin;
select plan(26);

select public.provision_tenant('test-fee-roles', 'Fee Roles Co', 'owner@feeroles.test');
select id as tenant_id from public.tenant where slug = 'test-fee-roles' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'owner_uid', 'o@feeroles.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'owner_uid', :'tenant_id', 'owner', 'Fee Roles Owner');
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role)
values (:'parent_uid', '923001110002', now(), 'x', 'authenticated', 'authenticated');

-- ── fixtures, built by the owner ─────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_a \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.create_student(:'campus_id'::uuid, 'Fee Role Student', '2015-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section_a'::uuid, :'student_id'::uuid) as enrol_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select public.collect_cash_payment((select id from public.fee_challan where enrolment_id = :'enrol_id'::uuid), 100000, 'fixture') as cash \gset
select public.create_concession_scheme('HARDSHIP', 'Hardship', 'مالی مشکلات', 'percentage', 10, array[:'tuition_id']::uuid[],
  p_approver_role => 'principal') as scheme_id \gset
select public.request_concession_award(:'enrol_id'::uuid, :'scheme_id'::uuid, 10, current_date, current_date + 30);

create function pg_temp.new_accepted_offer(p_campus uuid, p_phone text, p_child text)
returns uuid language plpgsql as $$
declare v_enquiry uuid; v_app uuid; v_offer uuid;
begin
  v_enquiry := public.create_enquiry(p_campus_id => p_campus, p_session_id => (select id from public.academic_session where tenant_id = app.auth_tenant_id() limit 1),
    p_child_name => p_child, p_dob => '2020-01-01'::date, p_class_applied_id => (select id from public.class_level where tenant_id = app.auth_tenant_id() and code = '1'),
    p_parent_name => 'A Parent', p_phone => p_phone, p_whatsapp_opt_in => false, p_source => 'walk_in');
  v_app := public.fn_submit_application(v_enquiry);
  v_offer := public.fn_issue_offer(v_app, 25000);
  perform public.fn_respond_to_offer(v_offer, 'accepted'::public.offer_status);
  return v_offer;
end;
$$;
select pg_temp.new_accepted_offer(:'campus_id'::uuid, '03001110001', 'Fee Role Candidate') as offer_id \gset
select public.record_admission_fee_payment(:'offer_id'::uuid, 1000000, 'cheque');

select public.fn_find_or_create_guardian(p_name_en => 'Fee Role Father', p_phone_e164 => '+923001110002') as g1 \gset
select public.link_guardian(:'student_id'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
reset role;
update public.guardian set auth_user_id = :'parent_uid' where id = :'g1';
select id as challan_id from public.fee_challan where enrolment_id = :'enrol_id'::uuid \gset

-- one row count per table the pages and the API read, as a single comparable string
create function pg_temp.fee_rows() returns text language sql stable as $$
  select concat_ws(',',
    (select count(*) from public.fee_challan),
    (select count(*) from public.fee_challan_line),
    (select count(*) from public.fee_ledger),
    (select count(*) from public.fee_payment),
    (select count(*) from public.fee_payment_allocation),
    (select count(*) from public.fee_receipt),
    (select count(*) from public.fee_plan),
    (select count(*) from public.fee_plan_line),
    (select count(*) from public.fee_structure),
    (select count(*) from public.fee_structure_line),
    (select count(*) from public.concession_award),
    (select count(*) from public.admission_fee_payment));
$$;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select pg_temp.fee_rows() as owner_rows \gset
select ok(:'owner_rows' !~ '(^|,)0(,|$)', 'fixture: the owner sees at least one row in every table we count (' || :'owner_rows' || ')');
reset role;

-- ── the finance roles still see everything ────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'accountant',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(pg_temp.fee_rows(), :'owner_rows', 'an accountant sees the same fee data as the owner');
select ok(public.student_balance(:'enrol_id'::uuid) > 0, 'and reads the balance');
select lives_ok(format($$ select public.portal_challan_payload(%L) $$, :'challan_id'), 'and can render the challan PDF payload');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'principal',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(pg_temp.fee_rows(), :'owner_rows', 'a principal sees the same fee data as the owner');

-- ── everyone else at the campus sees none of it ───────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(pg_temp.fee_rows(), '0,0,0,0,0,0,0,0,0,0,0,0', 'a subject teacher sees no fee data');
select is(public.student_balance(:'enrol_id'::uuid), 0::bigint, 'reads no balance (it comes back as nothing, not as the real figure)');
select throws_ok(format($$ select public.portal_challan_payload(%L) $$, :'challan_id'), 'CHALLAN_NOT_FOUND', 'and cannot download the challan PDF');
select throws_ok(format($$ select * from public.fn_withhold_sheet(%L, %L) $$, gen_random_uuid(), :'class1_id'), 'FORBIDDEN', 'nor read the withhold sheet of what every family owes');

select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'class_teacher',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(pg_temp.fee_rows(), '0,0,0,0,0,0,0,0,0,0,0,0', 'a class teacher sees no fee data');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'librarian',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(pg_temp.fee_rows(), '0,0,0,0,0,0,0,0,0,0,0,0', 'a librarian sees no fee data');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'nurse',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(pg_temp.fee_rows(), '0,0,0,0,0,0,0,0,0,0,0,0', 'a nurse sees no fee data');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'hr_manager',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(pg_temp.fee_rows(), '0,0,0,0,0,0,0,0,0,0,0,0', 'an HR manager sees no fee data');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'transport_manager',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(pg_temp.fee_rows(), '0,0,0,0,0,0,0,0,0,0,0,0', 'a transport manager sees no fee data');

-- the admissions staff keep what their work needs
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'admissions_officer',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(pg_temp.fee_rows(), '0,0,0,0,0,0,0,0,0,0,1,1', 'an admissions officer sees concession awards and admission fee payments only');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'vice_principal',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(pg_temp.fee_rows(), '0,0,0,0,0,0,0,0,0,0,0,1', 'a vice principal sees admission fee payments only');
select ok(public.student_balance(:'enrol_id'::uuid) > 0, 'but reads balances, which the result withholds depend on');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'receptionist',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(pg_temp.fee_rows(), '0,0,0,0,0,0,0,0,0,0,0,1', 'a receptionist sees admission fee payments only');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'exam_controller',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(pg_temp.fee_rows(), '0,0,0,0,0,0,0,0,0,0,0,0', 'an exam controller sees no fee tables');
select ok(public.student_balance(:'enrol_id'::uuid) > 0, 'but reads balances, which the withhold sheet shows by design');

-- ── a finance role at another school sees nothing ────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', gen_random_uuid(), 'app_role', 'accountant',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(pg_temp.fee_rows(), '0,0,0,0,0,0,0,0,0,0,0,0', 'an accountant of another school sees no fee data');

-- ── parents keep their own child's fees ──────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.fee_challan), 1, 'a parent still sees their child''s challan');
select ok((select count(*) from public.fee_challan_line) > 0, 'with its lines');
select ok((select count(*) from public.fee_structure) > 0, 'and the fee structure the portal shows');
select lives_ok(format($$ select public.portal_challan_payload(%L) $$, :'challan_id'), 'and can download their child''s challan');
reset role;

-- ── every root policy asks for a finance role ────────────────────────────────────────
select is(
  (select array_agg(c.relname || '.' || p.polname order by c.relname)
     from pg_policy p
     join pg_class c on c.oid = p.polrelid
    where c.relnamespace = 'public'::regnamespace
      and c.relname in ('fee_challan', 'fee_challan_batch', 'fee_ledger', 'fee_payment', 'fee_receipt', 'fee_plan', 'late_fee_rule', 'fee_structure',
                        'challan_template', 'concession_award', 'sibling_group', 'admission_fee_payment', 'admission_fee_waiver')
      and p.polcmd in ('r', '*')
      and p.polname !~ '^(portal_roles_|students_blocked)'
      and p.polname !~ 'parent'
      and pg_get_expr(p.polqual, p.polrelid) !~ 'fn_fee_staff'),
  null,
  'every read policy of the core fee tables (apart from the parents'' own) requires a finance role'
);

select * from finish();
rollback;
