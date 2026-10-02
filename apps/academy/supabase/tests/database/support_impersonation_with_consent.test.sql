-- pgTAP tests for FR-A16: support impersonation with consent.
--
--   AC1  with no active consent, a Super Admin starting impersonation fails
--        with IMPERSONATION_NOT_CONSENTED.
--   AC2  a 24-hour consent that has run out fails with CONSENT_EXPIRED (and a
--        withdrawn one with CONSENT_REVOKED).
--   AC3  inside a live session a financial or result-publishing write is
--        refused with IMPERSONATION_WRITE_BLOCKED, and the attempt is audited.
--   AC4  at minute 61 the session is over: the next request raises 401.
--   AC5  an audited write made while impersonating records actor = the support
--        engineer and effective_actor = the impersonated user.
--   AC6  the Owner's log carries start time, end time, engineer identity and
--        the read/write counts.
--
-- Plus, because this feature is a backdoor if it is built wrong: the consent
-- cap, the 60-minute cap, the role ceiling and the two-person control are
-- TABLE CHECKS (they bind service_role and the table owner, not just a
-- policy); the born-live triggers stop a service_role INSERT walking past the
-- gate with a pre-approved row; the deadline is wall clock and is compared on
-- every audited write, not only by the sweep; and consent withdrawn
-- mid-session ends it in the same statement.
begin;
select plan(92);

select public.provision_tenant('test-imp-co', 'Impersonation Co', 'owner@impco.test');
select id as tenant_id from public.tenant where slug = 'test-imp-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@impco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Nadia Owner');

select gen_random_uuid() as support_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'support_uid', 'support@seena.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'support_uid', :'tenant_id', 'super_admin', 'Imran Support');

select gen_random_uuid() as support2_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'support2_uid', 'support2@seena.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'support2_uid', :'tenant_id', 'super_admin', 'Sana Support');

select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_uid', 'teacher@impco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_uid', :'tenant_id', 'subject_teacher', 'Bilal Teacher');

select gen_random_uuid() as accountant_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'accountant_uid', 'accounts@impco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'accountant_uid', :'tenant_id', 'accountant', 'Ayesha Accounts');

select claims_version as teacher_cv from public.app_user where user_id = :'teacher_uid' \gset

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: no consent, no impersonation — and only the Owner may consent
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'super_admin',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'support_uid')::text,
  true
);

select throws_ok(
  format($$ select public.start_impersonation(%L) $$, :'teacher_uid'),
  '42501',
  'IMPERSONATION_NOT_CONSENTED',
  'AC1: with no consent on file, a Super Admin cannot start impersonation'
);
select throws_ok(
  format($$ select public.grant_impersonation_consent(%L, 24) $$, :'teacher_uid'),
  '42501',
  'FORBIDDEN',
  'and the support engineer cannot grant themselves the consent they need'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_uid')::text,
  true
);
select throws_ok(
  format($$ select public.grant_impersonation_consent(%L, 24) $$, :'teacher_uid'),
  '42501',
  'FORBIDDEN',
  'nor can the target user consent on their school''s behalf — only the Owner can'
);

reset role;
select set_config('request.jwt.claims', '', true);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: a consent that ran out, and one that was withdrawn
-- ═══════════════════════════════════════════════════════════════════════
--
-- The FR's clock: granted for 24 hours at 10:00, used at 09:00 the next day.
-- Exactly 24 hours wide, granted 25 hours ago: the two timestamps come from
-- one expression, because two clock_timestamp() calls in one row are
-- microseconds apart and chk_consent_window measures to the microsecond.
insert into public.impersonation_consent (tenant_id, granted_by, granted_at, expires_at, scope, target_user_id)
select :'tenant_id', :'owner_uid', t.g, t.g + interval '24 hours', 'user', :'teacher_uid'
  from (select now() - interval '25 hours' as g) t
returning id as consent_expired \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'super_admin',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'support_uid')::text,
  true
);
select throws_ok(
  format($$ select public.start_impersonation(%L) $$, :'teacher_uid'),
  '42501',
  'CONSENT_EXPIRED',
  'AC2: a 24-hour consent granted yesterday is refused the next morning'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text,
  true
);
select public.grant_impersonation_consent(:'teacher_uid'::uuid, 2) as consent_revoked \gset
select public.revoke_impersonation_consent(:'consent_revoked'::uuid) as revoked_none \gset
select is(
  (:'revoked_none')::int, 0,
  'withdrawing a consent that no session is using ends no session'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'super_admin',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'support_uid')::text,
  true
);
select throws_ok(
  format($$ select public.start_impersonation(%L) $$, :'teacher_uid'),
  '42501',
  'CONSENT_REVOKED',
  'and a withdrawn consent is refused with the reason it was withdrawn, not "never granted"'
);

-- The two live consents the rest of this file works against.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text,
  true
);
select throws_ok(
  format($$ select public.grant_impersonation_consent(%L, 48) $$, :'teacher_uid'),
  '23514',
  'CONSENT_WINDOW_INVALID',
  'the Owner cannot grant a 48-hour consent — the FR''s cap is 24'
);
select public.grant_impersonation_consent(:'teacher_uid'::uuid, 4) as consent_user \gset
select public.grant_impersonation_consent(null::uuid, 2) as consent_tenant \gset

reset role;
select set_config('request.jwt.claims', '', true);

select is(
  (select scope from public.impersonation_consent where id = :'consent_user'::uuid),
  'user',
  'consent naming one target has scope ''user'''
);
select is(
  (select scope from public.impersonation_consent where id = :'consent_tenant'::uuid),
  'tenant',
  'consent naming no target has scope ''tenant'' — for a school that cannot yet say which login is broken'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The consent record binds service_role and the table owner
-- ═══════════════════════════════════════════════════════════════════════

set local role service_role;

select throws_ok(
  format($$ insert into public.impersonation_consent
              (tenant_id, granted_by, granted_at, expires_at, scope, target_user_id)
            values (%L, %L, clock_timestamp() - interval '48 hours', clock_timestamp() + interval '1 hour', 'user', %L) $$,
         :'tenant_id', :'owner_uid', :'teacher_uid'),
  '23514',
  'new row for relation "impersonation_consent" violates check constraint "chk_consent_window"',
  'a consent window wider than 24 hours is refused by a table CHECK, so a service_role key cannot widen it'
);
select throws_ok(
  format($$ insert into public.impersonation_consent
              (tenant_id, granted_by, granted_at, expires_at, scope, target_user_id)
            values (%L, %L, clock_timestamp(), clock_timestamp() + interval '30 days', 'user', %L) $$,
         :'tenant_id', :'owner_uid', :'teacher_uid'),
  '23514',
  'CONSENT_WINDOW_INVALID',
  'and the 24 hours are measured from the wall clock, not from a neighbouring column a writer also supplies'
);
select throws_ok(
  format($$ insert into public.impersonation_consent
              (tenant_id, granted_by, granted_at, expires_at, scope, target_user_id, revoked_at, revoked_by)
            values (%L, %L, clock_timestamp(), clock_timestamp() + interval '1 hour', 'user', %L, clock_timestamp(), %L) $$,
         :'tenant_id', :'owner_uid', :'teacher_uid', :'owner_uid'),
  '42501',
  'a consent is born unrevoked',
  'a consent cannot be born already revoked'
);
select throws_ok(
  format($$ insert into public.impersonation_consent
              (tenant_id, granted_by, granted_at, expires_at, scope, target_user_id)
            values (%L, %L, clock_timestamp(), clock_timestamp() + interval '1 hour', 'user', %L) $$,
         :'tenant_id', :'teacher_uid', :'teacher_uid'),
  '42501',
  'consent can only be granted by an active Owner of the school it names',
  'nor granted by anyone but an active Owner of that school'
);
select throws_ok(
  format($$ insert into public.impersonation_consent
              (tenant_id, granted_by, granted_at, expires_at, scope, target_user_id)
            values (%L, %L, clock_timestamp(), clock_timestamp() + interval '1 hour', 'user', %L) $$,
         :'tenant_id', :'owner_uid', :'owner_uid'),
  '42501',
  'IMPERSONATION_ROLE_FORBIDDEN',
  'nor name an Owner as the user to be impersonated'
);
select throws_ok(
  format($$ update public.impersonation_consent set expires_at = clock_timestamp() + interval '10 hours' where id = %L $$,
         :'consent_user'),
  '42501',
  'impersonation consent is append-only',
  'a live consent cannot be extended by a service_role key'
);
select throws_ok(
  format($$ delete from public.impersonation_consent where id = %L $$, :'consent_user'),
  '42501',
  'impersonation consent is append-only',
  'nor deleted'
);

reset role;

select throws_ok(
  format($$ update public.impersonation_consent set expires_at = clock_timestamp() + interval '10 hours' where id = %L $$,
         :'consent_user'),
  '42501',
  'impersonation consent is append-only',
  'the table owner, writing the statement by hand, is held to it too'
);
select throws_ok(
  $$ truncate table public.impersonation_consent cascade $$,
  '42501',
  'impersonation records are append-only',
  'TRUNCATE on the consent record, which no row trigger and no policy would have caught'
);
select throws_ok(
  $$ truncate table public.impersonation_session cascade $$,
  '42501',
  'impersonation records are append-only',
  'and on the session log'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The caps, the ceiling and the two-person control are TABLE CHECKS
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select contype::text from pg_constraint
    where conname = 'chk_impersonation_two_person' and conrelid = 'public.impersonation_session'::regclass),
  'c',
  'the two-person control (consent_granted_by <> support_user_id) is a table CHECK, not a policy'
);
select is(
  (select contype::text from pg_constraint
    where conname = 'chk_impersonation_role_ceiling' and conrelid = 'public.impersonation_session'::regclass),
  'c',
  'so is the role ceiling'
);
select is(
  (select contype::text from pg_constraint
    where conname = 'chk_impersonation_window' and conrelid = 'public.impersonation_session'::regclass),
  'c',
  'so is the 60-minute session cap'
);
select is(
  (select contype::text from pg_constraint
    where conname = 'chk_consent_window' and conrelid = 'public.impersonation_consent'::regclass),
  'c',
  'and so is the 24-hour consent cap'
);
select ok(
  (select pg_get_constraintdef(oid) from pg_constraint
    where conname = 'chk_impersonation_role_ceiling' and conrelid = 'public.impersonation_session'::regclass)
    like '%super_admin%',
  'the ceiling names super_admin, owner, parent and student as never impersonatable'
);

-- ═══════════════════════════════════════════════════════════════════════
-- A service_role INSERT cannot walk past the gate
-- ═══════════════════════════════════════════════════════════════════════

set local role service_role;

select throws_ok(
  format($$ insert into public.impersonation_session
              (tenant_id, consent_id, consent_granted_by, support_user_id, target_user_id, target_role,
               started_at, ends_at, ended_at, end_reason, write_count)
            values (%L, %L, %L, %L, %L, 'subject_teacher',
                    clock_timestamp(), clock_timestamp() + interval '30 minutes', null, null, 5) $$,
         :'tenant_id', :'consent_tenant', :'owner_uid', :'support2_uid', :'teacher_uid'),
  '42501',
  'an impersonation session is born open',
  'a service_role key cannot INSERT a session that arrives with counters already spent'
);
select throws_ok(
  format($$ insert into public.impersonation_session
              (tenant_id, consent_id, consent_granted_by, support_user_id, target_user_id, target_role,
               started_at, ends_at)
            values (%L, %L, %L, %L, %L, 'subject_teacher',
                    clock_timestamp() + interval '1 year', clock_timestamp() + interval '1 year' + interval '30 minutes') $$,
         :'tenant_id', :'consent_tenant', :'owner_uid', :'support2_uid', :'teacher_uid'),
  '23514',
  'IMPERSONATION_WINDOW_INVALID',
  'nor one dated a year ahead, which would satisfy the 60-minute CHECK and then be live for a year'
);
select throws_ok(
  format($$ insert into public.impersonation_session
              (tenant_id, consent_id, consent_granted_by, support_user_id, target_user_id, target_role,
               started_at, ends_at)
            values (%L, %L, %L, %L, %L, 'subject_teacher',
                    clock_timestamp() - interval '2 hours', clock_timestamp() + interval '30 minutes') $$,
         :'tenant_id', :'consent_tenant', :'owner_uid', :'support2_uid', :'teacher_uid'),
  '23514',
  'new row for relation "impersonation_session" violates check constraint "chk_impersonation_window"',
  'and a window longer than 60 minutes is refused by the CHECK itself'
);
select throws_ok(
  format($$ insert into public.impersonation_session
              (tenant_id, consent_id, consent_granted_by, support_user_id, target_user_id, target_role,
               started_at, ends_at)
            values (%L, %L, %L, %L, %L, 'owner', clock_timestamp(), clock_timestamp() + interval '30 minutes') $$,
         :'tenant_id', :'consent_tenant', :'owner_uid', :'support2_uid', :'owner_uid'),
  '23514',
  'new row for relation "impersonation_session" violates check constraint "chk_impersonation_role_ceiling"',
  'the Owner — who is the consent granter — can never be the impersonated user, for service_role too'
);
select throws_ok(
  format($$ insert into public.impersonation_session
              (tenant_id, consent_id, consent_granted_by, support_user_id, target_user_id, target_role,
               started_at, ends_at)
            values (%L, %L, %L, %L, %L, 'super_admin', clock_timestamp(), clock_timestamp() + interval '30 minutes') $$,
         :'tenant_id', :'consent_tenant', :'owner_uid', :'support2_uid', :'support_uid'),
  '23514',
  'new row for relation "impersonation_session" violates check constraint "chk_impersonation_role_ceiling"',
  'and neither can another platform admin'
);
select throws_ok(
  format($$ insert into public.impersonation_session
              (tenant_id, consent_id, consent_granted_by, support_user_id, target_user_id, target_role,
               started_at, ends_at)
            values (%L, %L, %L, %L, %L, 'subject_teacher', clock_timestamp(), clock_timestamp() + interval '30 minutes') $$,
         :'tenant_id', :'consent_tenant', :'support2_uid', :'support2_uid', :'teacher_uid'),
  '42501',
  'IMPERSONATION_NOT_CONSENTED',
  'the denormalised consent_granted_by cannot be forged to satisfy the two-person CHECK'
);
select throws_ok(
  format($$ insert into public.impersonation_session
              (tenant_id, consent_id, consent_granted_by, support_user_id, target_user_id, target_role,
               started_at, ends_at)
            values (%L, %L, %L, %L, %L, 'subject_teacher', clock_timestamp(), clock_timestamp() + interval '30 minutes') $$,
         :'tenant_id', :'consent_expired', :'owner_uid', :'support2_uid', :'teacher_uid'),
  '42501',
  'IMPERSONATION_NOT_CONSENTED',
  'nor may a session be opened against a consent that has already run out'
);
select throws_ok(
  format($$ insert into public.impersonation_session
              (tenant_id, consent_id, consent_granted_by, support_user_id, target_user_id, target_role,
               started_at, ends_at)
            values (%L, %L, %L, %L, %L, 'accountant', clock_timestamp(), clock_timestamp() + interval '30 minutes') $$,
         :'tenant_id', :'consent_tenant', :'owner_uid', :'teacher_uid', :'accountant_uid'),
  '42501',
  'FORBIDDEN',
  'and only an active super_admin of that school may be the one impersonating'
);

reset role;

-- ═══════════════════════════════════════════════════════════════════════
-- Starting a session: ceiling, self, cap, one-at-a-time
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'super_admin',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'support_uid')::text,
  true
);

select throws_ok(
  format($$ select public.start_impersonation(%L) $$, :'owner_uid'),
  '42501',
  'IMPERSONATION_ROLE_FORBIDDEN',
  'the engineer cannot impersonate the Owner who grants the consent'
);
select throws_ok(
  format($$ select public.start_impersonation(%L) $$, :'support_uid'),
  '42501',
  'IMPERSONATION_SELF_FORBIDDEN',
  'nor themselves'
);
select throws_ok(
  format($$ select public.start_impersonation(%L, 90) $$, :'teacher_uid'),
  '23514',
  'IMPERSONATION_WINDOW_INVALID',
  'nor ask for a 90-minute window'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'accountant_uid')::text,
  true
);
select throws_ok(
  format($$ select public.start_impersonation(%L) $$, :'teacher_uid'),
  '42501',
  'FORBIDDEN',
  'and an ordinary member of staff cannot impersonate anyone at all'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'super_admin',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'support_uid')::text,
  true
);
select public.start_impersonation(:'teacher_uid'::uuid, 60) ->> 'session_id' as s1 \gset

select throws_ok(
  format($$ select public.start_impersonation(%L) $$, :'teacher_uid'),
  '42501',
  'IMPERSONATION_ALREADY_ACTIVE',
  'one engineer inside one account at a time, so "who did that" stays answerable'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'super_admin',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'support2_uid')::text,
  true
);
select public.start_impersonation(:'accountant_uid'::uuid, 30) ->> 'session_id' as s2 \gset

reset role;
select set_config('request.jwt.claims', '', true);

select is(
  (select target_role::text from public.impersonation_session where id = :'s1'::uuid),
  'subject_teacher',
  'the session snapshots the role that was impersonated'
);
select ok(
  (select ends_at <= started_at + interval '60 minutes' and ends_at > started_at
     from public.impersonation_session where id = :'s1'::uuid),
  'and its window is at most the FR''s 60 minutes'
);
select is(
  (select consent_id from public.impersonation_session where id = :'s2'::uuid),
  :'consent_tenant'::uuid,
  'a tenant-scoped consent covers a user it never named'
);
select is(
  (select count(*)::int from public.security_event
    where event_type = 'impersonation_started' and severity = 'alert' and subject_id = :'s1'::uuid),
  1,
  'starting a session raises an alert-severity security_event — a stranger is inside the school''s account'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The token overlay: sub is never rewritten
-- ═══════════════════════════════════════════════════════════════════════

select public.custom_access_token_hook(
  jsonb_build_object('user_id', :'support_uid',
                     'claims', jsonb_build_object('sub', :'support_uid', 'role', 'authenticated'))
) as hook_imp \gset

select is(
  (:'hook_imp')::jsonb -> 'claims' ->> 'sub', :'support_uid',
  'the token''s sub is NEVER rewritten — auth.uid() is the real support engineer, always'
);
select is(
  (:'hook_imp')::jsonb -> 'claims' -> 'imp' ->> 'sub', :'teacher_uid',
  'the imp claim names the impersonated user'
);
select is(
  (:'hook_imp')::jsonb -> 'claims' -> 'imp' ->> 'by', :'support_uid',
  'and the real human doing it'
);
select is(
  (:'hook_imp')::jsonb -> 'claims' -> 'imp' ->> 'sid', :'s1',
  'and the session it belongs to'
);
select is(
  (:'hook_imp')::jsonb -> 'claims' ->> 'app_role', 'subject_teacher',
  'the AUTHORISATION claims are the target''s, so RLS shows the target''s view of the product'
);
select is(
  ((:'hook_imp')::jsonb -> 'claims' ->> 'tenant_id')::uuid, :'tenant_id'::uuid,
  'including the school being diagnosed'
);
select is(
  ((:'hook_imp')::jsonb -> 'claims' ->> 'cv')::int, :'teacher_cv'::int,
  'and the target''s claims epoch, so a role change on the target ends the session'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the write block, for every writer
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'support_uid',
                    'imp', json_build_object('sid', :'s1', 'sub', :'teacher_uid', 'by', :'support_uid'))::text,
  true
);

set local role authenticated;
select throws_ok(
  format($$ insert into public.fee_payment (tenant_id) values (%L) $$, :'tenant_id'),
  '42501',
  'IMPERSONATION_WRITE_BLOCKED',
  'AC3: money cannot be marked received while impersonating'
);

reset role;
set local role service_role;
select throws_ok(
  format($$ insert into public.subject_result (tenant_id) values (%L) $$, :'tenant_id'),
  '42501',
  'IMPERSONATION_WRITE_BLOCKED',
  'AC3: nor a result made real — and a service_role key is refused identically'
);

reset role;
select throws_ok(
  format($$ insert into public.fee_payment (tenant_id) values (%L) $$, :'tenant_id'),
  '42501',
  'IMPERSONATION_WRITE_BLOCKED',
  'AC3: and so is the table owner, because the block is a trigger and not an RLS policy'
);

select is(
  (select count(*)::int from public.impersonation_blocked_tables()),
  14,
  'fourteen tables carry the block: the FR''s financial and result-publishing categories'
);
select ok(
  (select count(*) = 2 from public.impersonation_blocked_tables() t
    where t in ('fee_payment', 'subject_result')),
  'including the two the FR names by category'
);
select ok(
  (select count(*) = 0 from public.impersonation_blocked_tables() t where t = 'fee_challan'),
  'issuing a challan is deliberately NOT blocked — it is reversible, and reproducing a broken run is a legitimate diagnosis'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC5: attribution — the write traces to the real human
-- ═══════════════════════════════════════════════════════════════════════

insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
values (:'tenant_id', :'campus_id', 'GR-IMP-0001', 'Diagnosed Student',
        current_date - interval '13 years', 'male')
returning id as stu1 \gset

select is(
  (select actor_user_id from public.audit_log
    where tenant_id = :'tenant_id'::uuid and table_name = 'student' and row_id = :'stu1'::uuid
      and action = 'insert'),
  :'support_uid'::uuid,
  'AC5: the audit row''s actor is the SUPPORT ENGINEER, because sub was never rewritten'
);
select is(
  (select effective_actor_user_id from public.audit_log
    where tenant_id = :'tenant_id'::uuid and table_name = 'student' and row_id = :'stu1'::uuid
      and action = 'insert'),
  :'teacher_uid'::uuid,
  'AC5: and its effective_actor is the impersonated user — alongside the real one, never instead of it'
);
select is(
  (select impersonation_session_id from public.audit_log
    where tenant_id = :'tenant_id'::uuid and table_name = 'student' and row_id = :'stu1'::uuid
      and action = 'insert'),
  :'s1'::uuid,
  'AC5: pinned to the session it was made inside'
);
select is(
  (select write_count from public.impersonation_session where id = :'s1'::uuid),
  1::bigint,
  'AC6: and counted, by the audit trigger that already fires on every audited table'
);

-- The new columns are inside the digest, so they cannot be edited afterwards
-- — and the fold is conditional, so every pre-FR-A16 row still hashes the
-- same and the existing chain still verifies.
select set_config('request.jwt.claims', '', true);
select is(
  (select status::text from public.run_audit_chain_verification(:'tenant_id'::uuid) limit 1),
  'ok',
  'the hash chain still verifies with the impersonation attribution folded into it'
);

-- AC3's other half: the durable record of a refused attempt.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'support_uid',
                    'imp', json_build_object('sid', :'s1', 'sub', :'teacher_uid', 'by', :'support_uid'))::text,
  true
);
set local role authenticated;
select public.record_impersonation_block('fee_payment', 'insert') as blk1 \gset
select public.impersonation_note_reads(7) as reads1 \gset
reset role;

select is(
  (select count(*)::int from public.security_event
    where event_type = 'impersonation_write_blocked' and severity = 'alert'
      and subject_id = :'s1'::uuid and actor_user_id = :'support_uid'::uuid),
  1,
  'AC3: the refused attempt is recorded as an alert naming the real engineer'
);
select is(
  (select blocked_write_count from public.impersonation_session where id = :'s1'::uuid),
  1::bigint,
  'AC6: and counted on the session'
);
select is(
  (:'reads1')::bigint, 7::bigint,
  'AC6: reads are counted too, as the console reports them'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Who can see the log
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text,
  true
);
select is(
  (select count(*)::int from public.impersonation_session), 2,
  'AC6: the Owner sees every session in their school'
);
select ok(
  (select count(*) >= 3 from public.impersonation_consent),
  'and every consent their school ever gave'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_uid')::text,
  true
);
select is(
  (select count(*)::int from public.impersonation_session), 0,
  'an ordinary member of staff sees none of it'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'support_uid',
                    'imp', json_build_object('sid', :'s1', 'sub', :'teacher_uid', 'by', :'support_uid'))::text,
  true
);
select is(
  (select count(*)::int from public.impersonation_session), 1,
  'but the engineer can read the one session they are inside, so the banner can name it'
);

reset role;
select set_config('request.jwt.claims', '', true);

-- ═══════════════════════════════════════════════════════════════════════
-- Consent withdrawn mid-session
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'support2_uid',
                    'imp', json_build_object('sid', :'s2', 'sub', :'accountant_uid', 'by', :'support2_uid'))::text,
  true
);
select throws_ok(
  format($$ select public.revoke_impersonation_consent(%L) $$, :'consent_tenant'),
  '42501',
  'FORBIDDEN',
  'the engineer inside a session cannot withdraw the consent that authorises it'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text,
  true
);
select public.revoke_impersonation_consent(:'consent_tenant'::uuid) as ended2 \gset
reset role;

select is(
  (:'ended2')::int, 1,
  'the Owner withdrawing consent ends the live session in the same statement'
);
select is(
  (select end_reason from public.impersonation_session where id = :'s2'::uuid),
  'consent_revoked',
  'and the log says why it ended'
);
select ok(
  (select ended_at is not null from public.impersonation_session where id = :'s2'::uuid),
  'AC6: with an end time'
);
select is(
  (select count(*)::int from public.security_event
    where event_type = 'impersonation_consent_revoked' and subject_id = :'s2'::uuid),
  1,
  'and the withdrawal is itself a security_event the Owner can point at'
);

-- The per-request lookup is what actually refuses: nothing depends on the
-- token being re-minted or on the sweep being punctual.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'support2_uid',
                    'imp', json_build_object('sid', :'s2', 'sub', :'accountant_uid', 'by', :'support2_uid'))::text,
  true
);
select throws_ok(
  $$ select app.auth_tenant_id() $$,
  'PT401',
  'IMPERSONATION_SESSION_ENDED',
  'and the engineer''s very next request is refused with 401, on the token they already hold'
);

reset role;
select set_config('request.jwt.claims', '', true);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: minute 61
-- ═══════════════════════════════════════════════════════════════════════

-- Minute 61, without waiting an hour: the deadline is pulled back to the
-- instant after the session opened, which is the SHORTEN transition an Owner
-- uses to cut a live session short.
update public.impersonation_session
   set ends_at = started_at + interval '1 millisecond'
 where id = :'s1'::uuid;

select ok(
  (select ends_at < clock_timestamp() from public.impersonation_session where id = :'s1'::uuid),
  'a deadline may be moved EARLIER — narrowing is always safe, and it is how an Owner cuts a session short'
);
select throws_ok(
  format($$ update public.impersonation_session set ends_at = clock_timestamp() + interval '30 minutes' where id = %L $$,
         :'s1'),
  '42501',
  'impersonation session is append-only',
  'but never later, not even by the table owner'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'support_uid',
                    'imp', json_build_object('sid', :'s1', 'sub', :'teacher_uid', 'by', :'support_uid'))::text,
  true
);
select throws_ok(
  $$ select app.auth_tenant_id() $$,
  'PT401',
  'IMPERSONATION_SESSION_ENDED',
  'AC4: at minute 61 the next request returns 401, with no job having run'
);

reset role;
select throws_ok(
  format($$ insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
            values (%L, %L, 'GR-IMP-0002', 'After The Deadline', current_date - interval '13 years', 'male') $$,
         :'tenant_id', :'campus_id'),
  'PT401',
  'IMPERSONATION_SESSION_ENDED',
  'AC4: and the wall-clock deadline is compared on every audited WRITE too, which is where the SECURITY DEFINER RPCs that bypass RLS land'
);

select set_config('request.jwt.claims', '', true);
select public.expire_impersonation_sessions() as swept \gset

select is(
  (:'swept')::int, 1,
  'the five-minute sweep then closes the record — it makes the closed window visible, it does not close it'
);
select is(
  (select end_reason from public.impersonation_session where id = :'s1'::uuid),
  'expired',
  'with the reason it ended'
);
select ok(
  (select ended_at is not null and started_at is not null and read_count = 7 and write_count >= 1
     from public.impersonation_session where id = :'s1'::uuid),
  'AC6: the Owner''s log carries start time, end time and the read and write counts'
);
select is(
  (select support_user_id from public.impersonation_session where id = :'s1'::uuid),
  :'support_uid'::uuid,
  'AC6: and the engineer''s identity'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Leaving, and being thrown out
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'super_admin',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'support_uid')::text,
  true
);
select public.start_impersonation(:'teacher_uid'::uuid, 15) ->> 'session_id' as s3 \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'support_uid',
                    'imp', json_build_object('sid', :'s3', 'sub', :'teacher_uid', 'by', :'support_uid'))::text,
  true
);
select public.end_impersonation() ->> 'end_reason' as r3 \gset
select is(
  (:'r3')::text, 'ended_by_support',
  'the engineer can always leave — end_impersonation() never depends on the window still being open'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'super_admin',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'support_uid')::text,
  true
);
select public.start_impersonation(:'teacher_uid'::uuid, 15) ->> 'session_id' as s4 \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'accountant_uid')::text,
  true
);
select throws_ok(
  format($$ select public.end_impersonation(%L) $$, :'s4'),
  '42501',
  'FORBIDDEN',
  'a bystander cannot end someone else''s session'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text,
  true
);
select public.end_impersonation(:'s4'::uuid) ->> 'end_reason' as r4 \gset
select is(
  (:'r4')::text, 'ended_by_owner',
  'but any Owner of the school can throw the engineer out at any moment'
);

reset role;
select set_config('request.jwt.claims', '', true);

select ok(
  (select ended_at is not null from public.impersonation_session where id = :'s4'::uuid),
  'and the session is closed at once'
);
select throws_ok(
  format($$ update public.impersonation_session set ended_at = null, end_reason = null where id = %L $$, :'s4'),
  '42501',
  'impersonation session is append-only',
  'how a session ended cannot be re-decided afterwards'
);
select throws_ok(
  format($$ update public.impersonation_session set write_count = 0 where id = %L $$, :'s1'),
  '42501',
  'impersonation session is append-only',
  'nor a counter rewound'
);
select throws_ok(
  format($$ update public.impersonation_session set support_user_id = %L where id = %L $$, :'support2_uid', :'s1'),
  '42501',
  'impersonation session is append-only',
  'nor who was inside changed'
);
select throws_ok(
  format($$ delete from public.impersonation_session where id = %L $$, :'s1'),
  '42501',
  'impersonation session is append-only',
  'and a session that happened cannot be made not to have happened'
);

-- With no live session, the engineer's own token is ordinary again.
select public.custom_access_token_hook(
  jsonb_build_object('user_id', :'support_uid',
                     'claims', jsonb_build_object('sub', :'support_uid', 'role', 'authenticated'))
) as hook_plain \gset
select ok(
  not ((:'hook_plain')::jsonb -> 'claims' ? 'imp'),
  'once every session is over the engineer''s token carries no imp claim at all'
);
select is(
  (:'hook_plain')::jsonb -> 'claims' ->> 'app_role', 'super_admin',
  'and they are themselves again'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Tenant isolation
-- ═══════════════════════════════════════════════════════════════════════

select public.provision_tenant('other-imp-co', 'Other Imp Co', 'owner@otherimp.test');
select id as other_tenant from public.tenant where slug = 'other-imp-co' \gset
select id as other_campus from public.campus where tenant_id = :'other_tenant' \gset

select gen_random_uuid() as other_owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_owner_uid', 'owner@otherimp.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_owner_uid', :'other_tenant', 'owner', 'Other Owner');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'other_campus'), 'sub', :'other_owner_uid')::text,
  true
);
select is(
  (select count(*)::int from public.impersonation_consent), 0,
  'another school''s Owner sees none of this school''s consents'
);
select is(
  (select count(*)::int from public.impersonation_session), 0,
  'nor any of its sessions'
);

reset role;
select * from finish();
rollback;
