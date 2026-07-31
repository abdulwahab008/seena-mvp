-- pgTAP tests for FR-B13: book conflict-free interview slots.
begin;
select plan(15);

select public.provision_tenant('test-interview-co', 'Interview Co', 'owner@interviewco.test');
select id as tenant_id from public.tenant where slug = 'test-interview-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select public.provision_tenant('test-interview-other-co', 'Interview Other Co', 'owner@interviewotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-interview-other-co' \gset

-- A Principal with a real login, so a leave application against them can
-- be decided by the owner without tripping CANNOT_DECIDE_OWN_APPLICATION.
select gen_random_uuid() as principal_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_user_id', 'principal@interviewco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_user_id', :'tenant_id', 'principal', 'Ms. Principal');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_staff(:'campus_id'::uuid, 'Ms. Principal', 'female', p_cnic => '4210112345678') as principal_staff_id \gset
select public.link_staff_user_account(:'principal_staff_id'::uuid, :'principal_user_id'::uuid);

select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate One', p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent One', p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry1_id \gset
select public.fn_submit_application(:'enquiry1_id'::uuid) as app1_id \gset
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate Two', p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Two', p_phone => '03002222222', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry2_id \gset
select public.fn_submit_application(:'enquiry2_id'::uuid) as app2_id \gset
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate Three', p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Three', p_phone => '03003333333', p_whatsapp_opt_in => true, p_source => 'walk_in') as enquiry3_id \gset
select public.fn_submit_application(:'enquiry3_id'::uuid) as app3_id \gset

-- ── AC1: an overlapping booking for the same panel member is rejected ──

select public.book_interview(:'app1_id'::uuid, :'principal_user_id'::uuid, '2026-08-10 11:00:00+05'::timestamptz, '2026-08-10 11:20:00+05'::timestamptz, 'Principal office') as interview1_id \gset
select ok(:'interview1_id' is not null, 'the first booking succeeds');

select throws_ok(
  format('select public.book_interview(%L, %L, %L, %L)', :'app2_id', :'principal_user_id', '2026-08-10 11:10:00+05'::timestamptz, '2026-08-10 11:30:00+05'::timestamptz),
  'PANEL_MEMBER_BUSY',
  'AC: an overlapping window for the same panel member is rejected'
);
select is(
  (select count(*)::int from public.admission_interview where panel_user_id = :'principal_user_id'::uuid and status <> 'cancelled'),
  1,
  'AC: the rejected booking created no row — still exactly 1 active booking'
);

select throws_ok(
  format('select public.book_interview(%L, %L, %L, %L)', :'app2_id', :'principal_user_id', '2026-08-12 09:30:00+05'::timestamptz, '2026-08-12 09:00:00+05'::timestamptz),
  'END_MUST_BE_AFTER_START',
  'an end time at or before the start time is rejected'
);

-- ── AC2: cancelling frees the window immediately ────────────────────

select public.cancel_interview(:'interview1_id'::uuid);
select is(
  (select status from public.admission_interview where id = :'interview1_id'::uuid)::text,
  'cancelled',
  'the interview is now cancelled'
);
select public.book_interview(:'app2_id'::uuid, :'principal_user_id'::uuid, '2026-08-10 11:00:00+05'::timestamptz, '2026-08-10 11:20:00+05'::timestamptz) as interview2_id \gset
select ok(
  :'interview2_id' is not null,
  'AC: the exact same window can be rebooked immediately with no manual cleanup'
);

-- ── AC3: the notification payload resolves SMS vs WhatsApp from the
--    enquiry's own opt-in, WhatsApp taking precedence ──────────────────

select is(
  (public.fn_build_interview_notification_payload(:'interview2_id'::uuid))->>'channel',
  'sms',
  'AC: candidate two has no WhatsApp opt-in — the payload channel is sms'
);
select is(
  (public.fn_build_interview_notification_payload(:'interview2_id'::uuid))->>'application_no',
  (select application_no from public.admission_application where id = :'app2_id'::uuid),
  'the payload carries the booked application''s own number'
);

select public.book_interview(:'app3_id'::uuid, :'principal_user_id'::uuid, '2026-08-16 09:00:00+05'::timestamptz, '2026-08-16 09:20:00+05'::timestamptz) as interview4_id \gset
select is(
  (public.fn_build_interview_notification_payload(:'interview4_id'::uuid))->>'channel',
  'whatsapp',
  'AC: candidate three opted into WhatsApp — the payload channel is whatsapp, taking precedence over SMS'
);

-- ── AC4: a panel member on approved leave triggers a soft block that
--    a confirmed booking can override ───────────────────────────────

select public.create_leave_type('CASUAL', 'Casual Leave', 10) as casual_id \gset
select public.fn_grant_leave_balance(:'principal_staff_id'::uuid, :'casual_id'::uuid, 5.00);
select public.apply_for_leave(:'principal_staff_id'::uuid, :'casual_id'::uuid, '2026-08-15'::date, '2026-08-15'::date) as leave_app_id \gset
select public.fn_decide_leave_application(:'leave_app_id'::uuid, 'approved');

select throws_ok(
  format('select public.book_interview(%L, %L, %L, %L)', :'app1_id', :'principal_user_id', '2026-08-15 09:00:00+05'::timestamptz, '2026-08-15 09:20:00+05'::timestamptz),
  'PANEL_ON_LEAVE',
  'AC: booking into an approved-leave window is refused without confirmation'
);
select is(
  (select count(*)::int from public.admission_interview where panel_user_id = :'principal_user_id'::uuid and starts_at::date = '2026-08-15'::date),
  0,
  'the refused leave-window booking created no row'
);
select public.book_interview(:'app1_id'::uuid, :'principal_user_id'::uuid, '2026-08-15 09:00:00+05'::timestamptz, '2026-08-15 09:20:00+05'::timestamptz, p_confirm_despite_leave => true) as interview3_id \gset
select ok(:'interview3_id' is not null, 'AC: the same booking succeeds once confirmed despite the leave warning');

-- ── validation and tenant isolation ─────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.book_interview(%L, %L, %L, %L)', :'app1_id', :'principal_user_id', '2026-08-20 09:00:00+05'::timestamptz, '2026-08-20 09:20:00+05'::timestamptz),
  'FORBIDDEN',
  'a role with no admissions access cannot book an interview'
);

reset role;
select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'owner@interviewotherco2.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json, 'sub', :'other_user_id')::text,
  true
);
select throws_ok(
  format('select public.book_interview(%L, %L, %L, %L)', :'app1_id', :'principal_user_id', '2026-08-21 09:00:00+05'::timestamptz, '2026-08-21 09:20:00+05'::timestamptz),
  'APPLICATION_NOT_FOUND',
  'book_interview refuses a foreign-tenant application id'
);
select is(
  (select count(*)::int from public.admission_interview),
  0,
  'AC/defense-in-depth: another tenant''s owner sees zero interviews via RLS'
);

select * from finish();
rollback;
