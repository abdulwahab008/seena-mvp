-- pgTAP tests for FR-K06: concession award approval workflow.
begin;
select plan(14);

select public.provision_tenant('test-concession-award-co', 'Concession Award Co', 'owner@concessionawardco.test');
select id as tenant_id from public.tenant where slug = 'test-concession-award-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as principal_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_id', 'principal@concessionawardco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_id', :'tenant_id', 'principal', 'Principal One');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Award Student', '2015-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrolment_id \gset

select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset

select public.create_concession_scheme(
  'HARDSHIP', 'Hardship Award', 'مالی مشکلات', 'percentage', 10, array[:'tuition_id']::uuid[],
  p_max_value => 25, p_approver_role => 'principal'
) as scheme_id \gset
select public.create_concession_scheme(
  'DOC-REQ', 'Document Required Scheme', 'دستاویز درکار', 'percentage', 10, array[:'tuition_id']::uuid[],
  p_approver_role => 'principal', p_requires_document => true
) as doc_scheme_id \gset

-- ── request-time validation ──────────────────────────────────────────

select throws_ok(
  format(
    'select public.request_concession_award(%L, %L, 40, current_date, current_date + 30)',
    :'enrolment_id', :'scheme_id'
  ),
  'VALUE_EXCEEDS_MAXIMUM',
  'a request above the scheme''s max_value (25) is rejected'
);
select throws_ok(
  format(
    'select public.request_concession_award(%L, %L, 10, current_date, current_date + 30)',
    :'enrolment_id', :'doc_scheme_id'
  ),
  'DOCUMENT_REQUIRED',
  'a scheme requiring a document rejects a request with zero attachments'
);
select throws_ok(
  format(
    'select public.request_concession_award(%L, %L, 10, current_date, current_date)',
    :'enrolment_id', :'scheme_id'
  ),
  'EFFECTIVE_TO_MUST_FOLLOW_FROM',
  'effective_to must be strictly after effective_from'
);

-- ── successful request, with a document attached ────────────────────

select public.request_concession_award(
  :'enrolment_id'::uuid, :'doc_scheme_id'::uuid, 10, '2026-09-01'::date, '2027-03-31'::date, array['tenant/enrolment/hardship-letter.pdf']
) as award_id \gset
select is(
  (select status::text from public.concession_award where id = :'award_id'),
  'pending',
  'a fresh request starts pending'
);
select is(
  (select count(*)::int from public.concession_award_document where award_id = :'award_id'),
  1,
  'the attached document is recorded'
);

-- ── approval is gated by the scheme's own approver_role ──────────────
-- (owner/super_admin always bypass, so accountant is what actually
-- proves the gate — this scheme's approver_role is principal)

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.decide_concession_award(%L, true)', :'award_id'),
  'FORBIDDEN',
  'an accountant cannot approve — this scheme''s approver_role is principal'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', :'principal_id', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id')
  )::text,
  true
);
select throws_ok(
  format($$ select public.decide_concession_award(%L, false, 'too short') $$, :'award_id'),
  'REJECTION_REASON_TOO_SHORT',
  'a rejection reason under 10 characters is rejected'
);
select public.decide_concession_award(:'award_id'::uuid, true);
select is(
  (select status::text from public.concession_award where id = :'award_id'),
  'approved',
  'the matching approver_role can approve'
);
select isnt(
  (select approved_at from public.concession_award where id = :'award_id'),
  null,
  'approved_at is recorded'
);
select throws_ok(
  format('select public.decide_concession_award(%L, true)', :'award_id'),
  'AWARD_NOT_PENDING',
  'an already-decided award cannot be decided again'
);

-- ── editing an approved award forces it back to pending ─────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.edit_concession_award(:'award_id'::uuid, 15);
select is(
  (select status::text from public.concession_award where id = :'award_id'),
  'pending',
  'editing an approved award''s value resets it to pending — the trigger, not the function, does this'
);
select is(
  (select approved_by from public.concession_award where id = :'award_id'),
  null,
  'the previous approval is cleared, not just the status'
);
-- award_id's scheme (DOC-REQ) has no max_value set — only the percentage
-- ceiling of 100 applies to it.
select throws_ok(
  format('select public.edit_concession_award(%L, 140)', :'award_id'),
  'VALUE_EXCEEDS_MAXIMUM',
  'editing a percentage scheme''s award above 100 is still rejected'
);

-- ── a proper rejection records reason and decider, and is final ─────

select public.request_concession_award(:'enrolment_id'::uuid, :'scheme_id'::uuid, 10, current_date, current_date + 30) as award2_id \gset
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', :'principal_id', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id')
  )::text,
  true
);
select public.decide_concession_award(:'award2_id'::uuid, false, 'insufficient supporting evidence provided');
select is(
  (select rejection_reason from public.concession_award where id = :'award2_id'),
  'insufficient supporting evidence provided',
  'the rejection reason is displayed for a rejected award'
);

select * from finish();
rollback;
