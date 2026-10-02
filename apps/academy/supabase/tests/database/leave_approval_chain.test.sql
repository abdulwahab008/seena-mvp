-- pgTAP tests for FR-D12: multi-step leave approval chain.
begin;
select plan(10);

select public.provision_tenant('test-approval-co', 'Approval Co', 'owner@approvalco.test');
select id as tenant_id from public.tenant where slug = 'test-approval-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

-- HOD and Principal staff, each with a login (needed so app_role/self-
-- approval resolution has something to check against).
select gen_random_uuid() as hod_user_id \gset
select gen_random_uuid() as principal_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'hod_user_id', 'hod@approvalco.test', 'x', now(), 'authenticated', 'authenticated'),
       (:'principal_user_id', 'principal@approvalco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'hod_user_id', :'tenant_id', 'head_of_department', 'Mr. HOD'),
       (:'principal_user_id', :'tenant_id', 'principal', 'Ms. Principal');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_staff(:'campus_id'::uuid, 'Class Teacher Applicant', 'female', p_cnic => '4210112340011') as applicant_id \gset
select public.create_leave_type('CASUAL', 'Casual Leave', 10) as casual_id \gset
select public.fn_grant_leave_balance(:'applicant_id'::uuid, :'casual_id'::uuid, 10.00);

-- Chain: step 1 = HOD, step 2 = Principal.
select public.set_leave_approval_chain_step(:'campus_id'::uuid, :'casual_id'::uuid, 1::smallint, 'head_of_department', 24::smallint);
select public.set_leave_approval_chain_step(:'campus_id'::uuid, :'casual_id'::uuid, 2::smallint, 'principal', 24::smallint);

select public.apply_for_leave(:'applicant_id'::uuid, :'casual_id'::uuid, '2026-08-03'::date, '2026-08-04'::date) as app_id \gset

-- ── step 1 is auto-created for the configured role ──────────────────

select is(
  (select effective_approver_role from public.leave_approval_step where application_id = :'app_id' and step_no = 1),
  'head_of_department'::public.app_role,
  'applying against a chain-configured leave type auto-creates step 1 for the HOD'
);

-- ── a subject teacher (not in the chain at all) cannot act ──────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format($$ select public.advance_leave_approval(%L, 'approved') $$, :'app_id'),
  'FORBIDDEN',
  'a role not matching the current step is refused'
);

-- ── HOD approves step 1, which creates step 2 for the Principal ────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'head_of_department', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.advance_leave_approval(:'app_id'::uuid, 'approved', 'looks fine to me');

-- Switch back to owner before reading: an HOD is only visible RLS-wise on
-- their own step (approval_step_actor_or_hr_read matches
-- effective_approver_role to the caller's role), so step 2 (assigned to
-- principal) and the application's overall status are correctly invisible
-- to them — checking those needs an authorized-to-see-everything reader.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select decision from public.leave_approval_step where application_id = :'app_id' and step_no = 1),
  'approved'::public.approval_decision,
  'step 1 is recorded as approved'
);
select is(
  (select effective_approver_role from public.leave_approval_step where application_id = :'app_id' and step_no = 2),
  'principal'::public.app_role,
  'approving step 1 creates step 2 for the Principal'
);
select is(
  (select status from public.leave_application where id = :'app_id'),
  'pending'::public.leave_application_status,
  'the application itself is still pending — only the first of two steps has cleared'
);

-- ── the Principal rejects step 2: stops here, hold reverses, no step 3 ─

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.advance_leave_approval(:'app_id'::uuid, 'rejected', 'coverage clash with another teacher');
select is(
  (select status from public.leave_application where id = :'app_id'),
  'rejected'::public.leave_application_status,
  'the application is rejected at step 2'
);
select is(
  (select count(*)::int from public.leave_approval_step where application_id = :'app_id' and step_no = 3),
  0,
  'no step 3 was ever created after the rejection'
);
select is(
  public.fn_leave_balance(:'applicant_id'::uuid, :'casual_id'::uuid),
  10.00,
  'the 2-day hold is fully reversed — balance is back to the original 10.00'
);

-- ── escalation: original approver refused, Owner can resolve it ────

select public.apply_for_leave(:'applicant_id'::uuid, :'casual_id'::uuid, '2026-08-10'::date, '2026-08-10'::date, true) as escalate_app_id \gset
-- fn_escalate_overdue_steps is granted to service_role only (it's meant
-- to be invoked by a scheduler, same reasoning as FR-B16's
-- fn_expire_offers) — superuser exercises it the same way service_role
-- would, since both bypass grant checks.
reset role;
update public.leave_approval_step set sla_due_at = now() - interval '1 hour'
 where application_id = :'escalate_app_id' and step_no = 1;
select public.fn_escalate_overdue_steps();
set local role authenticated;

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'head_of_department', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format($$ select public.advance_leave_approval(%L, 'approved') $$, :'escalate_app_id'),
  'STEP_ESCALATED',
  'the original approver (HOD) is refused once their step has escalated'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select lives_ok(
  format($$ select public.advance_leave_approval(%L, 'approved') $$, :'escalate_app_id'),
  'Owner can resolve an escalated step even though they are not the configured approver'
);

select * from finish();
rollback;
