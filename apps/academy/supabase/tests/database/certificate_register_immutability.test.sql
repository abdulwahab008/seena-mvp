-- pgTAP tests for FR-T08: statutory certificate register with immutability.
--
-- Almost everything this FR is about lives in the database, so almost all
-- of it is tested here: the append-only trigger's allow-list and its
-- refusal message, exercised from all three callers the threat model names
-- (an authenticated application role, service_role, and the table owner
-- itself); cancellation leaving a serial exactly where it was with its
-- replacement cross-referenced in both directions; gap detection over a
-- multi-year register; and the DELETE refusal together with the audit row
-- the refusal leaves behind. The register's PDF export is Chromium's and
-- is asserted on for real in e2e/certificate-register.spec.ts.
--
-- What is NOT asserted here is AC3's "under 20 seconds", deliberately:
-- that budget covers a browser rendering tens of A4 pages, which no
-- database test can measure. What IS measured is the part the database
-- owns — the filtered register read over a genuinely 4,000-entry register
-- — so a query that lost its index or went quadratic fails here rather
-- than in front of an inspector.
--
-- Serials are derived from the clock's year, because FR-T02 renders {YEAR}
-- from the session's start date and provision_tenant() dates its session
-- off current_date. AC2's 00147 and 00212 are pinned as the sequence
-- positions they actually are.
begin;
select plan(71);

select extract(year from current_date)::int as y0 \gset

select public.provision_tenant('test-certreg-co', 'Cert Register Co', 'owner@certreg.test');
select id as tenant_id from public.tenant where slug = 'test-certreg-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@certreg.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Register Owner');

select gen_random_uuid() as principal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_uid', 'principal@certreg.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_uid', :'tenant_id', 'principal', 'Nusrat Jamil');

select gen_random_uuid() as clerk_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'clerk_uid', 'clerk@certreg.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'clerk_uid', :'tenant_id', 'admissions_officer', 'Farhat Jabeen');

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

select public.create_student(:'campus_a'::uuid, 'Ali Raza REG', '2011-03-04'::date, 'male') as student_ali \gset
select public.create_student(:'campus_a'::uuid, 'Sara Khan REG', '2013-05-09'::date, 'female') as student_sara \gset
select public.create_student(:'campus_a'::uuid, 'Zain Ahmed REG', '2012-08-19'::date, 'male') as student_zain \gset

select public.enrol_student(:'section_a'::uuid, :'student_ali'::uuid) as enrol_ali \gset
select public.enrol_student(:'section_a'::uuid, :'student_sara'::uuid) as enrol_sara \gset
select public.enrol_student(:'section_a'::uuid, :'student_zain'::uuid) as enrol_zain \gset

reset role;
update public.enrolment set joined_on = current_date - 200 where tenant_id = :'tenant_id';
set local role authenticated;

select public.create_certificate_template(
  'transfer'::public.certificate_type,
  'School Leaving Certificate',
  '<p>{{student.name_en}} s/o {{student.father_name_en}}, GR {{student.gr_number}}, born {{student.dob}} '
  || '({{student.dob_words}}), of {{enrolment.class_name}}, left this school on {{enrolment.left_on}} '
  || 'with conduct {{transfer.conduct}} for reason {{transfer.reason}}. '
  || 'Serial {{issue.serial_no}}, issued {{issue.date}}.</p>',
  null, 'en'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_a'::uuid
) as tpl_tc \gset
select public.activate_certificate_template(:'tpl_tc'::uuid) as _a \gset

select public.create_certificate_template(
  'character'::public.certificate_type,
  'Character Certificate',
  '<p>Certified that {{student.name_en}}, GR {{student.gr_number}}, was a student of this school '
  || 'from {{character.period_from}} to {{character.period_to}} and that his conduct during that '
  || 'period was {{character.conduct_grade}}. Serial {{issue.serial_no}}, issued {{issue.date}}.</p>',
  null, 'en'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_a'::uuid
) as tpl_cc \gset
select public.activate_certificate_template(:'tpl_cc'::uuid) as _a \gset

select (current_date - 10)::text as leaving_date \gset

-- ═══════════════════════════════════════════════════════════════════════
-- The school's history: six closed years, 335 students, one enrolment per
-- student per year. AC3 needs a register of thousands of entries spanning
-- several years, and a transfer certificate is one-per-enrolment
-- (uq_one_active_tc), so the enrolments have to be real. They are written
-- as 'graduated' rather than 'active' so the section capacity trigger —
-- which only counts active enrolments — is not the thing under test here.
-- ═══════════════════════════════════════════════════════════════════════

reset role;
insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on, is_current, status)
select :'tenant_id', :'campus_a', y || '-' || right((y + 1)::text, 2),
       make_date(y, 4, 1), make_date(y + 1, 3, 31), false, 'closed'
  from generate_series(:y0 - 6, :y0 - 1) as y;

insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
select :'tenant_id', :'campus_a', s.id, :'class1_id', 'H', 200
  from public.academic_session s
 where s.tenant_id = :'tenant_id';

insert into public.student (tenant_id, campus_id, gr_number, name_en, father_name_en, dob, gender, status)
select :'tenant_id', :'campus_a', 'H-' || lpad(n::text, 5, '0'),
       'Historic Student ' || n, 'Historic Father ' || n, make_date(2008, 1, 1), 'male', 'passed_out'
  from generate_series(1, 335) as n;

insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status, joined_on)
select :'tenant_id', :'campus_a', cs.session_id, st.id, :'class1_id', cs.id, 'graduated', s.starts_on
  from public.class_section cs
  join public.academic_session s on s.id = cs.session_id
  cross join public.student st
 where cs.tenant_id = :'tenant_id' and cs.name = 'H'
   and st.tenant_id = :'tenant_id' and st.name_en like 'Historic Student %';
set local role authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- serial_seq: the register's own ordinal
-- ═══════════════════════════════════════════════════════════════════════

select public.issue_character_certificate(:'student_sara'::uuid, 'Excellent')::text as cc1_json \gset
select (:'cc1_json'::jsonb) ->> 'issue_id'  as cc1_id,
       (:'cc1_json'::jsonb) ->> 'serial_no' as cc1_serial \gset

select is(
  (select serial_seq from public.certificate_issue where id = :'cc1_id'),
  1::bigint,
  'the first certificate of a series takes register position 1'
);
select is(
  (select serial_no from public.certificate_issue where id = :'cc1_id'),
  'CC-' || :y0 || '-000001',
  'and its serial is the number FR-T02''s counter rendered for that position'
);

-- A hand-written row whose serial is not the number the counter handed out
-- claims NO position in the run: the register shows what does exist, and
-- refuses to let a stray row occupy an ordinal it never had.
reset role;
insert into public.certificate_issue
  (tenant_id, campus_id, student_id, session_id, certificate_type, serial_no,
   template_id, template_version, language, pdf_path, payload_snapshot)
values (:'tenant_id', :'campus_a', :'student_sara', :'session_id', 'character', 'CC-HAND-WRITTEN',
        :'tpl_cc', 1, 'en', 'handwritten/one.pdf',
        jsonb_build_object('values', jsonb_build_object('character.conduct_grade', 'Good')))
returning id as handwritten_id \gset
set local role authenticated;

select is(
  (select serial_seq from public.certificate_issue where id = :'handwritten_id'),
  null,
  'a row whose serial the counter never allocated takes no position in the run'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: the register is append-only, for every caller that can reach it
-- ═══════════════════════════════════════════════════════════════════════

select public.issue_transfer_certificate(
  :'enrol_ali'::uuid, :'leaving_date'::date, 'Family relocating', 'Excellent'
)::text as tc1_json \gset
select (:'tc1_json'::jsonb) ->> 'issue_id'  as tc1_id,
       (:'tc1_json'::jsonb) ->> 'serial_no' as tc1_serial \gset

-- The Owner, through the application's own connection. FR-T03's read
-- policy already shows them this row; cert_issue_update_denied lets the
-- statement reach it precisely so the trigger is what answers.
select throws_ok(
  format($$ update public.certificate_issue set serial_no = 'TC-FORGED-000001' where id = %L $$, :'tc1_id'),
  '42501',
  'certificate register is append-only',
  'AC1: an Owner cannot rewrite a serial number'
);
select throws_ok(
  format($$ update public.certificate_issue set student_id = %L where id = %L $$, :'student_zain', :'tc1_id'),
  '42501',
  'certificate register is append-only',
  'AC1: nor move a certificate on to a different student'
);
select throws_ok(
  format($$ update public.certificate_issue set issued_at = issued_at - interval '1 year' where id = %L $$, :'tc1_id'),
  '42501',
  'certificate register is append-only',
  'AC1: nor backdate when it was issued'
);
select throws_ok(
  format($$ update public.certificate_issue set status = 'cancelled', revoked_at = clock_timestamp(),
                  revoke_reason = 'because I said so' where id = %L $$, :'tc1_id'),
  '42501',
  'certificate register is append-only',
  'AC1: nor strike an entry out by hand instead of through revoke_certificate()'
);
select throws_ok(
  format($$ update public.certificate_issue set payload_snapshot = '{"values":{}}'::jsonb where id = %L $$, :'tc1_id'),
  '42501',
  'certificate register is append-only',
  'AC1: nor edit what the document said'
);
select throws_ok(
  format($$ update public.certificate_issue set serial_seq = 999 where id = %L $$, :'tc1_id'),
  '42501',
  'certificate register is append-only',
  'AC1: nor move an entry to a different position in the run'
);

-- The same three columns as service_role, which has BYPASSRLS and every
-- table grant, so the trigger is the only thing standing there.
reset role;
set local role service_role;
select throws_ok(
  format($$ update public.certificate_issue set serial_no = 'TC-FORGED-000002' where id = %L $$, :'tc1_id'),
  '42501',
  'certificate register is append-only',
  'AC1: a leaked service_role key cannot rewrite a serial either — RLS is not what refuses'
);
select throws_ok(
  format($$ update public.certificate_issue set student_id = %L where id = %L $$, :'student_zain', :'tc1_id'),
  '42501',
  'certificate register is append-only',
  'AC1: nor move it to another student'
);
select throws_ok(
  format($$ update public.certificate_issue set issued_at = now() where id = %L $$, :'tc1_id'),
  '42501',
  'certificate register is append-only',
  'AC1: nor restamp it'
);

-- And the table's own owner, hand-writing the UPDATE. FR-T02 set this
-- precedent for its counter: passing the "is the owner" test is necessary
-- and nowhere near sufficient, because no sanctioned frame is on the stack.
reset role;
select throws_ok(
  format($$ update public.certificate_issue set serial_no = 'TC-FORGED-000003' where id = %L $$, :'tc1_id'),
  '42501',
  'certificate register is append-only',
  'AC1: even the table owner, writing the UPDATE by hand, is refused'
);
select throws_ok(
  format($$ update public.certificate_issue set student_id = %L where id = %L $$, :'student_zain', :'tc1_id'),
  '42501',
  'certificate register is append-only',
  'AC1: the owner check alone is never enough — the sanctioned frame has to be on the stack'
);
select throws_ok(
  format($$ update public.certificate_issue set issued_at = now() where id = %L $$, :'tc1_id'),
  '42501',
  'certificate register is append-only',
  'AC1: and issued_at is as frozen as the other seventeen'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);

select results_eq(
  format($$ select serial_no, student_id, status::text from public.certificate_issue where id = %L $$, :'tc1_id'),
  format($$ select %L::text, %L::uuid, 'issued'::text $$, :'tc1_serial', :'student_ali'),
  'AC1: after twelve attempts from three different callers the entry is untouched'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: no page is torn out, and the attempt is on the record
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'super_admin', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);

select is(
  (select count(*)::int from public.audit_log
    where tenant_id = :'tenant_id' and table_name = 'certificate_issue' and action = 'delete'),
  0,
  'no delete of a register entry has been attempted yet'
);

-- cert_issue_delete_denied qualifies zero rows, so nothing raises and the
-- statement trigger's audit row survives to COMMIT. That is the whole
-- design: a refusal that aborts cannot leave evidence behind it.
select lives_ok(
  format($$ delete from public.certificate_issue where id = %L $$, :'tc1_id'),
  'AC4: an authenticated Super Admin''s DELETE does not abort the transaction'
);
select isnt_empty(
  format($$ select 1 from public.certificate_issue where id = %L $$, :'tc1_id'),
  'AC4: and it deletes nothing — the entry is still in the register'
);
select is(
  (select count(*)::int from public.audit_log
    where tenant_id = :'tenant_id' and table_name = 'certificate_issue' and action = 'delete'),
  1,
  'AC4: the attempt is written to audit_log'
);
select is(
  (select before ->> 'reason' from public.audit_log
    where tenant_id = :'tenant_id' and table_name = 'certificate_issue' and action = 'delete'),
  'certificate register is append-only',
  'AC4: and says why it was refused'
);
select is(
  (select actor_role::text from public.audit_log
    where tenant_id = :'tenant_id' and table_name = 'certificate_issue' and action = 'delete'),
  'super_admin',
  'AC4: naming the role that tried it'
);
-- current_query() is the statement the CLIENT sent, which under pgTAP is
-- the lives_ok() wrapper around it; through PostgREST or psql it is the
-- DELETE itself. Either way the attempted statement is in the record.
select ok(
  (select before ->> 'statement' from public.audit_log
    where tenant_id = :'tenant_id' and table_name = 'certificate_issue' and action = 'delete')
    like '%delete from public.certificate_issue%',
  'AC4: and recording the statement itself, which is what an inspector reads'
);

-- FR-T14's chain has to still verify with those rows in it: a denial
-- record that broke the hash chain would be worse than no record at all.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);
select is(
  (select status::text from public.run_audit_chain_verification(:'tenant_id'::uuid)),
  'ok',
  'AC4: the denial row is chained with the same hash function, so FR-T14''s verifier still passes'
);

-- A caller RLS does not filter reaches the row trigger instead, and that
-- one raises — which is what stops a cascading campus or tenant delete
-- from quietly leaving register rows behind.
reset role;
set local role service_role;
select throws_ok(
  format($$ delete from public.certificate_issue where id = %L $$, :'tc1_id'),
  '42501',
  'certificate register is append-only',
  'AC4: service_role''s DELETE is refused outright by the row trigger'
);
reset role;
select throws_ok(
  format($$ delete from public.certificate_issue where id = %L $$, :'tc1_id'),
  '42501',
  'certificate register is append-only',
  'AC4: and so is the table owner''s'
);
-- A bare TRUNCATE is already refused by the FK graph (0A000, enrolment
-- references certificate_issue); TRUNCATE ... CASCADE is the form that
-- would otherwise empty the register in one statement, firing no row
-- trigger and consulting no RLS policy.
select throws_ok(
  $$ truncate table public.certificate_issue cascade $$,
  '42501',
  'certificate register is append-only',
  'AC4: and TRUNCATE CASCADE, which fires no row trigger and no RLS policy at all, is refused by its own'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: 00147 is cancelled and STAYS at 147
-- ═══════════════════════════════════════════════════════════════════════

-- The register as it stands on the morning of the cancellation: 146
-- transfer certificates already on the page, each against its own
-- enrolment. Written directly, as the schema owner, because issuing 145
-- more through the RPC would prove nothing this FR is about; the counter is
-- walked in step so FR-T02's record of what it allocated and the register's
-- record of what was written agree, which is what
-- certificate_register_continuity() reconciles.
reset role;
select count(*) as _tc_seed from (
  select public.allocate_certificate_serial(
    :'campus_a'::uuid, 'transfer'::public.certificate_type, :'session_id'::uuid)
    from generate_series(2, 146)
) s \gset

insert into public.certificate_issue
  (tenant_id, campus_id, student_id, enrolment_id, session_id, certificate_type, serial_no, serial_seq,
   template_id, template_version, language, pdf_path, payload_snapshot)
select :'tenant_id', :'campus_a', e.student_id, e.id, :'session_id', 'transfer',
       'TC-' || :y0 || '-' || lpad((e.rn + 1)::text, 6, '0'), e.rn + 1,
       :'tpl_tc', 1, 'en', 'seed/tc-' || (e.rn + 1) || '.pdf',
       jsonb_build_object('values', jsonb_build_object(
         'student.name_en', st.name_en, 'student.gr_number', st.gr_number))
  from (
    select en.id, en.student_id, row_number() over (order by en.student_id) as rn
      from public.enrolment en
      join public.academic_session s on s.id = en.session_id
     where en.tenant_id = :'tenant_id' and s.starts_on >= make_date(:y0, 1, 1)
       and en.status = 'graduated'
  ) e
  join public.student st on st.id = e.student_id
 where e.rn <= 145;
set local role authenticated;

select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_id'),
  146::bigint,
  'the transfer series stands at 146, with 146 entries on the page'
);

select public.issue_transfer_certificate(
  :'enrol_sara'::uuid, :'leaving_date'::date, 'Wrong date of birth on record', 'Excellent'
)::text as tc147_json \gset
select (:'tc147_json'::jsonb) ->> 'issue_id'  as tc147_id,
       (:'tc147_json'::jsonb) ->> 'serial_no' as tc147_serial \gset

select is(:'tc147_serial', 'TC-' || :y0 || '-000147', 'the next certificate issued is 00147');
select is(
  (select serial_seq from public.certificate_issue where id = :'tc147_id'),
  147::bigint,
  'and it takes register position 147'
);

-- Only a Principal or above strikes an entry out.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);
select throws_ok(
  format($$ select public.revoke_certificate(%L, 'wrong date of birth') $$, :'tc147_id'),
  '42501',
  'FORBIDDEN',
  'an Admissions Officer may issue and may void a failed render, but may not cancel a delivered certificate'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_b'), 'sub', :'principal_uid')::text,
  true
);
select throws_ok(
  format($$ select public.revoke_certificate(%L, 'wrong date of birth') $$, :'tc147_id'),
  '42501',
  'FORBIDDEN',
  'nor may a Principal cancel an entry at a campus outside their scope'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select throws_ok(
  format($$ select public.revoke_certificate(%L, '   ') $$, :'tc147_id'),
  '23514',
  'REVOCATION_REASON_REQUIRED',
  'AC2: a strike-through with no reason beside it is not a register annotation'
);
select throws_ok(
  format($$ select public.revoke_certificate(%L, 'wrong date of birth', %L) $$, :'tc147_id', :'cc1_id'),
  '23514',
  'REPLACEMENT_INVALID',
  'and a character certificate for a different student is not a replacement for a TC'
);

select public.revoke_certificate(:'tc147_id'::uuid, 'wrong date of birth')::text as revoke_json \gset

select is(
  (select status::text from public.certificate_issue where id = :'tc147_id'),
  'cancelled',
  'AC2: 00147 is cancelled'
);
select is(
  (select serial_no from public.certificate_issue where id = :'tc147_id'),
  :'tc147_serial',
  'AC2: and KEEPS its serial — cancelling frees no number'
);
select is(
  (select serial_seq from public.certificate_issue where id = :'tc147_id'),
  147::bigint,
  'AC2: and keeps position 147 in the run'
);
select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_id'),
  147::bigint,
  'AC2: FR-T02''s counter is not rewound by a cancellation'
);
select is(
  (select revoke_reason from public.certificate_issue where id = :'tc147_id'),
  'wrong date of birth',
  'AC2: the reason is on the page'
);
select is(
  (select revoked_by from public.certificate_issue where id = :'tc147_id'),
  :'principal_uid'::uuid,
  'AC2: with the Principal who struck it out'
);
select ok(
  (select revoked_at is not null from public.certificate_issue where id = :'tc147_id'),
  'AC2: and when'
);
select is(
  (select status::text from public.enrolment where id = :'enrol_sara'),
  'active',
  'a cancelled TC puts the child back on the roster — it should never have taken them off'
);

select throws_ok(
  format($$ select public.revoke_certificate(%L, 'changed my mind again') $$, :'tc147_id'),
  '55000',
  'CERTIFICATE_NOT_ISSUED',
  'and an entry is struck out once; a second cancellation is refused'
);

-- The rest of the year's register, then the replacement at 00212.
reset role;
select count(*) as _tc_seed2 from (
  select public.allocate_certificate_serial(
    :'campus_a'::uuid, 'transfer'::public.certificate_type, :'session_id'::uuid)
    from generate_series(148, 211)
) s \gset
insert into public.certificate_issue
  (tenant_id, campus_id, student_id, enrolment_id, session_id, certificate_type, serial_no, serial_seq,
   template_id, template_version, language, pdf_path, payload_snapshot)
select :'tenant_id', :'campus_a', e.student_id, e.id, :'session_id', 'transfer',
       'TC-' || :y0 || '-' || lpad((e.rn + 147)::text, 6, '0'), e.rn + 147,
       :'tpl_tc', 1, 'en', 'seed/tc-' || (e.rn + 147) || '.pdf',
       jsonb_build_object('values', jsonb_build_object(
         'student.name_en', st.name_en, 'student.gr_number', st.gr_number))
  from (
    select en.id, en.student_id, row_number() over (order by en.student_id) as rn
      from public.enrolment en
      join public.academic_session s on s.id = en.session_id
     where en.tenant_id = :'tenant_id' and s.starts_on >= make_date(:y0, 1, 1)
       and en.status = 'graduated'
       and not exists (select 1 from public.certificate_issue ci where ci.enrolment_id = en.id)
  ) e
  join public.student st on st.id = e.student_id
 where e.rn <= 64;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);

select public.issue_transfer_certificate(
  :'enrol_sara'::uuid, :'leaving_date'::date, 'Reissued with the corrected date of birth', 'Excellent'
)::text as tc212_json \gset
select (:'tc212_json'::jsonb) ->> 'issue_id'  as tc212_id,
       (:'tc212_json'::jsonb) ->> 'serial_no' as tc212_serial \gset

select is(:'tc212_serial', 'TC-' || :y0 || '-000212', 'AC2: the replacement is a NEW issuance with its own number, 00212');

select public.set_certificate_replacement(:'tc147_id'::uuid, :'tc212_id'::uuid)::text as link_json \gset

select throws_ok(
  format($$ select public.set_certificate_replacement(%L, %L) $$, :'tc147_id', :'tc1_id'),
  '23505',
  'REPLACEMENT_ALREADY_SET',
  'AC2: a register cross-reference is written once and never re-pointed'
);
select throws_ok(
  format($$ select public.set_certificate_replacement(%L, %L) $$, :'tc212_id', :'tc1_id'),
  '55000',
  'CERTIFICATE_NOT_CANCELLED',
  'and only a withdrawn entry names a replacement at all'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: what the printed register actually shows
-- ═══════════════════════════════════════════════════════════════════════

select results_eq(
  format($$ select serial_no, status::text, cancelled_reason, cancelled_by_name, replaced_by_serial_no
              from public.v_certificate_register where id = %L $$, :'tc147_id'),
  format($$ select %L::text, 'cancelled'::text, 'wrong date of birth'::text, 'Nusrat Jamil'::text, %L::text $$,
         :'tc147_serial', :'tc212_serial'),
  'AC2: 00147 prints as CANCELLED with its reason, who cancelled it, and the serial that replaced it'
);
select is(
  (select replaces_serial_no from public.v_certificate_register where id = :'tc212_id'),
  :'tc147_serial',
  'AC2: and 00212 prints what it replaced — the cross-reference reads both ways'
);
select ok(
  (select cancelled_at is not null from public.v_certificate_register where id = :'tc147_id'),
  'AC2: with the date it was struck out'
);
select is(
  (select student_name from public.v_certificate_register where id = :'tc147_id'),
  'Sara Khan REG',
  'the register names the student as the DOCUMENT does, from the frozen snapshot'
);

-- "Still appears in sequence" is the whole FR: the run reads 146, 147, 148
-- with nothing renumbered and nothing missing.
select results_eq(
  format($$ select serial_seq, status::text from public.v_certificate_register
             where campus_id = %L and certificate_type = 'transfer' and serial_seq between 146 and 148
             order by serial_seq $$, :'campus_a'),
  $$ values (146::bigint, 'issued'), (147::bigint, 'cancelled'), (148::bigint, 'issued') $$,
  'AC2: the cancelled entry still appears IN SEQUENCE between its neighbours'
);
select is(
  (select count(*)::int from public.v_certificate_register
    where campus_id = :'campus_a' and certificate_type = 'transfer'),
  212,
  'and the year''s transfer register holds exactly 212 entries'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_b'), 'sub', :'principal_uid')::text,
  true
);
select is_empty(
  format($$ select 1 from public.v_certificate_register where campus_id = %L $$, :'campus_a'),
  'the register is security_invoker, so a Principal at another campus sees none of it'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: a continuous run, and what a real hole would look like
-- ═══════════════════════════════════════════════════════════════════════

select results_eq(
  format($$ select expected_count, present_count, counter_value, missing_seq
              from public.certificate_register_continuity(%L, 'transfer'::public.certificate_type, %s) $$,
         :'campus_a', :y0),
  $$ values (212::bigint, 212::bigint, 212::bigint, array[]::bigint[]) $$,
  'AC3: this year''s transfer run is 1..212 with no missing numbers, and matches what the counter says it allocated'
);
select is(
  (select first_serial from public.certificate_register_continuity(
     :'campus_a'::uuid, 'transfer'::public.certificate_type, :y0)),
  'TC-' || :y0 || '-000001',
  'AC3: reported from its first serial'
);
select is(
  (select last_serial from public.certificate_register_continuity(
     :'campus_a'::uuid, 'transfer'::public.certificate_type, :y0)),
  'TC-' || :y0 || '-000212',
  'AC3: to its last'
);
select is(
  (select unnumbered_count from public.certificate_register_continuity(
     :'campus_a'::uuid, 'character'::public.certificate_type, :y0)),
  1::bigint,
  'AC3: while the hand-written character row is reported as unnumbered rather than counted into the run'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: 4,000 entries across six earlier years, filtered and read
-- ═══════════════════════════════════════════════════════════════════════

reset role;
insert into public.certificate_issue
  (tenant_id, campus_id, student_id, enrolment_id, session_id, certificate_type, serial_no, serial_seq,
   template_id, template_version, language, pdf_path, payload_snapshot)
select :'tenant_id', :'campus_a', h.student_id, h.id, h.session_id, 'transfer',
       'TC-' || h.yr || '-' || lpad(h.rn::text, 6, '0'), h.rn,
       :'tpl_tc', 1, 'en', 'history/tc/' || h.id || '.pdf',
       jsonb_build_object('values', jsonb_build_object(
         'student.name_en', st.name_en, 'student.gr_number', st.gr_number))
  from (
    select en.id, en.student_id, en.session_id,
           extract(year from s.starts_on)::int as yr,
           row_number() over (partition by en.session_id order by en.student_id) as rn
      from public.enrolment en
      join public.academic_session s on s.id = en.session_id
     where en.tenant_id = :'tenant_id' and s.starts_on < make_date(:y0, 1, 1)
  ) h
  join public.student st on st.id = h.student_id;

insert into public.certificate_issue
  (tenant_id, campus_id, student_id, session_id, certificate_type, serial_no, serial_seq,
   template_id, template_version, language, pdf_path, payload_snapshot)
select :'tenant_id', :'campus_a', h.student_id, h.session_id, 'character',
       'CC-' || h.yr || '-' || lpad(h.rn::text, 6, '0'), h.rn,
       :'tpl_cc', 1, 'en', 'history/cc/' || h.id || '.pdf',
       jsonb_build_object('values', jsonb_build_object(
         'student.name_en', st.name_en, 'student.gr_number', st.gr_number,
         'character.conduct_grade', 'Good'))
  from (
    select en.id, en.student_id, en.session_id,
           extract(year from s.starts_on)::int as yr,
           row_number() over (partition by en.session_id order by en.student_id) as rn
      from public.enrolment en
      join public.academic_session s on s.id = en.session_id
     where en.tenant_id = :'tenant_id' and s.starts_on < make_date(:y0, 1, 1)
  ) h
  join public.student st on st.id = h.student_id;

analyze public.certificate_issue;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);

select is(
  (select count(*)::int from public.certificate_issue where tenant_id = :'tenant_id'),
  4234,
  'AC3: the register holds 4,234 entries across seven years and two certificate types'
);

select :y0 - 3 as mid_year \gset
select is(
  (select count(*)::int from public.v_certificate_register
    where certificate_type = 'transfer' and academic_year = :mid_year),
  335,
  'AC3: filtered to one certificate type and one academic year, the register returns that year''s run'
);
select results_eq(
  format($$ select expected_count, present_count, missing_seq
              from public.certificate_register_continuity(%L, 'transfer'::public.certificate_type, %s) $$,
         :'campus_a', :mid_year),
  $$ values (335::bigint, 335::bigint, array[]::bigint[]) $$,
  'AC3: and that run has no missing numbers'
);

-- The read the PDF export makes, over the whole 4,234-entry register. Not
-- AC3's 20-second budget — that is a browser rendering tens of pages and
-- cannot be measured here — but the part of it the database owns.
select performs_ok(
  format($$ select serial_seq, serial_no, status, student_name, cancelled_reason, replaced_by_serial_no
              from public.v_certificate_register
             where campus_id = %L and certificate_type = 'transfer' and academic_year = %s
             order by serial_seq $$, :'campus_a', :mid_year),
  2000,
  'AC3: reading a filtered year off a 4,234-entry register stays well inside a second'
);

-- A genuine hole, so the continuity check is known to be capable of
-- failing. Nothing above can produce one — that is the point of the FR —
-- so it is written straight into the register as a series that skips 4.
reset role;
insert into public.certificate_issue
  (tenant_id, campus_id, student_id, session_id, certificate_type, serial_no, serial_seq,
   template_id, template_version, language, pdf_path, payload_snapshot)
select :'tenant_id', :'campus_b', :'student_zain', :'session_id', 'character',
       'CCB-' || :y0 || '-' || lpad(n::text, 6, '0'), n,
       :'tpl_cc', 1, 'en', 'gap/cc-' || n || '.pdf',
       jsonb_build_object('values', jsonb_build_object(
         'student.name_en', 'Gap Student ' || n, 'character.conduct_grade', 'Good'))
  from unnest(array[1, 2, 3, 5, 6]) as n;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);

select results_eq(
  format($$ select expected_count, present_count, missing_seq
              from public.certificate_register_continuity(%L, 'character'::public.certificate_type, %s) $$,
         :'campus_b', :y0),
  $$ values (6::bigint, 5::bigint, array[4]::bigint[]) $$,
  'AC3: a register that really did lose a number names the number it lost'
);

-- The cascade case the row trigger exists for, on the one campus whose
-- deletion nothing else already blocks (campus_a holds the certificate
-- TEMPLATES, whose own guard refuses first). A campus that has issued a
-- certificate cannot be deleted out from under the register: the FK cascade
-- reaches certificate_issue and the trigger refuses, aborting the whole
-- statement rather than orphaning the entries behind a campus that is gone.
reset role;
select throws_ok(
  format($$ delete from public.campus where id = %L $$, :'campus_b'),
  '42501',
  'certificate register is append-only',
  'AC4: a campus that has issued a certificate can no longer be cascaded away'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);

-- ═══════════════════════════════════════════════════════════════════════
-- FR-T03 and FR-T05 still work, which the new triggers are most likely to
-- have broken
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);

select public.issue_transfer_certificate(
  :'enrol_zain'::uuid, :'leaving_date'::date, 'Family relocating', 'Good'
)::text as tc_void_json \gset
select (:'tc_void_json'::jsonb) ->> 'issue_id'  as tc_void_id,
       (:'tc_void_json'::jsonb) ->> 'serial_no' as tc_void_serial \gset

select public.void_certificate_issue(:'tc_void_id'::uuid, 'RENDERER_UNAVAILABLE')::text as void_json \gset
select is(
  (select status::text from public.certificate_issue where id = :'tc_void_id'),
  'void',
  'FR-T03: void_certificate_issue() still marks a failed render void, through the new trigger'
);
select is(
  (select serial_no from public.certificate_issue where id = :'tc_void_id'),
  :'tc_void_serial',
  'FR-T03: and the void row still KEEPS its serial'
);
select is(
  (select revoked_by from public.certificate_issue where id = :'tc_void_id'),
  :'clerk_uid'::uuid,
  'and now also records who voided it, so the register''s withdrawn-by column is never half blank'
);
select is(
  (select status::text from public.enrolment where id = :'enrol_zain'),
  'active',
  'FR-T03: and the enrolment revert on the void path is untouched'
);

-- Back to the Owner for the counter probe: FR-T02's serial_counter_read
-- deliberately does not let an Admissions Officer see the counters.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);
select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_id'),
  213::bigint,
  'FR-T02: and the counter is still never rewound'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);

select lives_ok(
  format($$ select public.issue_character_certificate(%L, 'Good') $$, :'student_zain'),
  'FR-T05: character certificates still issue, on their own series'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Who may read the register at all
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'teacher', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);
select is_empty(
  $$ select 1 from public.v_certificate_register $$,
  'a teacher reads no register at all'
);
select throws_ok(
  $$ select * from public.certificate_register_continuity() $$,
  '42501',
  'FORBIDDEN',
  'and cannot ask whether it is continuous either'
);

select * from finish();
rollback;
