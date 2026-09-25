-- ═══════════════════════════════════════════════════════════════════════
-- Migration: 20260801420000_event_triggered_message_rules.sql
-- Module M: Communication
-- Requirement: FR-M08: Event-triggered message rules (No. 210, P0)
-- ═══════════════════════════════════════════════════════════════════════
-- Scope:
-- 1. Tables:
--    - comm_trigger_rule: Declarative trigger rules (event_type, condition jsonb, template_version_id, is_enabled).
--    - comm_trigger_fire: Fire audit log with UNIQUE(rule_id, entity_id, fire_key) for exact deduplication.
-- 2. Triggers:
--    - trg_attendance_absent: Fast trigger on attendance_day that writes to comm_trigger_fire ONLY, outside provider HTTP.
-- 3. Functions:
--    - evaluate_date_based_rules(run_date, tenant_id): Evaluates overdue challan rules (D+1, D+7, D+15) without backfill.
--    - process_pending_trigger_fires(tenant_id, limit): Enqueues messages to outbox.
--    - seed_default_trigger_rules(tenant_id, campus_id): Seeds default absence and fee reminder rules.
-- 4. RLS & Permissions.
-- ═══════════════════════════════════════════════════════════════════════

-- ─── 1. Declarative Communication Trigger Rules ─────────────────────────
create table if not exists public.comm_trigger_rule (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  campus_id           uuid references public.campus(id) on delete cascade,
  name                text not null,
  description         text,
  event_type          text not null,
  condition           jsonb not null default '{}'::jsonb,
  template_version_id uuid references public.message_template_version(id) on delete set null,
  template_id         uuid references public.message_template(id) on delete set null,
  channel             text not null default 'sms',
  is_enabled          boolean not null default true,
  last_evaluated_at   timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint ck_comm_trigger_event_type check (
    event_type in ('attendance_absent', 'fee_challan_overdue', 'result_published', 'admission_status_changed', 'custom')
  ),
  constraint ck_comm_trigger_channel check (
    channel in ('sms', 'whatsapp', 'email', 'in_app')
  )
);

create index if not exists idx_comm_trigger_rule_lookup
  on public.comm_trigger_rule (tenant_id, event_type, is_enabled);

-- ─── 2. Communication Trigger Fires (Exact Deduplication Log) ───────────
create table if not exists public.comm_trigger_fire (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  rule_id             uuid not null references public.comm_trigger_rule(id) on delete cascade,
  entity_id           uuid not null,
  fire_key            text not null,
  status              text not null default 'pending',
  enqueued_message_id uuid references public.message(id) on delete set null,
  skip_reason         text,
  metadata            jsonb not null default '{}'::jsonb,
  fired_at            timestamptz not null default now(),
  enqueued_at         timestamptz,
  constraint ck_trigger_fire_status check (
    status in ('pending', 'enqueued', 'skipped', 'cancelled')
  ),
  constraint uq_comm_trigger_fire unique (rule_id, entity_id, fire_key)
);

create index if not exists idx_comm_trigger_fire_status
  on public.comm_trigger_fire (tenant_id, status, fired_at);

create index if not exists idx_comm_trigger_fire_entity
  on public.comm_trigger_fire (tenant_id, entity_id, fire_key);

-- ─── 3. Database Trigger for Student Absence (AC 1 & AC 3) ──────────────
-- AC 3: Lightweight trigger that writes to comm_trigger_fire ONLY in microseconds.
-- AC 1: UNIQUE(rule_id, entity_id, fire_key) guarantees exactly one row even if edited multiple times on the same date.
create or replace function public.trg_fn_attendance_absent()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule record;
begin
  -- Only fire on student absence
  if NEW.status = 'absent' then
    for v_rule in
      select id, tenant_id
      from public.comm_trigger_rule
      where tenant_id = NEW.tenant_id
        and is_enabled = true
        and event_type = 'attendance_absent'
        and (campus_id is null or campus_id = NEW.campus_id)
    loop
      -- Dedupe key includes the attendance date (fire_key)
      insert into public.comm_trigger_fire (
        tenant_id,
        rule_id,
        entity_id,
        fire_key,
        status,
        metadata
      ) values (
        NEW.tenant_id,
        v_rule.id,
        NEW.enrolment_id,
        NEW.attendance_date::text,
        'pending',
        jsonb_build_object(
          'attendance_date', NEW.attendance_date,
          'campus_id', NEW.campus_id,
          'session_id', NEW.session_id,
          'section_id', NEW.section_id
        )
      )
      on conflict (rule_id, entity_id, fire_key) do nothing;
    end loop;
  end if;

  return NEW;
end;
$$;

drop trigger if exists trg_attendance_absent on public.attendance_day;
create trigger trg_attendance_absent
  after insert or update of status on public.attendance_day
  for each row
  execute function public.trg_fn_attendance_absent();

-- ─── 4. Date-Based Trigger Rule Evaluation (AC 2 & AC 4) ────────────────
-- Evaluates overdue fees for D+1, D+7, D+15.
-- AC 2: If payment was posted on D+6, status is 'paid'; D+7 produces no fire and cancels any pending fires.
-- AC 4: Does NOT backfill old missed weeks when re-enabled; only evaluates the given run_date.
create or replace function public.evaluate_date_based_rules(
  p_run_date date default current_date,
  p_tenant_id uuid default null
)
returns table (
  rule_id          uuid,
  rule_name        text,
  event_type       text,
  new_fires_count  integer,
  cancelled_count  integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule           record;
  v_day_offset     integer;
  v_target_due     date;
  v_challan        record;
  v_inserted_fires integer;
  v_cancelled      integer;
  v_fire_key       text;
begin
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
$$;

-- ─── 5. Process Pending Trigger Fires into Message Outbox ────────────────
create or replace function public.process_pending_trigger_fires(
  p_tenant_id uuid default null,
  p_limit integer default 200
)
returns table (
  fire_id             uuid,
  rule_id             uuid,
  entity_id           uuid,
  fire_key            text,
  status              text,
  enqueued_message_id uuid
)
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

-- ─── 6. Seed Default Communication Trigger Rules ────────────────────────
create or replace function public.seed_default_trigger_rules(
  p_tenant_id uuid,
  p_campus_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
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
$$;

-- ─── 7. Security & RLS Policies ─────────────────────────────────────────
alter table public.comm_trigger_rule enable row level security;
alter table public.comm_trigger_fire enable row level security;

drop policy if exists comm_trigger_rule_isolation on public.comm_trigger_rule;
create policy comm_trigger_rule_isolation on public.comm_trigger_rule
  for all using (tenant_id = app.auth_tenant_id())
  with check (tenant_id = app.auth_tenant_id());

drop policy if exists comm_trigger_fire_isolation on public.comm_trigger_fire;
create policy comm_trigger_fire_isolation on public.comm_trigger_fire
  for all using (tenant_id = app.auth_tenant_id())
  with check (tenant_id = app.auth_tenant_id());

grant execute on function public.evaluate_date_based_rules(date, uuid) to authenticated;
grant execute on function public.process_pending_trigger_fires(uuid, integer) to authenticated;
grant execute on function public.seed_default_trigger_rules(uuid, uuid) to authenticated;
