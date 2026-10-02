-- pgTAP tests for FR-T06: bonafide certificate self-service.
begin;
select plan(35);

select public.provision_tenant('test-bona-co', 'Bonafide Co', 'owner@bona.test');
select id as tenant_id from public.tenant where slug = 'test-bona-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-bona-other', 'Other Bona Co', 'owner@otherbona.test');
select id as other_tenant_id from public.tenant where slug = 'test-bona-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as officer_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as parent2_uid \gset
select gen_random_uuid() as stranger_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@bona.test', 'authenticated', 'authenticated', 'x'), (:'officer_uid', 'off@bona.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@bona.test', 'authenticated', 'authenticated', 'x'), (:'parent_uid', 'p@bona.test', 'authenticated', 'authenticated', 'x'),
  (:'parent2_uid', 'p2@bona.test', 'authenticated', 'authenticated', 'x'), (:'stranger_uid', 's@bona.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'officer_uid', :'tenant_id', 'admissions_officer', 'Farhat Jabeen'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as sec \gset
select public.create_student(:'campus_id'::uuid, 'Ayesha Khan', '2015-01-01'::date, 'female') as stu \gset
select public.create_student(:'campus_id'::uuid, 'Bilal Stranger', '2015-02-01'::date, 'male') as stu2 \gset
select public.enrol_student(:'sec'::uuid, :'stu'::uuid);
select public.enrol_student(:'sec'::uuid, :'stu2'::uuid);
select public.create_certificate_template(
  'bonafide'::public.certificate_type, 'Bonafide Certificate',
  '<p>This is to certify that {{student.name_en}} (GR {{student.gr_number}}) is a bonafide student of class {{enrolment.class_name}}. Purpose: {{bonafide.purpose}}. Issued {{issue.date}}.</p>',
  null, 'en'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_id'::uuid) as tpl \gset
select public.activate_certificate_template(:'tpl'::uuid) as _a \gset

reset role;
insert into public.guardian (tenant_id, name_en, phone_e164, auth_user_id) values (:'tenant_id', 'Khan Senior', '+923001234567', :'parent_uid') returning id as g1 \gset
insert into public.guardian (tenant_id, name_en, phone_e164, auth_user_id) values (:'tenant_id', 'Khan Junior', '+923007654321', :'parent2_uid') returning id as g2 \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing) values (:'tenant_id', :'stu', :'g1', 'father', true, true);
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, receives_billing) values (:'tenant_id', :'stu', :'g2', 'mother', true);
insert into public.guardian (tenant_id, name_en, auth_user_id) values (:'tenant_id', 'Stranger Parent', :'stranger_uid') returning id as g3 \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing) values (:'tenant_id', :'stu2', :'g3', 'father', true, true);

-- ── AC1: a guardian requests, an officer approves, the guardian is told ────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select public.submit_certificate_request(:'stu'::uuid, 'embassy/visa') as req1 \gset
select ok(:'req1' is not null and :'req1' <> '', 'AC1: the guardian''s embassy/visa request is accepted');
select is((select status::text from public.certificate_request where id = :'req1'::uuid), 'pending', 'and waits for an officer');
select is((select count(*) from public.certificate_request_purpose where label_ur is not null and char_length(label_ur) > 0), 6::bigint, 'every purpose has an Urdu label');

select set_config('request.jwt.claims', json_build_object('sub', :'officer_uid', 'tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.certificate_request where status = 'pending'), 1::bigint, 'the officer sees the pending request');
select public.approve_certificate_request(:'req1'::uuid) as ap \gset
select is(:'ap'::jsonb ->> 'certificate_type', 'bonafide', 'approval issues a bonafide certificate');
select is(:'ap'::jsonb -> 'payload_snapshot' -> 'values' ->> 'bonafide.purpose', 'Embassy or visa', 'stating the purpose');
select ok((:'ap'::jsonb ->> 'serial_no') like 'BC-%', 'on the bonafide serial series');
select is((select status::text from public.certificate_request where id = :'req1'::uuid), 'approved', 'the request is approved while the PDF is rendered');
select throws_ok(format($$ select public.queue_certificate_ready_message(%L, 'https://school.example') $$, :'req1'), 'REQUEST_NOT_ISSUED', 'nothing is sent until the PDF exists');
select public.mark_certificate_request_issued(:'req1'::uuid);
select is((select status::text from public.certificate_request where id = :'req1'::uuid), 'issued', 'the request becomes issued once the PDF is stored');
select public.queue_certificate_ready_message(:'req1'::uuid, 'https://school.example') as q \gset
select is((:'q'::jsonb ->> 'queued')::boolean, true, 'AC1: a WhatsApp message is queued for the guardian');
reset role;
select is((select channel::text from public.message where idempotency_key = 'cert-ready:' || :'req1'), 'whatsapp', 'AC1: on the WhatsApp channel');
select is((select recipient_phone from public.message where idempotency_key = 'cert-ready:' || :'req1'), '+923001234567', 'to the requesting guardian''s phone');
select ok((select body like '%https://school.example/api/certificates/share/%' from public.message where idempotency_key = 'cert-ready:' || :'req1'), 'carrying the share link');
select ok((select scheduled_at <= (select decided_at from public.certificate_request where id = :'req1'::uuid) + interval '5 minutes' from public.message where idempotency_key = 'cert-ready:' || :'req1'), 'AC1: scheduled to go out within 5 minutes of the approval');
select ok((select (metadata ->> 'link_expires_at')::timestamptz between now() + interval '6 days 23 hours' and now() + interval '7 days 1 hour' from public.message where idempotency_key = 'cert-ready:' || :'req1'), 'AC1: the link is valid for 7 days');
select ok((select count(*) = 0 from public.certificate_share_link where :'q'::jsonb ->> 'url' like '%' || token_hash || '%'), 'only a hash of the token is stored');
select is((public.resolve_certificate_share_link(split_part(:'q'::jsonb ->> 'url', '/share/', 2)) ->> 'serial_no'), (:'ap'::jsonb ->> 'serial_no'), 'the link opens the certificate with no login');
update public.certificate_share_link set expires_at = now() - interval '1 minute';
select is(public.resolve_certificate_share_link(split_part(:'q'::jsonb ->> 'url', '/share/', 2)), null::jsonb, 'an expired link opens nothing');
select is(public.resolve_certificate_share_link('not-a-real-token'), null::jsonb, 'and neither does a made-up one');

-- the parent can see the issued certificate for their own child
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.certificate_issue where student_id = :'stu'::uuid), 1::bigint, 'the PDF is available to the guardian in the portal');

-- ── AC2: a student they are not linked to returns zero rows, not an error ──
select is((select count(*) from public.submit_certificate_request(:'stu2'::uuid, 'passport')), 0::bigint, 'AC2: a request for an unlinked student returns zero rows');
select is((select count(*) from public.submit_certificate_request(gen_random_uuid(), 'passport')), 0::bigint, 'AC2: exactly like a student who does not exist');
select throws_ok(format($$ insert into public.certificate_request (tenant_id, campus_id, student_id, requested_by_user, purpose) values (%L, %L, %L, %L, 'passport') $$, :'tenant_id', :'campus_id', :'stu2', :'parent_uid'), '42501', null, 'and a direct insert for them is blocked by RLS');
select throws_ok(format($$ insert into public.certificate_request (tenant_id, campus_id, student_id, requested_by_user, purpose, status) values (%L, %L, %L, %L, 'passport', 'approved') $$, :'tenant_id', :'campus_id', :'stu', :'parent_uid'), '42501', null, 'a guardian cannot create a request that is already approved');

-- ── AC3: the fourth request in 24 hours is refused ────────────────────────
select public.submit_certificate_request(:'stu'::uuid, 'passport');
select public.submit_certificate_request(:'stu'::uuid, 'bank');
select throws_ok(format($$ select public.submit_certificate_request(%L, 'scholarship') $$, :'stu'), '53400', 'daily limit of 3 requests reached', 'AC3: the 4th request is rejected with ''daily limit of 3 requests reached''');

-- ── AC4: purpose=other needs a real justification ─────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'parent2_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select throws_ok(format($$ select public.submit_certificate_request(%L, 'other', 'too short') $$, :'stu'), '23514', null, 'AC4: purpose other with a short justification is refused');
select throws_ok(format($$ select public.submit_certificate_request(%L, 'other') $$, :'stu'), '23514', null, 'AC4: and with none at all');
select lives_ok(format($$ select public.submit_certificate_request(%L, 'other', 'Needed for a cricket academy trial') $$, :'stu'), 'AC4: 15 or more characters is accepted');
select is((select count(*) from public.certificate_request), 1::bigint, 'a guardian sees only their own requests');

-- ── rejection and roles ───────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'officer_uid', 'tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.reject_certificate_request(%L, '') $$, (select id from public.certificate_request where purpose = 'other')), 'REASON_REQUIRED', 'a rejection needs a reason');
select public.reject_certificate_request((select id from public.certificate_request where purpose = 'other'), 'Please apply to the office in person');
select is((select status::text from public.certificate_request where purpose = 'other'), 'rejected', 'the officer can reject with a reason');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.approve_certificate_request(%L) $$, :'req1'), 'FORBIDDEN', 'a teacher cannot approve');
select is((select count(*) from public.certificate_request), 0::bigint, 'and cannot read the requests');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.certificate_request), 0::bigint, 'another school sees none');

select * from finish();
rollback;
