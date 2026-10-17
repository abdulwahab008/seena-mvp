-- pgTAP tests: who may read or write student portal accounts, and who may mint them.
--
-- A student's portal account holds their first password. Before this change every parent,
-- every student and every staff role of a campus could read all of its accounts (initial
-- passwords in clear text included) and update any row, and provision_student_accounts()
-- could be called by anyone holding the public key, for every school at once.
begin;
select plan(27);

select public.provision_tenant('test-spa-a', 'Portal Account School A', 'owner@spa-a.test');
select public.provision_tenant('test-spa-b', 'Portal Account School B', 'owner@spa-b.test');
select id as tenant_a from public.tenant where slug = 'test-spa-a' \gset
select id as tenant_b from public.tenant where slug = 'test-spa-b' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_a' \gset
select id as campus_b from public.campus where tenant_id = :'tenant_b' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_a' \gset
select id as session_b from public.academic_session where tenant_id = :'tenant_b' \gset
select id as c6_a from public.class_level where tenant_id = :'tenant_a' and code = '6' \gset
select id as c6_b from public.class_level where tenant_id = :'tenant_b' and code = '6' \gset

reset role;
select gen_random_uuid() as owner_a \gset
select gen_random_uuid() as principal_a \gset
select gen_random_uuid() as nurse_a \gset
select gen_random_uuid() as owner_b \gset
select gen_random_uuid() as guardian_user \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role) values
  (:'owner_a',      'owner@spa-a.test',     'x', now(), 'authenticated', 'authenticated'),
  (:'principal_a',  'principal@spa-a.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'nurse_a',      'nurse@spa-a.test',     'x', now(), 'authenticated', 'authenticated'),
  (:'owner_b',      'owner@spa-b.test',     'x', now(), 'authenticated', 'authenticated'),
  (:'guardian_user','parent@spa-a.test',    'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_a'::uuid,     :'tenant_a'::uuid, 'owner',     'Owner A'),
  (:'principal_a'::uuid, :'tenant_a'::uuid, 'principal', 'Principal A'),
  (:'nurse_a'::uuid,     :'tenant_a'::uuid, 'nurse',     'Nurse A'),
  (:'owner_b'::uuid,     :'tenant_b'::uuid, 'owner',     'Owner B');

-- A class 6 section and two students in each school.
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_a', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_a')::text, true);
set local role authenticated;
select public.create_section(:'campus_a'::uuid, :'session_a'::uuid, :'c6_a'::uuid, 'A', 40) as sec_a \gset
select public.create_student(:'campus_a'::uuid, 'Alpha One', '2014-01-01'::date, 'male') as st_a1 \gset
select public.enrol_student(:'sec_a'::uuid, :'st_a1'::uuid) as en_a1 \gset
select public.create_student(:'campus_a'::uuid, 'Alpha Two', '2014-02-01'::date, 'female') as st_a2 \gset
select public.enrol_student(:'sec_a'::uuid, :'st_a2'::uuid) as en_a2 \gset
reset role;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_b', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_b'), 'sub', :'owner_b')::text, true);
set local role authenticated;
select public.create_section(:'campus_b'::uuid, :'session_b'::uuid, :'c6_b'::uuid, 'A', 40) as sec_b \gset
select public.create_student(:'campus_b'::uuid, 'Beta One', '2014-03-01'::date, 'male') as st_b1 \gset
select public.enrol_student(:'sec_b'::uuid, :'st_b1'::uuid) as en_b1 \gset
reset role;

-- A guardian of Alpha One, built the way activation builds one: an auth user, no app_user row.
insert into public.guardian (tenant_id, name_en, phone_e164, auth_user_id)
values (:'tenant_a'::uuid, 'Alpha Parent', '+923001110201', :'guardian_user'::uuid) returning id as g_a \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_a'::uuid, :'st_a1'::uuid, :'g_a'::uuid, 'father', true, true);

-- ── Who may call the provisioning function ───────────────────────────────────

select ok(
  not has_function_privilege('anon', 'public.provision_student_accounts(uuid)', 'execute'),
  'anon cannot execute provision_student_accounts'
);

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_a', 'app_role', 'nurse',
  'campus_ids', json_build_array(:'campus_a'), 'sub', :'nurse_a')::text, true);
set local role authenticated;
select throws_like(
  $$select * from public.provision_student_accounts()$$,
  '%FORBIDDEN%',
  'a nurse cannot provision student accounts'
);
reset role;

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_a', 'app_role', 'parent',
  'campus_ids', json_build_array(:'campus_a'), 'sub', :'guardian_user')::text, true);
set local role authenticated;
select throws_like(
  $$select * from public.provision_student_accounts()$$,
  '%FORBIDDEN%',
  'a guardian cannot provision student accounts'
);
reset role;

-- A principal runs it for their own school only, even when asking for every campus.
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_a', 'app_role', 'principal',
  'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_a')::text, true);
set local role authenticated;
select is(
  (select count(*)::int from public.provision_student_accounts()),
  2,
  'a principal provisions the two class 6 students of their own school'
);
reset role;
select is(
  (select count(*)::int from public.student_portal_account where tenant_id = :'tenant_b'::uuid),
  0,
  'the other school was not touched by that call'
);

-- The platform (a database session with no school in its token) provisions every school.
select set_config('request.jwt.claims', '{}', true);
select is(
  (select count(*)::int from public.provision_student_accounts()),
  1,
  'the platform can provision the remaining school in one call'
);
select is(
  (select count(*)::int from public.student_portal_account where tenant_id = :'tenant_b'::uuid),
  1,
  'and that school now has its account'
);

-- ── First passwords are random and can be told apart from the old pattern ────

select is(
  (select count(*)::int from public.student_portal_account where initial_password like 'Seena@%'),
  0,
  'no first password follows the old Seena@ + GR digits pattern'
);
select ok(
  (select bool_and(length(initial_password) = 10) from public.student_portal_account where tenant_id = :'tenant_a'::uuid),
  'first passwords are ten characters'
);
select is(
  (select count(distinct initial_password)::int from public.student_portal_account),
  3,
  'every account has its own first password'
);

-- ── Reading accounts ─────────────────────────────────────────────────────────

select user_id as stu_user_a1 from public.student_portal_account where student_id = :'st_a1'::uuid \gset

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_a', 'app_role', 'parent',
  'campus_ids', json_build_array(:'campus_a'), 'sub', :'guardian_user')::text, true);
set local role authenticated;
select is((select count(*)::int from public.student_portal_account), 0, 'a guardian sees no portal accounts');
reset role;

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_a', 'app_role', 'nurse',
  'campus_ids', json_build_array(:'campus_a'), 'sub', :'nurse_a')::text, true);
set local role authenticated;
select is((select count(*)::int from public.student_portal_account), 0, 'a nurse sees no portal accounts');
reset role;

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_a', 'app_role', 'student',
  'campus_ids', json_build_array(:'campus_a'), 'sub', :'stu_user_a1')::text, true);
set local role authenticated;
select is((select count(*)::int from public.student_portal_account), 1, 'a student sees only their own account');
reset role;

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_a', 'app_role', 'principal',
  'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_a')::text, true);
set local role authenticated;
select is((select count(*)::int from public.student_portal_account), 2, 'a principal sees their own school''s accounts and no one else''s');
select throws_ok(
  $$select initial_password from public.student_portal_account$$,
  '42501',
  null,
  'not even a principal can read the stored first password'
);
reset role;

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_a', 'app_role', 'student',
  'campus_ids', json_build_array(:'campus_a'), 'sub', :'stu_user_a1')::text, true);
set local role authenticated;
select throws_ok(
  $$select initial_password from public.student_portal_account$$,
  '42501',
  null,
  'a student cannot read their own stored first password either'
);

-- ── Writing accounts ─────────────────────────────────────────────────────────

select throws_ok(
  $$update public.student_portal_account set must_change_password = false$$,
  '42501',
  null,
  'a student cannot switch off their own forced password change'
);
select throws_ok(
  $$update public.student_portal_account set student_id = student_id$$,
  '42501',
  null,
  'a student cannot rewrite their account row'
);
reset role;

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_a', 'app_role', 'principal',
  'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_a')::text, true);
set local role authenticated;
select throws_ok(
  $$update public.student_portal_account set status = 'disabled'$$,
  '42501',
  null,
  'staff cannot write the table directly, even a principal'
);
select throws_ok(
  $$delete from public.student_portal_account$$,
  '42501',
  null,
  'nor delete from it'
);
reset role;

-- ── The first password stops existing once it has been replaced ──────────────

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_a', 'app_role', 'student',
  'campus_ids', json_build_array(:'campus_a'), 'sub', :'stu_user_a1')::text, true);
set local role authenticated;
select lives_ok(
  $$select public.change_student_password('a-new-password-1')$$,
  'a student can set their own password'
);
reset role;
select is(
  (select initial_password from public.student_portal_account where student_id = :'st_a1'::uuid),
  null::text,
  'the stored first password is cleared once the student has replaced it'
);
select is(
  (select must_change_password from public.student_portal_account where student_id = :'st_a1'::uuid),
  false,
  'and the forced change is recorded as done'
);

-- ── Backend-only functions are not open to everyone ─────────────────────────

select ok(
  not has_function_privilege('anon', 'public.resolve_student_login(text, uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.resolve_student_login(text, uuid)', 'execute')
    and has_function_privilege('service_role', 'public.resolve_student_login(text, uuid)', 'execute'),
  'resolve_student_login (student name and auth email for any GR number) is service role only'
);
select ok(
  not has_function_privilege('anon', 'public.deprovision_on_tc()', 'execute')
    and not has_function_privilege('authenticated', 'public.deprovision_on_tc()', 'execute')
    and has_function_privilege('service_role', 'public.deprovision_on_tc()', 'execute'),
  'deprovision_on_tc (a school-wide UPDATE) is service role only'
);
select ok(
  not has_function_privilege('authenticated', 'app.fn_generate_initial_password()', 'execute'),
  'the password generator is internal'
);
select ok(
  has_function_privilege('service_role', 'public.provision_student_accounts(uuid)', 'execute'),
  'the backend can still run provisioning with the service role'
);

select * from finish();
rollback;
