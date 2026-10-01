-- pgTAP tests for FR-D06: document expiry reminders and compliance flag.
begin;
select plan(18);

select public.provision_tenant('test-docexp-co', 'DocExp Co', 'owner@docexp.test');
select id as tenant_id from public.tenant where slug = 'test-docexp-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-docexp-other', 'Other DocExp Co', 'owner@otherdocexp.test');
select id as other_tenant_id from public.tenant where slug = 'test-docexp-other' \gset

select gen_random_uuid() as hr_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as t1_uid \gset
select gen_random_uuid() as t2_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'hr_uid', 'hr@docexp.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@docexp.test', 'authenticated', 'authenticated', 'x'),
  (:'t1_uid', 't1@docexp.test', 'authenticated', 'authenticated', 'x'), (:'t2_uid', 't2@docexp.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'hr_uid', :'tenant_id', 'hr_manager', 'HR'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'t1_uid', :'tenant_id', 'subject_teacher', 'Teacher One'), (:'t2_uid', :'tenant_id', 'subject_teacher', 'Teacher Two');
insert into public.staff (tenant_id, campus_id, user_id, employee_code, cnic, gender, contract_type, full_name) values
  (:'tenant_id', :'campus_id', :'t1_uid', 'DX-1', '42101-1234567-1', 'female', 'permanent', 'Teacher One'),
  (:'tenant_id', :'campus_id', :'t2_uid', 'DX-2', '42101-1234567-2', 'male', 'visiting', 'Teacher Two');
select id as s1 from public.staff where user_id = :'t1_uid' \gset
select id as s2 from public.staff where user_id = :'t2_uid' \gset
insert into public.staff_private_contact (staff_id, mobile) values (:'s1', '+923001234567');

-- ── AC1: one 60-day reminder; a same-day re-run adds none ────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.add_staff_compliance_document(:'t1_uid'::uuid, 'police_verification', '2026-09-30'::date) as pol \gset
reset role;

select is(public.check_staff_document_expiry('2026-08-01'::date, :'tenant_id'::uuid), 1, 'AC1: the nightly job on 2026-08-01 creates exactly one reminder');
select is((select threshold_days from public.staff_document_reminder where document_id = :'pol'::uuid), 60::smallint, 'AC1: it is the 60-day reminder (2026-08-01 is 60 days before 2026-09-30)');
select is(public.check_staff_document_expiry('2026-08-01'::date, :'tenant_id'::uuid), 0, 'AC1: re-running the job the same day creates zero additional reminders');
select is((select count(*) from public.staff_document_reminder where document_id = :'pol'::uuid), 1::bigint, 'AC1: still exactly one reminder row');

-- ── AC2: a retry never queues a second message ───────────────────────────
select is((select count(*) from public.message where tenant_id = :'tenant_id' and metadata ->> 'kind' = 'staff_document_expiry'), 1::bigint, 'AC2: one SMS was queued for the one reminder');
delete from public.staff_document_reminder where document_id = :'pol'::uuid; -- the crash lost the reminder row, not the message
select is(public.check_staff_document_expiry('2026-08-01'::date, :'tenant_id'::uuid), 1, 'AC2: the retry re-arms the lost reminder row');
select is((select count(*) from public.message where tenant_id = :'tenant_id' and metadata ->> 'kind' = 'staff_document_expiry'), 1::bigint, 'AC2: but no duplicate message is queued (idempotency key)');
select throws_ok(format($$ insert into public.staff_document_reminder (tenant_id, document_id, threshold_days) values (%L, %L, 60) $$, :'tenant_id', :'pol'),
  '23505', null, 'AC2: reminder rows are unique on (document_id, threshold_days)');

-- a later night crosses the next threshold: one more reminder, not a replay of history
select is(public.check_staff_document_expiry('2026-09-01'::date, :'tenant_id'::uuid), 1, 'on 2026-09-01 (29 days left) only the 30-day threshold fires');
select is((select array_agg(threshold_days order by threshold_days) from public.staff_document_reminder where document_id = :'pol'::uuid), array[30, 60]::smallint[], 'thresholds 60 and 30 exist, none replayed');

-- ── AC3: expired mandatory document => non_compliant, counted on the Principal's tile ──
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_staff_document_expiry(:'pol'::uuid, app.fn_karachi_today() - 2);
select public.add_staff_compliance_document(:'t1_uid'::uuid, 'medical_certificate', app.fn_karachi_today() + 200);
select is((select compliance_status from public.v_staff_compliance where staff_id = :'s1'::uuid), 'non_compliant', 'AC3: a mandatory document expired 2 days ago makes the staff row non_compliant');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.v_staff_compliance where compliance_status = 'non_compliant'), 1::bigint, 'AC3: the Principal''s compliance tile counts it');
select set_config('request.jwt.claims', json_build_object('sub', :'t2_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.v_staff_compliance), 1::bigint, 'a teacher sees only their own compliance row');

-- ── AC4: renewal returns the staff to compliant and arms new thresholds ──
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_staff_document_expiry(:'pol'::uuid, app.fn_karachi_today() + 50);
select is((select compliance_status from public.v_staff_compliance where staff_id = :'s1'::uuid), 'compliant', 'AC4: after renewal the staff row is compliant again');
reset role;
select is((select count(*) from public.staff_document_reminder where document_id = :'pol'::uuid), 0::bigint, 'AC4: the old thresholds were cleared on renewal');
select public.check_staff_document_expiry(null, :'tenant_id'::uuid);
select is((select threshold_days from public.staff_document_reminder where document_id = :'pol'::uuid), 60::smallint, 'AC4: the next job cycle arms the new 60-day threshold for the new expiry');

-- ── the contract-type scope of the policy ────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.upsert_document_type_policy('degree', 'Degree / transcript', true, array['permanent']);
select is((select missing_types from public.v_staff_compliance where staff_id = :'s2'::uuid), '{}'::text[] || array['medical_certificate', 'police_verification'], 'a mandatory type limited to permanent staff does not apply to a visiting teacher (only the all-contract types are missing)');

select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'hr_manager', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.staff_document_reminder), 0::bigint, 'another school sees none of these reminders');

select * from finish();
rollback;
