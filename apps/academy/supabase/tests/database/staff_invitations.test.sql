-- pgTAP tests for FR-A07: invite_user / get_invitation_preview / accept_invitation.
begin;
select plan(11);

select public.provision_tenant('test-invite-co', 'Invite Co', 'owner@inviteco.test');
select id as tenant_id from public.tenant where slug = 'test-invite-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── invite_user ────────────────────────────────────────────────────────

select lives_ok(
  format(
    $$ select public.invite_user('teacher@inviteco.test'::public.citext, 'subject_teacher'::public.app_role, array[%L]::uuid[]) $$,
    :'campus_id'
  ),
  'an owner can invite a new staff member'
);
select is(
  (select count(*)::int from public.tenant_invitation where tenant_id = :'tenant_id' and email = 'teacher@inviteco.test'),
  1,
  'exactly one invitation row exists'
);

-- Re-inviting the same email supersedes the prior outstanding invite.
select public.invite_user('teacher@inviteco.test'::public.citext, 'class_teacher'::public.app_role, '{}'::uuid[]);
select is(
  (select count(*)::int from public.tenant_invitation where tenant_id = :'tenant_id' and email = 'teacher@inviteco.test'),
  1,
  'a second invite to the same email replaces the first rather than adding a row'
);
select is(
  (select app_role::text from public.tenant_invitation where tenant_id = :'tenant_id' and email = 'teacher@inviteco.test'),
  'class_teacher',
  'the surviving invitation reflects the second (latest) role'
);

-- ── forbidden path ─────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', '[]'::json)::text,
  true
);
select throws_ok(
  $$ select public.invite_user('nope@inviteco.test'::public.citext, 'owner'::public.app_role, '{}'::uuid[]) $$,
  'FORBIDDEN',
  'a subject_teacher cannot invite anyone'
);

-- ── get_invitation_preview (anon-callable) ────────────────────────────────

reset role;
select id as invite_id, token as invite_token from public.tenant_invitation where email = 'teacher@inviteco.test' \gset

set local role anon;
select is(
  (select valid from public.get_invitation_preview(:'invite_token')),
  true,
  'anon can preview a fresh, unaccepted, unexpired invitation as valid'
);
select is(
  (select tenant_name from public.get_invitation_preview(:'invite_token')),
  'Invite Co',
  'the preview reveals the tenant name (needed to render "join X as Y")'
);
select is(
  (select valid from public.get_invitation_preview('not-a-real-token')),
  null,
  'an unknown token returns no row (not an error, not a leak)'
);

-- ── accept_invitation ──────────────────────────────────────────────────

reset role;
insert into auth.users (id, email) values (gen_random_uuid(), 'teacher@inviteco.test');
select id as new_user_id from auth.users where email = 'teacher@inviteco.test' \gset

set local role authenticated;
select set_config('request.jwt.claim.sub', :'new_user_id', true);
select set_config('request.jwt.claims', json_build_object('sub', :'new_user_id')::text, true);

select lives_ok(
  format('select public.accept_invitation(%L)', :'invite_token'),
  'the invited user can accept their own invitation'
);

-- Verify as superuser: the 'authenticated' session's own JWT claims above
-- only carry {"sub": ...} (accept_invitation only needs auth.uid()), so
-- app_user's tenant-scoped RLS policy would hide the just-inserted row from
-- that same session — this checks the data landed, not RLS visibility.
reset role;
select is(
  (select app_role::text from public.app_user where user_id = :'new_user_id'),
  'class_teacher',
  'accepting creates an app_user row with the invited role'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', :'new_user_id', true);
select set_config('request.jwt.claims', json_build_object('sub', :'new_user_id')::text, true);
select throws_ok(
  format('select public.accept_invitation(%L)', :'invite_token'),
  'INVITE_ALREADY_USED',
  'the same token cannot be accepted twice'
);

select * from finish();
rollback;
