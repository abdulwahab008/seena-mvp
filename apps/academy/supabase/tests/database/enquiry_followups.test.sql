-- pgTAP tests for FR-B04: assign and track enquiry follow-up tasks.
begin;
select plan(11);

select public.provision_tenant('test-followup-co', 'Followup Co', 'owner@followupco.test');
select id as tenant_id from public.tenant where slug = 'test-followup-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as officer1_id \gset
select gen_random_uuid() as officer2_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values
  (:'officer1_id', 'officer1@followupco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'officer2_id', 'officer2@followupco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values
  (:'officer1_id', :'tenant_id', 'admissions_officer', 'Officer One'),
  (:'officer2_id', :'tenant_id', 'admissions_officer', 'Officer Two');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_enquiry(
  p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Follow Up Applicant',
  p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent One',
  p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry_id \gset

-- ── FORBIDDEN: a role with no admissions access cannot assign follow-ups ──

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format(
    $$ select public.create_followup(%L, now() + interval '1 day', 'call', %L) $$,
    :'enquiry_id', :'officer1_id'
  ),
  'FORBIDDEN',
  'a role with no admissions access cannot create a follow-up'
);

-- ── overdue worklist: only the incomplete, past-due one for this user ────

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', :'officer1_id', 'tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_id')
  )::text,
  true
);
select public.create_followup(:'enquiry_id'::uuid, now() + interval '1 day', 'call', :'officer1_id'::uuid) as followup1_id \gset
select public.create_followup(:'enquiry_id'::uuid, now() - interval '3 days', 'whatsapp', :'officer1_id'::uuid) as followup2_id \gset
select is(
  (select array_agg(id) from public.my_overdue_followups()),
  array[:'followup2_id'::uuid],
  'the overdue worklist returns only the past-due, incomplete follow-up assigned to the caller'
);

-- ── completing a follow-up records outcome, note and completer ──────────

select public.fn_complete_followup(:'followup1_id'::uuid, 'connected', 'answered on first ring');
select is(
  (select outcome::text from public.admission_followup where id = :'followup1_id'),
  'connected',
  'completing a follow-up records the mandatory outcome'
);
select is(
  (select completed_by from public.admission_followup where id = :'followup1_id'),
  :'officer1_id'::uuid,
  'the completer is recorded'
);
select throws_ok(
  format($$ select public.fn_complete_followup(%L, 'connected') $$, :'followup1_id'),
  'ALREADY_COMPLETED',
  'completing an already-completed follow-up a second time is rejected'
);

-- ── closing as lost is blocked while a follow-up is still open ──────────

select throws_ok(
  format($$ select public.fn_close_enquiry(%L, 'lost') $$, :'enquiry_id'),
  'OPEN_FOLLOWUPS_EXIST',
  'an enquiry with an open follow-up cannot be closed as lost'
);
select throws_ok(
  format($$ select public.fn_close_enquiry(%L, 'converted') $$, :'enquiry_id'),
  'UNSUPPORTED_STATUS',
  'fn_close_enquiry only handles the lost transition — converted has its own path'
);

select public.fn_complete_followup(:'followup2_id'::uuid, 'not_interested');
select public.fn_close_enquiry(:'enquiry_id'::uuid, 'lost');
select is(
  (select status::text from public.admission_enquiry where id = :'enquiry_id'),
  'lost',
  'once every follow-up is closed, the enquiry can be marked lost'
);

-- ── reassignment moves only open work, never completed history ─────────

select public.create_followup(:'enquiry_id'::uuid, now() + interval '2 days', 'sms', :'officer1_id'::uuid) as followup3_id \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  public.fn_reassign_followups(:'officer1_id'::uuid, :'officer2_id'::uuid),
  1,
  'reassignment moves exactly the one still-open follow-up'
);
select is(
  (select assigned_to from public.admission_followup where id = :'followup3_id'),
  :'officer2_id'::uuid,
  'the open follow-up is now assigned to the target user'
);
select is(
  (select assigned_to from public.admission_followup where id = :'followup1_id'),
  :'officer1_id'::uuid,
  'a completed follow-up is left with its original assignee, untouched by reassignment'
);

select * from finish();
rollback;
