-- pgTAP tests for FR-T05: Character Certificate issuance.
--
-- The PDF bytes are produced outside the database (headless Chromium, see
-- apps/academy/lib/pdf/render.ts) and are asserted on for real in
-- e2e/character-certificate-issuance.spec.ts. What is tested here is
-- everything the database owns: the attendance period derived from a
-- MULTI-SESSION enrolment history, the conduct grade guarded both by the
-- issuing function and by the table, the independence of the character
-- serial series from the transfer one, that a fourth certificate is an
-- ordinary insert, role and campus gating, and that a failure after the
-- allocation returns the number.
--
-- The attendance history IS written out in absolute dates (2018-04-01 ..
-- 2023-03-31), because that span is exactly what AC1 pins and it must not
-- move with the clock. Everything about the ISSUE — today's date, the
-- current session, the serial's year — is derived from the clock, because
-- provision_tenant() dates its session off current_date.
begin;
select plan(58);

select extract(year from current_date)::int as y0 \gset

select public.provision_tenant('test-certcc-co', 'Cert CC Co', 'owner@certcc.test');
select id as tenant_id from public.tenant where slug = 'test-certcc-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@certcc.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'CC Owner');

select gen_random_uuid() as clerk_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'clerk_uid', 'clerk@certcc.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'clerk_uid', :'tenant_id', 'admissions_officer', 'Farhat Jabeen');

select gen_random_uuid() as other_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_uid', 'other@certcc.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_uid', :'tenant_id', 'exam_controller', 'CC Exam Controller');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);

select public.create_campus('SOUTH', 'Campus South', null) as _c \gset
select id as campus_b from public.campus where tenant_id = :'tenant_id' and code = 'SOUTH' \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_a'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_a \gset

reset role;
-- Inserted directly rather than through create_student(): gr_number is
-- immutable after insert and the register assertions below name it.
insert into public.student (tenant_id, campus_id, gr_number, name_en, father_name_en, dob, gender, religion, status)
values (:'tenant_id', :'campus_a', '2018-0311', 'Ali Raza CC', 'Muhammad Raza', '2007-06-15', 'male', 'Islam', 'passed_out')
returning id as student_ali \gset

-- AC1's history. FR-A06's rollover creates ONE ENROLMENT PER SESSION and
-- deliberately does not stamp left_on on the row it supersedes, so this is
-- the shape a real 2018→2023 student has: five rows, every left_on null,
-- each one ending when its session ended. (enrolment_status has no
-- 'passed_out' value and gains none — that state lives on the STUDENT, put
-- there by FR-A06's rollover; the period is read off the dates either way.)
insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on, is_current, status)
select :'tenant_id', :'campus_a', y || '-' || right((y + 1)::text, 2),
       make_date(y, 4, 1), make_date(y + 1, 3, 31), false, 'closed'
  from generate_series(2018, 2022) as y;

insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
select :'tenant_id', :'campus_a', s.id, :'class1_id', 'A', 40
  from public.academic_session s
 where s.tenant_id = :'tenant_id' and s.starts_on < make_date(2023, 1, 1);

insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status, joined_on, left_on)
select :'tenant_id', :'campus_a', cs.session_id, :'student_ali', :'class1_id', cs.id,
       'graduated', s.starts_on, null
  from public.class_section cs
  join public.academic_session s on s.id = cs.session_id
 where s.tenant_id = :'tenant_id' and s.starts_on < make_date(2023, 1, 1);

set local role authenticated;

-- Sara is still enrolled; Zain left on a recorded date; Nadia has no
-- enrolment history at all (a pre-import record); Hina gets soft-deleted.
select public.create_student(:'campus_a'::uuid, 'Sara Khan CC', '2013-05-09'::date, 'female') as student_sara \gset
select public.create_student(:'campus_a'::uuid, 'Zain Ahmed CC', '2012-08-19'::date, 'male') as student_zain \gset
select public.create_student(:'campus_a'::uuid, 'Nadia Iqbal CC', '2009-02-02'::date, 'female') as student_nadia \gset
select public.create_student(:'campus_a'::uuid, 'Hina Bilal CC', '2012-02-02'::date, 'female') as student_hina \gset

select public.enrol_student(:'section_a'::uuid, :'student_sara'::uuid) as enrol_sara \gset
select public.enrol_student(:'section_a'::uuid, :'student_zain'::uuid) as enrol_zain \gset
select public.enrol_student(:'section_a'::uuid, :'student_hina'::uuid) as enrol_hina \gset

reset role;
update public.enrolment set joined_on = current_date - 200 where id in (:'enrol_sara', :'enrol_zain', :'enrol_hina');
update public.enrolment set status = 'left', left_on = current_date - 30 where id = :'enrol_zain';
set local role authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: the attendance period comes from the enrolment history
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (public.student_attendance_span(:'student_ali'::uuid) ->> 'enrolment_count')::int,
  5,
  'AC1: the 2018-2023 student really does have one enrolment per session'
);
select is(
  (public.student_attendance_span(:'student_ali'::uuid) ->> 'period_from')::date,
  '2018-04-01'::date,
  'AC1: the period starts at the EARLIEST joined_on across all of them'
);
select is(
  (public.student_attendance_span(:'student_ali'::uuid) ->> 'period_to')::date,
  '2023-03-31'::date,
  'AC1: and ends when the last session ended — not today, and not the last joined_on'
);
select is(
  (public.student_attendance_span(:'student_zain'::uuid) ->> 'period_to')::date,
  current_date - 30,
  'a recorded left_on wins over the session end, because it is the better fact'
);
select is(
  (public.student_attendance_span(:'student_sara'::uuid) ->> 'period_to')::date,
  current_date,
  'a student who is still enrolled has attended up to TODAY, not to the end of the session'
);
select is(
  (public.student_attendance_span(:'student_nadia'::uuid) ->> 'period_from')::date,
  null,
  'a student with no enrolment history has no derivable period'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Nothing can be issued without an active character template
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ select public.issue_character_certificate(%L, 'Excellent') $$, :'student_ali'),
  'P0002',
  'TEMPLATE_NOT_FOUND',
  'with no active Character Certificate template, issuing is refused'
);
select is(
  (select count(*)::int from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'character'),
  0,
  'and the refusal happened before any serial was allocated — no character counter exists yet'
);

-- AC1's period fields and the conduct grade are REQUIRED on a character
-- template, exactly as FR-T01 made enrolment.left_on required on a transfer
-- one: a template that omits them cannot be activated at all.
select public.create_certificate_template(
  'character'::public.certificate_type,
  'Character Certificate',
  '<p>{{student.name_en}}, GR {{student.gr_number}}, attended this school and bore '
  || 'a conduct of {{character.conduct_grade}}. Issued {{issue.date}}.</p>',
  null, 'en'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_a'::uuid
) as tpl_bad \gset
select throws_ok(
  format($$ select public.activate_certificate_template(%L) $$, :'tpl_bad'),
  '23514',
  'MERGE_FIELD_REQUIRED_MISSING',
  'a character template that never states the attendance period cannot be activated'
);

select public.create_certificate_template(
  'character'::public.certificate_type,
  'Character Certificate',
  '<p>Certified that {{student.name_en}}, GR {{student.gr_number}}, was a student of this school '
  || 'from {{character.period_from}} to {{character.period_to}} and that his conduct during that '
  || 'period was {{character.conduct_grade}}. {{character.remarks}} '
  || 'Serial {{issue.serial_no}}, issued {{issue.date}}.</p>',
  null, 'en'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_a'::uuid
) as tpl_v1 \gset
select public.activate_certificate_template(:'tpl_v1'::uuid) as _a \gset

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the transfer series is at 147 and knows nothing about this one
-- ═══════════════════════════════════════════════════════════════════════

-- allocate_certificate_serial() is service_role-only by design (FR-T02), so
-- the transfer series is walked up here as the owner of the schema rather
-- than by issuing 147 real transfer certificates.
reset role;
select count(*) as _tc_seed from (
  select public.allocate_certificate_serial(
    :'campus_a'::uuid, 'transfer'::public.certificate_type, :'session_id'::uuid)
    from generate_series(1, 147)
) s \gset
set local role authenticated;

select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_id'),
  147::bigint,
  'AC3: the campus transfer series stands at 147'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1 + AC3: the issue itself, by the Admissions Officer
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);

select public.issue_character_certificate(
  :'student_ali'::uuid, 'Excellent', null, null, 'A diligent and courteous student.'
)::text as issue_json \gset
select (:'issue_json'::jsonb) ->> 'issue_id'  as issue_id,
       (:'issue_json'::jsonb) ->> 'serial_no' as serial_1,
       (:'issue_json'::jsonb) ->> 'pdf_path'  as pdf_path \gset

-- Back to the Owner for the counter probes: FR-T02's serial_counter_read
-- deliberately does not let an Admissions Officer see the counters.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);

select is(
  :'serial_1',
  'CC-' || :y0 || '-000001',
  'AC3: the first Character Certificate of the year is 000001 — an INDEPENDENT series'
);
select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_id'),
  147::bigint,
  'AC3: and the transfer series was not touched by it'
);
select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'character' and session_id = :'session_id'),
  1::bigint,
  'AC3: the two series are separate counter rows, keyed on certificate_type'
);
select is(
  :'pdf_path',
  :'tenant_id' || '/' || :'campus_a' || '/character/CC-' || :y0 || '-000001.pdf',
  'the PDF path is tenant/campus/type/serial.pdf, the same shape FR-T09 will hash'
);
select is(
  (select status::text from public.certificate_issue where id = :'issue_id'),
  'issued',
  'the register row is issued'
);

-- AC1's point: a student who left in 2023, issued in the current year, and
-- the document says 2018-2023.
select is(
  (select payload_snapshot -> 'values' ->> 'character.period_from' from public.certificate_issue where id = :'issue_id'),
  '01-04-2018',
  'AC1: the certificate states the real start of the attendance period'
);
select is(
  (select payload_snapshot -> 'values' ->> 'character.period_to' from public.certificate_issue where id = :'issue_id'),
  '31-03-2023',
  'AC1: and the real end of it — derived from the enrolment history, not from today'
);
select is(
  (select payload_snapshot -> 'values' ->> 'issue.date' from public.certificate_issue where id = :'issue_id'),
  to_char(current_date, 'DD-MM-YYYY'),
  'while the date of ISSUE is today, three years after the student left'
);
select is(
  (select payload_snapshot -> 'values' ->> 'character.conduct_grade' from public.certificate_issue where id = :'issue_id'),
  'Excellent',
  'the conduct grade is frozen onto the document'
);
select is(
  (select payload_snapshot -> 'values' ->> 'character.remarks' from public.certificate_issue where id = :'issue_id'),
  'A diligent and courteous student.',
  'as are the remarks'
);
select is(
  (select payload_snapshot -> 'values' ->> 'student.gr_number' from public.certificate_issue where id = :'issue_id'),
  '2018-0311',
  'and the GR number'
);
select is(
  (select payload_snapshot -> 'values' ->> 'signatory.name' from public.certificate_issue where id = :'issue_id'),
  'Farhat Jabeen',
  'the issuing officer is recorded as the signatory until FR-T09 supplies a signing identity'
);
select is(
  (select session_id from public.certificate_issue where id = :'issue_id'),
  :'session_id'::uuid,
  'the row is numbered against the CURRENT session, not the one the student attended'
);
select is(
  (select enrolment_id from public.certificate_issue where id = :'issue_id'),
  (select id from public.enrolment where student_id = :'student_ali' order by joined_on desc limit 1),
  'and points at the enrolment the conduct was last observed in — context, not a key'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: not one per enrolment
-- ═══════════════════════════════════════════════════════════════════════

select public.issue_character_certificate(:'student_ali'::uuid, 'Very Good')::text as issue2_json \gset
select public.issue_character_certificate(:'student_ali'::uuid, 'Good')::text as issue3_json \gset
select public.issue_character_certificate(:'student_ali'::uuid, 'Satisfactory')::text as issue4_json \gset

select is(
  (:'issue4_json'::jsonb) ->> 'serial_no',
  'CC-' || :y0 || '-000004',
  'AC4: a fourth Character Certificate is issued, and takes the next number'
);
select is(
  (select count(*)::int from public.certificate_issue
    where student_id = :'student_ali' and certificate_type = 'character' and status = 'issued'),
  4,
  'AC4: all four stand in the register — unlike a TC, these are not one per enrolment'
);
select is(
  (select count(distinct enrolment_id)::int from public.certificate_issue
    where student_id = :'student_ali' and certificate_type = 'character'),
  1,
  'AC4: all four against the SAME enrolment, which uq_one_active_tc does not police'
);
select is(
  (select count(*)::int from public.certificate_issue where student_id = :'student_ali' and certificate_type = 'transfer'),
  0,
  'and none of them is a transfer certificate, so the TC rule was never in play'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: the conduct grade, twice
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ select public.issue_character_certificate(%L, 'Poor') $$, :'student_ali'),
  '23514',
  'CONDUCT_GRADE_INVALID',
  'AC2: a conduct of Poor is refused by the issuing function, with a message a clerk can act on'
);
select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'character' and session_id = :'session_id'),
  4::bigint,
  'AC2: and that refusal, like every other, happens before the allocator'
);

-- The structural half. The function is not the only way to write a row, so
-- the table itself refuses it — this is the insert an API client makes.
reset role;
select throws_ok(
  format($$ insert into public.certificate_issue
             (tenant_id, campus_id, student_id, session_id, certificate_type, serial_no,
              template_id, template_version, language, pdf_path, payload_snapshot)
           values (%L, %L, %L, %L, 'character', 'CC-DIRECT-000001', %L, 1, 'en', 'direct/poor.pdf',
                   jsonb_build_object('values', jsonb_build_object('character.conduct_grade', 'Poor'))) $$,
         :'tenant_id', :'campus_a', :'student_ali', :'session_id', :'tpl_v1'),
  '23514',
  'new row for relation "certificate_issue" violates check constraint "chk_conduct_grade"',
  'AC2: and chk_conduct_grade refuses the same value on a direct insert, whatever wrote it'
);
select throws_ok(
  format($$ insert into public.certificate_issue
             (tenant_id, campus_id, student_id, session_id, certificate_type, serial_no,
              template_id, template_version, language, pdf_path, payload_snapshot)
           values (%L, %L, %L, %L, 'character', 'CC-DIRECT-000002', %L, 1, 'en', 'direct/none.pdf', '{}'::jsonb) $$,
         :'tenant_id', :'campus_a', :'student_ali', :'session_id', :'tpl_v1'),
  '23514',
  'new row for relation "certificate_issue" violates check constraint "chk_conduct_grade"',
  'AC2: a character certificate with NO conduct at all is refused too — a null check result must not pass'
);
select lives_ok(
  format($$ insert into public.certificate_issue
             (tenant_id, campus_id, student_id, session_id, certificate_type, serial_no,
              template_id, template_version, language, pdf_path, payload_snapshot)
           values (%L, %L, %L, %L, 'character', 'CC-DIRECT-000003', %L, 1, 'en', 'direct/ok.pdf',
                   jsonb_build_object('values', jsonb_build_object('character.conduct_grade', 'Satisfactory'))) $$,
         :'tenant_id', :'campus_a', :'student_ali', :'session_id', :'tpl_v1'),
  'while a permitted grade passes, so the constraint is a scale and not a blanket refusal'
);
delete from public.certificate_issue where serial_no = 'CC-DIRECT-000003';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);

select is(
  (select count(*)::int from public.certificate_type_field_catalog
    where certificate_type = 'character' and field_path = 'character.conduct'),
  0,
  'the free-text character.conduct field is gone, so a template cannot print an ungraded conduct'
);
select is(
  (select required from public.certificate_type_field_catalog
    where certificate_type = 'character' and field_path = 'character.conduct_grade'),
  true,
  'and its graded replacement is required on every character template'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The period overrides, and the guards on them
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ select public.issue_character_certificate(%L, 'Good') $$, :'student_nadia'),
  'P0002',
  'ATTENDANCE_PERIOD_UNKNOWN',
  'a student with no enrolment history cannot have a period invented for them'
);

select public.issue_character_certificate(
  :'student_nadia'::uuid, 'Good', '2015-04-01'::date, '2019-03-31'::date
)::text as nadia_json \gset
select is(
  (select payload_snapshot -> 'values' ->> 'character.period_from' from public.certificate_issue
    where id = ((:'nadia_json'::jsonb) ->> 'issue_id')::uuid),
  '01-04-2015',
  'but a stated period is accepted, because pre-import history is real'
);

select public.issue_character_certificate(
  :'student_ali'::uuid, 'Good', '2019-04-01'::date
)::text as partial_json \gset
select is(
  (select payload_snapshot -> 'values' ->> 'character.period_to' from public.certificate_issue
    where id = ((:'partial_json'::jsonb) ->> 'issue_id')::uuid),
  '31-03-2023',
  'each end falls back on its own, so correcting one does not discard the recorded other'
);

select throws_ok(
  format($$ select public.issue_character_certificate(%L, 'Good', '2023-04-01'::date, '2018-03-31'::date) $$, :'student_ali'),
  '23514',
  'PERIOD_END_BEFORE_START',
  'a period that ends before it starts is refused'
);
select throws_ok(
  format($$ select public.issue_character_certificate(%L, 'Good', null, (current_date + 1)::date) $$, :'student_ali'),
  '23514',
  'PERIOD_IN_FUTURE',
  'and a certificate cannot certify conduct that has not happened yet'
);

-- ═══════════════════════════════════════════════════════════════════════
-- A currently enrolled student, and who may issue at all
-- ═══════════════════════════════════════════════════════════════════════

select public.issue_character_certificate(:'student_sara'::uuid, 'Good')::text as sara_json \gset
select is(
  (select status::text from public.enrolment where id = :'enrol_sara'),
  'active',
  'issuing a character certificate to a currently enrolled student changes nothing about the enrolment'
);
select is(
  (select left_on from public.enrolment where id = :'enrol_sara'),
  null,
  'and never takes them off a roster — that is a transfer certificate''s job, not this one''s'
);

reset role;
update public.student set deleted_at = clock_timestamp() where id = :'student_hina';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);
select throws_ok(
  format($$ select public.issue_character_certificate(%L, 'Good') $$, :'student_hina'),
  'P0002',
  'STUDENT_NOT_FOUND',
  'FR-A15: a soft-deleted student is not a record to print a statutory document from'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'other_uid')::text,
  true
);
select throws_ok(
  format($$ select public.issue_character_certificate(%L, 'Good') $$, :'student_sara'),
  '42501',
  'FORBIDDEN',
  'a role with no issuing authority cannot issue a character certificate'
);
select is_empty(
  $$ select 1 from public.certificate_issue $$,
  'nor read the register at all'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_b'), 'sub', :'other_uid')::text,
  true
);
select throws_ok(
  format($$ select public.issue_character_certificate(%L, 'Good') $$, :'student_ali'),
  '42501',
  'FORBIDDEN',
  'nor may a Principal issue against a student outside their campus scope'
);
select throws_ok(
  format($$ select public.student_attendance_span(%L) $$, :'student_ali'),
  '42501',
  'FORBIDDEN',
  'and they cannot even ask what that student''s attendance span was'
);
select is_empty(
  format($$ select 1 from public.certificate_issue where id = %L $$, :'issue_id'),
  'nor see the certificate that was issued at the other campus'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'other_uid')::text,
  true
);
select isnt_empty(
  format($$ select 1 from public.certificate_issue where id = %L $$, :'issue_id'),
  'the Principal of the issuing campus reads the register'
);
select lives_ok(
  format($$ select public.issue_character_certificate(%L, 'Good') $$, :'student_sara'),
  'and may issue — Principal, Owner and Admissions Officer are the issuing roles'
);

-- ═══════════════════════════════════════════════════════════════════════
-- FR-T02's AC2 in this call path: a failure after allocation returns the
-- number; a void keeps it
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);
select current_value as before_failure from public.certificate_serial_counter
 where campus_id = :'campus_a' and certificate_type = 'character' and session_id = :'session_id' \gset

do $$
declare
  v_student uuid;
begin
  select id into v_student from public.student where name_en = 'Zain Ahmed CC';
  begin
    perform public.issue_character_certificate(v_student, 'Good');
    -- ... and here the render blows up.
    raise exception 'PDF_RENDER_FAILED';
  exception when others then
    null;
  end;
end;
$$;

select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'character' and session_id = :'session_id'),
  :'before_failure'::bigint,
  'FR-T02 AC2: a failure after the allocation leaves the counter exactly where it was'
);
select is(
  (select count(*)::int from public.certificate_issue where student_id = :'student_zain'),
  0,
  'FR-T02 AC2: and no register row survived it either'
);

select public.issue_character_certificate(:'student_zain'::uuid, 'Good')::text as zain_json \gset
select (:'zain_json'::jsonb) ->> 'issue_id' as zain_issue_id, (:'zain_json'::jsonb) ->> 'serial_no' as zain_serial \gset
select is(
  :'zain_serial',
  'CC-' || :y0 || '-' || lpad((:'before_failure'::bigint + 1)::text, 6, '0'),
  'FR-T02 AC2: so the number the failed attempt gave up is handed straight back out'
);

select public.void_certificate_issue(:'zain_issue_id'::uuid, 'RENDERER_UNAVAILABLE') as _v \gset
select is(
  (select status::text from public.certificate_issue where id = :'zain_issue_id'),
  'void',
  'a render that never produced a document voids the issue, character or not'
);
select is(
  (select serial_no from public.certificate_issue where id = :'zain_issue_id'),
  :'zain_serial',
  'the void row KEEPS its serial, so the register has no hole to explain'
);
select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'character' and session_id = :'session_id'),
  (:'before_failure'::bigint + 1),
  'and the counter is not rewound'
);
select is(
  (select status::text from public.enrolment where id = :'enrol_zain'),
  'left',
  'voiding a character certificate touches no enrolment — there was nothing to revert'
);
select lives_ok(
  format($$ select public.issue_character_certificate(%L, 'Good') $$, :'student_zain'),
  'and the student may simply be issued another one'
);

select * from finish();
rollback;
