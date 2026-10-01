-- pgTAP tests for FR-T10: public certificate verification by QR.
begin;
select plan(33);

select public.provision_tenant('test-verify-co', 'Verify Co', 'owner@verify.test');
select id as tenant_id from public.tenant where slug = 'test-verify-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-verify-other', 'Other Verify Co', 'owner@otherverify.test');
select id as other_tenant_id from public.tenant where slug = 'test-verify-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@verify.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@verify.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@verify.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as sec \gset
select public.create_certificate_template('transfer'::public.certificate_type, 'Transfer Certificate', '<p>{{student.name_en}} {{student.gr_number}} {{issue.serial_no}} {{issue.date}} {{enrolment.left_on}}</p>', null, 'en'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_id'::uuid) as tpl \gset
reset role;

insert into public.student (tenant_id, campus_id, gr_number, name_en, father_name_en, dob, gender, status) values
  (:'tenant_id', :'campus_id', '2019-0311', 'Ahmed Hassan', 'Hassan Ali', '2012-05-05', 'male', 'transferred'),
  (:'tenant_id', :'campus_id', '2020-0042', 'Sara Khan', 'Khan Sr', '2013-06-06', 'female', 'active'),
  (:'tenant_id', :'campus_id', '2021-0007', 'Zainab Bilal Raza', 'Bilal Raza', '2014-07-07', 'female', 'active');
select id as s_ahmed from public.student where gr_number = '2019-0311' and tenant_id = :'tenant_id' \gset
select id as s_sara from public.student where gr_number = '2020-0042' and tenant_id = :'tenant_id' \gset
select id as s_zainab from public.student where gr_number = '2021-0007' and tenant_id = :'tenant_id' \gset
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status, joined_on) values
  (:'tenant_id', :'campus_id', :'session_id', :'s_ahmed', :'class1_id', :'sec', 'transferred', current_date - 300) returning id as e_ahmed \gset
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status, joined_on) values
  (:'tenant_id', :'campus_id', :'session_id', :'s_sara', :'class1_id', :'sec', 'transferred', current_date - 300) returning id as e_sara \gset

insert into public.certificate_issue (tenant_id, campus_id, student_id, enrolment_id, session_id, certificate_type, serial_no, template_id, template_version, language, pdf_path, payload_snapshot, issued_at)
values (:'tenant_id', :'campus_id', :'s_ahmed', :'e_ahmed', :'session_id', 'transfer', 'GHS-LHR/TC/2026/00147', :'tpl', 1, 'en', 'v/ahmed.pdf',
        '{"values": {"student.name_en": "Ahmed Hassan", "student.gr_number": "2019-0311"}}'::jsonb, '2026-06-30 10:00:00+05')
returning verify_token as tok_valid \gset
insert into public.certificate_issue (tenant_id, campus_id, student_id, enrolment_id, session_id, certificate_type, serial_no, template_id, template_version, language, pdf_path, payload_snapshot, issued_at)
values (:'tenant_id', :'campus_id', :'s_sara', :'e_sara', :'session_id', 'transfer', 'GHS-LHR/TC/2026/00148', :'tpl', 1, 'en', 'v/sara.pdf',
        '{"values": {"student.name_en": "Sara Khan", "student.gr_number": "2020-0042"}}'::jsonb, '2026-06-30 11:00:00+05')
returning verify_token as tok_cancel, id as id_cancel \gset
-- cancelled on 12-Jul-2026 (the register trigger only lets the revoke function do this, so it is stepped around for the fixture)
alter table public.certificate_issue disable trigger trg_cert_issue_no_update;
update public.certificate_issue set status = 'cancelled', revoked_at = '2026-07-12 11:00:00+05', revoke_reason = 'Issued in error' where id = :'id_cancel';
alter table public.certificate_issue enable trigger trg_cert_issue_no_update;

-- ── tokens ────────────────────────────────────────────────────────────────
select ok(length(:'tok_valid') >= 16 and :'tok_valid' ~ '^[A-Za-z0-9_-]+$', 'every certificate has a random URL-safe verify token');
select isnt(:'tok_valid'::text, :'tok_cancel'::text, 'and they are different');
select is((select count(*) from pg_indexes where indexname = 'uq_cert_verify_token'), 1::bigint, 'the token has a unique index');
select ok(:'tok_valid' !~ '2019|0311|Ahmed', 'the token encodes nothing about the student');

-- ── AC1: a valid token, unauthenticated ───────────────────────────────────
set local role anon;
select is(public.verify_certificate(:'tok_valid', 'ip-1', 'ua') ->> 'headline',
          'VALID - Transfer Certificate GHS-LHR/TC/2026/00147 issued 30-Jun-2026 to A* H (GR 2019-)',
          'AC1: the page shows VALID, the certificate, its date and the masked name and GR');
select is(public.verify_certificate(:'tok_valid', 'ip-1', 'ua') ->> 'http_status', '200', 'AC1: HTTP 200');
select is((public.verify_certificate(:'tok_valid', 'ip-1', 'ua') - 'headline' - 'http_status' - 'state'), '{}'::jsonb, 'AC1: and nothing else is returned');
select is(public.verify_certificate(:'tok_valid', 'ip-1', 'ua') ->> 'headline' ~ 'Hassan|0311|Ali', false, 'the full name, the full GR number and the father''s name are not in it');
select throws_ok($$ select app.fn_mask_person_name('Zainab Bilal Raza') $$, '42501', null, 'the masking helpers are not callable by anon');
reset role;
select is(app.fn_mask_person_name('Zainab Bilal Raza'), 'Z* B* R', 'masking keeps an initial and a star for every word but the last');
select is(app.fn_mask_person_name('Ayesha'), 'A', 'a single name keeps only its initial');
select is(app.fn_mask_gr('2019-0311'), '2019-', 'a GR number keeps only its year prefix');
set local role anon;

-- ── AC2: a cancelled certificate ──────────────────────────────────────────
select is(public.verify_certificate(:'tok_cancel', 'ip-2', 'ua') ->> 'headline', 'CANCELLED on 12-Jul-2026', 'AC2: a cancelled certificate shows CANCELLED on 12-Jul-2026');
select is(public.verify_certificate(:'tok_cancel', 'ip-2', 'ua') ->> 'state', 'cancelled', 'AC2: in the cancelled state (the page paints it red)');
select is(public.verify_certificate(:'tok_cancel', 'ip-2', 'ua') ->> 'headline' ~ 'Sara|Khan|0042|GHS', false, 'AC2: and shows no student detail, so a replacement''s details are never exposed');

-- ── AC3: unknown tokens are a generic 404 ─────────────────────────────────
select is(public.verify_certificate('definitely-not-a-real-token', 'ip-3', 'ua') ->> 'http_status', '404', 'AC3: a random token is a 404');
select is(public.verify_certificate('definitely-not-a-real-token', 'ip-3', 'ua') ->> 'headline', 'No certificate found for this code', 'AC3: with the generic message');
select is(public.verify_certificate(null, 'ip-3', 'ua') ->> 'http_status', '404', 'a missing token is the same 404');
select is(public.verify_certificate(repeat('x', 5000), 'ip-3', 'ua') ->> 'headline', 'No certificate found for this code', 'and so is an absurd one');
reset role;
create temp table _timing (hit numeric, miss numeric);
do $$
declare
  t0 timestamptz;
  hit numeric := 0;
  miss numeric := 0;
  i int;
  v_tok text := (select verify_token from public.certificate_issue where serial_no = 'GHS-LHR/TC/2026/00147');
begin
  for i in 1..25 loop
    t0 := clock_timestamp();
    perform public.verify_certificate(v_tok, 'ip-timing-' || i, 'ua');
    hit := hit + extract(epoch from clock_timestamp() - t0) * 1000;
    t0 := clock_timestamp();
    perform public.verify_certificate('zzzzzzzzzzzzzzzzzzzzzz' || i, 'ip-timing-m' || i, 'ua');
    miss := miss + extract(epoch from clock_timestamp() - t0) * 1000;
  end loop;
  insert into _timing values (hit / 25, miss / 25);
end;
$$;
select ok((select abs(hit - miss) < 50 from _timing), 'AC3: a valid lookup and an unknown one take the same time (well within 50ms)');
set local role anon;

-- ── AC4: 60 a minute from one address ─────────────────────────────────────
create temp table _burst (status int);
grant all on _burst to anon;
insert into _burst select (public.verify_certificate(:'tok_valid', 'ip-burst', 'ua') ->> 'http_status')::int from generate_series(1, 200);
select is((select count(*) from _burst where status = 429), 140::bigint, 'AC4: of 200 requests from one address in a minute, 140 beyond the first 60 are rejected with 429');
select is((select count(*) from _burst where status = 200), 60::bigint, 'AC4: and 60 are served');
select is(public.verify_certificate(:'tok_valid', 'ip-someone-else', 'ua') ->> 'http_status', '200', 'AC4: a different address is unaffected');

-- ── anon can reach nothing but the function ───────────────────────────────
select throws_ok($$ select count(*) from public.certificate_issue $$, '42501', null, 'anon cannot read the certificate register');
select throws_ok($$ select count(*) from public.v_certificate_public_verify $$, '42501', null, 'anon cannot read the masked view, so there is no list of tokens to enumerate');
select throws_ok($$ select count(*) from public.certificate_verify_log $$, '42501', null, 'anon cannot read the verification log');

-- ── logging and the report ────────────────────────────────────────────────
reset role;
select ok((select count(*) from public.certificate_verify_log where result = 'valid' and campus_id = :'campus_id') >= 1, 'every verification is logged against its campus');
select is((select count(*) from public.certificate_verify_log where token_hash = :'tok_valid'), 0::bigint, 'the log keeps hashes, never the token itself');
select ok((select total_scans >= 60 from public.v_certificate_verify_activity where certificate_type = 'transfer' and campus_id = :'campus_id' order by total_scans desc limit 1), 'the activity report counts scans per campus, day and serial range');

-- ── staff can read the log and the masked view; others cannot ─────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok((select count(*) from public.certificate_verify_log) > 0, 'the Principal can read the verification log');
select is((select masked_name from public.v_certificate_public_verify where serial_no = 'GHS-LHR/TC/2026/00147'), 'A* H', 'staff see the same masked view');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.certificate_verify_log), 0::bigint, 'a teacher cannot read the log');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.certificate_verify_log), 0::bigint, 'another school sees none of it');

select * from finish();
rollback;
