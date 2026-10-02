-- pgTAP tests for FR-N12: English and Urdu language toggle (data side).
begin;
select plan(16);

select public.provision_tenant('test-lang-co', 'Lang Co', 'owner@langco.test');
select id as tenant_id from public.tenant where slug = 'test-lang-co' \gset
select public.provision_tenant('test-lang-other', 'Other Lang Co', 'owner@otherlangco.test');
select id as other_tenant_id from public.tenant where slug = 'test-lang-other' \gset

select gen_random_uuid() as uid1 \gset
select gen_random_uuid() as uid2 \gset
insert into auth.users (id, phone, aud, role, encrypted_password) values (:'uid1', '923009990001', 'authenticated', 'authenticated', 'x'), (:'uid2', '923009990002', 'authenticated', 'authenticated', 'x');
insert into public.guardian (tenant_id, name_en, phone_e164, auth_user_id) values (:'tenant_id', 'Lang Parent One', '+923009990001', :'uid1') returning id as g1 \gset
insert into public.guardian (tenant_id, name_en, phone_e164, auth_user_id) values (:'tenant_id', 'Lang Parent Two', '+923009990002', :'uid2') returning id as g2 \gset
insert into public.guardian (tenant_id, name_en, phone_e164) values (:'other_tenant_id', 'Foreign Parent', '+923009990003') returning id as g_other \gset

insert into public.message_template (tenant_id, code, name, audience_entity) values (:'tenant_id', 'fee_reminder', 'Fee reminder', 'guardian') returning id as tmpl_id \gset
insert into public.message_template_version (template_id, version_no, message_class, body_en, body_ur, is_published)
values (:'tmpl_id', 1, 'reminder', 'Fee due: PKR {{amount}}', 'فیس واجب الادا: PKR {{amount}}', true) returning id as ver_id \gset
insert into public.message_template_version (template_id, version_no, message_class, body_en, body_ur, is_published)
values (:'tmpl_id', 2, 'reminder', 'English only body', null, true) returning id as ver_en_only \gset

select col_default_is('public', 'guardian', 'preferred_language', 'en', 'guardians default to English');
select col_default_is('public', 'student_portal_account', 'preferred_language', 'en', 'student portal accounts default to English');
select throws_ok($$ update public.guardian set preferred_language = 'fr' where false or id is not null and name_en = 'Lang Parent One' $$, '23514', null, 'the table itself refuses an unsupported language');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is(public.get_preferred_language(), 'en', 'a new guardian reads English');
select is(public.set_preferred_language('ur'), 'ur', 'the guardian switches to Urdu');
select throws_ok($$ select public.set_preferred_language('fr') $$, 'LANGUAGE_NOT_SUPPORTED', 'an unsupported language is refused');
select is((select count(*)::int from public.guardian), 1, 'a parent sees only their own guardian row');

-- AC: persists across devices/logins — a fresh session for the same user sees it.
select set_config('request.jwt.claims', json_build_object('sub', :'uid1', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'session_id', gen_random_uuid())::text, true);
select is(public.get_preferred_language(), 'ur', 'AC: the Urdu preference is applied on a new session without re-selecting');

-- No direct write path: an UPDATE touches no rows (no policy), and another guardian is unaffected.
update public.guardian set preferred_language = 'en';
reset role;
select is((select preferred_language from public.guardian where id = :'g1'), 'ur', 'a direct UPDATE by a parent changes nothing');
select is((select preferred_language from public.guardian where id = :'g2'), 'en', 'and the other guardian''s preference is untouched');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'principal')::text, true);
select throws_ok($$ select public.set_preferred_language('ur') $$, 'NO_PORTAL_PROFILE', 'a user with no portal profile has nothing to set');
reset role;

-- ── FR-M04: the template body follows the guardian's preference ───────────

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal')::text, true);
select is(public.pick_body_for_guardian(:'ver_id'::uuid, :'g1'::uuid), 'فیس واجب الادا: PKR {{amount}}', 'AC: an Urdu-preferring guardian gets body_ur');
select is(public.pick_body_for_guardian(:'ver_id'::uuid, :'g2'::uuid), 'Fee due: PKR {{amount}}', 'an English-preferring guardian gets body_en');
select is(public.pick_body_for_guardian(:'ver_en_only'::uuid, :'g1'::uuid), 'English only body', 'a template with no Urdu body falls back to English');
select throws_ok(format($$ select public.pick_body_for_guardian(%L, %L) $$, :'ver_id', :'g_other'), 'GUARDIAN_OR_TEMPLATE_NOT_FOUND', 'another school''s guardian cannot be used');
select set_config('request.jwt.claims', json_build_object('sub', :'uid1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select throws_ok(format($$ select public.pick_body_for_guardian(%L, %L) $$, :'ver_id', :'g1'), 'FORBIDDEN', 'a parent cannot call the sender-side picker');
reset role;

select * from finish();
rollback;
