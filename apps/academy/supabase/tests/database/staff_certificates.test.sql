-- pgTAP tests for FR-D18: experience and service certificate generation.
begin;
select plan(29);

select public.provision_tenant('test-cert-co', 'Cert Co', 'owner@certco.test');
select id as tenant_id from public.tenant where slug = 'test-cert-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-cert-other', 'Other Cert Co', 'owner@othercert.test');
select id as other_tenant_id from public.tenant where slug = 'test-cert-other' \gset
update public.tenant set name_ur = 'برائٹ فیوچر اسکول' where id = :'tenant_id';

select gen_random_uuid() as hr_uid \gset
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as other_teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'hr_uid', 'h@certco.test', 'authenticated', 'authenticated', 'x'), (:'owner_uid', 'o@certco.test', 'authenticated', 'authenticated', 'x'),
  (:'prin_uid', 'p@certco.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@certco.test', 'authenticated', 'authenticated', 'x'),
  (:'other_teach_uid', 't2@certco.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'hr_uid', :'tenant_id', 'hr_manager', 'HR'), (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'teach_uid', :'tenant_id', 'subject_teacher', 'Leaving Teacher'), (:'other_teach_uid', :'tenant_id', 'subject_teacher', 'Other Teacher');
insert into public.designation (tenant_id, code, name_en) values (:'tenant_id', 'TCH', 'Teacher'), (:'tenant_id', 'STCH', 'Senior Teacher');
select id as d_teacher from public.designation where tenant_id = :'tenant_id' and code = 'TCH' \gset
select id as d_senior from public.designation where tenant_id = :'tenant_id' and code = 'STCH' \gset
insert into public.staff (tenant_id, campus_id, user_id, employee_code, cnic, gender, doj, designation_id, full_name) values
  (:'tenant_id', :'campus_id', :'teach_uid', 'CE-1', '42101-4444444-1', 'female', '2019-04-01', :'d_teacher', 'Leaving Teacher'),
  (:'tenant_id', :'campus_id', :'other_teach_uid', 'CE-2', '42101-4444444-2', 'male', '2022-01-01', :'d_teacher', 'Other Teacher');
select id as s1 from public.staff where employee_code = 'CE-1' and tenant_id = :'tenant_id' \gset
select id as s2 from public.staff where employee_code = 'CE-2' and tenant_id = :'tenant_id' \gset

-- the person left on 2026-08-31 after a promotion on 2023-04-01
insert into public.staff_exit (tenant_id, campus_id, staff_id, exit_type, last_working_date) values (:'tenant_id', :'campus_id', :'s1', 'retirement', '2026-08-31');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.record_designation_change(:'s1'::uuid, :'d_senior'::uuid, '2023-04-01'::date);
select throws_ok(format($$ select public.record_designation_change(%L::uuid, %L::uuid, '2023-04-01'::date) $$, :'s1', :'d_teacher'), 'EFFECTIVE_DATE_BEFORE_CURRENT_SPAN', 'a change cannot be dated before the current span began');
select public.issue_staff_certificate(:'s1'::uuid, 'experience') as c1 \gset

-- ── AC1: spans and total service ─────────────────────────────────────────
select is(jsonb_array_length((select payload -> 'spans' from public.staff_certificate where id = :'c1'::uuid)), 2, 'AC1: the certificate lists both designation spans');
select is((select payload -> 'spans' -> 0 ->> 'designation' from public.staff_certificate where id = :'c1'::uuid) || ' / ' || (select payload -> 'spans' -> 1 ->> 'designation' from public.staff_certificate where id = :'c1'::uuid), 'Teacher / Senior Teacher', 'AC1: Teacher then Senior Teacher');
select is((select payload -> 'spans' -> 0 ->> 'to' from public.staff_certificate where id = :'c1'::uuid), '2023-03-31', 'the first span closes the day before the promotion');
select is((select payload ->> 'total_service' from public.staff_certificate where id = :'c1'::uuid), '7 years 5 months', 'AC1: total service 2019-04-01 to 2026-08-31 is 7 years 5 months');
select is((select payload ->> 'school_name_ur' from public.staff_certificate where id = :'c1'::uuid), 'برائٹ فیوچر اسکول', 'AC4: the Urdu school name is snapshotted for the Nastaliq render');
select ok((select payload -> 'values' ->> 'positions' like 'Teacher (01 Apr 2019 to 31 Mar 2023); Senior Teacher (01 Apr 2023 to 31 Aug 2026)' from public.staff_certificate where id = :'c1'::uuid), 'the merge values spell out each position');

-- ── AC2: numbering ───────────────────────────────────────────────────────
select is((select certificate_no from public.staff_certificate where id = :'c1'::uuid), 'EXP-' || extract(year from app.fn_karachi_today())::int || '-0001', 'AC2: the first certificate of the year is EXP-{year}-0001');
reset role;
update public.staff_certificate_counter set last_value = 42 where tenant_id = :'tenant_id' and cert_type = 'experience' and year = 2026;
insert into public.staff_certificate_counter (tenant_id, cert_type, year, last_value) values (:'tenant_id', 'experience', 2026, 42) on conflict (tenant_id, cert_type, year) do nothing;
select is(public.next_certificate_no(:'tenant_id'::uuid, 'experience', 2026::smallint), 'EXP-2026-0043', 'AC2: after 42 issued in 2026 the next number is EXP-2026-0043');
select is((select count(distinct n) from (select public.next_certificate_no(:'tenant_id'::uuid, 'experience', 2026::smallint) as n from generate_series(1, 5)) q), 5::bigint, 'AC2: five allocations give five distinct numbers');
select is(public.next_certificate_no(:'tenant_id'::uuid, 'service', 2026::smallint), 'SVC-2026-0001', 'each certificate type counts on its own');
select is((select last_value from public.staff_certificate_counter where tenant_id = :'tenant_id' and cert_type = 'experience' and year = 2026), 48, 'the counter row holds the last number given out');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((public.reprint_staff_certificate(:'c1'::uuid) ->> 'certificate_no'), (select certificate_no from public.staff_certificate where id = :'c1'::uuid), 'AC2: a reprint returns the stored number');
reset role;
select is((select last_value from public.staff_certificate_counter where tenant_id = :'tenant_id' and cert_type = 'experience' and year = 2026), 48, 'AC2: and a reprint consumes no new number');

-- the snapshot survives later changes
update public.staff_certificate_template set body_html = '<p>changed</p>' where tenant_id = :'tenant_id' and cert_type = 'experience';
select ok((select payload ->> 'body_html' like '%served {{school_name}}%' from public.staff_certificate where id = :'c1'::uuid), 'the issued wording is frozen in the payload, not read from the template again');
select throws_ok(format($$ update public.staff_certificate set payload = '{}'::jsonb where id = %L $$, :'c1'), '42501', 'CERTIFICATE_IMMUTABLE', 'an issued certificate cannot be edited');
select public.store_staff_certificate_pdf(:'c1'::uuid, 'x/y.pdf', repeat('ab', 32));
select throws_ok(format($$ select public.store_staff_certificate_pdf(%L::uuid, 'x/z.pdf', repeat('cd', 32)) $$, :'c1'), '42501', 'CERTIFICATE_PDF_SEALED', 'the PDF seal is write-once');

-- ── AC3: an open termination for misconduct blocks the experience certificate ──
insert into public.staff_disciplinary (tenant_id, campus_id, staff_id, action_type, issued_by, description) values
  (:'tenant_id', :'campus_id', :'s1', 'termination', :'hr_uid', 'Gross misconduct');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok(public.staff_certificate_blocked(:'s1'::uuid, 'experience'), 'the UI can see that the certificate is blocked');
select throws_ok(format($$ select public.issue_staff_certificate(%L::uuid, 'experience') $$, :'s1'), 'CERTIFICATE_BLOCKED_PENDING_OWNER_OVERRIDE', 'AC3: HR is blocked while the termination is open');
select throws_ok(format($$ select public.issue_staff_certificate(%L::uuid, 'experience', 'I am HR and I insist on this') $$, :'s1'), 'CERTIFICATE_BLOCKED_PENDING_OWNER_OVERRIDE', 'AC3: HR cannot override, even with a reason');
select lives_ok(format($$ select public.issue_staff_certificate(%L::uuid, 'service') $$, :'s1'), 'other certificate types are not blocked by this rule');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.issue_staff_certificate(%L::uuid, 'experience', 'short') $$, :'s1'), 'CERTIFICATE_BLOCKED_PENDING_OWNER_OVERRIDE', 'the Owner must give a written reason of at least 10 characters');
select public.issue_staff_certificate(:'s1'::uuid, 'experience', 'Board inquiry cleared; owner approves release') as c2 \gset
select ok((select override_id is not null from public.staff_certificate where id = :'c2'::uuid), 'AC3: the Owner override is linked to the certificate');
reset role;
select is((select count(*) from public.audit_log where tenant_id = :'tenant_id' and table_name = 'staff_certificate_override' and action = 'insert'), 1::bigint, 'AC3: the override is written to audit_log');

-- ── access ───────────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.issue_staff_certificate(%L::uuid, 'service') $$, :'s1'), 'FORBIDDEN', 'a Principal cannot issue certificates');
select ok((select count(*) from public.staff_certificate) >= 3, 'a Principal can read them');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok((select count(*) from public.staff_certificate) >= 3 and (select count(distinct staff_id) from public.staff_certificate) = 1, 'the teacher reads only their own certificates');
select set_config('request.jwt.claims', json_build_object('sub', :'other_teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.staff_certificate), 0::bigint, 'another teacher sees none of them');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'hr_manager', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.staff_certificate), 0::bigint, 'another school sees none');

select * from finish();
rollback;
