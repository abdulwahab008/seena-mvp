-- ==============================================================================
-- pgTAP Test: FR-N10 Parent complaint and query tickets
-- ==============================================================================
begin;

select plan(35);

-- ── 1. Schema & Table Tests ──────────────────────────────────────────────────
select has_table('public', 'support_ticket', 'Table support_ticket exists');
select has_table('public', 'ticket_counter', 'Table ticket_counter exists');
select has_table('public', 'ticket_message', 'Table ticket_message exists');
select has_table('public', 'ticket_attachment', 'Table ticket_attachment exists');

select has_column('public', 'support_ticket', 'ticket_no', 'Column ticket_no exists');
select has_column('public', 'support_ticket', 'category', 'Column category exists');
select has_column('public', 'support_ticket', 'status', 'Column status exists');
select has_column('public', 'support_ticket', 'sla_due_at', 'Column sla_due_at exists');
select has_column('public', 'support_ticket', 'breached_at', 'Column breached_at exists');
select has_column('public', 'support_ticket', 'first_staff_reply_at', 'Column first_staff_reply_at exists');
select has_column('public', 'support_ticket', 'resolved_at', 'Column resolved_at exists');

select has_function('public', 'next_ticket_no', 'Function next_ticket_no exists');
select has_function('public', 'sla_due', 'Function sla_due exists');
select has_function('public', 'create_support_ticket', 'Function create_support_ticket exists');
select has_function('public', 'add_ticket_message', 'Function add_ticket_message exists');
select has_function('public', 'resolve_ticket', 'Function resolve_ticket exists');
select has_function('public', 'reopen_ticket', 'Function reopen_ticket exists');
select has_function('public', 'escalate_tickets', 'Function escalate_tickets exists');

-- ── 2. Seed Test Environment ─────────────────────────────────────────────────
do $$
declare
  v_tenant_id uuid := '88888888-8888-8888-8888-888888888888';
  v_campus_id uuid := '99999999-9999-9999-9999-999999999999';
  v_session_id uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_staff_id uuid := '11111111-1111-1111-1111-111111111111';
  v_parent1_id uuid := '22222222-2222-2222-2222-222222222222';
  v_parent2_id uuid := '33333333-3333-3333-3333-333333333333';
  v_student_id uuid := '44444444-4444-4444-4444-444444444444';
begin
  -- Tenant & Campus
  insert into public.tenant (id, name, slug)
  values (v_tenant_id, 'Ticket Test Tenant', 'ticket-test-tenant')
  on conflict (id) do nothing;

  insert into public.campus (id, tenant_id, name, code)
  values (v_campus_id, v_tenant_id, 'Main Campus', 'MAIN')
  on conflict (id) do nothing;

  -- Users in auth.users
  insert into auth.users (id, instance_id, email, aud, role, created_at, updated_at)
  values
    (v_staff_id, '00000000-0000-0000-0000-000000000000', 'principal@ticket.test', 'authenticated', 'authenticated', now(), now()),
    (v_parent1_id, '00000000-0000-0000-0000-000000000000', 'parent1@ticket.test', 'authenticated', 'authenticated', now(), now()),
    (v_parent2_id, '00000000-0000-0000-0000-000000000000', 'parent2@ticket.test', 'authenticated', 'authenticated', now(), now())
  on conflict (id) do nothing;

  -- App User for Principal
  insert into public.app_user (user_id, tenant_id, app_role, full_name, status)
  values (v_staff_id, v_tenant_id, 'principal', 'Principal Tariq', 'active')
  on conflict (user_id) do nothing;

  insert into public.user_campus (user_id, tenant_id, campus_id)
  values (v_staff_id, v_tenant_id, v_campus_id)
  on conflict do nothing;

  -- Guardians
  insert into public.guardian (id, tenant_id, auth_user_id, name_en, phone_e164)
  values
    ('aaaa0001-0000-0000-0000-000000000000', v_tenant_id, v_parent1_id, 'Parent One', '+923001111111'),
    ('aaaa0002-0000-0000-0000-000000000000', v_tenant_id, v_parent2_id, 'Parent Two', '+923002222222')
  on conflict (id) do nothing;

  -- Student
  insert into public.student (id, tenant_id, campus_id, name_en, gr_number, status, dob, gender)
  values (v_student_id, v_tenant_id, v_campus_id, 'Child One', 'GR-009911', 'active', '2016-01-01', 'male')
  on conflict (id) do nothing;

  insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
  values (v_tenant_id, v_student_id, 'aaaa0001-0000-0000-0000-000000000000', 'father', true, true)
  on conflict do nothing;
end;
$$;

-- ── 3. AC 1: Gap-Free Ticket Numbering ───────────────────────────────────────
select is(
  public.next_ticket_no('99999999-9999-9999-9999-999999999999'::uuid),
  'MAIN-' || extract(year from clock_timestamp())::text || '-000001',
  'FR-N10 AC 1: First ticket receives MAIN-YYYY-000001'
);

select is(
  public.next_ticket_no('99999999-9999-9999-9999-999999999999'::uuid),
  'MAIN-' || extract(year from clock_timestamp())::text || '-000002',
  'FR-N10 AC 1: Consecutive ticket receives gap-free MAIN-YYYY-000002'
);

-- ── 4. AC 2: Calendar-Aware SLA Calculation ──────────────────────────────────
-- Setup a Friday afternoon timestamp: 2026-10-02 14:00 PKT (Friday)
-- Friday 14:00 to 16:00 is 2 working hours.
-- Saturday (2026-10-03) and Sunday (2026-10-04) are excluded.
-- Let's add a holiday on Monday (2026-10-05).
-- So Monday is also excluded.
-- Tuesday (2026-10-06) 08:00 to 16:00 gives 8 working hours (total 10).
-- Testing with 10 working hours from Friday 14:00: should land on Tuesday 2026-10-06 16:00 PKT!

insert into public.campus_event (
  tenant_id, campus_id, title, event_type, starts_at, ends_at, is_cancelled
) values (
  '88888888-8888-8888-8888-888888888888',
  '99999999-9999-9999-9999-999999999999',
  'Special Holiday Monday',
  'holiday',
  '2026-10-05 00:00:00+05'::timestamptz,
  '2026-10-05 23:59:59+05'::timestamptz,
  false
);

select is(
  to_char(public.sla_due(
    '99999999-9999-9999-9999-999999999999'::uuid,
    '2026-10-02 14:00:00+05'::timestamptz,
    10 -- 2 hrs on Friday + weekend skipped + holiday skipped + 8 hrs on Tuesday = Tuesday 16:00
  ) at time zone 'Asia/Karachi', 'YYYY-MM-DD HH24:MI'),
  '2026-10-06 16:00',
  'FR-N10 AC 2: Weekend and calendar holiday excluded; Friday 14:00 + 10 working hours lands on Tuesday 16:00'
);

-- ── 5. AC 3: Escalation Job on SLA Breach ────────────────────────────────────
-- Create a ticket that breached SLA (due in the past, no staff reply)
insert into public.support_ticket (
  id, tenant_id, campus_id, ticket_no, category, status, subject, description,
  creator_user_id, sla_hours, sla_due_at, created_at, updated_at
) values (
  'eeee0001-0000-0000-0000-000000000000',
  '88888888-8888-8888-8888-888888888888',
  '99999999-9999-9999-9999-999999999999',
  'MAIN-2026-000003',
  'transport',
  'open',
  'Van is consistently late',
  'Route 4 van arrives 40 mins late every morning',
  '22222222-2222-2222-2222-222222222222',
  48,
  clock_timestamp() - interval '2 hours', -- Breached!
  clock_timestamp() - interval '50 hours',
  clock_timestamp() - interval '50 hours'
);

select is(
  public.escalate_tickets(),
  1,
  'FR-N10 AC 3: Hourly escalation job flags 1 breached ticket'
);

select is(
  (select breached_at is not null from public.support_ticket where id = 'eeee0001-0000-0000-0000-000000000000'),
  true,
  'FR-N10 AC 3: Breached ticket has breached_at timestamp set'
);

select is(
  (select count(*)::int from public.ticket_escalation_notification where ticket_id = 'eeee0001-0000-0000-0000-000000000000' and recipient_id = '11111111-1111-1111-1111-111111111111'),
  1,
  'FR-N10 AC 3: Principal notification recorded for breach'
);

-- ── 6. AC 4: Resolve & Reopen Within 7 Days ──────────────────────────────────
-- Resolve ticket
select is(
  public.resolve_ticket('eeee0001-0000-0000-0000-000000000000', 'Driver replaced and route timing adjusted'),
  true,
  'FR-N10 AC 4: resolve_ticket succeeds'
);

select is(
  (select status from public.support_ticket where id = 'eeee0001-0000-0000-0000-000000000000')::text,
  'resolved',
  'FR-N10 AC 4: Ticket status is resolved'
);

-- Reopen within 7 days
select is(
  public.reopen_ticket('eeee0001-0000-0000-0000-000000000000', 'Van was late again this morning'),
  true,
  'FR-N10 AC 4: Reopening within 7 days succeeds'
);

select is(
  (select status from public.support_ticket where id = 'eeee0001-0000-0000-0000-000000000000')::text,
  'open',
  'FR-N10 AC 4: Reopened ticket status is open again'
);

select is(
  (select ticket_no from public.support_ticket where id = 'eeee0001-0000-0000-0000-000000000000'),
  'MAIN-2026-000003',
  'FR-N10 AC 4: Reopened ticket retains exact same ticket number'
);

-- Check thread history preserved and reopened note appended
select is(
  (select count(*)::int from public.ticket_message where ticket_id = 'eeee0001-0000-0000-0000-000000000000'),
  2, -- 1 resolution message + 1 reopen message
  'FR-N10 AC 4: Prior thread retained and reopen message appended'
);

-- Test reopen failure after 7 days
update public.support_ticket
set status = 'resolved',
    resolved_at = clock_timestamp() - interval '8 days'
where id = 'eeee0001-0000-0000-0000-000000000000';

select throws_ok(
  $$ select public.reopen_ticket('eeee0001-0000-0000-0000-000000000000', 'Too late') $$,
  'Tickets resolved more than 7 days ago cannot be reopened. Please open a new ticket.',
  'FR-N10 AC 4: Reopening after 7 days raises exception'
);

-- ── 7. RLS & Internal Note Isolation ─────────────────────────────────────────
-- Create a parent ticket with an internal note and public message
insert into public.support_ticket (
  id, tenant_id, campus_id, ticket_no, category, status, subject, description,
  creator_user_id, sla_hours, sla_due_at
) values (
  'eeee0002-0000-0000-0000-000000000000',
  '88888888-8888-8888-8888-888888888888',
  '99999999-9999-9999-9999-999999999999',
  'MAIN-2026-000004',
  'fee',
  'in_progress',
  'Challan fine query',
  'Why was late fee added?',
  '22222222-2222-2222-2222-222222222222', -- Parent 1
  48,
  clock_timestamp() + interval '24 hours'
);

-- Staff internal note
insert into public.ticket_message (
  id, tenant_id, ticket_id, author_id, body, is_internal
) values (
  'bbbb0001-0000-0000-0000-000000000000',
  '88888888-8888-8888-8888-888888888888',
  'eeee0002-0000-0000-0000-000000000000',
  '11111111-1111-1111-1111-111111111111',
  'INTERNAL: Parent paid 2 days past due date. Fine is correct.',
  true
);

-- Public staff reply
insert into public.ticket_message (
  id, tenant_id, ticket_id, author_id, body, is_internal
) values (
  'bbbb0002-0000-0000-0000-000000000000',
  '88888888-8888-8888-8888-888888888888',
  'eeee0002-0000-0000-0000-000000000000',
  '11111111-1111-1111-1111-111111111111',
  'Dear Parent, late fee is applicable as payment was credited on the 17th.',
  false
);

-- Set JWT as Parent 1
set local role authenticated;
select set_config('request.jwt.claims', jsonb_build_object(
  'sub', '22222222-2222-2222-2222-222222222222',
  'app_role', 'parent',
  'tenant_id', '88888888-8888-8888-8888-888888888888',
  'campus_ids', array['99999999-9999-9999-9999-999999999999']::text[]
)::text, true);

select is(
  (select count(*)::int from public.support_ticket where id = 'eeee0002-0000-0000-0000-000000000000'),
  1,
  'FR-N10 RLS: Parent 1 can see their own ticket'
);

select is(
  (select count(*)::int from public.ticket_message where ticket_id = 'eeee0002-0000-0000-0000-000000000000'),
  1,
  'FR-N10 RLS: Parent 1 can ONLY see public messages (1 public message seen)'
);

select is(
  (select count(*)::int from public.ticket_message where ticket_id = 'eeee0002-0000-0000-0000-000000000000' and is_internal = true),
  0,
  'FR-N10 RLS: Parent 1 CANNOT see staff internal notes (0 internal notes seen)'
);

-- Set JWT as Parent 2 (Unrelated parent)
select set_config('request.jwt.claims', jsonb_build_object(
  'sub', '33333333-3333-3333-3333-333333333333',
  'app_role', 'parent',
  'tenant_id', '88888888-8888-8888-8888-888888888888',
  'campus_ids', array['99999999-9999-9999-9999-999999999999']::text[]
)::text, true);

select is(
  (select count(*)::int from public.support_ticket where id = 'eeee0002-0000-0000-0000-000000000000'),
  0,
  'FR-N10 RLS: Parent 2 CANNOT see Parent 1 ticket (0 rows returned)'
);

rollback;
