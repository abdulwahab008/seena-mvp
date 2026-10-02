-- pgTAP tests for FR-T09: digital signature and stamp on issued PDFs.
--
-- What the database owns of this FR, and therefore what is tested here: who
-- may upload a signature and set a signing identity (AC4, at the RPC, at the
-- table and at the storage policy), the 300-DPI floor an image has to clear
-- before it can be a signature at all (AC1's source-resolution half), the
-- write-once digest and the FOURTH transition it arrives through — exercised
-- from all three callers FR-T08's threat model names, an authenticated
-- application role, service_role and the table owner itself — and the
-- superseded-identity behaviour AC3 turns on.
--
-- What is NOT here, deliberately: the composited image, the anchor
-- arithmetic and the 409. Those are Chromium's, Node's and a route
-- handler's, and they are asserted for real in
-- lib/certificates/seal.test.ts, lib/certificates/html.test.ts and
-- e2e/certificate-digital-signature.spec.ts, where the bytes actually exist.
--
-- Serials are derived from the clock's year, because FR-T02 renders {YEAR}
-- from the session's start date and provision_tenant() dates its session off
-- current_date.
begin;
select plan(57);

select extract(year from current_date)::int as y0 \gset

select public.provision_tenant('test-certsign-co', 'Cert Signing Co', 'owner@certsign.test');
select id as tenant_id from public.tenant where slug = 'test-certsign-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@certsign.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Signing Owner');

select gen_random_uuid() as principal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_uid', 'principal@certsign.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_uid', :'tenant_id', 'principal', 'Nusrat Jamil');

select gen_random_uuid() as clerk_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'clerk_uid', 'clerk@certsign.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'clerk_uid', :'tenant_id', 'admissions_officer', 'Farhat Clerk');

select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_uid', 'teacher@certsign.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_uid', :'tenant_id', 'librarian', 'Sana Librarian');

-- Claim-setting helpers, so each role switch is one line rather than five.
create or replace function pg_temp.act_as(p_role text, p_uid uuid, p_tenant uuid, p_campus uuid)
returns void language plpgsql as $$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object('tenant_id', p_tenant, 'app_role', p_role,
                      'campus_ids', json_build_array(p_campus), 'sub', p_uid)::text,
    true);
end;
$$;

set local role authenticated;
select pg_temp.act_as('owner', :'owner_uid', :'tenant_id', :'campus_a');

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_a'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_a \gset

select public.create_student(:'campus_a'::uuid, 'Ali Raza SIGN', '2011-03-04'::date, 'male') as student_ali \gset
select public.create_student(:'campus_a'::uuid, 'Sara Khan SIGN', '2013-05-09'::date, 'female') as student_sara \gset
select public.create_student(:'campus_a'::uuid, 'Zain Ahmed SIGN', '2012-08-19'::date, 'male') as student_zain \gset

select public.enrol_student(:'section_a'::uuid, :'student_ali'::uuid) as enrol_ali \gset
select public.enrol_student(:'section_a'::uuid, :'student_sara'::uuid) as enrol_sara \gset
select public.enrol_student(:'section_a'::uuid, :'student_zain'::uuid) as enrol_zain \gset

reset role;
update public.enrolment set joined_on = current_date - 200 where tenant_id = :'tenant_id';
set local role authenticated;
select pg_temp.act_as('owner', :'owner_uid', :'tenant_id', :'campus_a');

select public.create_certificate_template(
  'transfer'::public.certificate_type,
  'School Leaving Certificate',
  '<p>{{student.name_en}}, GR {{student.gr_number}}, born {{student.dob}} ({{student.dob_words}}), '
  || 'of {{enrolment.class_name}}, left on {{enrolment.left_on}}. Conduct {{transfer.conduct}}. '
  || 'Reason {{transfer.reason}}. Serial {{issue.serial_no}}, issued {{issue.date}}. '
  || 'Signed {{signatory.name}}, {{signatory.designation}}.</p>',
  null, 'en'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_a'::uuid
) as tpl_tc \gset
select public.activate_certificate_template(:'tpl_tc'::uuid) as _a \gset

select public.create_certificate_template(
  'character'::public.certificate_type,
  'Character Certificate',
  '<p>Certified that {{student.name_en}}, GR {{student.gr_number}}, attended from '
  || '{{character.period_from}} to {{character.period_to}} with conduct {{character.conduct_grade}}. '
  || 'Serial {{issue.serial_no}}, issued {{issue.date}}. Signed {{signatory.name}}.</p>',
  null, 'en'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_a'::uuid
) as tpl_cc \gset
select public.activate_certificate_template(:'tpl_cc'::uuid) as _a \gset

select (current_date - 10)::text as leaving_date \gset

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: the anchor lives on the template version, at the AC's own numbers
-- ═══════════════════════════════════════════════════════════════════════

select results_eq(
  format($$ select signature_anchor_x_mm::text, signature_anchor_y_mm::text, stamp_opacity::text
              from public.certificate_template where id = %L $$, :'tpl_tc'),
  $$ select '140.00'::text, '235.00'::text, '0.60'::text $$,
  'AC1: a template authored before this FR already anchors the signature at (140mm, 235mm) with a 60% stamp'
);

-- Moving the seal on an ACTIVATED version forks a new draft, exactly as
-- re-writing the wording does — the issued certificates that point at v1
-- keep printing where v1 said.
update public.certificate_template set signature_anchor_y_mm = 200 where id = :'tpl_tc';
select is(
  (select signature_anchor_y_mm::text from public.certificate_template where id = :'tpl_tc'),
  '235.00',
  'AC1: an activated version''s anchor cannot be edited in place'
);
select is(
  (select count(*)::int from public.certificate_template
    where tenant_id = :'tenant_id' and certificate_type = 'transfer' and status = 'draft' and signature_anchor_y_mm = 200),
  1,
  'AC1: the moved anchor lands on a new draft version instead'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: who may upload a signature at all
-- ═══════════════════════════════════════════════════════════════════════

select pg_temp.act_as('principal', :'principal_uid', :'tenant_id', :'campus_a');

select throws_ok(
  format($$ select public.create_branding_asset('signature'::public.branding_asset_type, 900, 300, 20000,
                     'image/png', 'png', %L) $$, :'campus_a'),
  '42501',
  'FORBIDDEN',
  'AC4: a Principal cannot reserve a signature asset'
);
select throws_ok(
  format($$ select public.create_branding_asset('stamp'::public.branding_asset_type, 800, 800, 20000,
                     'image/png', 'png', %L) $$, :'campus_a'),
  '42501',
  'FORBIDDEN',
  'AC4: nor a school stamp'
);
select lives_ok(
  format($$ select public.create_branding_asset('logo'::public.branding_asset_type, 800, 600, 20000,
                     'image/png', 'png', %L) $$, :'campus_a'),
  'AC4 is narrow: a Principal still runs their campus''s logo, as FR-A18 always allowed'
);

select pg_temp.act_as('admissions_officer', :'clerk_uid', :'tenant_id', :'campus_a');
select throws_ok(
  format($$ select public.create_branding_asset('signature'::public.branding_asset_type, 900, 300, 20000,
                     'image/png', 'png', %L) $$, :'campus_a'),
  '42501',
  'FORBIDDEN',
  'AC4: an Admissions Officer who issues certificates still cannot supply the signature on them'
);

-- The storage policy itself, which is what AC4 names. RESTRICTIVE, so it
-- ANDs with FR-A18's branding_insert_owner.
select ok(
  (select permissive = 'RESTRICTIVE' and cmd = 'INSERT'
     from pg_policies where schemaname = 'storage' and tablename = 'objects'
      and policyname = 'branding_signature_owner_only'),
  'AC4: the storage policy that narrows signature uploads is restrictive, so it cannot be widened by another policy'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The signing identity, and AC1's 300-DPI floor
-- ═══════════════════════════════════════════════════════════════════════

select pg_temp.act_as('owner', :'owner_uid', :'tenant_id', :'campus_a');

select public.create_branding_asset('signature'::public.branding_asset_type, 900, 300, 20000, 'image/png', 'png', :'campus_a'::uuid) as sig1 \gset
select (:'sig1'::jsonb ->> 'asset_id') as sig1_id \gset
select public.confirm_branding_asset(:'sig1_id'::uuid);

select public.create_branding_asset('stamp'::public.branding_asset_type, 800, 800, 20000, 'image/png', 'png', :'campus_a'::uuid) as stamp1 \gset
select (:'stamp1'::jsonb ->> 'asset_id') as stamp1_id \gset
select public.confirm_branding_asset(:'stamp1_id'::uuid);

-- Clears FR-A18's 200px floor for a signature and fails FR-T09's 532px one:
-- the two floors answer different questions, and this FR's is about print.
select public.create_branding_asset('signature'::public.branding_asset_type, 300, 100, 9000, 'image/png', 'png', :'campus_a'::uuid) as sig_small \gset
select (:'sig_small'::jsonb ->> 'asset_id') as sig_small_id \gset

select public.create_branding_asset('stamp'::public.branding_asset_type, 400, 400, 9000, 'image/png', 'png', :'campus_a'::uuid) as stamp_small \gset
select (:'stamp_small'::jsonb ->> 'asset_id') as stamp_small_id \gset

select throws_ok(
  format($$ select public.create_signing_identity(%L, 'Farhat Jabeen', 'Principal', %L) $$, :'campus_a', :'sig_small_id'),
  '23514',
  'SIGNATURE_RESOLUTION_TOO_LOW',
  'AC1: a 300px signature cannot print a 45mm box at 300 DPI, and is refused rather than upscaled'
);
select throws_ok(
  format($$ select public.create_signing_identity(%L, 'Farhat Jabeen', 'Principal', %L, %L) $$,
         :'campus_a', :'sig1_id', :'stamp_small_id'),
  '23514',
  'STAMP_RESOLUTION_TOO_LOW',
  'AC1: and the stamp is measured against its own 35mm box'
);
select throws_ok(
  format($$ select public.create_signing_identity(%L, '   ', 'Principal', %L) $$, :'campus_a', :'sig1_id'),
  '23514',
  'SIGNATORY_INCOMPLETE',
  'a signing identity without a name has nothing to print under the signature'
);

select pg_temp.act_as('principal', :'principal_uid', :'tenant_id', :'campus_a');
select throws_ok(
  format($$ select public.create_signing_identity(%L, 'Nusrat Jamil', 'Principal', %L) $$, :'campus_a', :'sig1_id'),
  '42501',
  'FORBIDDEN',
  'AC4: a Principal cannot decide whose signature goes on a statutory document — not even their own'
);

select pg_temp.act_as('owner', :'owner_uid', :'tenant_id', :'campus_a');
select public.create_signing_identity(:'campus_a'::uuid, 'Farhat Jabeen', 'Principal', :'sig1_id'::uuid, :'stamp1_id'::uuid) as ident1 \gset
select (:'ident1'::jsonb ->> 'signing_identity_id') as ident1_id \gset

select is(
  (public.resolve_signing_identity(:'campus_a'::uuid)) ->> 'holder_name',
  'Farhat Jabeen',
  'the campus now resolves to a signing identity'
);
select is(
  ((public.resolve_signing_identity(:'campus_a'::uuid)) ->> 'signature_width_px')::int,
  900,
  'and it carries the pixel dimensions the render checks the anchor box against'
);

-- ── RLS ───────────────────────────────────────────────────────────────

select pg_temp.act_as('principal', :'principal_uid', :'tenant_id', :'campus_a');
select is(
  (select count(*)::int from public.signing_identity),
  1,
  'signing_identity_read_campus: a Principal sees who signs at their campus'
);
select throws_ok(
  format($$ insert into public.signing_identity (tenant_id, campus_id, holder_name, designation, signature_asset_id)
            values (%L, %L, 'Nusrat Jamil', 'Principal', %L) $$, :'tenant_id', :'campus_a', :'sig1_id'),
  '42501',
  null,
  'signing_identity_write_owner: and cannot write one directly either'
);

select pg_temp.act_as('librarian', :'teacher_uid', :'tenant_id', :'campus_a');
select is(
  (select count(*)::int from public.signing_identity),
  0,
  'a role with no certificate authority sees no signing identity at all'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Issuance stamps WHO signed, and freezes the seal into the snapshot
-- ═══════════════════════════════════════════════════════════════════════

select pg_temp.act_as('admissions_officer', :'clerk_uid', :'tenant_id', :'campus_a');

select public.issue_transfer_certificate(
  :'enrol_ali'::uuid, :'leaving_date'::date, 'Family relocation', 'Good', null, 'en'::public.certificate_language
) as tc_ali \gset
select (:'tc_ali'::jsonb ->> 'issue_id') as tc_ali_id \gset
select (:'tc_ali'::jsonb ->> 'serial_no') as tc_ali_serial \gset

select is(
  (select signing_identity_id from public.certificate_issue where id = :'tc_ali_id'),
  :'ident1_id'::uuid,
  'AC3: the register records WHO signed the certificate, not just that somebody did'
);
select is(
  (select payload_snapshot -> 'values' ->> 'signatory.name' from public.certificate_issue where id = :'tc_ali_id'),
  'Farhat Jabeen',
  'the document is signed in the signing identity''s name, not the clerk''s who issued it'
);
select is(
  (select payload_snapshot -> 'values' ->> 'signatory.designation' from public.certificate_issue where id = :'tc_ali_id'),
  'Principal',
  'and carries its designation'
);
select is(
  (select (payload_snapshot -> 'seal' ->> 'signature_anchor_y_mm')::numeric from public.certificate_issue where id = :'tc_ali_id'),
  235::numeric,
  'AC1: the anchor the document was printed at is frozen onto the row, not re-read from the template later'
);
select is(
  (select (payload_snapshot -> 'seal' ->> 'stamp_opacity')::numeric from public.certificate_issue where id = :'tc_ali_id'),
  0.6::numeric,
  'AC1: as is the stamp opacity'
);
select is(
  (select payload_snapshot -> 'seal' ->> 'signature_storage_path' from public.certificate_issue where id = :'tc_ali_id'),
  (select storage_path from public.branding_asset where id = :'sig1_id'::uuid),
  'and the exact image the render composited'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The digest: write-once, through the fourth transition and nothing else
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select pdf_sha256 from public.certificate_issue where id = :'tc_ali_id'),
  null,
  'the register row starts unsealed — the bytes do not exist until the render has run'
);

select throws_ok(
  format($$ select public.attach_certificate_pdf_digest(%L, 'not-a-digest') $$, :'tc_ali_id'),
  '22023',
  'DIGEST_MALFORMED',
  'a digest that is not 64 hex characters is refused before it reaches the column'
);

select public.attach_certificate_pdf_digest(
  :'tc_ali_id'::uuid, repeat('a', 64)
) as sealed \gset

select is(
  (select pdf_sha256 from public.certificate_issue where id = :'tc_ali_id'),
  repeat('a', 64),
  'the digest of the stored bytes is sealed onto the register row'
);

select throws_ok(
  format($$ select public.attach_certificate_pdf_digest(%L, %L) $$, :'tc_ali_id', repeat('b', 64)),
  '23505',
  'CERTIFICATE_ALREADY_SEALED',
  'write-once: a hash that can be re-written is not a tamper check but a second place to forge'
);

-- The same three callers FR-T08's threat model names, each writing the
-- UPDATE by hand rather than through the sanctioned frame.
select throws_ok(
  format($$ update public.certificate_issue set pdf_sha256 = %L where id = %L $$, repeat('c', 64), :'tc_ali_id'),
  '42501',
  'certificate register is append-only',
  'AC2: an authenticated role cannot re-point the digest at forged bytes'
);
select throws_ok(
  format($$ update public.certificate_issue set pdf_sha256 = null where id = %L $$, :'tc_ali_id'),
  '42501',
  'certificate register is append-only',
  'AC2: nor clear it so the download check has nothing to compare against'
);
select throws_ok(
  format($$ update public.certificate_issue set signing_identity_id = null where id = %L $$, :'tc_ali_id'),
  '42501',
  'certificate register is append-only',
  'AC3: nor disown who signed it — signing_identity_id is the nineteenth frozen column'
);

reset role;
set local role service_role;
select throws_ok(
  format($$ update public.certificate_issue set pdf_sha256 = %L where id = %L $$, repeat('d', 64), :'tc_ali_id'),
  '42501',
  'certificate register is append-only',
  'AC2: a leaked service_role key cannot rewrite the digest either — RLS is not what refuses'
);

reset role;
select throws_ok(
  format($$ update public.certificate_issue set pdf_sha256 = %L where id = %L $$, repeat('e', 64), :'tc_ali_id'),
  '42501',
  'certificate register is append-only',
  'AC2: and neither can the table owner, hand-writing the UPDATE — the sanctioned frame has to be on the stack'
);

set local role authenticated;
select pg_temp.act_as('admissions_officer', :'clerk_uid', :'tenant_id', :'campus_a');
select is(
  (select pdf_sha256 from public.certificate_issue where id = :'tc_ali_id'),
  repeat('a', 64),
  'after five attempts from three callers the sealed digest is untouched'
);

-- ═══════════════════════════════════════════════════════════════════════
-- FR-T08's own transitions still work, and none of them disturbs the digest
-- ═══════════════════════════════════════════════════════════════════════

select public.issue_transfer_certificate(
  :'enrol_sara'::uuid, :'leaving_date'::date, 'Relocation', 'Good', null, 'en'::public.certificate_language
) as tc_sara \gset
select (:'tc_sara'::jsonb ->> 'issue_id') as tc_sara_id \gset
select public.attach_certificate_pdf_digest(:'tc_sara_id'::uuid, repeat('1', 64)) as _s \gset

select public.void_certificate_issue(:'tc_sara_id'::uuid, 'RENDER_FAILED') as _v \gset
select is(
  (select status::text from public.certificate_issue where id = :'tc_sara_id'),
  'void',
  'FR-T03''s void still works on a sealed row'
);
select is(
  (select pdf_sha256 from public.certificate_issue where id = :'tc_sara_id'),
  repeat('1', 64),
  'and takes the digest with it unchanged — a withdrawn document still hashes to what it hashed to'
);

select pg_temp.act_as('owner', :'owner_uid', :'tenant_id', :'campus_a');
select public.revoke_certificate(:'tc_ali_id'::uuid, 'Wrong date of birth') as _r \gset
select is(
  (select status::text from public.certificate_issue where id = :'tc_ali_id'),
  'cancelled',
  'FR-T08''s strike-through still works on a sealed row'
);
select is(
  (select pdf_sha256 from public.certificate_issue where id = :'tc_ali_id'),
  repeat('a', 64),
  'and the cancelled entry keeps the digest of the document that was handed over'
);

-- The replacement, and FR-T08's cross-reference transition, both still
-- reachable: cancelling reverted the enrolment, so a corrected TC can be
-- issued and linked.
select public.issue_transfer_certificate(
  :'enrol_ali'::uuid, :'leaving_date'::date, 'Family relocation', 'Good', null, 'en'::public.certificate_language
) as tc_ali2 \gset
select (:'tc_ali2'::jsonb ->> 'issue_id') as tc_ali2_id \gset
select public.attach_certificate_pdf_digest(:'tc_ali2_id'::uuid, repeat('2', 64)) as _s2 \gset
select public.set_certificate_replacement(:'tc_ali_id'::uuid, :'tc_ali2_id'::uuid) as _l \gset

select is(
  (select replaced_by_issue_id from public.certificate_issue where id = :'tc_ali_id'),
  :'tc_ali2_id'::uuid,
  'FR-T08''s cross-reference still works on sealed rows'
);
select is(
  (select pdf_sha256 from public.certificate_issue where id = :'tc_ali_id'),
  repeat('a', 64),
  'and does not disturb either digest'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the Principal is replaced
-- ═══════════════════════════════════════════════════════════════════════

select public.create_branding_asset('signature'::public.branding_asset_type, 1200, 400, 30000, 'image/png', 'png', :'campus_a'::uuid) as sig2 \gset
select (:'sig2'::jsonb ->> 'asset_id') as sig2_id \gset
select public.confirm_branding_asset(:'sig2_id'::uuid);

select public.create_signing_identity(:'campus_a'::uuid, 'Nusrat Jamil', 'Principal', :'sig2_id'::uuid, :'stamp1_id'::uuid) as ident2 \gset
select (:'ident2'::jsonb ->> 'signing_identity_id') as ident2_id \gset

select isnt(
  (select valid_to from public.signing_identity where id = :'ident1_id'::uuid),
  null,
  'AC3: the outgoing holder''s identity is CLOSED rather than deleted'
);
select is(
  (public.resolve_signing_identity(:'campus_a'::uuid)) ->> 'holder_name',
  'Nusrat Jamil',
  'AC3: and only new issues resolve to the new signature'
);
select is(
  (select signing_identity_id from public.certificate_issue where id = :'tc_ali2_id'),
  :'ident1_id'::uuid,
  'AC3: a certificate issued BEFORE the handover still points at the identity that signed it'
);
select is(
  (select payload_snapshot -> 'seal' ->> 'signature_storage_path' from public.certificate_issue where id = :'tc_ali2_id'),
  (select storage_path from public.branding_asset where id = :'sig1_id'::uuid),
  'AC3: and its frozen snapshot still names the PRIOR signature image, which is still on disk'
);

select public.issue_character_certificate(
  :'student_zain'::uuid, 'Excellent', null, null, null, null, 'en'::public.certificate_language
) as cc_zain \gset
select (:'cc_zain'::jsonb ->> 'issue_id') as cc_zain_id \gset
select is(
  (select signing_identity_id from public.certificate_issue where id = :'cc_zain_id'),
  :'ident2_id'::uuid,
  'AC3: the next certificate issued is signed by the new holder'
);
select is(
  (select payload_snapshot -> 'values' ->> 'signatory.name' from public.certificate_issue where id = :'cc_zain_id'),
  'Nusrat Jamil',
  'FR-T05''s character certificates go through exactly the same seal'
);

select throws_ok(
  format($$ delete from public.signing_identity where id = %L $$, :'ident1_id'),
  '23503',
  null,
  'AC3: a signing identity a certificate points at cannot be deleted out from under it'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: the alert a failed digest check leaves behind
-- ═══════════════════════════════════════════════════════════════════════

select public.log_certificate_digest_mismatch(:'cc_zain_id'::uuid, repeat('f', 64), 12345) as alert \gset
select (:'alert'::jsonb ->> 'security_event_id') as alert_id \gset

select is(
  (select event_type from public.security_event where id = :'alert_id'::uuid),
  'certificate_digest_mismatch',
  'AC2: a download whose bytes did not match writes an alert row'
);
select is(
  (select detail ->> 'observed_sha256' from public.security_event where id = :'alert_id'::uuid),
  repeat('f', 64),
  'AC2: naming what was found'
);
select is(
  (select subject_id from public.security_event where id = :'alert_id'::uuid),
  :'cc_zain_id'::uuid,
  'AC2: against the certificate it concerns'
);
select is(
  (select count(*)::int from public.audit_log
    where tenant_id = :'tenant_id' and table_name = 'security_event' and action = 'insert'),
  1,
  'AC2: and the alert is itself chained into FR-T14''s audit log, so a planted one is visible'
);

select throws_ok(
  format($$ insert into public.security_event (tenant_id, event_type, detail)
            values (%L, 'certificate_digest_mismatch', '{}'::jsonb) $$, :'tenant_id'),
  '42501',
  null,
  'AC2: nobody writes a security event directly — there is no INSERT policy, only the definer function'
);

select pg_temp.act_as('librarian', :'teacher_uid', :'tenant_id', :'campus_a');
select is(
  (select count(*)::int from public.security_event),
  0,
  'a teacher cannot read the school''s security events'
);

select pg_temp.act_as('owner', :'owner_uid', :'tenant_id', :'campus_a');
select is(
  (select count(*)::int from public.security_event),
  1,
  'the Owner can'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Tenant isolation
-- ═══════════════════════════════════════════════════════════════════════

reset role;
select public.provision_tenant('test-certsign-other', 'Other Signing Co', 'owner@certsignother.test');
select id as other_tenant_id from public.tenant where slug = 'test-certsign-other' \gset
select gen_random_uuid() as other_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_uid', 'owner2@certsignother.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_uid', :'other_tenant_id', 'owner', 'Other Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json, 'sub', :'other_uid')::text,
  true
);

select is(
  (select count(*)::int from public.signing_identity),
  0,
  'another tenant sees no signing identity of this one'
);
select is(
  (select count(*)::int from public.security_event),
  0,
  'nor its security events'
);
select is(
  public.resolve_signing_identity(:'campus_a'::uuid),
  null,
  'nor can it resolve one for a campus that is not its own'
);
select throws_ok(
  format($$ select public.attach_certificate_pdf_digest(%L, %L) $$, :'cc_zain_id', repeat('9', 64)),
  'P0002',
  'CERTIFICATE_ISSUE_NOT_FOUND',
  'nor seal a digest onto another tenant''s certificate'
);

select * from finish();
rollback;
