-- pgTAP tests for the 6 Nov 2026 browser-audit fixes: the setup checklist completes itself from
-- real data, and a new member's name is the one they gave rather than their email (BUG-18).
begin;
select plan(5);

select public.provision_tenant('test-audit-onb-co', 'Audit Onboarding Co', 'owner@auditonb.test');
select id as tenant_id from public.tenant where slug = 'test-audit-onb-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

select is(
  (select count(*)::int from public.onboarding_progress where tenant_id = :'tenant_id'::uuid and status = 'pending'),
  7,
  'a new school starts with every checklist step pending'
);

insert into public.fee_head (tenant_id, code, name_en, name_ur) values (:'tenant_id', 'TUITION', 'Tuition', 'ٹیوشن فیس');
select is(
  (select status::text from public.onboarding_progress where tenant_id = :'tenant_id'::uuid and step_key = 'fee_heads'),
  'done',
  'adding a fee head completes the fee heads step'
);
select is(
  (select status::text from public.onboarding_progress where tenant_id = :'tenant_id'::uuid and step_key = 'campus_details'),
  'pending',
  'confirm-style steps stay for a person to tick'
);

-- BUG-18: the invitee's own name.
select gen_random_uuid() as uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role, raw_user_meta_data)
values (:'uid', 'named@auditonb.test', 'x', now(), 'authenticated', 'authenticated', '{"full_name": "Sana Teacher"}');
insert into public.tenant_invitation (tenant_id, email, app_role, campus_ids) values (:'tenant_id', 'named@auditonb.test', 'subject_teacher', array[:'campus_id'::uuid])
returning token as tok \gset
select is(
  (select status::text from public.onboarding_progress where tenant_id = :'tenant_id'::uuid and step_key = 'staff_invitations'),
  'done',
  'inviting a staff member completes the staff invitations step'
);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'role', 'authenticated')::text, true);
select public.accept_invitation(:'tok');
reset role;
select is((select full_name from public.app_user where user_id = :'uid'::uuid), 'Sana Teacher', 'BUG-18: the member is named as they asked, not by email');

select * from finish();
rollback;
