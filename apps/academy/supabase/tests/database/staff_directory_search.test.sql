-- pgTAP tests for FR-D19 (searchable staff directory).
begin;
select plan(14);

select public.provision_tenant('test-dir-co', 'Directory Co', 'owner@dirco.test');
select id as tenant_id from public.tenant where slug = 'test-dir-co' \gset
select id as khi_id from public.campus where tenant_id = :'tenant_id' \gset

-- All synthetic auth.users/app_user rows are created up front, while still
-- under the unrestricted test-runner role — auth.users is not writable
-- once the session switches to `authenticated` below.
select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@dirco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'subject_teacher', 'Searching Teacher');

select gen_random_uuid() as hr_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'hr_user_id', 'hr@dirco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'hr_user_id', :'tenant_id', 'hr_manager', 'HR Manager');

select gen_random_uuid() as principal_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_user_id', 'principal@dirco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_user_id', :'tenant_id', 'principal', 'Karachi Principal');

select gen_random_uuid() as other_teacher_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_teacher_id', 'other@dirco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_teacher_id', :'tenant_id', 'subject_teacher', 'Other Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'khi_id'))::text,
  true
);
select public.create_campus('LHR', 'Lahore Campus') as lhr_id \gset

select public.create_staff(:'khi_id'::uuid, 'Ahmed Raza', 'male', p_cnic => '42101-1234567-1') as ahmed_id \gset
select public.create_staff(:'khi_id'::uuid, 'Bilal Khan', 'male', p_cnic => '42101-1234567-2') as bilal_id \gset
select public.create_staff(:'lhr_id'::uuid, 'Sara Ahmed', 'female', p_cnic => '42101-1234567-3') as sara_id \gset
select employee_code from public.staff where id = :'sara_id'::uuid \gset
select public.link_staff_user_account(:'ahmed_id'::uuid, :'teacher_user_id'::uuid);

-- employment_status has no direct-UPDATE RLS policy (function-gated writes
-- only) and staff_private_contact has no INSERT policy at all — both need
-- the unrestricted role, same bracketing this suite uses everywhere else.
reset role;
update public.staff set employment_status = 'exited' where id = :'bilal_id'::uuid;
insert into public.staff_private_contact (staff_id, mobile, address)
values (:'ahmed_id'::uuid, '+923001234567', '123 Model Town');
set local role authenticated;

-- ── AC1: a non-privileged teacher's search of 'Ahmed' finds the Karachi
--    colleague, but no CNIC/mobile leak into the result ──────────────
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'khi_id'), 'sub', :'teacher_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.search_staff('Ahmed')),
  1,
  'AC1: a teacher searching "Ahmed" finds exactly the one Karachi-campus match (the Lahore "Sara Ahmed" is out of scope)'
);
select ok(
  (select mobile is null from public.search_staff('Ahmed') limit 1),
  'AC1: mobile is withheld from a non-privileged searcher'
);
select ok(
  (select identity_document_number is null from public.search_staff('Ahmed') limit 1),
  'AC1: identity document number is withheld from a non-privileged searcher'
);

-- Fuzzy variant spelling still resolves via trigram word-similarity.
select is(
  (select full_name from public.search_staff('Ahmad') limit 1),
  'Ahmed Raza',
  'AC: a near-miss spelling ("Ahmad") still finds "Ahmed Raza" via trigram matching'
);

-- ── AC2: the identical search by an HR Manager includes mobile + id doc ─
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'khi_id'), 'sub', :'hr_user_id')::text,
  true
);
select is(
  (select mobile from public.search_staff('Ahmed') limit 1),
  '+923001234567',
  'AC2: an HR Manager''s identical search includes the mobile number'
);
select is(
  (select identity_document_number from public.search_staff('Ahmed') limit 1),
  '42101-1234567-1',
  'AC2: an HR Manager''s identical search includes the identity document number'
);

-- ── AC3: an exact employee_code belonging to another campus returns
--    zero rows for a principal scoped only to Karachi ─────────────────
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'khi_id'), 'sub', :'principal_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.search_staff(:'employee_code')),
  0,
  'AC3: a Karachi-scoped principal searching a Lahore employee_code gets zero rows'
);
-- Sanity: the owner (whole-tenant scope) finds that same code fine.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'khi_id'))::text,
  true
);
select is(
  (select full_name from public.search_staff(:'employee_code') limit 1),
  'Sara Ahmed',
  'a tenant-wide owner search on the exact employee_code finds the Lahore staff member'
);

-- ── AC4: an exited staff member is hidden by default, shown (and
--    flagged) only with p_include_former ─────────────────────────────
select is(
  (select count(*)::int from public.search_staff('Bilal')),
  0,
  'AC4: an exited staff member is absent from the default search'
);
select is(
  (select count(*)::int from public.search_staff('Bilal', true)),
  1,
  'AC4: the exited staff member appears once "include former staff" is set'
);
select ok(
  (select is_former from public.search_staff('Bilal', true) limit 1),
  'AC4: the returned row is marked is_former = true'
);

-- ── An unauthenticated/roleless caller is refused outright ─────────────
select set_config('request.jwt.claims', '{}', true);
select throws_ok(
  $$ select * from public.search_staff('Ahmed') $$,
  'FORBIDDEN',
  'a caller with no app_role at all is refused'
);

-- ── staff_private_contact's own RLS: a defense-in-depth boundary
--    independent of search_staff() itself ────────────────────────────
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'khi_id'), 'sub', :'teacher_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.staff_private_contact where staff_id = :'ahmed_id'::uuid),
  1,
  'staff_contact_self_read: Ahmed himself can read his own private contact row directly'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'khi_id'), 'sub', :'other_teacher_id')::text,
  true
);
select is(
  (select count(*)::int from public.staff_private_contact where staff_id = :'ahmed_id'::uuid),
  0,
  'a different, non-privileged teacher cannot read Ahmed''s private contact row directly'
);

select * from finish();
rollback;
