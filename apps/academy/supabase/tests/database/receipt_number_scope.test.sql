-- pgTAP tests: receipt numbers run on per campus, across academic sessions.
--
-- The receipt counter was keyed by (tenant, campus, session) while the unique index on
-- fee_receipt was tenant-wide, so the first cash receipt at a second campus, and the first one of
-- a new academic session, tried to issue RCP-00000001 again and failed with a duplicate key.
begin;
select plan(14);

select public.provision_tenant('test-receipt-scope', 'Receipt Scope Co', 'owner@receiptscope.test');
select id as tenant_id from public.tenant where slug = 'test-receipt-scope' \gset
select id as campus1_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session1_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'North Campus', 'NC') returning id as campus2_id \gset
select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'owner_uid', 'o@receiptscope.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'owner_uid', :'tenant_id', 'owner', 'Receipt Scope Owner');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus1_id', :'campus2_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset

select (current_date + interval '1 year')::date as s2_start, (current_date + interval '2 years' - interval '1 day')::date as s2_end \gset
select public.create_academic_session(:'campus1_id'::uuid, 'Receipt Scope Next Year', :'s2_start'::date, :'s2_end'::date) as session2_id \gset

select public.create_section(:'campus1_id'::uuid, :'session1_id'::uuid, :'class1_id'::uuid, 'A', 20) as c1_section \gset
select public.create_section(:'campus2_id'::uuid, :'session1_id'::uuid, :'class1_id'::uuid, 'A', 20) as c2_section \gset
select public.create_section(:'campus1_id'::uuid, :'session2_id'::uuid, :'class1_id'::uuid, 'A', 20) as c1_section_next \gset

select public.create_draft_structure(:'campus1_id'::uuid, :'session1_id'::uuid) as st1 \gset
select public.add_structure_line(:'st1'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'st1'::uuid);
select public.create_draft_structure(:'campus2_id'::uuid, :'session1_id'::uuid) as st2 \gset
select public.add_structure_line(:'st2'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'st2'::uuid);
select public.create_draft_structure(:'campus1_id'::uuid, :'session2_id'::uuid) as st3 \gset
select public.add_structure_line(:'st3'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'st3'::uuid);

select public.create_student(:'campus1_id'::uuid, 'Receipt Kid A', '2015-01-01'::date, 'male') as sa \gset
select public.create_student(:'campus1_id'::uuid, 'Receipt Kid B', '2015-01-02'::date, 'female') as sb \gset
select public.create_student(:'campus2_id'::uuid, 'Receipt Kid C', '2015-01-03'::date, 'male') as sc \gset
select public.create_student(:'campus2_id'::uuid, 'Receipt Kid D', '2015-01-04'::date, 'female') as sd \gset
select public.create_student(:'campus1_id'::uuid, 'Receipt Kid E', '2015-01-05'::date, 'male') as se \gset
select public.create_student(:'campus2_id'::uuid, 'Receipt Kid F', '2015-01-06'::date, 'female') as sf \gset
select public.enrol_student(:'c1_section'::uuid, :'sa'::uuid) as ea \gset
select public.enrol_student(:'c1_section'::uuid, :'sb'::uuid) as eb \gset
select public.enrol_student(:'c2_section'::uuid, :'sc'::uuid) as ec \gset
select public.enrol_student(:'c2_section'::uuid, :'sd'::uuid) as ed \gset
select public.enrol_student(:'c1_section_next'::uuid, :'se'::uuid) as ee \gset
select public.enrol_student(:'c2_section'::uuid, :'sf'::uuid) as ef \gset

select public.generate_challans(:'campus1_id'::uuid, :'session1_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select public.generate_challans(:'campus2_id'::uuid, :'session1_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select public.generate_challans(:'campus1_id'::uuid, :'session2_id'::uuid, :'s2_start'::date, false);
reset role;
select id as ca from public.fee_challan where enrolment_id = :'ea' \gset
select id as cb from public.fee_challan where enrolment_id = :'eb' \gset
select id as cc from public.fee_challan where enrolment_id = :'ec' \gset
select id as cd from public.fee_challan where enrolment_id = :'ed' \gset
select id as ce from public.fee_challan where enrolment_id = :'ee' \gset
select id as cf from public.fee_challan where enrolment_id = :'ef' \gset

-- ── the cash counter issues receipts at both campuses and in a new session ───────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus1_id', :'campus2_id'))::text, true);
select lives_ok(format($$ select public.collect_cash_payment(%L, 100000, 'rcpt-a') $$, :'ca'), 'the first receipt at the Main campus is issued');
select lives_ok(format($$ select public.collect_cash_payment(%L, 100000, 'rcpt-c') $$, :'cc'), 'so is the first receipt at the North campus');
select lives_ok(format($$ select public.collect_cash_payment(%L, 100000, 'rcpt-b') $$, :'cb'), 'a second receipt at the Main campus is issued');
select lives_ok(format($$ select public.collect_cash_payment(%L, 100000, 'rcpt-e') $$, :'ce'), 'so is the first receipt of the next academic session');
select lives_ok(format($$ select public.collect_cash_payment(%L, 100000, 'rcpt-d') $$, :'cd'), 'and a second receipt at the North campus');
reset role;

create function pg_temp.receipt_of(p_enrolment uuid) returns text language sql as $$
  select r.receipt_no from public.fee_receipt r join public.fee_payment p on p.id = r.payment_id where p.enrolment_id = p_enrolment
$$;
select is(pg_temp.receipt_of(:'ea'::uuid), 'RCP-00000001', 'the Main campus series starts at one');
select is(pg_temp.receipt_of(:'ec'::uuid), 'RCP-00000001', 'the North campus has its own series, also starting at one');
select is(pg_temp.receipt_of(:'eb'::uuid), 'RCP-00000002', 'the Main campus series continues');
select is(pg_temp.receipt_of(:'ee'::uuid), 'RCP-00000003', 'a new academic session carries the series on instead of starting again at one');
select is(pg_temp.receipt_of(:'ed'::uuid), 'RCP-00000002', 'the North campus series continues');
select is((select count(*)::int from public.fee_receipt_counter where tenant_id = :'tenant_id' and campus_id = :'campus1_id'), 1,
  'a campus keeps one running series however many sessions it issues in');
select throws_ok(
  format($$ insert into public.fee_receipt (tenant_id, campus_id, payment_id, receipt_no) values (%L, %L, (select id from public.fee_payment where enrolment_id = %L), 'RCP-00000001') $$,
    :'tenant_id', :'campus1_id', :'eb'),
  '23505', null, 'a campus cannot hand out the same receipt number twice'
);

-- A campus that already has counters from before (one per session) carries on above the highest.
alter table public.fee_receipt_counter disable trigger trg_block_manual_receipt_no_edit;
insert into public.fee_receipt_counter (tenant_id, campus_id, session_id, last_no) values (:'tenant_id', :'campus2_id', :'session2_id', 40);
alter table public.fee_receipt_counter enable trigger trg_block_manual_receipt_no_edit;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus1_id', :'campus2_id'))::text, true);
select lives_ok(format($$ select public.collect_cash_payment(%L, 100000, 'rcpt-f') $$, :'cf'), 'a receipt can still be issued at that campus');
reset role;
select is(pg_temp.receipt_of(:'ef'::uuid), 'RCP-00000041', 'counters left over from earlier sessions are carried on from their highest number');

select * from finish();
rollback;
