-- pgTAP tests for FR-T03: Transfer Certificate issuance workflow.
--
-- The PDF bytes are produced outside the database (headless Chromium, see
-- apps/academy/lib/pdf/render.ts) and are asserted on for real in
-- e2e/transfer-certificate-issuance.spec.ts. What is tested here is
-- everything the database owns: who may issue, what the four acceptance
-- criteria do, what payload_snapshot freezes, that a failure after the
-- serial allocation returns the number (FR-T02's AC2 in this real call
-- path), and that voiding an issue never rewinds the counter.
--
-- Dates are derived from the clock rather than written out. The ACs say
-- "leaving date 2026-06-30"; what they mean is a leaving date inside the
-- current enrolment's life, and provision_tenant() dates its session off
-- current_date, so hard-coding would rot into a date-drift failure. The
-- date of birth IS written out, because AC3 is about the exact words
-- 2011-03-04 produces.
begin;
select plan(65);

select extract(year from current_date)::int as y0 \gset

select public.provision_tenant('test-certtc-co', 'Cert TC Co', 'owner@certtc.test');
select id as tenant_id from public.tenant where slug = 'test-certtc-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@certtc.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'TC Owner');

select gen_random_uuid() as clerk_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'clerk_uid', 'clerk@certtc.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'clerk_uid', :'tenant_id', 'admissions_officer', 'Farhat Jabeen');

select gen_random_uuid() as other_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_uid', 'other@certtc.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_uid', :'tenant_id', 'exam_controller', 'TC Exam Controller');

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
-- Ali is alone in section A, so the section's roster count IS his presence
-- on it; everybody else lives in section B.
select public.create_section(:'campus_a'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_a \gset
select public.create_section(:'campus_a'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 40) as section_b \gset

reset role;
-- Inserted directly rather than through create_student(), which allocates
-- its own GR number: AC1 names GR 2019-0442 and gr_number is immutable
-- after insert (trg_gr_number_immutable).
insert into public.student (tenant_id, campus_id, gr_number, name_en, father_name_en, dob, gender, religion)
values (:'tenant_id', :'campus_a', '2019-0442', 'Ali Raza', 'Muhammad Raza', '2011-03-04', 'male', 'Islam')
returning id as student_ali \gset
set local role authenticated;

select public.create_student(:'campus_a'::uuid, 'Sara Khan', '2013-05-09'::date, 'female') as student_sara \gset
select public.create_student(:'campus_a'::uuid, 'Zain Ahmed', '2012-08-19'::date, 'male') as student_zain \gset
select public.create_student(:'campus_a'::uuid, 'Hina Bilal', '2012-02-02'::date, 'female') as student_hina \gset

select public.enrol_student(:'section_a'::uuid, :'student_ali'::uuid) as enrol_ali \gset
select public.enrol_student(:'section_b'::uuid, :'student_sara'::uuid) as enrol_sara \gset
select public.enrol_student(:'section_b'::uuid, :'student_zain'::uuid) as enrol_zain \gset
select public.enrol_student(:'section_b'::uuid, :'student_hina'::uuid) as enrol_hina \gset

select public.fn_find_or_create_guardian(p_name_en => 'Raza Sahib', p_phone_e164 => '+923001112222') as guardian_id \gset
select public.link_guardian(:'student_ali'::uuid, :'guardian_id'::uuid, 'father'::public.guardian_relationship, true, true);

reset role;
-- enrol_student() stamps joined_on = current_date; the certificate needs a
-- leaving date inside an enrolment that already existed.
update public.enrolment set joined_on = current_date - 200 where tenant_id = :'tenant_id';
-- AC4's "the student was never enrolled": enrolment_status has no
-- 'pending_admission' value, and an enrolment that is not 'active' is the
-- same refusal for the same reason.
update public.enrolment set status = 'left' where id = :'enrol_sara';
select gen_random_uuid() as guardian_auth_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'guardian_auth_uid', 'parent@certtc.test', 'x', now(), 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'guardian_auth_uid'::uuid where id = :'guardian_id'::uuid;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);

select (current_date - 10)::text as leaving_date \gset
select (current_date - 9)::text as day_after \gset

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the date of birth in words
-- ═══════════════════════════════════════════════════════════════════════

select is(
  public.dob_to_words('2011-03-04'::date, 'en'),
  'Fourth March Two Thousand Eleven',
  'AC3: 2011-03-04 reads as Fourth March Two Thousand Eleven'
);
select is(
  public.dob_to_words('2012-03-04'::date, 'en'),
  'Fourth March Two Thousand Twelve',
  'and matches the sample FR-T01''s field catalogue previews for student.dob_words'
);
select is(
  public.dob_to_words('2001-12-31'::date, 'en'),
  'Thirty First December Two Thousand One',
  'the irregular ordinals are words, not a number with a suffix'
);
select is(
  public.dob_to_words('2020-01-01'::date, 'en'),
  'First January Two Thousand Twenty',
  'a round decade year is not written with a trailing Zero'
);
select is(
  public.dob_to_words('2000-06-15'::date, 'en'),
  'Fifteenth June Two Thousand',
  'and the century year is just Two Thousand'
);
select is(
  public.dob_to_words('1999-11-22'::date, 'en'),
  'Twenty Second November Nineteen Ninety Nine',
  'a twentieth-century date of birth still reads correctly'
);
select is(
  public.dob_to_words('2011-03-04'::date, 'ur'),
  null,
  'Urdu returns null rather than English words — a language never silently falls back'
);
select is(public.dob_to_words(null, 'en'), null, 'a null date of birth has no words');

-- ═══════════════════════════════════════════════════════════════════════
-- Nothing can be issued without an active template
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ select public.issue_transfer_certificate(%L, %L::date) $$, :'enrol_ali', :'leaving_date'),
  'P0002',
  'TEMPLATE_NOT_FOUND',
  'with no active transfer template, issuing is refused'
);
select is(
  (select count(*)::int from public.certificate_serial_counter where campus_id = :'campus_a'),
  0,
  'and the refusal happened before any serial was allocated — no counter exists yet'
);

select public.create_certificate_template(
  'transfer'::public.certificate_type,
  'School Leaving Certificate',
  '<p>{{student.name_en}} s/o {{student.father_name_en}}, GR {{student.gr_number}}, born {{student.dob}} '
  || '({{student.dob_words}}), of {{enrolment.class_name}}, left this school on {{enrolment.left_on}} '
  || 'with conduct {{transfer.conduct}} for reason {{transfer.reason}}. '
  || 'Serial {{issue.serial_no}}, issued {{issue.date}}.</p>',
  'FBISE', 'en'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_a'::uuid
) as tpl_v1 \gset
select public.activate_certificate_template(:'tpl_v1'::uuid) as _a \gset

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: an enrolment the student never actually held
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ select public.issue_transfer_certificate(%L, %L::date, null, null, 'FBISE') $$, :'enrol_sara', :'leaving_date'),
  '55000',
  'ENROLMENT_NOT_ACTIVE',
  'AC4: a TC cannot be issued against an enrolment that is not active'
);
select is(
  (select count(*)::int from public.certificate_serial_counter where campus_id = :'campus_a'),
  0,
  'AC4: and that refusal, too, costs no serial'
);

select throws_ok(
  format($$ select public.issue_transfer_certificate(%L, %L::date, null, null, 'FBISE') $$,
         :'enrol_ali', (current_date - 500)::text),
  '23514',
  'LEAVING_DATE_BEFORE_ADMISSION',
  'a leaving date before the date of admission is refused'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: the issue itself
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);

select public.issue_transfer_certificate(
  :'enrol_ali'::uuid, :'leaving_date'::date, 'Family relocation', 'Good', 'FBISE'
)::text as issue_json \gset
select (:'issue_json'::jsonb) ->> 'issue_id'  as issue_id,
       (:'issue_json'::jsonb) ->> 'serial_no' as serial_1,
       (:'issue_json'::jsonb) ->> 'pdf_path'  as pdf_path \gset

select is(:'serial_1', 'TC-' || :y0 || '-000001', 'AC1: the first TC of the session carries serial 000001');
select is(
  (select status::text from public.certificate_issue where id = :'issue_id'),
  'issued',
  'AC1: the register row is issued'
);
select is(
  :'pdf_path',
  :'tenant_id' || '/' || :'campus_a' || '/transfer/TC-' || :y0 || '-000001.pdf',
  'AC1: the PDF path is tenant/campus/type/serial.pdf'
);
select is(
  (select status::text from public.enrolment where id = :'enrol_ali'),
  'transferred',
  'AC1: enrolment.status becomes transferred'
);
select isnt(
  (select tc_issued_at from public.enrolment where id = :'enrol_ali'),
  null,
  'AC1: enrolment.tc_issued_at is stamped'
);
select is(
  (select left_on from public.enrolment where id = :'enrol_ali'),
  :'leaving_date'::date,
  'AC1: enrolment.left_on is the leaving date — the roster mechanism, not a new one'
);
select is(
  (select tc_certificate_issue_id from public.enrolment where id = :'enrol_ali'),
  :'issue_id'::uuid,
  'AC1: and the enrolment points back at the certificate that did it'
);

-- AC1's roster clause, through the predicate every point-in-time roster in
-- this schema already uses.
select is(
  (select count(*)::int from public.enrolment e join public.student s on s.id = e.student_id
    where e.section_id = :'section_a'
      and e.joined_on <= :'leaving_date'::date and (e.left_on is null or e.left_on >= :'leaving_date'::date)
      and s.status = 'active'),
  1,
  'AC1: on the leaving date itself the student is still on the section roster'
);
select is(
  (select count(*)::int from public.enrolment e join public.student s on s.id = e.student_id
    where e.section_id = :'section_a'
      and e.joined_on <= :'day_after'::date and (e.left_on is null or e.left_on >= :'day_after'::date)
      and s.status = 'active'),
  0,
  'AC1: and off it for every date after'
);

-- The same thing, through a real consumer rather than a copy of its WHERE
-- clause: FR-G13's escalation counts the roster for a date.
select is(
  (select enrolled_count from public.check_unmarked_attendance(:'campus_a'::uuid, :'leaving_date'::date)
    where section_id = :'section_a'),
  1,
  'AC1: FR-G13''s roster count still sees the student on the leaving date'
);
select is(
  (select count(*)::int from public.check_unmarked_attendance(:'campus_a'::uuid, :'day_after'::date)
    where section_id = :'section_a'),
  0,
  'AC1: and the section has nobody left on it the day after'
);

select is(
  (select count(*)::int from public.enrolment e
    where e.session_id = :'session_id' and e.status = 'active' and e.deleted_at is null and e.id = :'enrol_ali'),
  0,
  'a transferred enrolment is no longer eligible for FR-A06''s rollover scan'
);

-- ═══════════════════════════════════════════════════════════════════════
-- payload_snapshot: what a reprint renders from
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select payload_snapshot -> 'values' ->> 'student.gr_number' from public.certificate_issue where id = :'issue_id'),
  '2019-0442',
  'the snapshot froze the GR number'
);
select is(
  (select payload_snapshot -> 'values' ->> 'student.dob' from public.certificate_issue where id = :'issue_id'),
  '04-03-2011',
  'AC3: the date of birth prints in figures as 04-03-2011'
);
select is(
  (select payload_snapshot -> 'values' ->> 'student.dob_words' from public.certificate_issue where id = :'issue_id'),
  'Fourth March Two Thousand Eleven',
  'AC3: alongside the same date in words'
);
select is(
  (select payload_snapshot -> 'values' ->> 'issue.serial_no' from public.certificate_issue where id = :'issue_id'),
  :'serial_1',
  'the serial on the document is the serial on the register row'
);
select is(
  (select payload_snapshot -> 'values' ->> 'enrolment.left_on' from public.certificate_issue where id = :'issue_id'),
  to_char(:'leaving_date'::date, 'DD-MM-YYYY'),
  'the leaving date is frozen onto the document'
);
select is(
  (select payload_snapshot -> 'values' ->> 'transfer.conduct' from public.certificate_issue where id = :'issue_id'),
  'Good',
  'as are the conduct'
);
select is(
  (select payload_snapshot -> 'values' ->> 'transfer.last_class_studied' from public.certificate_issue where id = :'issue_id'),
  (select cl.name_en from public.class_level cl where cl.id = :'class1_id'),
  'and the last class studied'
);
select is(
  (select payload_snapshot -> 'values' ->> 'signatory.name' from public.certificate_issue where id = :'issue_id'),
  'Farhat Jabeen',
  'the issuing officer is recorded as the signatory until FR-T09 supplies a signing identity'
);
select is(
  (select template_version from public.certificate_issue where id = :'issue_id'),
  1,
  'the issue records the template version it was printed from'
);

-- FR-T01's promise, made real: the template moves on, the issued document
-- does not.
reset role;
update public.student set name_en = 'Ali Raza Khan' where id = :'student_ali';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);
select public.save_certificate_template(
  :'tpl_v1'::uuid, 'School Leaving Certificate',
  '<p>v2 wording — {{student.name_en}} {{student.gr_number}} {{issue.serial_no}} {{issue.date}} {{enrolment.left_on}}</p>',
  'A4'::public.certificate_page_size
) as tpl_v2 \gset
select public.activate_certificate_template(:'tpl_v2'::uuid) as _a2 \gset

select is(
  (select template_version from public.certificate_issue where id = :'issue_id'),
  1,
  'a new active template version does not retroactively change what was issued'
);
select is(
  (select payload_snapshot -> 'template' ->> 'body_html' like '%s/o%' from public.certificate_issue where id = :'issue_id'),
  true,
  'and the snapshot still holds the v1 wording, not v2''s'
);
select is(
  (select payload_snapshot -> 'values' ->> 'student.name_en' from public.certificate_issue where id = :'issue_id'),
  'Ali Raza',
  'a later correction to the student record does not rewrite the certificate either'
);
select is(
  (select public.resolve_certificate_template(:'campus_a'::uuid, 'transfer'::public.certificate_type, 'FBISE')),
  :'tpl_v2'::uuid,
  'while a NEW certificate would resolve v2'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: a second original, refused by name
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);

select throws_ok(
  format($$ select public.issue_transfer_certificate(%L, %L::date, null, null, 'FBISE') $$, :'enrol_ali', :'leaving_date'),
  '23505',
  'TC_ALREADY_ISSUED: ' || :'serial_1',
  'AC2: a second TC is refused, and the refusal NAMES the serial already on paper'
);

-- Back to the Owner from here on: FR-T02's serial_counter_read deliberately
-- does not let an Admissions Officer see the counters, so every counter
-- probe below is made by a role that may read them.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);
select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_id'),
  1::bigint,
  'AC2: the refusal is a pre-check, so it never reaches the allocator'
);

-- The friendly message is the pre-check's; the index is the race backstop
-- for two clerks who both passed that check.
reset role;
select throws_ok(
  format($$ insert into public.certificate_issue
             (tenant_id, campus_id, student_id, enrolment_id, session_id, certificate_type, serial_no,
              template_id, template_version, language, pdf_path, payload_snapshot)
           values (%L, %L, %L, %L, %L, 'transfer', 'TC-RACE-000001', %L, 1, 'en', 'race/path.pdf', '{}'::jsonb) $$,
         :'tenant_id', :'campus_a', :'student_ali', :'enrol_ali', :'session_id', :'tpl_v1'),
  '23505',
  null,
  'AC2: uq_one_active_tc refuses a second issued TC for the enrolment whatever wrote it'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);

-- ═══════════════════════════════════════════════════════════════════════
-- FR-T02's AC2, in this call path: a failure after allocation returns the
-- number
-- ═══════════════════════════════════════════════════════════════════════

-- issue_transfer_certificate() does every fallible thing it can BEFORE the
-- allocation, so the window this protects is small — but it is real (the
-- uq_one_active_tc backstop, a constraint, a trigger) and the property has
-- to hold. The shape below is the one FR-T02's own test used: the real
-- call plus a failure, both inside a plpgsql BEGIN…EXCEPTION block, which
-- is a savepoint.
select current_value as before_failure from public.certificate_serial_counter
 where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_id' \gset

do $$
declare
  v_enrolment uuid;
begin
  select e.id into v_enrolment
    from public.enrolment e join public.student s on s.id = e.student_id
   where s.name_en = 'Zain Ahmed';
  begin
    perform public.issue_transfer_certificate(v_enrolment, current_date - 10, null, null, 'FBISE');
    -- ... and here the render blows up.
    raise exception 'PDF_RENDER_FAILED';
  exception when others then
    null;
  end;
end;
$$;

select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_id'),
  :'before_failure'::bigint,
  'FR-T02 AC2: a failure after the allocation leaves the counter exactly where it was'
);
select is(
  (select status::text from public.enrolment where id = :'enrol_zain'),
  'active',
  'FR-T02 AC2: and the enrolment was never transferred'
);
select is(
  (select count(*)::int from public.certificate_issue where enrolment_id = :'enrol_zain'),
  0,
  'FR-T02 AC2: and no register row survived either'
);

select public.issue_transfer_certificate(:'enrol_zain'::uuid, :'leaving_date'::date, null, 'Excellent', 'FBISE')::text as zain_json \gset
select (:'zain_json'::jsonb) ->> 'issue_id' as zain_issue_id, (:'zain_json'::jsonb) ->> 'serial_no' as zain_serial \gset

select is(
  :'zain_serial',
  'TC-' || :y0 || '-000002',
  'FR-T02 AC2: so the number the failed attempt gave up is handed straight back out'
);
select is(
  (select payload_snapshot -> 'template' ->> 'version' from public.certificate_issue where id = :'zain_issue_id'),
  '2',
  'and this one really was printed from v2, so the snapshot is per-issue and not a constant'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The failure path: void keeps the number, and never rewinds the counter
-- ═══════════════════════════════════════════════════════════════════════

select public.issue_transfer_certificate(:'enrol_hina'::uuid, :'leaving_date'::date, null, null, 'FBISE')::text as hina_json \gset
select (:'hina_json'::jsonb) ->> 'issue_id' as hina_issue_id, (:'hina_json'::jsonb) ->> 'serial_no' as hina_serial \gset

select is(:'hina_serial', 'TC-' || :y0 || '-000003', 'the third certificate of the session is 000003');

select public.void_certificate_issue(:'hina_issue_id'::uuid, 'RENDERER_UNAVAILABLE') as _v \gset

select is(
  (select status::text from public.certificate_issue where id = :'hina_issue_id'),
  'void',
  'a render that never produced a document voids the issue'
);
select is(
  (select serial_no from public.certificate_issue where id = :'hina_issue_id'),
  :'hina_serial',
  'the void row KEEPS its serial, so the register has no hole to explain'
);
select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_id'),
  3::bigint,
  'and the counter is not rewound — FR-T02 forbids it, and a rewound number gets printed twice'
);
select is(
  (select status::text from public.enrolment where id = :'enrol_hina'),
  'active',
  'the enrolment goes back to active, because the child was never actually transferred'
);
select is(
  (select left_on from public.enrolment where id = :'enrol_hina'),
  null,
  'and back onto every roster it was taken off'
);
select is(
  (select tc_certificate_issue_id from public.enrolment where id = :'enrol_hina'),
  null,
  'with no certificate pointed at it'
);

select public.issue_transfer_certificate(:'enrol_hina'::uuid, :'leaving_date'::date, null, null, 'FBISE')::text as hina2_json \gset
select is(
  (:'hina2_json'::jsonb) ->> 'serial_no',
  'TC-' || :y0 || '-000004',
  'the retry after a void takes the NEXT number; the voided one is spent, not reused'
);
select throws_ok(
  format($$ select public.void_certificate_issue(%L, 'again') $$, :'hina_issue_id'),
  '55000',
  'CERTIFICATE_NOT_ISSUED',
  'and a void cannot be voided twice'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Role and campus gating, and who can read the register
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'other_uid')::text,
  true
);
select throws_ok(
  format($$ select public.issue_transfer_certificate(%L, %L::date, null, null, 'FBISE') $$, :'enrol_sara', :'leaving_date'),
  '42501',
  'FORBIDDEN',
  'a role with no issuing authority cannot issue a certificate'
);
select is_empty(
  $$ select 1 from public.certificate_issue $$,
  'nor read the register at all'
);
select throws_ok(
  format($$ select public.void_certificate_issue(%L, 'nope') $$, :'issue_id'),
  '42501',
  'FORBIDDEN',
  'nor void one'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_b'), 'sub', :'other_uid')::text,
  true
);
select is_empty(
  format($$ select 1 from public.certificate_issue where id = %L $$, :'issue_id'),
  'a Principal scoped to another campus cannot see this campus''s certificates'
);
select throws_ok(
  format($$ select public.issue_transfer_certificate(%L, %L::date, null, null, 'FBISE') $$, :'enrol_zain', :'leaving_date'),
  '42501',
  'FORBIDDEN',
  'nor issue against an enrolment outside their campus scope'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);
select isnt_empty(
  format($$ select 1 from public.certificate_issue where id = %L $$, :'issue_id'),
  'the Admissions Officer who issued it can read it back'
);

-- The parent side. auth_guardian_student_ids() resolves from the guardian
-- row's auth_user_id, so a parent sees exactly their own children.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::json, 'sub', :'guardian_auth_uid')::text,
  true
);
select isnt_empty(
  format($$ select 1 from public.certificate_issue where id = %L $$, :'issue_id'),
  'a guardian can read their own child''s issued certificate'
);
select is_empty(
  format($$ select 1 from public.certificate_issue where id = %L $$, :'zain_issue_id'),
  'and not another child''s'
);
select is_empty(
  format($$ select 1 from public.certificate_issue where id = %L $$, :'hina_issue_id'),
  'and never a voided one, which is a register entry rather than a document'
);
select is(
  (select count(*)::int from public.certificate_issue),
  1,
  'a parent''s whole view of the register is their own child''s issued certificates'
);

select * from finish();
rollback;
