-- The messaging engine is no longer open to anyone who holds the public API key.
--
-- About sixty SECURITY DEFINER functions in the communication module (wallet top-up and debit,
-- the outbound queue claim, delivery receipts, opt-out resubscribe, circular publishing, template
-- status, audience resolvers, the trigger and campaign runners) were executable by the signed-out
-- anon role and by every signed-in user of every school, and none of them checked who was asking
-- or whose data it was. Anyone with the public key could claim every school's queued messages
-- (recipient numbers and text included), top up or drain a school's messaging wallet, forge
-- delivery receipts and inbound WhatsApp messages, re-subscribe numbers that had opted out, and
-- publish another school's circular.
--
-- Three things change:
--  1. Nothing here is callable signed out any more. The public pages (admission form, invitation
--     and certificate checks, OTP and login lockouts) keep the grants they were given on purpose.
--  2. Functions that only the worker, the webhooks or other functions ever call are service-role
--     only. The app calls them through the service client or from inside other SECURITY DEFINER
--     functions, which run as the owner and are unaffected.
--  3. The ones staff run from the Communication screens stay open to signed-in users but now check
--     the tenant: a school session can only act on its own tenant (an omitted tenant, which used
--     to mean "every school", now means "mine"), parents and students cannot use them at all, and
--     the service role, cron and direct database sessions are unchanged.
-- Helpers that other functions call on a parent's behalf (templates, quiet hours, ticket numbers)
-- are not given a caller check of their own; they only lose the signed-out grant.

create or replace function app.fn_comm_scope_tenant(p_tenant_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_caller uuid := app.auth_tenant_id();
begin
  if v_caller is not null then
    if app.auth_role() in ('parent', 'student', 'none') or (p_tenant_id is not null and p_tenant_id <> v_caller) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    return v_caller;
  end if;
  -- No school session: only the service role, cron and direct database connections get through.
  if coalesce(auth.role(), '') = 'service_role'
     or (coalesce(auth.role(), '') = '' and session_user in ('postgres', 'supabase_admin')) then
    return p_tenant_id;
  end if;
  raise exception 'FORBIDDEN' using errcode = '42501';
end;
$$;

create or replace function app.fn_comm_assert_tenant(p_record_tenant_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  -- A record that does not exist has no tenant; the function being guarded reports that itself.
  if p_record_tenant_id is null then
    return;
  end if;
  perform app.fn_comm_scope_tenant(p_record_tenant_id);
end;
$$;

revoke all on function app.fn_comm_scope_tenant(uuid) from public, anon, authenticated;
revoke all on function app.fn_comm_assert_tenant(uuid) from public, anon, authenticated;

-- public.claim_message_batch
create or replace function public.claim_message_batch(p_worker_id uuid, p_limit integer default 50, p_tenant_id uuid default null::uuid, p_channel public.comm_channel default null::public.comm_channel)
 returns SETOF public.message
 language plpgsql
 security definer
 set search_path = 'public'
as $function$
declare
  v_limit int := coalesce(p_limit, 50);
begin
  p_tenant_id := app.fn_comm_scope_tenant(p_tenant_id);
  if v_limit < 1 then
    v_limit := 1;
  elsif v_limit > 500 then
    v_limit := 500;
  end if;

  return query
  with locked_messages as (
    select id
    from public.message
    where status = 'queued'
      and scheduled_at <= clock_timestamp()
      and (p_tenant_id is null or tenant_id = p_tenant_id)
      and (p_channel is null or channel = p_channel)
    order by scheduled_at asc, id asc
    limit v_limit
    for update skip locked
  )
  update public.message m
  set status = 'claimed',
      claimed_at = clock_timestamp(),
      claimed_by = p_worker_id,
      updated_at = clock_timestamp()
  from locked_messages lm
  where m.id = lm.id
  returning m.*;
end;
$function$;

-- public.expire_stale_attempts
create or replace function public.expire_stale_attempts(p_tenant_id uuid default null::uuid, p_cutoff_interval interval default '24:00:00'::interval)
 returns TABLE(expired_count integer, expired_attempt_ids uuid[])
 language plpgsql
 security definer
 set search_path = 'public', 'pg_temp'
as $function$
declare
  v_ids uuid[];
  v_count int := 0;
begin
  p_tenant_id := app.fn_comm_scope_tenant(p_tenant_id);
  select coalesce(array_agg(ma.id), '{}')
  into v_ids
  from public.message_attempt ma
  join public.message m on m.id = ma.message_id
  where (p_tenant_id is null or m.tenant_id = p_tenant_id)
    and ma.status in ('sent'::public.attempt_status, 'sending'::public.attempt_status, 'submitted'::public.attempt_status)
    and ma.dispatched_at <= (clock_timestamp() - p_cutoff_interval);

  v_count := array_length(v_ids, 1);
  if v_count is null then
    v_count := 0;
  end if;

  if v_count > 0 then
    -- Mark attempts expired
    update public.message_attempt
    set
      status = 'expired'::public.attempt_status,
      completed_at = clock_timestamp(),
      error_message = 'EXPIRED_NO_DLR_AFTER_24H'
    where id = any(v_ids);

    -- Also update parent messages whose active attempts expired
    update public.message m
    set
      status = 'expired'::public.message_status,
      final_status = 'expired'::public.message_status,
      updated_at = clock_timestamp()
    where m.id in (
      select message_id from public.message_attempt where id = any(v_ids)
    ) and m.status in ('queued'::public.message_status, 'claimed'::public.message_status, 'sending'::public.message_status, 'sent'::public.message_status);
  end if;

  return query select v_count, v_ids;
end;
$function$;

-- public.escalate_timed_out_attempts
create or replace function public.escalate_timed_out_attempts(p_tenant_id uuid default null::uuid)
 returns TABLE(message_id uuid, timed_out_attempt_id uuid, new_attempt_id uuid, escalated_to_channel public.comm_channel)
 language plpgsql
 security definer
 set search_path = 'public'
as $function$
declare
  v_rec record;
  v_chain public.comm_channel[];
  v_wait jsonb;
  v_timeout_sec int;
  v_new_att uuid;
  v_new_ch public.comm_channel;
begin
  p_tenant_id := app.fn_comm_scope_tenant(p_tenant_id);
  for v_rec in
    select a.id as attempt_id,
           a.message_id,
           a.channel,
           a.dispatched_at,
           m.tenant_id,
           m.message_class
    from public.message_attempt a
    join public.message m on m.id = a.message_id
    where a.status = 'sent'
      and m.status not in ('delivered', 'exhausted', 'cancelled')
      and (p_tenant_id is null or m.tenant_id = p_tenant_id)
      -- only consider the latest attempt for the message
      and a.attempt_number = (
        select max(sub.attempt_number)
        from public.message_attempt sub
        where sub.message_id = a.message_id
      )
  loop
    select ordered_channels, wait_seconds
    into v_chain, v_wait
    from public.get_channel_chain(v_rec.tenant_id, v_rec.message_class);

    v_timeout_sec := coalesce((v_wait->>v_rec.channel::text)::int, 900);

    if clock_timestamp() - v_rec.dispatched_at >= make_interval(secs => v_timeout_sec) then
      -- Mark this attempt as timed out
      update public.message_attempt
      set status = 'timeout',
          error_code = 'DELIVERY_RECEIPT_TIMEOUT',
          error_message = format('No delivery receipt received within %s seconds', v_timeout_sec),
          completed_at = clock_timestamp()
      where id = v_rec.attempt_id;

      -- Fire fallback escalation
      v_new_att := public.escalate_message(v_rec.message_id, v_rec.attempt_id, 'timeout_window_elapsed');

      if v_new_att is not null then
        select channel into v_new_ch from public.message_attempt where id = v_new_att;
      else
        v_new_ch := null;
      end if;

      message_id := v_rec.message_id;
      timed_out_attempt_id := v_rec.attempt_id;
      new_attempt_id := v_new_att;
      escalated_to_channel := v_new_ch;
      return next;
    end if;
  end loop;
end;
$function$;

-- public.evaluate_date_based_rules
create or replace function public.evaluate_date_based_rules(p_run_date date default current_date, p_tenant_id uuid default null::uuid)
 returns TABLE(rule_id uuid, rule_name text, event_type text, new_fires_count integer, cancelled_count integer)
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_rule           record;
  v_day_offset     integer;
  v_target_due     date;
  v_challan        record;
  v_inserted_fires integer;
  v_cancelled      integer;
  v_fire_key       text;
begin
  p_tenant_id := app.fn_comm_scope_tenant(p_tenant_id);
  for v_rule in
    select r.*
    from public.comm_trigger_rule r
    where (p_tenant_id is null or r.tenant_id = p_tenant_id)
      and r.is_enabled = true
      and r.event_type = 'fee_challan_overdue'
  loop
    v_inserted_fires := 0;
    v_cancelled := 0;

    -- Evaluate each configured day offset in condition->'days_overdue' (e.g. [1, 7, 15])
    for v_day_offset in
      select (jsonb_array_elements_text(coalesce(v_rule.condition->'days_overdue', '["1", "7", "15"]'::jsonb)))::integer
    loop
      v_target_due := p_run_date - v_day_offset;
      v_fire_key := 'D+' || v_day_offset || ':' || p_run_date::text;

      -- 1. Find unpaid or part_paid challans due on target date
      for v_challan in
        select c.id, c.tenant_id, c.enrolment_id, c.student_id, c.challan_no, c.net_paisa
        from public.fee_challan c
        where c.tenant_id = v_rule.tenant_id
          and (v_rule.campus_id is null or c.campus_id = v_rule.campus_id)
          and c.due_date = v_target_due
          and c.status in ('unpaid', 'part_paid')
          and c.deleted_at is null
      loop
        -- Insert fire record with unique constraint deduplication
        insert into public.comm_trigger_fire (
          tenant_id, rule_id, entity_id, fire_key, status, metadata
        ) values (
          v_rule.tenant_id,
          v_rule.id,
          v_challan.id,
          v_fire_key,
          'pending',
          jsonb_build_object(
            'challan_id', v_challan.id,
            'challan_no', v_challan.challan_no,
            'due_date', v_target_due,
            'day_offset', v_day_offset,
            'evaluation_date', p_run_date,
            'enrolment_id', v_challan.enrolment_id,
            'student_id', v_challan.student_id
          )
        )
        on conflict (rule_id, entity_id, fire_key) do nothing;

        if found then
          v_inserted_fires := v_inserted_fires + 1;
        end if;
      end loop;
    end loop;

    -- 2. AC 2: Cancel any pending fires for challans that have since been paid
    with cancelled_rows as (
      update public.comm_trigger_fire f
      set status = 'cancelled',
          skip_reason = 'Payment received prior to dispatch'
      from public.fee_challan fc
      where f.rule_id = v_rule.id
        and f.status = 'pending'
        and f.entity_id = fc.id
        and fc.status in ('paid', 'cancelled')
      returning f.id
    )
    select count(*) into v_cancelled from cancelled_rows;

    -- Update last_evaluated_at on the rule
    update public.comm_trigger_rule
    set last_evaluated_at = clock_timestamp(), updated_at = clock_timestamp()
    where id = v_rule.id;

    rule_id := v_rule.id;
    rule_name := v_rule.name;
    event_type := v_rule.event_type;
    new_fires_count := v_inserted_fires;
    cancelled_count := v_cancelled;
    return next;
  end loop;
end;
$function$;

-- public.evaluate_scheduled_campaigns
create or replace function public.evaluate_scheduled_campaigns(p_tenant_id uuid default null::uuid, p_as_of timestamp with time zone default clock_timestamp())
 returns TABLE(campaign_id uuid, title text, previous_status text, new_status text, deferred_until_out timestamp with time zone, notes text)
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_rec record;
  v_is_quiet boolean;
  v_next_end timestamptz;
begin
  p_tenant_id := app.fn_comm_scope_tenant(p_tenant_id);
  for v_rec in
    select c.*
    from public.message_campaign c
    where (p_tenant_id is null or c.tenant_id = p_tenant_id)
      and c.status in ('scheduled', 'deferred_quiet_hours')
      and (
        (c.status = 'scheduled' and c.scheduled_at <= p_as_of)
        or (c.status = 'deferred_quiet_hours' and coalesce(c.deferred_until, c.scheduled_at) <= p_as_of)
      )
    order by c.scheduled_at asc
  loop
    v_is_quiet := public.is_quiet_now(v_rec.tenant_id, p_as_of);

    if v_rec.is_emergency then
      -- Emergency always dispatches immediately
      update public.message_campaign
      set status = 'dispatching', updated_at = clock_timestamp()
      where id = v_rec.id;

      campaign_id := v_rec.id;
      title := v_rec.title;
      previous_status := v_rec.status;
      new_status := 'dispatching';
      deferred_until_out := null;
      notes := 'Emergency campaign dispatched immediately via authorized bypass';
      return next;

    elsif v_rec.status = 'scheduled' and v_is_quiet then
      -- Scheduled for 22:30 PKT -> Deferred to 08:00 next morning (AC 1)
      v_next_end := public.get_next_quiet_window_end(v_rec.tenant_id, p_as_of);

      update public.message_campaign
      set status = 'deferred_quiet_hours',
          deferred_until = v_next_end,
          updated_at = clock_timestamp()
      where id = v_rec.id;

      campaign_id := v_rec.id;
      title := v_rec.title;
      previous_status := 'scheduled';
      new_status := 'deferred_quiet_hours';
      deferred_until_out := v_next_end;
      notes := 'Quiet hours active: deferred send until 08:00 next morning';
      return next;

    elsif v_rec.status = 'deferred_quiet_hours' and not v_is_quiet then
      -- Resumption reached at 08:00: dispatching
      update public.message_campaign
      set status = 'dispatching', updated_at = clock_timestamp()
      where id = v_rec.id;

      campaign_id := v_rec.id;
      title := v_rec.title;
      previous_status := 'deferred_quiet_hours';
      new_status := 'dispatching';
      deferred_until_out := null;
      notes := 'Quiet hours window ended; dispatching deferred campaign';
      return next;

    elsif v_rec.status = 'scheduled' and not v_is_quiet then
      -- Normal dispatch outside quiet hours
      update public.message_campaign
      set status = 'dispatching', updated_at = clock_timestamp()
      where id = v_rec.id;

      campaign_id := v_rec.id;
      title := v_rec.title;
      previous_status := 'scheduled';
      new_status := 'dispatching';
      deferred_until_out := null;
      notes := 'Normal daytime schedule reached; dispatching campaign';
      return next;
    end if;
  end loop;
end;
$function$;

-- public.process_pending_trigger_fires
create or replace function public.process_pending_trigger_fires(p_tenant_id uuid default null::uuid, p_limit integer default 200)
 returns TABLE(fire_id uuid, rule_id uuid, entity_id uuid, fire_key text, status text, enqueued_message_id uuid)
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_fire          record;
  v_rule          record;
  v_phone         text;
  v_student_name  text;
  v_msg_body      text;
  v_msg_id        uuid;
  v_student_id    uuid;
  v_enrolment_id  uuid;
begin
  p_tenant_id := app.fn_comm_scope_tenant(p_tenant_id);
  for v_fire in
    select f.*
    from public.comm_trigger_fire f
    where (p_tenant_id is null or f.tenant_id = p_tenant_id)
      and f.status = 'pending'
    order by f.fired_at asc
    limit p_limit
    for update skip locked
  loop
    select * into v_rule
    from public.comm_trigger_rule
    where id = v_fire.rule_id;

    v_phone := null;
    v_student_name := 'Student';
    v_msg_body := null;

    -- Case A: Absence Event
    if v_rule.event_type = 'attendance_absent' then
      v_enrolment_id := v_fire.entity_id;

      select
        s.id,
        coalesce(s.name_en, 'Student'),
        coalesce(g.phone_e164, g.alt_phone, '03001234567')
      into v_student_id, v_student_name, v_phone
      from public.enrolment e
      join public.student s on s.id = e.student_id
      left join public.student_guardian sg on sg.student_id = s.id and sg.is_primary = true
      left join public.guardian g on g.id = sg.guardian_id
      where e.id = v_enrolment_id;

      v_msg_body := format(
        'Dear Parent, your child %s was marked absent today (%s). Please contact the school office if unexcused.',
        v_student_name,
        coalesce(v_fire.metadata->>'attendance_date', current_date::text)
      );

    -- Case B: Overdue Fee Challan
    elsif v_rule.event_type = 'fee_challan_overdue' then
      select
        s.id,
        coalesce(s.name_en, 'Student'),
        coalesce(g.phone_e164, g.alt_phone, '03001234567'),
        fc.challan_no,
        round(coalesce(fc.net_paisa, 0) / 100.0, 2)
      into v_student_id, v_student_name, v_phone
      from public.fee_challan fc
      left join public.student s on s.id = fc.student_id
      left join public.student_guardian sg on sg.student_id = s.id and sg.is_primary = true
      left join public.guardian g on g.id = sg.guardian_id
      where fc.id = v_fire.entity_id;

      v_msg_body := format(
        'Fee Reminder: Payment for challan %s (%s) is overdue. Please settle arrears promptly to avoid late surcharge.',
        coalesce(v_fire.metadata->>'challan_no', 'CHL'),
        v_student_name
      );
    else
      v_phone := '03001234567';
      v_msg_body := format('Automated Notification: %s', v_rule.name);
    end if;

    -- Enqueue message into public.message outbox
    insert into public.message (
      tenant_id,
      campus_id,
      recipient_id,
      recipient_phone,
      channel,
      body,
      status,
      idempotency_key,
      template_id,
      metadata
    ) values (
      v_fire.tenant_id,
      v_rule.campus_id,
      v_student_id,
      coalesce(v_phone, '03001234567'),
      v_rule.channel::public.comm_channel,
      v_msg_body,
      'queued',
      v_fire.rule_id || ':' || v_fire.entity_id || ':' || v_fire.fire_key,
      v_rule.template_id,
      jsonb_build_object(
        'trigger_fire_id', v_fire.id,
        'rule_name', v_rule.name,
        'event_type', v_rule.event_type,
        'fire_key', v_fire.fire_key
      )
    )
    returning id into v_msg_id;

    -- Update trigger fire status to enqueued
    update public.comm_trigger_fire
    set status = 'enqueued',
        enqueued_message_id = v_msg_id,
        enqueued_at = clock_timestamp()
    where id = v_fire.id;

    fire_id := v_fire.id;
    rule_id := v_fire.rule_id;
    entity_id := v_fire.entity_id;
    fire_key := v_fire.fire_key;
    status := 'enqueued';
    enqueued_message_id := v_msg_id;
    return next;
  end loop;
end;
$function$;

-- public.top_up_comm_wallet
create or replace function public.top_up_comm_wallet(p_tenant_id uuid, p_paisa bigint, p_reference text default 'Prepaid credit top-up'::text, p_metadata jsonb default '{}'::jsonb)
 returns bigint
 language plpgsql
 security definer
 set search_path = 'public', 'pg_temp'
as $function$
declare
  v_new_balance bigint;
begin
  p_tenant_id := app.fn_comm_scope_tenant(p_tenant_id);
  if p_paisa <= 0 then
    raise exception 'TOPUP_AMOUNT_MUST_BE_POSITIVE';
  end if;

  insert into public.tenant_comm_wallet (tenant_id, balance_paisa, updated_at)
  values (p_tenant_id, p_paisa, clock_timestamp())
  on conflict (tenant_id) do update
  set balance_paisa = public.tenant_comm_wallet.balance_paisa + excluded.balance_paisa,
      updated_at = clock_timestamp()
  returning balance_paisa into v_new_balance;

  insert into public.tenant_comm_wallet_txn (
    tenant_id, txn_type, amount_paisa, balance_after_paisa, reference, metadata
  ) values (
    p_tenant_id, 'top_up', p_paisa, v_new_balance, p_reference, p_metadata
  );

  return v_new_balance;
end;
$function$;

-- public.resubscribe_recipient
create or replace function public.resubscribe_recipient(p_tenant_id uuid, p_phone text, p_channel public.comm_channel, p_actor_id uuid default null::uuid, p_reason text default 'Parent portal toggle'::text)
 returns boolean
 language plpgsql
 security definer
 set search_path = 'public', 'pg_temp'
as $function$
begin
  p_tenant_id := app.fn_comm_scope_tenant(p_tenant_id);
  -- Delete from suppression table
  delete from public.comm_opt_out
  where tenant_id = p_tenant_id
    and recipient_phone = p_phone
    and channel = p_channel;

  -- Audit log
  insert into public.comm_opt_out_audit (
    tenant_id,
    recipient_phone,
    channel,
    action,
    actor_id,
    reason,
    created_at
  ) values (
    p_tenant_id,
    p_phone,
    p_channel,
    'resubscribe',
    p_actor_id,
    p_reason,
    clock_timestamp()
  );

  return true;
end;
$function$;

-- public.process_wa_inbound_message
create or replace function public.process_wa_inbound_message(p_tenant_id uuid, p_msisdn text, p_body text default null::text, p_wam_id text default null::text, p_received_at timestamp with time zone default null::timestamp with time zone)
 returns uuid
 language plpgsql
 security definer
 set search_path = 'public'
as $function$
declare
  v_norm_phone text := trim(p_msisdn);
  v_inbound_id uuid;
  v_recv_at timestamptz := coalesce(p_received_at, clock_timestamp());
begin
  p_tenant_id := app.fn_comm_scope_tenant(p_tenant_id);
  insert into public.wa_inbound_message (
    tenant_id, msisdn, wam_id, body, received_at
  ) values (
    p_tenant_id, v_norm_phone, p_wam_id, p_body, v_recv_at
  ) returning id into v_inbound_id;

  -- Open or renew the 24-hour customer service session window
  insert into public.wa_session_window (
    tenant_id, msisdn, window_opened_at, window_expires_at, last_inbound_id, updated_at
  ) values (
    p_tenant_id, v_norm_phone, v_recv_at, v_recv_at + interval '24 hours', v_inbound_id, clock_timestamp()
  )
  on conflict (tenant_id, msisdn) do update set
    window_opened_at = excluded.window_opened_at,
    window_expires_at = excluded.window_expires_at,
    last_inbound_id = excluded.last_inbound_id,
    updated_at = clock_timestamp();

  return v_inbound_id;
end;
$function$;

-- public.seed_default_comm_policy
create or replace function public.seed_default_comm_policy(p_tenant_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_id uuid;
begin
  p_tenant_id := app.fn_comm_scope_tenant(p_tenant_id);
  insert into public.tenant_comm_policy (
    tenant_id, quiet_start, quiet_end, timezone, emergency_bypass_role
  ) values (
    p_tenant_id, '21:00:00', '08:00:00', 'Asia/Karachi', 'principal'
  )
  on conflict (tenant_id) do update
    set updated_at = now()
  returning id into v_id;

  return v_id;
end;
$function$;

-- public.seed_default_segments
create or replace function public.seed_default_segments(p_tenant_id uuid, p_campus_id uuid default null::uuid)
 returns void
 language plpgsql
 security definer
 set search_path = 'public'
as $function$
begin
  p_tenant_id := app.fn_comm_scope_tenant(p_tenant_id);
  -- 1. Fee Defaulters (> PKR 5,000)
  insert into public.message_segment (
    tenant_id, campus_id, name, description, segment_type, definition
  ) values (
    p_tenant_id, p_campus_id,
    'Fee Defaulters (> PKR 5,000)',
    'Active students with outstanding fees over PKR 5,000, excluding approved hardship waivers.',
    'defaulters',
    '{"min_dues_pkr": 5000, "exclude_hardship": true}'::jsonb
  ) on conflict (tenant_id, campus_id, name) do nothing;

  -- 2. Unexcused Absentees Today (with 11:00 cutoff)
  insert into public.message_segment (
    tenant_id, campus_id, name, description, segment_type, definition
  ) values (
    p_tenant_id, p_campus_id,
    'Unexcused Absentees Today',
    'Students marked absent for the day. Evaluated after the 11:00 PKT morning register cutoff.',
    'absent_today',
    '{"status": "absent", "cutoff_time": "11:00:00", "enforce_cutoff": false}'::jsonb
  ) on conflict (tenant_id, campus_id, name) do nothing;

  -- 3. High Dues Escalation (> PKR 15,000)
  insert into public.message_segment (
    tenant_id, campus_id, name, description, segment_type, definition
  ) values (
    p_tenant_id, p_campus_id,
    'High Dues Escalation (> PKR 15,000)',
    'Critical fee defaulters exceeding PKR 15,000 for bursar priority outreach.',
    'defaulters',
    '{"min_dues_pkr": 15000, "exclude_hardship": true}'::jsonb
  ) on conflict (tenant_id, campus_id, name) do nothing;
end;
$function$;

-- public.seed_default_trigger_rules
create or replace function public.seed_default_trigger_rules(p_tenant_id uuid, p_campus_id uuid default null::uuid)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
begin
  p_tenant_id := app.fn_comm_scope_tenant(p_tenant_id);
  -- 1. Daily Absence Alert Rule
  insert into public.comm_trigger_rule (
    tenant_id, campus_id, name, description, event_type, condition, channel, is_enabled
  ) values (
    p_tenant_id,
    p_campus_id,
    'Daily Absence Alert (SMS)',
    'Automatically sends an SMS notice to primary guardian when student is marked absent.',
    'attendance_absent',
    jsonb_build_object('status', 'absent'),
    'sms',
    true
  )
  on conflict do nothing;

  -- 2. Fee Challan Overdue Reminders (D+1, D+7, D+15)
  insert into public.comm_trigger_rule (
    tenant_id, campus_id, name, description, event_type, condition, channel, is_enabled
  ) values (
    p_tenant_id,
    p_campus_id,
    'Fee Overdue Escalation (D+1, D+7, D+15)',
    'Automated reminders dispatched on day 1, 7, and 15 past challan due date.',
    'fee_challan_overdue',
    jsonb_build_object('days_overdue', jsonb_build_array(1, 7, 15)),
    'sms',
    true
  )
  on conflict do nothing;
end;
$function$;

-- public.seed_default_versioned_templates
create or replace function public.seed_default_versioned_templates(p_tenant_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path = 'public'
as $function$
declare
  v_tmpl_id uuid;
  v_v1_id uuid;
begin
  p_tenant_id := app.fn_comm_scope_tenant(p_tenant_id);
  -- 1. Student Absence Alert
  insert into public.message_template (tenant_id, name, audience_entity, category, description, is_active)
  values (
    p_tenant_id,
    'Student Absence Alert',
    'guardian',
    'attendance',
    'Automated notification sent to parents when a student is marked absent.',
    true
  )
  returning id into v_tmpl_id;

  insert into public.message_template_version (
    template_id, version_no, message_class, body_en, body_ur, sms_encoding, is_published, published_at, change_summary
  ) values (
    v_tmpl_id,
    1,
    'transactional',
    'Dear Guardian, {{student_name}} (Roll No: {{roll_no}}) of {{grade_level}} - {{section_name}} was marked absent on {{attendance_date}}. If this was unexpected, please contact {{campus_name}}.',
    'محترم والدین، آپ کے بچے {{student_name}} (رول نمبر: {{roll_no}}) جماعت {{grade_level}} - {{section_name}} کو بتاریخ {{attendance_date}} غیر حاضر شمار کیا گیا ہے۔ معلومات کے لیے {{campus_name}} سے رابطہ فرمائیں۔',
    'auto',
    true,
    clock_timestamp(),
    'Initial published version'
  );

  -- 2. Monthly Fee Challan Due Notice
  insert into public.message_template (tenant_id, name, audience_entity, category, description, is_active)
  values (
    p_tenant_id,
    'Monthly Fee Challan Due Notice',
    'guardian',
    'fee',
    'Billing reminder containing invoice number, amount, and due date.',
    true
  )
  returning id into v_tmpl_id;

  insert into public.message_template_version (
    template_id, version_no, message_class, body_en, body_ur, sms_encoding, is_published, published_at, change_summary
  ) values (
    v_tmpl_id,
    1,
    'transactional',
    'Dear Guardian, Fee Challan {{challan_no}} for {{student_name}} amounting to {{amount_due}} for {{fee_month}} is due on {{due_date}}. Please pay before the due date to avoid late charges. Portal: {{portal_link}}',
    'محترم والدین، {{student_name}} کا فیس چالان {{challan_no}} برائے {{fee_month}} بمبلغ {{amount_due}} واجب الادا ہے۔ آخری تاریخ {{due_date}} ہے۔ برائے مہربانی بروقت ادا فرمائیں۔ رابطہ: {{portal_link}}',
    'auto',
    true,
    clock_timestamp(),
    'Initial published version'
  );

  -- 3. General Circular Notice
  insert into public.message_template (tenant_id, name, audience_entity, category, description, is_active)
  values (
    p_tenant_id,
    'Campus General Notice',
    'guardian',
    'general',
    'Standard notification for circulars, events, and school notices.',
    true
  )
  returning id into v_tmpl_id;

  insert into public.message_template_version (
    template_id, version_no, message_class, body_en, body_ur, sms_encoding, is_published, published_at, change_summary
  ) values (
    v_tmpl_id,
    1,
    'transactional',
    'Dear Guardian, important announcement from {{campus_name}} regarding {{notice_title}} on {{date}}. Please check the portal or contact {{school_phone}} for queries.',
    'محترم والدین، {{campus_name}} کی طرف سے {{notice_title}} بتاریخ {{date}} کے حوالے سے اہم اطلاع۔ مزید معلومات کے لیے {{school_phone}} پر رابطہ کریں۔',
    'auto',
    true,
    clock_timestamp(),
    'Initial published version'
  );
end;
$function$;

-- public.seed_default_wa_templates
create or replace function public.seed_default_wa_templates(p_tenant_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path = 'public'
as $function$
begin
  p_tenant_id := app.fn_comm_scope_tenant(p_tenant_id);
  insert into public.wa_template (
    tenant_id, meta_template_name, category, status, body_text
  ) values (
    p_tenant_id,
    'student_absence_v1',
    'UTILITY',
    'APPROVED',
    'Dear Parent, {{1}} was marked absent on {{2}}. Please contact {{3}} for queries.'
  ) on conflict (tenant_id, meta_template_name, language) do nothing;

  insert into public.wa_template (
    tenant_id, meta_template_name, category, status, body_text
  ) values (
    p_tenant_id,
    'monthly_challan_v1',
    'UTILITY',
    'APPROVED',
    'Dear Parent, fee challan {{1}} for {{2}} is due on {{3}}. Amount: {{4}}.'
  ) on conflict (tenant_id, meta_template_name, language) do nothing;

  insert into public.wa_template (
    tenant_id, meta_template_name, category, status, body_text
  ) values (
    p_tenant_id,
    'sports_gala_draft_v1',
    'MARKETING',
    'PENDING',
    'Join us for the Annual Sports Gala on {{1}}.'
  ) on conflict (tenant_id, meta_template_name, language) do nothing;

  insert into public.wa_template (
    tenant_id, meta_template_name, category, status, body_text, rejection_reason
  ) values (
    p_tenant_id,
    'commercial_discount_v1',
    'MARKETING',
    'REJECTED',
    'Get 50% discount on summer camp registration.',
    'Violates Meta Commerce Policy section 4.3 (Misleading commercial claims)'
  ) on conflict (tenant_id, meta_template_name, language) do nothing;
end;
$function$;

-- public.publish_circular
create or replace function public.publish_circular(p_circular_id uuid, p_publish_at timestamp with time zone default clock_timestamp())
 returns public.circular
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_circ public.circular;
begin
  perform app.fn_comm_assert_tenant((select c.tenant_id from public.circular c where c.id = p_circular_id));
  update public.circular
  set
    status = 'published',
    publish_at = coalesce(p_publish_at, clock_timestamp()),
    updated_at = clock_timestamp()
  where id = p_circular_id
  returning * into v_circ;

  if not found then
    raise exception 'CIRCULAR_NOT_FOUND: Circular % does not exist', p_circular_id using errcode = 'P0002';
  end if;

  return v_circ;
end;
$function$;

-- public.unpublish_circular
create or replace function public.unpublish_circular(p_circular_id uuid)
 returns public.circular
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_circ public.circular;
begin
  perform app.fn_comm_assert_tenant((select c.tenant_id from public.circular c where c.id = p_circular_id));
  update public.circular
  set
    status = 'unpublished',
    updated_at = clock_timestamp()
  where id = p_circular_id
  returning * into v_circ;

  if not found then
    raise exception 'CIRCULAR_NOT_FOUND: Circular % does not exist', p_circular_id using errcode = 'P0002';
  end if;

  return v_circ;
end;
$function$;

-- public.export_circular_unread_segment
create or replace function public.export_circular_unread_segment(p_circular_id uuid, p_segment_name text)
 returns uuid
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_circ record;
  v_segment_id uuid;
begin
  perform app.fn_comm_assert_tenant((select c.tenant_id from public.circular c where c.id = p_circular_id));
  select * into v_circ
  from public.circular
  where id = p_circular_id;

  if not found then
    raise exception 'CIRCULAR_NOT_FOUND: Circular % does not exist', p_circular_id
      using errcode = 'P0002';
  end if;

  insert into public.message_segment (
    tenant_id,
    campus_id,
    name,
    description,
    segment_type,
    definition,
    is_active
  )
  values (
    v_circ.tenant_id,
    v_circ.campus_id,
    p_segment_name,
    'Unread follow-up for circular: ' || v_circ.title,
    'custom_filter',
    jsonb_build_object(
      'filter_type', 'circular_unread',
      'circular_id', p_circular_id,
      'exported_at', clock_timestamp()
    ),
    true
  )
  returning id into v_segment_id;

  return v_segment_id;
end;
$function$;

-- public.resolve_unknown_attempt
create or replace function public.resolve_unknown_attempt(p_attempt_id uuid, p_resolved_status public.attempt_status, p_provider_ref text default null::text, p_raw_response jsonb default null::jsonb)
 returns public.message_attempt
 language plpgsql
 security definer
 set search_path = 'public'
as $function$
declare
  v_attempt public.message_attempt;
  v_msg_status public.message_status;
begin
  perform app.fn_comm_assert_tenant((select m.tenant_id from public.message_attempt a join public.message m on m.id = a.message_id where a.id = p_attempt_id));
  update public.message_attempt
  set status = p_resolved_status,
      provider_ref = coalesce(p_provider_ref, provider_ref),
      raw_response = coalesce(p_raw_response, raw_response),
      completed_at = clock_timestamp()
  where id = p_attempt_id
  returning * into v_attempt;

  if not found then
    raise exception 'Attempt % not found', p_attempt_id;
  end if;

  v_msg_status := case p_resolved_status
    when 'delivered' then 'delivered'::public.message_status
    when 'sent' then 'sending'::public.message_status
    when 'failed' then 'failed'::public.message_status
    else 'unknown'::public.message_status
  end;

  update public.message
  set status = v_msg_status,
      updated_at = clock_timestamp()
  where id = v_attempt.message_id;

  return v_attempt;
end;
$function$;

-- public.apply_receipt
create or replace function public.apply_receipt(p_attempt_id uuid, p_receipt_status text, p_error_code text default null::text, p_raw_response jsonb default null::jsonb)
 returns public.attempt_status
 language plpgsql
 security definer
 set search_path = 'public'
as $function$
declare
  v_att record;
  v_mapped_status public.attempt_status;
  v_status_text text := lower(trim(p_receipt_status));
begin
  perform app.fn_comm_assert_tenant((select m.tenant_id from public.message_attempt a join public.message m on m.id = a.message_id where a.id = p_attempt_id));
  select a.id, a.message_id, a.channel, a.status, a.attempt_number, m.status as message_status
  into v_att
  from public.message_attempt a
  join public.message m on m.id = a.message_id
  where a.id = p_attempt_id;

  if not found then
    raise exception 'message_attempt not found: %', p_attempt_id using errcode = 'P0002';
  end if;

  if v_status_text in ('delivered', 'read') then
    v_mapped_status := 'delivered';
  elsif v_status_text in ('undelivered', 'failed') then
    v_mapped_status := 'undelivered';
  elsif v_status_text in ('sent', 'dispatched') then
    v_mapped_status := 'sent';
  else
    v_mapped_status := 'unknown';
  end if;

  -- Update attempt record
  update public.message_attempt
  set status = v_mapped_status,
      error_code = coalesce(p_error_code, error_code),
      raw_response = coalesce(p_raw_response, raw_response),
      completed_at = clock_timestamp()
  where id = p_attempt_id;

  if v_mapped_status = 'delivered' then
    -- Note for AC2: A late delivered receipt arriving after fallback already fired
    -- updates this attempt and marks message delivered, but does NOT cancel or reverse
    -- the escalated SMS attempt.
    update public.message
    set status = 'delivered',
        final_status = 'delivered',
        updated_at = clock_timestamp()
    where id = v_att.message_id;
  elsif v_mapped_status = 'undelivered' then
    -- Immediately trigger fallback escalation to next channel (AC1)
    perform public.escalate_message(v_att.message_id, p_attempt_id, 'undelivered_receipt');
  end if;

  return v_mapped_status;
end;
$function$;

-- public.sync_wa_template_status
create or replace function public.sync_wa_template_status(p_template_id uuid, p_new_status public.wa_template_status, p_rejection_reason text default null::text)
 returns void
 language plpgsql
 security definer
 set search_path = 'public'
as $function$
declare
  v_tmpl record;
  v_paused_count int;
begin
  perform app.fn_comm_assert_tenant((select t.tenant_id from public.wa_template t where t.id = p_template_id));
  select id, tenant_id, meta_template_name, status
  into v_tmpl
  from public.wa_template
  where id = p_template_id;

  if not found then
    raise exception 'WhatsApp template not found: %', p_template_id using errcode = 'P0002';
  end if;

  update public.wa_template
  set status = p_new_status,
      rejection_reason = coalesce(p_rejection_reason, rejection_reason),
      last_synced_at = clock_timestamp(),
      updated_at = clock_timestamp()
  where id = p_template_id;

  -- AC 3: If template transitions to REJECTED or PAUSED, pause scheduled messages/campaigns and alert Principal
  if p_new_status in ('REJECTED', 'PAUSED') and v_tmpl.status = 'APPROVED' then
    -- Pause all queued messages referencing this template
    update public.message
    set status = 'cancelled',
        updated_at = clock_timestamp()
    where wa_template_id = p_template_id
      and status = 'queued';

    get diagnostics v_paused_count = row_count;

    -- Create Principal alert within 1 hour
    insert into public.wa_compliance_alert (
      tenant_id, template_id, alert_type, title, message
    ) values (
      v_tmpl.tenant_id,
      p_template_id,
      'TEMPLATE_REJECTED',
      format('URGENT: WhatsApp Template %s was %s by Meta', v_tmpl.meta_template_name, p_new_status),
      format('Meta transitioned template %s to %s (Reason: %s). %s scheduled message(s) using this template have been safely paused to prevent account suspension.',
        v_tmpl.meta_template_name, p_new_status, coalesce(p_rejection_reason, 'None specified'), v_paused_count)
    );
  end if;
end;
$function$;

-- public.guard_campaign_dispatch
create or replace function public.guard_campaign_dispatch(p_batch_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path = 'public', 'pg_temp'
as $function$
declare
  v_tenant_id uuid;
  v_est_paisa bigint;
  v_balance bigint;
begin
  perform app.fn_comm_assert_tenant((select b.tenant_id from public.message_batch b where b.id = p_batch_id));
  select tenant_id into v_tenant_id
  from public.message_batch
  where id = p_batch_id;

  if v_tenant_id is null then
    raise exception 'CAMPAIGN_NOT_FOUND';
  end if;

  v_est_paisa := public.estimate_campaign_cost(p_batch_id);

  -- Concurrency-safe check with row lock
  select balance_paisa
  into v_balance
  from public.tenant_comm_wallet
  where tenant_id = v_tenant_id
  for update;

  if v_balance is null then
    v_balance := 0;
  end if;

  if v_balance < v_est_paisa then
    raise exception 'INSUFFICIENT_COMM_BALANCE: Campaign requires PKR %, but wallet balance is PKR % (Shortfall: PKR %)',
      to_char(v_est_paisa::numeric / 100, 'FM999,990.00'),
      to_char(v_balance::numeric / 100, 'FM999,990.00'),
      to_char((v_est_paisa - v_balance)::numeric / 100, 'FM999,990.00')
      using errcode = '23514';
  end if;

  return jsonb_build_object(
    'success', true,
    'estimated_paisa', v_est_paisa,
    'balance_before', v_balance
  );
end;
$function$;

-- public.recompute_past_holiday_impact
create or replace function public.recompute_past_holiday_impact(p_event_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_event record;
  v_affected_attendance int := 0;
begin
  perform app.fn_comm_assert_tenant((select e.tenant_id from public.campus_event e where e.id = p_event_id));
  select * into v_event
  from public.campus_event
  where id = p_event_id;

  if not found then
    raise exception 'EVENT_NOT_FOUND: Campus event % does not exist', p_event_id
      using errcode = 'P0002';
  end if;

  if v_event.event_type <> 'holiday' then
    return jsonb_build_object('recomputed', false, 'reason', 'Not a holiday event');
  end if;

  -- Example explicit recompute audit: check past attendance records during the retroactive holiday period
  select count(*) into v_affected_attendance
  from public.attendance_day ad
  where (v_event.campus_id is null or ad.campus_id = v_event.campus_id)
    and ad.attendance_date between v_event.starts_at::date and v_event.ends_at::date;

  return jsonb_build_object(
    'recomputed', true,
    'event_id', p_event_id,
    'starts_at', v_event.starts_at,
    'ends_at', v_event.ends_at,
    'affected_attendance_records', v_affected_attendance,
    'recomputed_at', clock_timestamp()
  );
end;
$function$;

-- public.resolve_segment
create or replace function public.resolve_segment(p_segment_id uuid, p_as_of date default current_date)
 returns TABLE(student_id uuid, enrolment_id uuid, guardian_id uuid, student_name text, gr_number text, guardian_name text, guardian_phone text, dues_pkr numeric, attendance_status text, meta jsonb)
 language plpgsql
 stable security definer
 set search_path = 'public'
as $function$
declare
  v_segment record;
  v_min_dues_paisa bigint;
  v_exclude_hardship boolean;
  v_campus_cutoff time;
  v_cutoff_time time;
  v_enforce_cutoff boolean;
  v_check_time time := clock_timestamp()::time;
  v_circ_id uuid;
begin
  perform app.fn_comm_assert_tenant((select s.tenant_id from public.message_segment s where s.id = p_segment_id));
  select id, tenant_id, campus_id, name, segment_type, definition
  into v_segment
  from public.message_segment
  where id = p_segment_id and is_active = true;

  if not found then
    raise exception 'Segment not found or inactive: %', p_segment_id using errcode = 'P0002';
  end if;

  -- ─── Segment Type: Fee Defaulters (AC 1) ──────────────────────────────────
  if v_segment.segment_type = 'defaulters' then
    v_min_dues_paisa := (coalesce((v_segment.definition->>'min_dues_pkr')::numeric, 5000) * 100)::bigint;
    v_exclude_hardship := coalesce((v_segment.definition->>'exclude_hardship')::boolean, true);

    return query
    select
      s.id as student_id,
      e.id as enrolment_id,
      g.id as guardian_id,
      s.name_en as student_name,
      s.gr_number as gr_number,
      coalesce(g.name_en, 'Parent of ' || s.name_en) as guardian_name,
      coalesce(g.phone_e164, g.alt_phone) as guardian_phone,
      round(o.outstanding_paisa / 100.0, 2) as dues_pkr,
      null::text as attendance_status,
      jsonb_build_object(
        'outstanding_paisa', o.outstanding_paisa,
        'min_dues_pkr', round(v_min_dues_paisa / 100.0, 2),
        'enrolment_roll_no', e.roll_no,
        'has_hardship_waiver', false
      ) as meta
    from public.v_student_outstanding o
    join public.enrolment e on e.id = o.enrolment_id
    join public.student s on s.id = o.student_id
    left join lateral (
      select sg.guardian_id
      from public.student_guardian sg
      where sg.student_id = s.id
      order by sg.is_primary desc, sg.receives_billing desc, sg.priority asc
      limit 1
    ) primary_sg on true
    left join public.guardian g on g.id = primary_sg.guardian_id
    where o.tenant_id = v_segment.tenant_id
      and (v_segment.campus_id is null or o.campus_id = v_segment.campus_id)
      and e.status = 'active'
      and s.status = 'active'
      and o.outstanding_paisa >= v_min_dues_paisa
      and (
        not v_exclude_hardship
        or not exists (
          select 1
          from public.concession_award ca
          left join public.concession_scheme cs on cs.id = ca.scheme_id
          where ca.enrolment_id = e.id
            and ca.status = 'approved'
            and (ca.effective_to is null or ca.effective_to >= p_as_of)
            and (ca.effective_from is null or ca.effective_from <= p_as_of)
            and (
              cs.category = 'hardship'
              or cs.code ilike '%hardship%'
              or cs.name_en ilike '%hardship%'
              or ca.rejection_reason ilike '%hardship%'
            )
        )
      )
      and coalesce(g.phone_e164, g.alt_phone) is not null;

  -- ─── Segment Type: Absent Today with Attendance Lock Cutoff (AC 2) ────────
  elsif v_segment.segment_type = 'absent_today' then
    select attendance_lock_cutoff into v_campus_cutoff
    from public.campus
    where id = v_segment.campus_id;

    v_cutoff_time := coalesce(
      (v_segment.definition->>'cutoff_time')::time,
      v_campus_cutoff,
      '11:00:00'::time
    );

    v_enforce_cutoff := coalesce((v_segment.definition->>'enforce_cutoff')::boolean, true);

    -- If cutoff is enforced and current time is prior to cutoff on today's date,
    -- guard against premature dispatches while teachers are still correcting registers.
    if v_enforce_cutoff and p_as_of = current_date and v_check_time < v_cutoff_time then
      -- Cutoff not reached yet: return empty to prevent sending unconfirmed absentee alerts
      return;
    end if;

    return query
    select
      s.id as student_id,
      e.id as enrolment_id,
      g.id as guardian_id,
      s.name_en as student_name,
      s.gr_number as gr_number,
      coalesce(g.name_en, 'Parent of ' || s.name_en) as guardian_name,
      coalesce(g.phone_e164, g.alt_phone) as guardian_phone,
      0::numeric as dues_pkr,
      ad.status::text as attendance_status,
      jsonb_build_object(
        'attendance_date', ad.attendance_date,
        'marked_at', ad.marked_at,
        'corrected', ad.corrected,
        'attendance_status', ad.status,
        'cutoff_time', v_cutoff_time
      ) as meta
    from public.attendance_day ad
    join public.enrolment e on e.id = ad.enrolment_id
    join public.student s on s.id = e.student_id
    left join lateral (
      select sg.guardian_id
      from public.student_guardian sg
      where sg.student_id = s.id
      order by sg.is_primary desc, sg.receives_academic desc, sg.priority asc
      limit 1
    ) primary_sg on true
    left join public.guardian g on g.id = primary_sg.guardian_id
    where ad.tenant_id = v_segment.tenant_id
      and (v_segment.campus_id is null or ad.campus_id = v_segment.campus_id)
      and ad.attendance_date = p_as_of
      and ad.status = 'absent'
      and e.status = 'active'
      and s.status = 'active'
      and coalesce(g.phone_e164, g.alt_phone) is not null;

  -- ─── Generic / Class Level Segment ────────────────────────────────────────
  -- ─── Segment Type: Circular Unread Export (FR-M13 AC 2) ───────────────────
  elsif v_segment.segment_type = 'custom_filter' and (v_segment.definition->>'filter_type') = 'circular_unread' then
    v_circ_id := (v_segment.definition->>'circular_id')::uuid;

    return query
    select distinct on (ug.guardian_id)
      s.id as student_id,
      e.id as enrolment_id,
      ug.guardian_id,
      s.name_en as student_name,
      s.gr_number as gr_number,
      ug.guardian_name,
      coalesce(ug.phone_e164, ug.alt_phone) as guardian_phone,
      0::numeric as dues_pkr,
      'unread'::text as attendance_status,
      jsonb_build_object('circular_id', v_circ_id, 'reason', 'unread_circular_follow_up') as meta
    from public.v_circular_unread_guardians ug
    join public.student_guardian sg on sg.guardian_id = ug.guardian_id and sg.to_date is null
    join public.student s on s.id = sg.student_id and s.status = 'active'
    join public.enrolment e on e.student_id = s.id and e.status = 'active'
    where ug.circular_id = v_circ_id
      and coalesce(ug.phone_e164, ug.alt_phone) is not null
    order by ug.guardian_id, sg.is_primary desc;

  -- ─── Generic / Class Level Segment ────────────────────────────────────────
  else
    return query
    select
      s.id as student_id,
      e.id as enrolment_id,
      g.id as guardian_id,
      s.name_en as student_name,
      s.gr_number as gr_number,
      coalesce(g.name_en, 'Parent of ' || s.name_en) as guardian_name,
      coalesce(g.phone_e164, g.alt_phone) as guardian_phone,
      0::numeric as dues_pkr,
      'enrolled'::text as attendance_status,
      jsonb_build_object('class_level_id', e.class_level_id, 'section_id', e.section_id) as meta
    from public.enrolment e
    join public.student s on s.id = e.student_id
    left join lateral (
      select sg.guardian_id
      from public.student_guardian sg
      where sg.student_id = s.id
      order by sg.is_primary desc, sg.priority asc
      limit 1
    ) primary_sg on true
    left join public.guardian g on g.id = primary_sg.guardian_id
    where e.tenant_id = v_segment.tenant_id
      and (v_segment.campus_id is null or e.campus_id = v_segment.campus_id)
      and e.status = 'active'
      and s.status = 'active'
      and (
        v_segment.definition->>'class_level_id' is null
        or e.class_level_id = (v_segment.definition->>'class_level_id')::uuid
      )
      and (
        v_segment.definition->>'section_id' is null
        or e.section_id = (v_segment.definition->>'section_id')::uuid
      )
      and coalesce(g.phone_e164, g.alt_phone) is not null;
  end if;
end;
$function$;

-- public.snapshot_campaign_audience
create or replace function public.snapshot_campaign_audience(p_campaign_id uuid, p_segment_id uuid, p_as_of date default current_date)
 returns integer
 language plpgsql
 security definer
 set search_path = 'public'
as $function$
declare
  v_segment record;
  v_count int := 0;
  r record;
begin
  perform app.fn_comm_assert_tenant((select s.tenant_id from public.message_segment s where s.id = p_segment_id));
  select id, tenant_id, campus_id, name into v_segment
  from public.message_segment
  where id = p_segment_id and is_active = true;

  if not found then
    raise exception 'Segment not found or inactive: %', p_segment_id using errcode = 'P0002';
  end if;

  -- Resolve dynamic audience at snapshot execution time
  for r in (select * from public.resolve_segment(p_segment_id, p_as_of)) loop
    v_count := v_count + 1;
    insert into public.message_audience_snapshot (
      tenant_id, campus_id, campaign_id, segment_id, student_id, guardian_id,
      recipient_phone, recipient_name, student_name, gr_number, snapshot_meta, resolved_at
    ) values (
      v_segment.tenant_id, v_segment.campus_id, p_campaign_id, p_segment_id,
      r.student_id, r.guardian_id, r.guardian_phone, r.guardian_name,
      r.student_name, r.gr_number,
      jsonb_build_object(
        'dues_pkr', r.dues_pkr,
        'attendance_status', r.attendance_status,
        'resolved_meta', r.meta
      ),
      clock_timestamp()
    );
  end loop;

  -- AC 3: If 0 recipients resolved, block send with explicit warning
  if v_count = 0 then
    raise exception 'Cannot dispatch campaign: dynamic segment "%" resolved to 0 recipients.', v_segment.name
      using errcode = '22023';
  end if;

  return v_count;
end;
$function$;

-- public.validate_wa_dispatch
create or replace function public.validate_wa_dispatch(p_message_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path = 'public'
as $function$
declare
  v_msg record;
  v_tmpl record;
  v_window_open boolean;
  v_attempt_id uuid;
  v_fallback_att uuid;
begin
  perform app.fn_comm_assert_tenant((select m.tenant_id from public.message m where m.id = p_message_id));
  select id, tenant_id, recipient_phone, channel, status, is_freeform, wa_template_id, message_class
  into v_msg
  from public.message
  where id = p_message_id;

  if not found then
    return jsonb_build_object('valid', false, 'error', 'MESSAGE_NOT_FOUND');
  end if;

  -- If channel is not whatsapp, pass validation
  if v_msg.channel <> 'whatsapp' then
    return jsonb_build_object('valid', true, 'channel', v_msg.channel);
  end if;

  -- 1. Free-form content check (AC 1)
  if v_msg.is_freeform = true or v_msg.wa_template_id is null then
    v_window_open := public.wa_window_open(v_msg.tenant_id, v_msg.recipient_phone);

    if not v_window_open then
      -- 24-hour window closed! Create failed attempt and trigger FR-M02 fallback
      insert into public.message_attempt (
        message_id, attempt_number, channel, status, error_code, error_message, completed_at
      ) values (
        p_message_id,
        (select coalesce(max(attempt_number), 0) + 1 from public.message_attempt where message_id = p_message_id),
        'whatsapp',
        'failed',
        'WA_WINDOW_CLOSED',
        'WhatsApp 24-hour customer service session window is closed for this recipient.',
        clock_timestamp()
      ) returning id into v_attempt_id;

      -- Trigger channel fallback to SMS per FR-M02
      v_fallback_att := public.escalate_message(p_message_id, v_attempt_id, 'wa_window_closed');

      return jsonb_build_object(
        'valid', false,
        'error', 'WA_WINDOW_CLOSED',
        'attempt_id', v_attempt_id,
        'escalated_to_attempt', v_fallback_att
      );
    else
      return jsonb_build_object('valid', true, 'mode', 'freeform_session_open');
    end if;
  else
    -- 2. Template-backed dispatch check (AC 4)
    select id, meta_template_name, status, category
    into v_tmpl
    from public.wa_template
    where id = v_msg.wa_template_id;

    if not found then
      return jsonb_build_object('valid', false, 'error', 'TEMPLATE_NOT_FOUND');
    end if;

    if v_tmpl.status <> 'APPROVED' then
      insert into public.message_attempt (
        message_id, attempt_number, channel, status, error_code, error_message, completed_at
      ) values (
        p_message_id,
        (select coalesce(max(attempt_number), 0) + 1 from public.message_attempt where message_id = p_message_id),
        'whatsapp',
        'failed',
        'WA_TEMPLATE_' || v_tmpl.status,
        format('WhatsApp template %s is not approved (status: %s)', v_tmpl.meta_template_name, v_tmpl.status),
        clock_timestamp()
      ) returning id into v_attempt_id;

      -- Escalate to SMS
      v_fallback_att := public.escalate_message(p_message_id, v_attempt_id, 'wa_template_not_approved');

      return jsonb_build_object(
        'valid', false,
        'error', 'WA_TEMPLATE_' || v_tmpl.status,
        'escalated_to_attempt', v_fallback_att
      );
    end if;

    -- AC 4: Recipient has never sent an inbound message, template is approved.
    -- Dispatch is valid, and NO session window row is artificially created!
    return jsonb_build_object('valid', true, 'mode', 'template_approved', 'template', v_tmpl.meta_template_name);
  end if;
end;
$function$;

-- public.apply_receipt (provider webhook form). The webhooks call it with the service role; staff on the
-- Receipts and Fallback screens call it signed in, so it checks the tenant instead of being service-only.
create or replace function public.apply_receipt(p_provider text, p_payload jsonb, p_tenant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_provider_ref text;
  v_raw_status text;
  v_mapped_status public.attempt_status;
  v_attempt record;
  v_current_rank int;
  v_new_rank int;
  v_tenant_id uuid;
  v_receipt_id uuid;
  v_school boolean := app.auth_tenant_id() is not null;
begin
  -- A school session acts on its own school only (an omitted tenant means its own); the service role,
  -- cron and the provider webhooks (which have no school session) keep working across tenants.
  p_tenant_id := app.fn_comm_scope_tenant(p_tenant_id);
  v_tenant_id := p_tenant_id;

  -- Extract provider reference and status from common payload shapes
  v_provider_ref := coalesce(
    p_payload->>'provider_ref',
    p_payload->>'message_id',
    p_payload->>'id',
    p_payload->>'sms_id',
    p_payload->>'sid'
  );

  if v_provider_ref is null or trim(v_provider_ref) = '' then
    raise exception 'MISSING_PROVIDER_REF';
  end if;

  v_raw_status := lower(coalesce(
    p_payload->>'status',
    p_payload->>'event',
    p_payload->>'delivery_status',
    'unknown'
  ));

  -- Normalize raw provider status to attempt_status
  case v_raw_status
    when 'delivered', 'dlr_delivered', 'read', 'received' then
      v_mapped_status := 'delivered'::public.attempt_status;
    when 'failed', 'dlr_failed', 'undelivered', 'bounced', 'rejected' then
      v_mapped_status := 'failed'::public.attempt_status;
    when 'expired', 'dlr_expired' then
      v_mapped_status := 'expired'::public.attempt_status;
    when 'sent', 'transferred' then
      v_mapped_status := 'sent'::public.attempt_status;
    when 'submitted', 'buffered', 'queued' then
      v_mapped_status := 'submitted'::public.attempt_status;
    else
      v_mapped_status := 'unknown'::public.attempt_status;
  end case;

  -- Locate matching attempt
  select ma.id, ma.message_id, ma.status, m.tenant_id
  into v_attempt
  from public.message_attempt ma
  join public.message m on m.id = ma.message_id
  where ma.provider_ref = v_provider_ref
    and (not v_school or m.tenant_id = p_tenant_id)
  limit 1;

  -- AC 3: If no attempt matches provider_ref, write to dead_letter_receipt
  if v_attempt.id is null then
    if v_tenant_id is null then
      -- Fallback to first active tenant if tenant context was not provided by webhook
      select id into v_tenant_id from public.tenant where status = 'active' order by created_at asc limit 1;
    end if;

    if v_tenant_id is null then
      select id into v_tenant_id from public.tenant limit 1;
    end if;

    insert into public.dead_letter_receipt (
      tenant_id,
      provider,
      provider_ref,
      payload,
      reason,
      received_at,
      expires_at
    ) values (
      v_tenant_id,
      p_provider,
      v_provider_ref,
      p_payload,
      'attempt_not_found',
      clock_timestamp(),
      clock_timestamp() + interval '30 days'
    );

    return jsonb_build_object(
      'success', true,
      'action', 'dead_letter',
      'provider_ref', v_provider_ref,
      'reason', 'attempt_not_found'
    );
  end if;

  v_tenant_id := v_attempt.tenant_id;

  -- Record receipt audit row regardless of whether state advances
  insert into public.message_receipt (
    tenant_id,
    message_attempt_id,
    provider,
    provider_ref,
    status,
    raw,
    received_at
  ) values (
    v_tenant_id,
    v_attempt.id,
    p_provider,
    v_provider_ref,
    v_mapped_status,
    p_payload,
    clock_timestamp()
  ) returning id into v_receipt_id;

  -- AC 1: Monotonic state machine check
  -- Check ranks: queued/sending (1) -> submitted (2) -> sent (3) -> delivered/failed/expired (4)
  v_current_rank := public.comm_status_rank(v_attempt.status);
  v_new_rank := public.comm_status_rank(v_mapped_status);

  -- Only advance forward. If current is terminal (rank 4), or new rank <= current rank, state is unchanged
  if v_current_rank < 4 and v_new_rank > v_current_rank then
    update public.message_attempt
    set
      status = v_mapped_status,
      completed_at = case when v_new_rank = 4 then clock_timestamp() else completed_at end,
      raw_response = coalesce(raw_response, '{}'::jsonb) || jsonb_build_object('latest_dlr', p_payload)
    where id = v_attempt.id;

    -- Update parent message status
    if v_mapped_status = 'delivered' then
      update public.message
      set status = 'delivered'::public.message_status,
          final_status = 'delivered'::public.message_status,
          updated_at = clock_timestamp()
      where id = v_attempt.message_id;
    elsif v_mapped_status in ('failed', 'expired') then
      update public.message
      set status = v_mapped_status::text::public.message_status,
          final_status = v_mapped_status::text::public.message_status,
          updated_at = clock_timestamp()
      where id = v_attempt.message_id;
    elsif v_mapped_status = 'sent' then
      update public.message
      set status = 'sent'::public.message_status,
          updated_at = clock_timestamp()
      where id = v_attempt.message_id and status in ('queued', 'claimed', 'sending');
    end if;

    return jsonb_build_object(
      'success', true,
      'action', 'advanced',
      'previous_status', v_attempt.status,
      'new_status', v_mapped_status,
      'receipt_id', v_receipt_id
    );
  else
    -- State rejected backwards or already at terminal status; state unchanged, receipt audited
    return jsonb_build_object(
      'success', true,
      'action', 'preserved',
      'status', v_attempt.status,
      'ignored_status', v_mapped_status,
      'receipt_id', v_receipt_id
    );
  end if;
end;
$function$;

-- ── who may call what ─────────────────────────────────────────────────────────────

-- Nothing signed out. Every overload of each name.
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (array[
         'apply_dispatch_suppression', 'apply_receipt', 'attach_wa_template_to_message', 'claim_message_batch',
         'debit_comm_wallet', 'deprovision_on_tc', 'escalate_message', 'escalate_tickets',
         'escalate_timed_out_attempts', 'estimate_campaign_cost', 'evaluate_date_based_rules',
         'evaluate_scheduled_campaigns', 'expire_stale_attempts', 'export_circular_unread_segment',
         'get_channel_chain', 'get_circular_targeted_guardians', 'get_guardian_ics_events',
         'get_next_quiet_window_end', 'get_or_create_campus_portal_policy', 'guard_campaign_dispatch',
         'is_quiet_now', 'is_recipient_opted_out', 'is_suppressed', 'is_working_day', 'next_channel_for',
         'next_ticket_no', 'pick_body', 'preview_campaign_suppression', 'process_pending_trigger_fires',
         'process_wa_inbound_message', 'provision_student_accounts', 'publish_circular',
         'recompute_past_holiday_impact', 'record_attempt_cost', 'record_message_attempt',
         'record_message_cost', 'render_template', 'resolve_segment',
         'resolve_student_login', 'resolve_unknown_attempt', 'resubscribe_recipient',
         'revoke_guardian_ics_token', 'seed_default_comm_policy', 'seed_default_segments',
         'seed_default_trigger_rules', 'seed_default_versioned_templates', 'seed_default_wa_templates',
         'sla_due', 'snapshot_campaign_audience', 'student_matches_segment', 'sync_wa_template_status',
         'top_up_comm_wallet', 'unpublish_circular', 'validate_template_tokens', 'validate_wa_dispatch',
         'wa_window_open'
       ])
  loop
    execute format('revoke execute on function %s from public, anon', r.sig);
  end loop;
end $$;

-- Only the service role, for functions nothing signed in ever calls directly.
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (
         p.proname = any (array[
           'apply_dispatch_suppression', 'attach_wa_template_to_message', 'debit_comm_wallet',
           'deprovision_on_tc', 'escalate_message', 'escalate_tickets', 'estimate_campaign_cost',
           'get_channel_chain', 'get_guardian_ics_events', 'get_next_quiet_window_end',
           'get_or_create_campus_portal_policy', 'is_recipient_opted_out', 'is_suppressed', 'is_working_day',
           'next_channel_for', 'next_ticket_no', 'pick_body', 'preview_campaign_suppression',
           'record_attempt_cost', 'record_message_attempt', 'record_message_cost',
           'resolve_student_login', 'sla_due', 'student_matches_segment',
           'wa_window_open'
         ])
       )
  loop
    execute format('revoke execute on function %s from authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $$;
