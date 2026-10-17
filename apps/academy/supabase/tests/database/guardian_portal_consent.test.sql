-- pgTAP tests: a guardian can record and withdraw consent from the portal.
--
-- The older consent_capture test gives its portal parent an app_user row, which
-- the product never does: a guardian is linked through guardian.auth_user_id and
-- has no app_user row at all (see custom_access_token_hook). With that row in
-- place the foreign key on consent_record.recorded_by is satisfied, so the test
-- passed while every real guardian's submission failed with 23503.
--
-- Here the guardians are built the way activate_guardian_account builds them:
-- an auth user, a guardian row pointing at it, and nothing in app_user.
begin;
select plan(11);

select public.provision_tenant('test-guardian-consent', 'Guardian Consent Co', 'owner@guardianconsent.test');
select id as tenant_id from public.tenant where slug = 'test-guardian-consent' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

reset role;
select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner-user@guardianconsent.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id'::uuid, 'owner', 'Owner User');

select gen_random_uuid() as clerk_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'clerk_user_id', 'clerk-user@guardianconsent.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'clerk_user_id', :'tenant_id'::uuid, 'receptionist', 'Front Desk');

-- Two families. Neither guardian gets an app_user row.
select gen_random_uuid() as parent_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'parent_user_id', 'parent-user@guardianconsent.test', 'x', now(), 'authenticated', 'authenticated');
select gen_random_uuid() as other_parent_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_parent_user_id', 'other-parent@guardianconsent.test', 'x', now(), 'authenticated', 'authenticated');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_a \gset
select public.create_student(:'campus_id'::uuid, 'Portal Kid', '2015-01-01'::date, 'male') as s_mine \gset
select public.enrol_student(:'section_a'::uuid, :'s_mine'::uuid) as e_mine \gset
select public.create_student(:'campus_id'::uuid, 'Other Family Kid', '2015-01-01'::date, 'female') as s_other \gset
select public.enrol_student(:'section_a'::uuid, :'s_other'::uuid) as e_other \gset

reset role;
insert into public.guardian (tenant_id, name_en, phone_e164, auth_user_id)
values (:'tenant_id'::uuid, 'Portal Parent', '+923001110101', :'parent_user_id'::uuid) returning id as g_mine \gset
insert into public.guardian (tenant_id, name_en, phone_e164, auth_user_id)
values (:'tenant_id'::uuid, 'Other Parent', '+923001110102', :'other_parent_user_id'::uuid) returning id as g_other \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing) values
  (:'tenant_id'::uuid, :'s_mine'::uuid,  :'g_mine'::uuid,  'father', true, true),
  (:'tenant_id'::uuid, :'s_other'::uuid, :'g_other'::uuid, 'mother', true, true);

select is(
  (select count(*) from public.app_user where user_id in (:'parent_user_id'::uuid, :'other_parent_user_id'::uuid)),
  0::bigint,
  'precondition: portal guardians have no app_user row, exactly as in production'
);

-- ── The guardian, from the portal ────────────────────────────────────────────
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'parent_user_id')::text,
  true
);

select lives_ok(
  format('select public.record_consent(%L::uuid, %L, %L::uuid, %L, %L)',
         :'s_mine', 'whatsapp_messaging', :'g_mine', 'granted', 'portal'),
  'a guardian with no app_user row can grant consent from the portal'
);
select is(
  public.has_consent(:'s_mine'::uuid, 'whatsapp_messaging'),
  true,
  'the grant takes effect straight away'
);
select is(
  (select granted_by_guardian_id from public.consent_record
    where student_id = :'s_mine'::uuid and purpose_code = 'whatsapp_messaging' and superseded_by is null),
  :'g_mine'::uuid,
  'the decision belongs to the guardian who made it'
);
select is(
  (select recorded_by from public.consent_record
    where student_id = :'s_mine'::uuid and purpose_code = 'whatsapp_messaging' and superseded_by is null),
  null::uuid,
  'a decision the guardian recorded themselves has no staff recorder'
);

select lives_ok(
  format('select public.record_consent(%L::uuid, %L, %L::uuid, %L, %L)',
         :'s_mine', 'whatsapp_messaging', :'g_mine', 'withdrawn', 'portal'),
  'the same guardian can withdraw it again from the portal'
);
select is(
  public.has_consent(:'s_mine'::uuid, 'whatsapp_messaging'),
  false,
  'the withdrawal takes effect straight away'
);
select is(
  (select count(*) from public.consent_record
    where student_id = :'s_mine'::uuid and purpose_code = 'whatsapp_messaging' and superseded_by is null),
  1::bigint,
  'exactly one current decision remains after the withdrawal supersedes the grant'
);

-- ── Still refused: another family's child, and a paper capture ───────────────
select throws_like(
  format('select public.record_consent(%L::uuid, %L, %L::uuid, %L, %L)',
         :'s_other', 'whatsapp_messaging', :'g_other', 'granted', 'portal'),
  '%FORBIDDEN%',
  'a guardian cannot record a decision for a child who is not theirs'
);
select throws_like(
  format('select public.record_consent(%L::uuid, %L, %L::uuid, %L, %L)',
         :'s_mine', 'whatsapp_messaging', :'g_mine', 'granted', 'paper'),
  '%FORBIDDEN%',
  'a guardian cannot manufacture a paper capture from the portal'
);

-- ── Staff capture still records who captured it ──────────────────────────────
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'receptionist',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'clerk_user_id')::text,
  true
);
select public.record_consent(:'s_mine'::uuid, 'whatsapp_messaging', :'g_mine'::uuid, 'granted', 'counter');
reset role;
select is(
  (select recorded_by from public.consent_record
    where student_id = :'s_mine'::uuid and purpose_code = 'whatsapp_messaging' and superseded_by is null),
  :'clerk_user_id'::uuid,
  'a counter capture still records the staff member who took it'
);

select * from finish();
rollback;
