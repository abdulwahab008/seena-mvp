-- pgTAP tests for FR-N01: guardian portal access claim.
begin;
select plan(54);

select public.provision_tenant('test-claim-co', 'Claim Co', 'owner@claimco.test');
select id as tenant_id from public.tenant where slug = 'test-claim-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select public.provision_tenant('test-claim-other', 'Claim Other', 'owner@claimother.test');
select id as other_tenant_id from public.tenant where slug = 'test-claim-other' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset

select public.create_student(:'campus_id'::uuid, 'Claim Kid One', '2015-01-01'::date, 'male') as s1 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid) as e1 \gset
select public.create_student(:'campus_id'::uuid, 'Claim Kid Two', '2016-01-01'::date, 'female') as s2 \gset
select public.enrol_student(:'section_id'::uuid, :'s2'::uuid) as e2 \gset
select public.create_student(:'campus_id'::uuid, 'Claim Kid Three', '2015-06-01'::date, 'male') as s3 \gset
select public.enrol_student(:'section_id'::uuid, :'s3'::uuid) as e3 \gset

select public.fn_find_or_create_guardian(p_name_en => 'Claim Father', p_cnic => '35202-1234567-1', p_phone_e164 => '+923001112233') as g1 \gset
select public.link_guardian(:'s1'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
select public.link_guardian(:'s2'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
select public.fn_find_or_create_guardian(p_name_en => 'Claim Mother', p_cnic => '35202-7654321-9') as g2 \gset
select public.link_guardian(:'s3'::uuid, :'g2'::uuid, 'mother'::public.guardian_relationship, true, true);

reset role;
select gr_number as gr1 from public.student where id = :'s1' \gset
select gr_number as gr2 from public.student where id = :'s2' \gset
select gr_number as gr3 from public.student where id = :'s3' \gset
select right(cnic_digits, 6) as cnic1 from public.guardian where id = :'g1' \gset
select right(cnic_digits, 6) as cnic2 from public.guardian where id = :'g2' \gset

-- ── schema and exposure ───────────────────────────────────────────────────

select has_table('public', 'guardian_claim', 'guardian_claim exists');
select has_table('public', 'guardian_claim_attempt', 'guardian_claim_attempt exists');
select ok(
  (select bool_and(relrowsecurity) from pg_class where oid in ('public.guardian_claim'::regclass, 'public.guardian_claim_attempt'::regclass)),
  'RLS is enabled on both new tables'
);
select ok(
  (select count(*) from pg_policies where tablename in ('guardian_claim', 'guardian_claim_attempt')) >= 2,
  'both new tables carry at least one policy'
);
select is(has_function_privilege('anon', 'public.start_guardian_claim(text,text,text,text)', 'execute'), false, 'anon cannot call start_guardian_claim directly');
select is(has_function_privilege('authenticated', 'public.start_guardian_claim(text,text,text,text)', 'execute'), false, 'authenticated cannot call start_guardian_claim directly');
select is(has_function_privilege('service_role', 'public.start_guardian_claim(text,text,text,text)', 'execute'), true, 'service_role can call start_guardian_claim');

-- ── happy path ────────────────────────────────────────────────────────────

set local role service_role;
select public.start_guardian_claim('test-claim-co', :'gr1', :'cnic1', 'device-happy-0000000001') as r_ok \gset
select is((:'r_ok'::jsonb ->> 'status'), 'otp', 'valid GR + CNIC digits start an OTP claim');
select ok((:'r_ok'::jsonb ->> 'token') is not null, 'a token is returned to the server only for the activation redirect');
select ok((:'r_ok'::jsonb ->> 'phone_masked') like '+92%33' and (:'r_ok'::jsonb ->> 'phone_masked') like '%*%', 'the phone is masked');
reset role;

select is(
  (select i.sent_channel from public.guardian_claim c join public.guardian_invite i on i.id = c.invite_id where c.student_id = :'s1'::uuid),
  'claim', 'the claim is backed by a claim-channel invite');
select ok(
  (select i.expires_at <= now() + interval '5 minutes' + interval '2 seconds' from public.guardian_claim c join public.guardian_invite i on i.id = c.invite_id where c.student_id = :'s1'::uuid),
  'AC: the claim window is 5 minutes');
select isnt(
  (select i.token_hash from public.guardian_claim c join public.guardian_invite i on i.id = c.invite_id where c.student_id = :'s1'::uuid),
  (:'r_ok'::jsonb ->> 'token'), 'only the token hash is stored');

-- ── never reveal which half was wrong ─────────────────────────────────────

set local role service_role;
select public.start_guardian_claim('test-claim-co', :'gr1', '000000', 'device-nf-a-0000000001') as r_bad_cnic \gset
select public.start_guardian_claim('test-claim-co', '999999', :'cnic1', 'device-nf-b-0000000001') as r_bad_gr \gset
select public.start_guardian_claim('no-such-school', :'gr1', :'cnic1', 'device-nf-c-0000000001') as r_bad_school \gset
select public.start_guardian_claim('test-claim-co', :'gr3', :'cnic1', 'device-nf-d-0000000001') as r_wrong_family \gset
reset role;
select is((:'r_bad_cnic'::jsonb), '{"status": "not_found"}'::jsonb, 'wrong CNIC -> generic not_found');
select is((:'r_bad_gr'::jsonb), (:'r_bad_cnic'::jsonb), 'wrong GR is indistinguishable from wrong CNIC');
select is((:'r_bad_school'::jsonb), (:'r_bad_cnic'::jsonb), 'wrong school code is indistinguishable too');
select is((:'r_wrong_family'::jsonb), (:'r_bad_cnic'::jsonb), 'a real GR with another family''s CNIC is indistinguishable too');

-- ── device lockout: 3 failures in 10 min -> locked for 30 min ─────────────

set local role service_role;
select public.start_guardian_claim('test-claim-co', :'gr1', '111111', 'device-lock-0000000001');
select public.start_guardian_claim('test-claim-co', :'gr1', '222222', 'device-lock-0000000001');
select public.start_guardian_claim('test-claim-co', :'gr1', '333333', 'device-lock-0000000001');
select public.start_guardian_claim('test-claim-co', :'gr1', :'cnic1', 'device-lock-0000000001') as r_locked \gset
reset role;
select is((:'r_locked'::jsonb ->> 'status'), 'locked', 'AC: the 4th attempt from the device is locked out even with correct input');
select is((select count(*)::int from public.guardian_claim_attempt where device_hash = 'device-lock-0000000001' and outcome = 'failed'), 3, 'AC: the three failures are logged');
select is((select count(*)::int from public.guardian_claim_attempt where device_hash = 'device-lock-0000000001' and outcome = 'locked'), 1, 'the locked attempt is logged, separately from failures');

set local role service_role;
select public.start_guardian_claim('test-claim-co', :'gr1', :'cnic1', 'device-other-000000001') as r_other_dev \gset
reset role;
select is((:'r_other_dev'::jsonb ->> 'status'), 'otp', 'a different device is unaffected by the lock');

update public.guardian_claim_attempt set created_at = created_at - interval '31 minutes' where device_hash = 'device-lock-0000000001';
set local role service_role;
select public.start_guardian_claim('test-claim-co', :'gr1', :'cnic1', 'device-lock-0000000001') as r_unlocked \gset
reset role;
select is((:'r_unlocked'::jsonb ->> 'status'), 'otp', 'the lock lifts after 30 minutes');

-- ── per-GR cap across devices, with no existence oracle ───────────────────

select set_config('test.gr2', :'gr2', false);
do $$
declare i int;
begin
  for i in 1..10 loop
    perform public.start_guardian_claim('test-claim-co', current_setting('test.gr2'), lpad(i::text, 6, '0'), 'device-grcap-' || lpad(i::text, 10, '0'));
    perform public.start_guardian_claim('test-claim-co', '8888888', lpad(i::text, 6, '0'), 'device-ghost-' || lpad(i::text, 10, '0'));
  end loop;
end $$;

set local role service_role;
select public.start_guardian_claim('test-claim-co', :'gr2', :'cnic1', 'device-fresh-000000001') as r_gr_locked \gset
select public.start_guardian_claim('test-claim-co', '8888888', :'cnic1', 'device-fresh-000000002') as r_ghost_locked \gset
reset role;
select is((:'r_gr_locked'::jsonb ->> 'status'), 'locked', '10 failures on one GR lock it for every device, even with correct input');
select is((:'r_ghost_locked'::jsonb ->> 'status'), 'locked', 'a GR that does not exist locks identically — the lock is not an existence oracle');

-- ── manual review: no phone on record ─────────────────────────────────────

set local role service_role;
select public.start_guardian_claim('test-claim-co', :'gr3', :'cnic2', 'device-manual-00000001') as r_manual \gset
reset role;
select is((:'r_manual'::jsonb ->> 'status'), 'manual_review', 'AC: a guardian with no usable phone is queued for manual verification');
select is((select review_reason from public.guardian_claim where student_id = :'s3'::uuid), 'NO_PHONE', 'the reason is recorded');
select is((select count(*)::int from public.guardian_invite where guardian_id = :'g2'::uuid), 0, 'no invite (and so no self-entered number) exists for it');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.guardian_claim where status = 'manual_review'), 1, 'the admissions officer sees the queued claim');
select is((select count(*)::int from public.guardian_claim_attempt where outcome = 'failed') > 0, true, 'the admissions officer sees the logged failures');
select throws_ok(
  format($$ select public.resolve_guardian_claim(%L, true, 'verified at desk') $$, (select id from public.guardian_claim where student_id = :'s3'::uuid)),
  'PHONE_REQUIRED', 'approval needs a phone on the guardian record — the office fixes the record, nobody self-enters one');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner')::text, true);
select is((select count(*)::int from public.guardian_claim), 0, 'another school''s owner sees none of these claims');
select is((select count(*)::int from public.guardian_claim_attempt), 0, 'nor any of these attempt logs');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(
  format($$ select public.resolve_guardian_claim(%L, false, null) $$, (select id from public.guardian_claim where student_id = :'s3'::uuid)),
  'FORBIDDEN', 'a teacher cannot resolve claims');
reset role;

update public.guardian set phone_e164 = '+923004445566' where id = :'g2'::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.resolve_guardian_claim((select id from public.guardian_claim where student_id = :'s3'::uuid), true, 'verified at desk') as r_approve \gset
reset role;
select is((:'r_approve'::jsonb ->> 'status'), 'approved', 'approval issues an invite once the phone is fixed');
select is((select status from public.guardian_claim where student_id = :'s3'::uuid), 'approved', 'the claim is marked approved');

-- ── "I cannot receive the code" and OTP burn ──────────────────────────────

set local role service_role;
select public.start_guardian_claim('test-claim-co', :'gr1', :'cnic1', 'device-burn-000000001') as r_burn \gset
reset role;
select is(
  (select valid from public.get_guardian_invite_preview((:'r_burn'::jsonb ->> 'token'))),
  true, 'a fresh claim invite previews valid');
select public.register_guardian_otp_attempt((:'r_burn'::jsonb ->> 'token'), 'verify_failed');
select public.register_guardian_otp_attempt((:'r_burn'::jsonb ->> 'token'), 'verify_failed');
select is(
  (select valid from public.get_guardian_invite_preview((:'r_burn'::jsonb ->> 'token'))),
  true, 'two wrong codes leave the invite alive');
select public.register_guardian_otp_attempt((:'r_burn'::jsonb ->> 'token'), 'verify_failed');
select is(
  (select valid from public.get_guardian_invite_preview((:'r_burn'::jsonb ->> 'token'))),
  false, 'AC: the invite is rejected after 3 incorrect verification attempts');

set local role service_role;
select public.start_guardian_claim('test-claim-co', :'gr1', :'cnic1', 'device-unreach-0000001') as r_unreach \gset
reset role;
set local role anon;
select is(public.request_claim_manual_review((:'r_unreach'::jsonb ->> 'token')), true, 'an anonymous claimant can route to manual review with the token');
select is(public.request_claim_manual_review((:'r_unreach'::jsonb ->> 'token')), false, 'the token cannot be used twice');
select is(public.request_claim_manual_review('not-a-token'), false, 'an unknown token does nothing');
reset role;
select is((select review_reason from public.guardian_claim where student_id = :'s1'::uuid and status = 'manual_review'), 'PHONE_UNREACHABLE', 'the claim is queued for the office');

-- ── activation links ONLY the claimed student; siblings need their own claim

set local role service_role;
select public.start_guardian_claim('test-claim-co', :'gr1', :'cnic1', 'device-activate-000001') as r_act \gset
reset role;

select gen_random_uuid() as guardian_uid \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role)
values (:'guardian_uid', '923001112233', now(), 'x', 'authenticated', 'authenticated');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'guardian_uid')::text, true);
select is(public.activate_guardian_account((:'r_act'::jsonb ->> 'token')), :'g1'::uuid, 'the claim token activates the guardian');
reset role;

select is((select count(*)::int from public.guardian_claim where student_id = :'s1'::uuid and status = 'activated'), 1, 'the claim is marked activated');
select is(
  (select portal_access from public.student_guardian where guardian_id = :'g1'::uuid and student_id = :'s1'::uuid), true,
  'AC: the claimed student is linked');
select is(
  (select portal_access from public.student_guardian where guardian_id = :'g1'::uuid and student_id = :'s2'::uuid), false,
  'AC: the sibling is NOT linked by the first claim');

-- the per-GR cap from the earlier scenario has served its purpose; age it out
update public.guardian_claim_attempt set created_at = created_at - interval '2 hours' where outcome = 'failed' and tenant_id = :'tenant_id';

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'guardian_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is(app.auth_guardian_student_ids(), array[:'s1'::uuid], 'the portal scope contains only the claimed student');
select is((select count(*)::int from public.student), 1, 'RLS shows the parent only that one student');

select is((public.claim_additional_student(:'gr2', '000000') ->> 'status'), 'not_found', 'a sibling claim with the wrong CNIC digits fails generically');
select is((public.claim_additional_student(:'gr2', :'cnic1') ->> 'status'), 'linked', 'a signed-in guardian can claim the sibling with its GR + their CNIC digits');
select is((select count(*)::int from public.student), 2, 'the sibling is now visible');
reset role;
select is((select count(*)::int from public.guardian_claim_attempt where device_hash = 'uid:' || :'guardian_uid' and outcome = 'failed'), 1, 'the failed sibling attempt was logged against the guardian');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_guardian_portal_access(:'s2'::uuid, :'g1'::uuid, false);
reset role;
select is((select portal_access from public.student_guardian where guardian_id = :'g1'::uuid and student_id = :'s2'::uuid), false, 'the office can withdraw portal access for a linked student');

set local role service_role;
select public.start_guardian_claim('test-claim-co', :'gr1', :'cnic1', 'device-already-000001') as r_already \gset
reset role;
select is((:'r_already'::jsonb ->> 'status'), 'already_active', 'claiming an already-active guardian points them to sign-in');

select * from finish();
rollback;
