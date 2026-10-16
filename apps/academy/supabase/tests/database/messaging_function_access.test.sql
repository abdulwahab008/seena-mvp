-- pgTAP tests: the messaging engine is closed to signed-out callers and to other schools.
--
-- About sixty SECURITY DEFINER functions of the communication module could be run by anyone holding
-- the public API key, and by any signed-in user of any school, with no check on whose data they
-- touched: claim another school's queued messages, top up or drain its wallet, forge delivery
-- receipts, publish its circulars.
begin;
select plan(29);

select public.provision_tenant('test-msg-access-a', 'Messaging Access A', 'owner@msgaccess-a.test');
select public.provision_tenant('test-msg-access-b', 'Messaging Access B', 'owner@msgaccess-b.test');
select id as tenant_a from public.tenant where slug = 'test-msg-access-a' \gset
select id as tenant_b from public.tenant where slug = 'test-msg-access-b' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_a' \gset
select id as campus_b from public.campus where tenant_id = :'tenant_b' \gset

-- ── the signed-out role ──────────────────────────────────────────────────────
-- Every SECURITY DEFINER function in public that anon can run must be one of the pages that are
-- public on purpose, or check the caller itself. Anything new has to revoke public/anon.
select is(
  (select array_agg(p.proname::text order by p.proname)
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.prosecdef
      and p.prorettype <> 'pg_catalog.trigger'::regtype
      and has_function_privilege('anon', p.oid, 'execute')
      and p.proname <> all (array[
        -- public on purpose: admission form, invitation, certificate and password-reset checks, OTP and login lockouts
        'classify_password_reset_token', 'fn_public_school_info', 'get_guardian_invite_preview', 'get_invitation_preview',
        'is_guardian_otp_locked', 'is_login_locked', 'is_otp_locked', 'issue_otp', 'register_guardian_otp_attempt', 'request_claim_manual_review',
        'submit_public_enquiry', 'verify_certificate',
        -- check auth.uid() or the role themselves, and are used by row-level security policies
        'add_ticket_message', 'change_student_password', 'create_support_ticket', 'edit_student_remark',
        'generate_guardian_ics_token', 'guardian_can_read_circular', 'mark_circular_read', 'moderate_student_remark',
        'my_student_id', 'my_student_ids', 'publish_template_version', 'reopen_ticket', 'resolve_ticket',
        'schedule_campaign', 'submit_student_remark'
      ])),
  null,
  'no other security definer function in public can be run signed out'
);

select is(
  (select array_agg(n.name order by n.name)
     from unnest(array[
       'apply_dispatch_suppression', 'attach_wa_template_to_message', 'debit_comm_wallet', 'deprovision_on_tc', 'escalate_message',
       'escalate_tickets', 'estimate_campaign_cost', 'get_channel_chain', 'get_guardian_ics_events', 'get_next_quiet_window_end',
       'get_or_create_campus_portal_policy', 'is_recipient_opted_out', 'is_suppressed', 'is_working_day', 'next_channel_for',
       'next_ticket_no', 'pick_body', 'preview_campaign_suppression', 'record_attempt_cost', 'record_message_attempt',
       'record_message_cost', 'resolve_student_login', 'sla_due', 'student_matches_segment',
       'wa_window_open'
     ]) as n(name)
     join pg_proc p on p.proname = n.name and p.pronamespace = 'public'::regnamespace
    where has_function_privilege('authenticated', p.oid, 'execute')),
  null,
  'functions only the worker and other functions call are not open to signed-in users either'
);
select ok(
  not has_function_privilege('authenticated', 'public.apply_receipt(text, jsonb, uuid)'::regprocedure, 'execute')
  and has_function_privilege('service_role', 'public.apply_receipt(text, jsonb, uuid)'::regprocedure, 'execute'),
  'the provider webhook form of apply_receipt is service role only'
);
select ok(
  has_function_privilege('authenticated', 'public.apply_receipt(uuid, text, text, jsonb)'::regprocedure, 'execute'),
  'while the staff form that resolves one attempt stays available to signed-in users'
);

-- ── fixtures, as the database owner ──────────────────────────────────────────
insert into public.message (tenant_id, campus_id, body, status, recipient_phone, channel)
values (:'tenant_a', :'campus_a', 'A message', 'queued', '03001110001', 'sms'),
       (:'tenant_b', :'campus_b', 'B message one', 'queued', '03001110002', 'sms'),
       (:'tenant_b', :'campus_b', 'B message two', 'queued', '03001110003', 'sms');
insert into public.circular (tenant_id, campus_id, title, body_en) values (:'tenant_a', :'campus_a', 'A circular', 'Body A') returning id as circular_a \gset
insert into public.circular (tenant_id, campus_id, title, body_en) values (:'tenant_b', :'campus_b', 'B circular', 'Body B') returning id as circular_b \gset
select public.seed_default_segments(:'tenant_b'::uuid);
select id as segment_b from public.message_segment where tenant_id = :'tenant_b' limit 1 \gset
insert into public.wa_template (tenant_id, meta_template_name, body_text) values (:'tenant_b', 'b_template', 'Hello') returning id as template_b \gset
select gen_random_uuid() as worker_id \gset

-- ── a staff member of school A ───────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'tenant_id', :'tenant_a', 'app_role', 'principal',
  'campus_ids', json_build_array(:'campus_a'))::text, true);

select lives_ok(format($$ select public.top_up_comm_wallet(%L, 5000) $$, :'tenant_a'), 'staff can top up their own school''s wallet');
select throws_ok(format($$ select public.top_up_comm_wallet(%L, 5000) $$, :'tenant_b'), 'FORBIDDEN', 'but not another school''s');
select throws_ok(format($$ select public.resubscribe_recipient(%L, '03001110002', 'sms') $$, :'tenant_b'), 'FORBIDDEN', 'nor re-subscribe another school''s opted-out numbers');
select throws_ok(format($$ select public.process_wa_inbound_message(%L, '03001110002', 'hello') $$, :'tenant_b'), 'FORBIDDEN', 'nor inject an inbound WhatsApp message into it');
select throws_ok(format($$ select public.seed_default_comm_policy(%L) $$, :'tenant_b'), 'FORBIDDEN', 'nor change its messaging policy');
select lives_ok(format($$ select public.process_wa_inbound_message(%L, '03001110001', 'hello') $$, :'tenant_a'), 'own school''s inbound message is accepted');

select is((select count(*)::int from public.claim_message_batch(:'worker_id'::uuid, 500)), 1, 'claiming the queue gets only the school''s own messages');
select throws_ok(format($$ select * from public.claim_message_batch(%L, 500, %L) $$, :'worker_id', :'tenant_b'), 'FORBIDDEN', 'even when it asks for another school''s by name');

select lives_ok(format($$ select public.publish_circular(%L) $$, :'circular_a'), 'staff can publish their own circular');
select throws_ok(format($$ select public.publish_circular(%L) $$, :'circular_b'), 'FORBIDDEN', 'but not another school''s');
select throws_ok(format($$ select public.unpublish_circular(%L) $$, :'circular_b'), 'FORBIDDEN', 'nor take it down');
select throws_ok(format($$ select * from public.resolve_segment(%L) $$, :'segment_b'), 'FORBIDDEN', 'nor read another school''s audience, guardian numbers and dues');
select throws_ok(format($$ select public.sync_wa_template_status(%L, 'APPROVED') $$, :'template_b'), 'FORBIDDEN', 'nor approve another school''s WhatsApp template');
select throws_like(format($$ select public.publish_circular(%L) $$, gen_random_uuid()), 'CIRCULAR_NOT_FOUND%', 'a record that does not exist is still reported as not found');
reset role;

select is((select count(*)::int from public.message where tenant_id = :'tenant_b' and status = 'queued'), 2, 'school B''s queue was left alone');
select is((select status from public.circular where id = :'circular_b'), 'draft', 'and school B''s circular is still a draft');

-- ── a parent of school A ─────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', gen_random_uuid(), 'tenant_id', :'tenant_a', 'app_role', 'parent')::text, true);
select throws_ok(format($$ select public.top_up_comm_wallet(%L, 1) $$, :'tenant_a'), 'FORBIDDEN', 'a parent cannot top up the wallet');
select throws_ok(format($$ select * from public.claim_message_batch(%L, 10) $$, :'worker_id'), 'FORBIDDEN', 'cannot claim the outbound queue');
select throws_ok(format($$ select public.publish_circular(%L) $$, :'circular_a'), 'FORBIDDEN', 'and cannot publish a circular');
reset role;

-- ── a signed-in user who belongs to no school ────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', gen_random_uuid())::text, true);
select throws_ok(format($$ select public.top_up_comm_wallet(%L, 1) $$, :'tenant_a'), 'FORBIDDEN', 'a signed-in user with no school cannot top up a wallet');
select throws_ok(format($$ select * from public.claim_message_batch(%L, 10) $$, :'worker_id'), 'FORBIDDEN', 'or claim the queue by leaving the tenant out');
reset role;

-- ── the server side is unchanged ─────────────────────────────────────────────
select set_config('request.jwt.claims', '', true);
select is((select count(*)::int from public.claim_message_batch(:'worker_id'::uuid, 500)), 2, 'a direct database session still sees every school''s queue (school B''s two messages remain)');
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
select lives_ok(format($$ select public.top_up_comm_wallet(%L, 100) $$, :'tenant_b'), 'the service role can still top up any school');
select lives_ok(format($$ select public.publish_circular(%L) $$, :'circular_b'), 'and publish any school''s circular');
select set_config('request.jwt.claims', '', true);
select is(
  (select balance_paisa from public.tenant_comm_wallet where tenant_id = :'tenant_a'), 5000::bigint,
  'school A''s wallet holds only its own top-up'
);

select * from finish();
rollback;
