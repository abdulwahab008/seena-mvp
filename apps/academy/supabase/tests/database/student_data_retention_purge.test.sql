-- pgTAP tests for FR-T16: student data retention and purge policy.
begin;
select plan(40);

select public.provision_tenant('test-ret-co', 'Retention Co', 'owner@ret.test');
select id as tenant_id from public.tenant where slug = 'test-ret-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1 from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity) values (:'tenant_id', :'campus_id', :'session_id', :'class1', 'R1', 200) returning id as sec \gset
select gen_random_uuid() as sa_uid \gset
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'sa_uid', 'sa@ret.test', 'authenticated', 'authenticated', 'x'), (:'owner_uid', 'o@ret.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@ret.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'sa_uid', :'tenant_id', 'super_admin', 'Super'), (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);
insert into public.student (tenant_id, campus_id, gr_number, name_en, name_ur, father_name_en, dob, gender, b_form_no, photo_path) values
  (:'tenant_id', :'campus_id', 'GR-S1', 'Departed One', 'گیارہ', 'Father One', '2008-01-01', 'male', '35202-1234567-1', 'photos/s1.jpg'),
  (:'tenant_id', :'campus_id', 'GR-S2', 'Certified Two', null, 'Father Two', '2000-01-01', 'male', '35202-2222222-2', null),
  (:'tenant_id', :'campus_id', 'GR-S3', 'Departed Three', null, 'Father Three', '2000-01-01', 'female', null, null),
  (:'tenant_id', :'campus_id', 'GR-S4', 'Sibling Gone', null, null, '2005-01-01', 'male', null, null),
  (:'tenant_id', :'campus_id', 'GR-S5', 'Sibling Here', null, null, '2012-01-01', 'male', null, null);
-- S1 left 2020-05-31; S2 and S3 left 2014-05-31; S4 left 2015 but sibling S5 is still enrolled
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, joined_on, left_on, status)
select :'tenant_id', :'campus_id', :'session_id', id, :'class1', :'sec', date '2010-04-01',
       case gr_number when 'GR-S1' then date '2020-05-31' when 'GR-S5' then null else date '2014-05-31' end,
       case gr_number when 'GR-S5' then 'active'::public.enrolment_status else 'left'::public.enrolment_status end
  from public.student where tenant_id = :'tenant_id' and gr_number like 'GR-S%';
update public.enrolment set left_on = '2015-06-30' where student_id = (select id from public.student where gr_number = 'GR-S4' and tenant_id = :'tenant_id');
insert into public.guardian (tenant_id, name_en, cnic, phone_e164, alt_phone, email) values
  (:'tenant_id', 'Guardian One', '35202-9999999-1', '+923001111111', '+923002222222', 'g1@example.com'),
  (:'tenant_id', 'Guardian Sibs', '35202-8888888-1', '+923003333333', null, null);
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
select :'tenant_id', s.id, g.id, 'father', true, true from public.student s join public.guardian g on g.tenant_id = s.tenant_id
 where s.tenant_id = :'tenant_id' and ((s.gr_number = 'GR-S1' and g.name_en = 'Guardian One') or (s.gr_number in ('GR-S4', 'GR-S5') and g.name_en = 'Guardian Sibs'));

-- an issued Character Certificate for S2 (statutory register)
insert into public.certificate_template (tenant_id, certificate_type, version, title, body_html) values (:'tenant_id', 'character', 1, 'Character', '<p>x</p>') returning id as tpl \gset
insert into public.certificate_issue (tenant_id, campus_id, student_id, session_id, certificate_type, serial_no, template_id, template_version, language, pdf_path, payload_snapshot)
select :'tenant_id', :'campus_id', id, :'session_id', 'character', 'RET-0001', :'tpl', 1, 'en', 'x/y.pdf', '{"values":{"character.conduct_grade":"Excellent"}}'::jsonb
  from public.student where tenant_id = :'tenant_id' and gr_number = 'GR-S2';

-- fee ledger rows from 2019 (belonging to S3) and 2026
select e.id as enr3, e.session_id from public.enrolment e join public.student s on s.id = e.student_id where s.gr_number = 'GR-S3' and s.tenant_id = :'tenant_id' \gset
insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, amount_paisa, direction, value_date)
select :'tenant_id', :'campus_id', :'enr3', :'session_id', 'charge', 100000, 'debit', d from (values (date '2019-06-01'), (date '2019-11-01'), (date '2026-02-01')) v(d);

select has_index('public', 'enrolment', 'idx_enrolment_left_on', 'idx_enrolment_left_on exists');
select is((select count(*)::int from public.retention_policy where tenant_id is null), 4, 'four default retention policies');

-- ── dry run: the full candidate list and counts, zero changes ─────────────
select app.fn_start_retention_run(:'tenant_id'::uuid, '2026-08-01'::date, true) as dry \gset
select is((select status from public.retention_purge_run where id = :'dry'), 'done', 'AC4: a dry run completes immediately');
select is((select dry_run from public.retention_purge_run where id = :'dry'), true, 'and is recorded as a dry run');
select ok((select candidates_count from public.retention_purge_run where id = :'dry') >= 6, 'AC4: it lists the candidates');
select is((select count(*)::int from public.retention_purge_item where run_id = :'dry' and data_category = 'student_identity'), 2, 'AC4: counts per category: 2 students with identity data due (S1, S2; S3 has none)');
select is((select count(*)::int from public.retention_purge_item where run_id = :'dry' and data_category = 'fee_ledger'), 0, 'AC2: the 2019 ledger rows are not yet due on 2026-08-01');
select is((select b_form_no from public.student where gr_number = 'GR-S1' and tenant_id = :'tenant_id'), '35202-1234567-1', 'AC4: a dry run modifies zero rows (B-Form still there)');
select is((select count(*)::int from public.retention_purge_item where run_id = :'dry' and action_taken <> 'dry_run' and action_taken <> 'exempt'), 0, 'dry-run items are only ever dry_run or exempt');

-- ── live run at 2026-08-01 ────────────────────────────────────────────────
select app.fn_start_retention_run(:'tenant_id'::uuid, '2026-08-01'::date, false) as run1 \gset
select is(public.apply_retention_purge(:'run1'::uuid, 500), 0, 'the run completes in one batch (nothing pending after)');
select is((select b_form_no from public.student where gr_number = 'GR-S1' and tenant_id = :'tenant_id'), null, 'AC1: B-Form is nulled');
select is((select photo_path from public.student where gr_number = 'GR-S1' and tenant_id = :'tenant_id'), null, 'AC1: and the photo reference');
select is((select cnic is null and phone_e164 is null and alt_phone is null and email is null from public.guardian where name_en = 'Guardian One' and tenant_id = :'tenant_id'), true, 'AC1: parent CNIC, phones and email are nulled');
select is((select name_en || '/' || gr_number from public.student where gr_number = 'GR-S1' and tenant_id = :'tenant_id'), 'Departed One/GR-S1', 'AC1: name and GR number remain intact (not yet due for 10 years)');
select is((select count(*)::int from public.certificate_issue where student_id = (select id from public.student where gr_number = 'GR-S2' and tenant_id = :'tenant_id')), 1, 'the certificate record is untouched');
select is((select cnic from public.guardian where name_en = 'Guardian Sibs' and tenant_id = :'tenant_id'), '35202-8888888-1', 'a guardian with a child still enrolled keeps their contact data');
select is((select count(*)::int from public.fee_ledger where tenant_id = :'tenant_id'), 3, 'AC2: the 2019 fee ledger rows survive on 2026-08-01');
select is((select count(*)::int from public.retention_purge_item where run_id = :'run1' and storage_path = 'photos/s1.jpg'), 1, 'the photo blob is queued for deletion');
select is((select count(*)::int from public.retention_blobs_to_delete() where storage_path = 'photos/s1.jpg'), 1, 'and the worker can collect it');

-- ── the purge's own audit rows do not copy what it removed ────────────────
select is((select count(*)::int from public.audit_log where table_name = 'student' and action = 'update' and tenant_id = :'tenant_id' and (before::text like '%35202-1234567-1%' or after::text like '%35202-1234567-1%')), 0, 'audit rows written by the purge carry no B-Form value');

-- ── later run: name policy and the 2019 ledger ────────────────────────────
select app.fn_start_retention_run(:'tenant_id'::uuid, '2027-01-02'::date, false) as run2 \gset
select is((select exemption_reason from public.retention_purge_item where run_id = :'run2' and data_category = 'student_name_gr' and row_pk = (select id from public.student where gr_number = 'GR-S2' and tenant_id = :'tenant_id')), 'issued_certificate_register', 'AC3: the certificate holder''s name/GR is exempt, and the reason is logged');
select public.apply_retention_purge(:'run2'::uuid, 500);
select is((select name_en || '/' || gr_number from public.student where id = (select id from public.student where tenant_id = :'tenant_id' and name_en = 'Certified Two')), 'Certified Two/GR-S2', 'AC3: GR number and name stay intact for the certificate holder');
select is((select count(*)::int from public.student where tenant_id = :'tenant_id' and gr_number like 'PSEUDO-%'), 2, 'other departed students (S3, S4... due) are pseudonymised one-way');
select is((select count(*)::int from public.fee_ledger where tenant_id = :'tenant_id'), 1, 'AC2: after 2026-12-31 the 2019 ledger rows are purged; the 2026 row stays');
select is((select cnic from public.guardian where name_en = 'Guardian Sibs' and tenant_id = :'tenant_id'), '35202-8888888-1', 'the sibling guardian still keeps their data');
select throws_ok(format($$ update public.student set gr_number = 'X1' where tenant_id = %L and gr_number like 'GR-S2' $$, :'tenant_id'), 'GR_NUMBER_IMMUTABLE', 'outside the purge a GR number is still immutable');
select throws_ok(format($$ delete from public.fee_ledger where tenant_id = %L $$, :'tenant_id'), 'FEE_LEDGER_IMMUTABLE', 'and the fee ledger is still append-only');

-- ── AC5: an interrupted run resumes without reprocessing ──────────────────
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender, photo_path)
select :'tenant_id', :'campus_id', 'BULK' || lpad(g::text, 5, '0'), 'Bulk ' || g, '2008-01-01', 'male', 'photos/bulk' || g || '.jpg' from generate_series(1, 800) g;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, joined_on, left_on, status)
select :'tenant_id', :'campus_id', :'session_id', id, :'class1', :'sec', date '2016-04-01', date '2020-05-31', 'left' from public.student where tenant_id = :'tenant_id' and gr_number like 'BULK%';
select app.fn_start_retention_run(:'tenant_id'::uuid, '2026-08-01'::date, false) as run3 \gset
select is((select count(*)::int from public.retention_purge_item where run_id = :'run3' and data_category = 'student_identity'), 800, 'the bulk run has 800 candidates');
select is(public.apply_retention_purge(:'run3'::uuid, 300), 500, 'first batch: 300 done, 500 left (then the job "crashes")');
select is((select purged_count from public.retention_purge_run where id = :'run3'), 300, 'purged_count reflects the 300');
select is(public.apply_retention_purge(:'run3'::uuid, 300), 200, 'the re-run resumes: another 300, 200 left');
select is(public.apply_retention_purge(:'run3'::uuid, 300), 0, 'and finishes');
select is((select purged_count || '/' || (select count(*) from public.retention_purge_item where run_id = :'run3' and action_taken = 'null_out') from public.retention_purge_run where id = :'run3'), '800/800', 'AC5: every candidate processed exactly once');
select is((select count(*)::int from (select 1 from public.retention_purge_item where run_id = :'run3' group by table_name, row_pk, data_category having count(*) > 1) d), 0, 'AC5: no duplicate purge-log entries');
select is(public.apply_retention_purge(:'run3'::uuid, 300), 0, 'applying a finished run does nothing');

-- ── policy, access ────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);
select throws_ok($$ select public.set_retention_policy('student_identity', 10) $$, 'FORBIDDEN', 'only a Super Admin can change a policy');
select ok((select count(*) from public.retention_purge_run) >= 3, 'an owner can read the runs');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher')::text, true);
select is((select count(*)::int from public.retention_purge_run), 0, 'a teacher cannot');
select set_config('request.jwt.claims', json_build_object('sub', :'sa_uid', 'tenant_id', :'tenant_id', 'app_role', 'super_admin')::text, true);
select public.set_retention_policy('student_identity', 20);
select throws_ok($$ select public.set_retention_policy('student_identity', 0) $$, 'RETENTION_YEARS_INVALID', 'retention years must be sensible');
reset role;
select is((select count(*)::int from public.find_retention_candidates(:'tenant_id'::uuid, '2026-08-01'::date) where data_category = 'student_identity'), 0, 'a longer tenant policy removes them from the candidates');

select * from finish();
rollback;
