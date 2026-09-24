-- ═══════════════════════════════════════════════════════════════════════
-- pgTAP tests for Module M: Communication
-- FR-M07: Scheduled sends with quiet hours
-- ═══════════════════════════════════════════════════════════════════════

begin;
select plan(22);

-- ─── 1. Setup Test Fixtures ─────────────────────────────────────────────
select public.provision_tenant('test-quiet-hours', 'Quiet Hours Academy', 'principal@quiethours.test');
select id as tenant_id from public.tenant where slug = 'test-quiet-hours' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' limit 1 \gset
select gen_random_uuid() as principal_id \gset

insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_id', 'principal@quiethours.test', 'x', now(), 'authenticated', 'authenticated');

insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_id', :'tenant_id', 'principal', 'Principal Officer');

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', :'principal_id',
    'tenant_id', :'tenant_id',
    'app_role', 'principal',
    'campus_ids', json_build_array(:'campus_id')
  )::text,
  true
);

-- Seed default policy
select public.seed_default_comm_policy(:'tenant_id'::uuid);

-- ─── 2. Schema Integrity Checks ────────────────────────────────────────
select has_table('public', 'tenant_comm_policy', 'Table tenant_comm_policy exists');
select has_table('public', 'comm_quiet_hours_override', 'Table comm_quiet_hours_override exists');
select has_table('public', 'message_campaign', 'Table message_campaign exists');
select has_table('public', 'quiet_hours_bypass_log', 'Table quiet_hours_bypass_log exists');

select has_column('public', 'tenant_comm_policy', 'quiet_start', 'tenant_comm_policy has quiet_start');
select has_column('public', 'tenant_comm_policy', 'quiet_end', 'tenant_comm_policy has quiet_end');
select has_column('public', 'message_campaign', 'scheduled_at', 'message_campaign has scheduled_at');
select has_column('public', 'message_campaign', 'deferred_until', 'message_campaign has deferred_until');
select has_column('public', 'message_campaign', 'is_emergency', 'message_campaign has is_emergency');
select has_column('public', 'quiet_hours_bypass_log', 'bypass_reason', 'quiet_hours_bypass_log has bypass_reason');

-- ─── 3. Default Policy Seed Verification ────────────────────────────────
select results_eq(
  format('select quiet_start, quiet_end, timezone from public.tenant_comm_policy where tenant_id = %L', :'tenant_id'),
  $$values ('21:00:00'::time, '08:00:00'::time, 'Asia/Karachi')$$,
  'Default quiet window is 21:00:00 to 08:00:00 PKT'
);

-- ─── 4. Quiet Hours Detection Function (is_quiet_now) ───────────────────
-- 22:30 PKT is 17:30 UTC -> inside quiet hours
select is(
  public.is_quiet_now(:'tenant_id'::uuid, '2026-10-15 17:30:00+00'::timestamptz),
  true,
  '22:30 PKT is detected as quiet hours (AC 1)'
);

-- 14:00 PKT is 09:00 UTC -> outside quiet hours
select is(
  public.is_quiet_now(:'tenant_id'::uuid, '2026-10-15 09:00:00+00'::timestamptz),
  false,
  '14:00 PKT is detected as daytime / allowed hours'
);

-- 07:30 PKT is 02:30 UTC -> inside quiet hours (before 08:00 morning)
select is(
  public.is_quiet_now(:'tenant_id'::uuid, '2026-10-15 02:30:00+00'::timestamptz),
  true,
  '07:30 PKT is detected as quiet hours'
);

-- ─── 5. AC 3: Validation Error on Past Timestamp ────────────────────────
select throws_ok(
  format(
    $$select public.schedule_campaign(
      'Past Announcement', null, null, 'sms', 'Hello world',
      now() - interval '2 hours', 'Asia/Karachi', false, null, %L::uuid
    )$$,
    :'campus_id'
  ),
  '22023',
  NULL,
  'Scheduling with a past timestamp is rejected with validation error (AC 3)'
);

-- ─── 6. AC 1: Scheduled for 22:30 PKT Deferred to 08:00 Next Morning ───
-- Create a campaign scheduled for tomorrow 22:30 PKT (17:30 UTC)
select public.schedule_campaign(
  'Evening Newsletter',
  null,
  null,
  'sms',
  'Parent teacher conference details',
  timezone('Asia/Karachi', (current_date + interval '2 days' + time '22:30:00')),
  'Asia/Karachi',
  false,
  null,
  :'campus_id'::uuid
) as deferred_campaign_id \gset

select results_eq(
  format('select status from public.message_campaign where id = %L', :'deferred_campaign_id'),
  $$values ('deferred_quiet_hours')$$,
  'AC 1: Campaign scheduled during quiet hours (22:30 PKT) is deferred_quiet_hours'
);

-- Verify deferred_until is set to next day 08:00:00 PKT
select is(
  (select timezone('Asia/Karachi', deferred_until)::time from public.message_campaign where id = :'deferred_campaign_id'),
  '08:00:00'::time,
  'AC 1: Campaign deferred_until is exactly 08:00:00 PKT'
);

-- Evaluate at 08:05:00 PKT on resumption morning
select ok(
  exists (
    select 1
    from public.evaluate_scheduled_campaigns(
      :'tenant_id'::uuid,
      (select deferred_until + interval '5 minutes' from public.message_campaign where id = :'deferred_campaign_id')
    )
    where campaign_id = :'deferred_campaign_id'::uuid
      and new_status = 'dispatching'
  ),
  'AC 1: Evaluating at 08:05 PKT transitions deferred campaign to dispatching'
);

-- ─── 7. AC 2: Emergency School Closure Bypass at 23:10 PKT ─────────────
select public.schedule_campaign(
  'Emergency Flood Closure',
  null,
  null,
  'sms',
  'School will remain closed tomorrow due to heavy rainfall and flood advisory.',
  timezone('Asia/Karachi', (current_date + interval '1 day' + time '23:10:00')),
  'Asia/Karachi',
  true, -- is_emergency
  'Severe weather alert issued by District Administration', -- emergency_bypass_reason
  :'campus_id'::uuid
) as emergency_campaign_id \gset

select results_eq(
  format('select status, is_emergency from public.message_campaign where id = %L', :'emergency_campaign_id'),
  $$values ('dispatching', true)$$,
  'AC 2: Emergency campaign dispatches immediately despite quiet hours'
);

select ok(
  exists (
    select 1
    from public.quiet_hours_bypass_log
    where campaign_id = :'emergency_campaign_id'::uuid
      and tenant_id = :'tenant_id'::uuid
      and approver_role = 'principal'
      and bypass_reason = 'Severe weather alert issued by District Administration'
  ),
  'AC 2: Emergency bypass is recorded in quiet_hours_bypass_log with approver and reason'
);

-- ─── 8. AC 4: Ramadan Seasonal Quiet Window Override ───────────────────
-- Insert Ramadan override: Quiet hours 23:30 to 09:00 PKT for the next 30 days
insert into public.comm_quiet_hours_override (
  tenant_id, name, date_range, quiet_start, quiet_end
) values (
  :'tenant_id'::uuid,
  'Ramadan 2026 Schedule',
  daterange(current_date + 10, current_date + 40, '[]'),
  '23:30:00'::time,
  '09:00:00'::time
);

-- Under default policy, 22:00 PKT is quiet (default start is 21:00).
-- But during Ramadan, quiet starts at 23:30 PKT. So 22:00 PKT during Ramadan is ALLOWED (false).
select is(
  public.is_quiet_now(
    :'tenant_id'::uuid,
    timezone('Asia/Karachi', ((current_date + 15) || ' 22:00:00')::timestamp)
  ),
  false,
  'AC 4: During Ramadan override, 22:00 PKT is not quiet (override starts 23:30)'
);

-- And 08:30 PKT during Ramadan is QUIET (override quiet_end is 09:00, whereas default was 08:00)
select is(
  public.is_quiet_now(
    :'tenant_id'::uuid,
    timezone('Asia/Karachi', ((current_date + 15) || ' 08:30:00')::timestamp)
  ),
  true,
  'AC 4: During Ramadan override, 08:30 PKT is quiet (override ends 09:00)'
);

select * from finish();
rollback;
