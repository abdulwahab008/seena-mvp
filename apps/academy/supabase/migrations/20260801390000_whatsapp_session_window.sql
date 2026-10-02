-- FR-M05: WhatsApp session window enforcement
-- Module M: Communication
--
-- Features implemented:
--   * wa_template table tracking Meta-registered message templates with approval status
--     ('APPROVED', 'PENDING', 'REJECTED', 'PAUSED'), category, and rejection diagnostics.
--   * wa_session_window table tracking 24-hour parent customer service windows per MSISDN.
--   * wa_inbound_message table recording inbound parent messages from Meta webhooks.
--   * wa_compliance_alert table recording Principal alerts when templates are rejected.
--   * Functions:
--       - wa_window_open(tenant_id, msisdn): checks if 24h window is currently active.
--       - process_wa_inbound_message(tenant_id, msisdn, body, wam_id): opens/renews 24h window.
--       - attach_wa_template(message_id, template_id): blocks attachment if template is PENDING/REJECTED.
--       - validate_wa_dispatch(message_id): validates 24h window for free-form content and triggers
--         SMS fallback via FR-M02 when window is closed (WA_WINDOW_CLOSED); verifies APPROVED state
--         for template content without creating artificial session windows for unengaged parents.
--       - sync_wa_template_status(template_id, status, reason): updates Meta sync status and
--         automatically pauses affected scheduled campaigns/messages while alerting the Principal.

-- 1. Custom Types
do $$
begin
  if not exists (select 1 from pg_type where typname = 'wa_template_status') then
    create type public.wa_template_status as enum ('APPROVED', 'PENDING', 'REJECTED', 'PAUSED');
  end if;

  if not exists (select 1 from pg_type where typname = 'wa_template_category') then
    create type public.wa_template_category as enum ('UTILITY', 'MARKETING', 'AUTHENTICATION', 'SERVICE');
  end if;
end $$;

-- 2. Meta WhatsApp Templates Table
create table if not exists public.wa_template (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant(id) on delete cascade,
  meta_template_name text not null,
  category           public.wa_template_category not null default 'UTILITY',
  status             public.wa_template_status not null default 'PENDING',
  language           text not null default 'en_US',
  body_text          text not null,
  rejection_reason   text,
  last_synced_at     timestamptz not null default clock_timestamp(),
  created_at         timestamptz not null default clock_timestamp(),
  updated_at         timestamptz not null default clock_timestamp(),
  constraint uq_wa_template_name_lang unique (tenant_id, meta_template_name, language)
);

create index if not exists idx_wa_template_lookup
  on public.wa_template (tenant_id, status, category);

-- 3. WhatsApp 24-Hour Session Window Table
create table if not exists public.wa_session_window (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  msisdn            text not null,
  window_opened_at  timestamptz not null default clock_timestamp(),
  window_expires_at timestamptz not null default clock_timestamp() + interval '24 hours',
  last_inbound_id   uuid,
  created_at        timestamptz not null default clock_timestamp(),
  updated_at        timestamptz not null default clock_timestamp(),
  constraint uq_wa_session_msisdn unique (tenant_id, msisdn)
);

create index if not exists idx_wa_session_window_expiry
  on public.wa_session_window (tenant_id, msisdn, window_expires_at);

-- 4. WhatsApp Inbound Messages Log
create table if not exists public.wa_inbound_message (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  msisdn       text not null,
  wam_id       text unique,
  message_type text not null default 'text',
  body         text,
  received_at  timestamptz not null default clock_timestamp(),
  raw_payload  jsonb not null default '{}'::jsonb
);

create index if not exists idx_wa_inbound_msisdn
  on public.wa_inbound_message (tenant_id, msisdn, received_at desc);

-- 5. WhatsApp Compliance Alerts Table (Notifies Principal when template is rejected)
create table if not exists public.wa_compliance_alert (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  template_id uuid references public.wa_template(id) on delete cascade,
  alert_type  text not null default 'TEMPLATE_REJECTED',
  title       text not null,
  message     text not null,
  is_resolved boolean not null default false,
  created_at  timestamptz not null default clock_timestamp()
);

create index if not exists idx_wa_compliance_alert_tenant
  on public.wa_compliance_alert (tenant_id, is_resolved, created_at desc);

-- 6. Enhance public.message with WhatsApp specific tracking columns
alter table public.message
  add column if not exists wa_template_id uuid references public.wa_template(id) on delete set null,
  add column if not exists is_freeform boolean not null default false;

-- 7. Audit Triggers
drop trigger if exists trg_wa_template_audit on public.wa_template;
create trigger trg_wa_template_audit
  after insert or update or delete on public.wa_template
  for each row execute function app.tg_audit_row();

drop trigger if exists trg_wa_session_window_audit on public.wa_session_window;
create trigger trg_wa_session_window_audit
  after insert or update or delete on public.wa_session_window
  for each row execute function app.tg_audit_row();

-- 8. Business Logic Functions

-- Check whether 24-hour customer service session window is currently open
create or replace function public.wa_window_open(
  p_tenant_id uuid,
  p_msisdn text
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_msisdn is null or trim(p_msisdn) = '' then
    return false;
  end if;

  return exists (
    select 1
    from public.wa_session_window
    where tenant_id = p_tenant_id
      and msisdn = trim(p_msisdn)
      and window_expires_at > clock_timestamp()
  );
end;
$$;

-- Inbound Webhook: Process incoming message and renew 24h session window
create or replace function public.process_wa_inbound_message(
  p_tenant_id uuid,
  p_msisdn text,
  p_body text default null,
  p_wam_id text default null,
  p_received_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_norm_phone text := trim(p_msisdn);
  v_inbound_id uuid;
  v_recv_at timestamptz := coalesce(p_received_at, clock_timestamp());
begin
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
$$;

-- AC 2: Attach template to message/campaign with status enforcement
create or replace function public.attach_wa_template_to_message(
  p_message_id uuid,
  p_template_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status public.wa_template_status;
  v_name text;
begin
  select status, meta_template_name into v_status, v_name
  from public.wa_template
  where id = p_template_id;

  if not found then
    raise exception 'WhatsApp template not found: %', p_template_id using errcode = 'P0002';
  end if;

  if v_status in ('PENDING', 'REJECTED') then
    raise exception 'Cannot attach template %: current Meta status is %', v_name, v_status
      using errcode = '22023';
  end if;

  update public.message
  set wa_template_id = p_template_id,
      is_freeform = false,
      updated_at = clock_timestamp()
  where id = p_message_id;
end;
$$;

-- AC 1 & AC 4: Validate WhatsApp message before dispatch
create or replace function public.validate_wa_dispatch(
  p_message_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_msg record;
  v_tmpl record;
  v_window_open boolean;
  v_attempt_id uuid;
  v_fallback_att uuid;
begin
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
$$;

-- AC 3: Meta Template Status Sync & Invalidation
create or replace function public.sync_wa_template_status(
  p_template_id uuid,
  p_new_status public.wa_template_status,
  p_rejection_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tmpl record;
  v_paused_count int;
begin
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
$$;

-- 9. Row-Level Security
alter table public.wa_template enable row level security;
alter table public.wa_session_window enable row level security;
alter table public.wa_inbound_message enable row level security;
alter table public.wa_compliance_alert enable row level security;

-- Policies for wa_template
drop policy if exists wa_template_select on public.wa_template;
create policy wa_template_select on public.wa_template
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

drop policy if exists wa_template_modify on public.wa_template;
create policy wa_template_modify on public.wa_template
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin', 'principal')
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin', 'principal')
  );

-- Policies for wa_session_window
drop policy if exists wa_session_window_select on public.wa_session_window;
create policy wa_session_window_select on public.wa_session_window
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

-- Policies for wa_inbound_message
drop policy if exists wa_inbound_message_select on public.wa_inbound_message;
create policy wa_inbound_message_select on public.wa_inbound_message
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

-- Policies for wa_compliance_alert
drop policy if exists wa_compliance_alert_select on public.wa_compliance_alert;
create policy wa_compliance_alert_select on public.wa_compliance_alert
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

-- 10. Default Meta WhatsApp Templates Seeding Function
create or replace function public.seed_default_wa_templates(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
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
$$;

-- Seed for existing tenants
do $$
declare
  r record;
begin
  for r in select id from public.tenant loop
    perform public.seed_default_wa_templates(r.id);
  end loop;
end $$;

insert into public.wa_template (
  tenant_id, meta_template_name, category, status, body_text
)
select
  id as tenant_id,
  'monthly_challan_v1',
  'UTILITY'::public.wa_template_category,
  'APPROVED'::public.wa_template_status,
  'Dear Parent, fee challan {{1}} for {{2}} is due on {{3}}. Amount: {{4}}.'
from public.tenant
on conflict (tenant_id, meta_template_name, language) do nothing;

insert into public.wa_template (
  tenant_id, meta_template_name, category, status, body_text
)
select
  id as tenant_id,
  'sports_gala_draft_v1',
  'MARKETING'::public.wa_template_category,
  'PENDING'::public.wa_template_status,
  'Join us for the Annual Sports Gala on {{1}}.'
from public.tenant
on conflict (tenant_id, meta_template_name, language) do nothing;

insert into public.wa_template (
  tenant_id, meta_template_name, category, status, body_text, rejection_reason
)
select
  id as tenant_id,
  'commercial_discount_v1',
  'MARKETING'::public.wa_template_category,
  'REJECTED'::public.wa_template_status,
  'Get 50% discount on summer camp registration.',
  'Violates Meta Commerce Policy section 4.3 (Misleading commercial claims)'
from public.tenant
on conflict (tenant_id, meta_template_name, language) do nothing;
