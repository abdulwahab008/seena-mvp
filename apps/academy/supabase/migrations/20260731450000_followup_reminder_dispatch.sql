-- FR-B05: dispatch automated follow-up and appointment reminders.
--
-- Scope cuts, documented per this session's established conventions:
--   * No pg_cron locally (neither pg_cron nor pg_net is enabled anywhere
--     in this project — confirmed by grep across every migration and
--     config.toml) — fn_queue_followup_reminders(), fn_queue_
--     appointment_reminders() and fn_process_sms_fallbacks() are plain
--     callable functions, correct and pgTAP-tested, just not wired to a
--     schedule yet — the same "not wired to a schedule (no pg_cron
--     locally)" pattern already used for fn_expire_offers() (FR-B16),
--     fn_apply_late_fee_charges() (FR-K13), fn_escalate_overdue_steps()
--     (FR-D12) and half a dozen others in this codebase.
--   * No send-whatsapp Edge Function and no actual WhatsApp/SMS
--     delivery — the same "data layer only" pattern as FR-K11/B11/B13:
--     these functions build and queue exactly the outbound_message row
--     a future sender would consume (channel, template_id, locale,
--     to_phone, payload), and mark_outbound_message_failed() stands in
--     for the delivery-status webhook callback a real provider
--     integration would call.
--   * admission_enquiry has no per-enquiry language column — child_
--     name_ur being non-null is the only existing per-enquiry Urdu
--     signal in this schema (confirmed by research), so it is reused
--     here as the locale proxy, same as whatsapp_opt_in is already
--     reused as the channel proxy in fn_build_interview_notification_
--     payload() (FR-B13).
--   * channel reuses the existing followup_channel enum values
--     ('whatsapp'/'sms') via a check constraint rather than minting a
--     second, narrower enum for the same two values.
--   * Tenant isolation: the three queue/sweep functions are granted to
--     BOTH authenticated (manual "check now" trigger from the UI) and
--     service_role (a future cron sweep). Each driving query filters
--     with "app.auth_tenant_id() is null or ... = app.auth_tenant_id()"
--     so an authenticated officer only ever sweeps their own tenant
--     (their JWT always carries a tenant_id), while service_role — which
--     carries no JWT and so has a null tenant_id — sweeps every tenant.
--   * fn_queue_appointment_reminders()'s rate-cap check (max 2 reminders
--     per enquiry per 24h) is wrapped in a pg_advisory_xact_lock keyed on
--     the enquiry id, closing the TOCTOU race where two concurrent calls
--     could both read the same stale count and both insert, same
--     advisory-lock pattern as FR-K10/K16/B07/B11/B13.

create type public.reminder_kind as enum ('followup_officer', 'appointment_parent');
create type public.outbound_status as enum ('queued', 'sent', 'failed', 'rate_capped');

create table public.message_template (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  code          text not null,
  channel       public.followup_channel not null check (channel in ('whatsapp', 'sms')),
  locale        text not null check (locale in ('en', 'ur')),
  template_id   text not null,
  body_preview  text,
  constraint uq_message_template unique (tenant_id, code, channel, locale)
);

create or replace function public.seed_default_message_templates(p_tenant_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.message_template (tenant_id, code, channel, locale, template_id, body_preview)
  select p_tenant_id, code, channel::public.followup_channel, locale,
    code || '_' || channel || '_' || locale || '_v1',
    case when locale = 'ur' then 'یاد دہانی: ' || code else 'Reminder: ' || code end
  from unnest(array['followup_reminder', 'test_reminder', 'interview_reminder']) as code,
       unnest(array['whatsapp', 'sms']) as channel,
       unnest(array['en', 'ur']) as locale;
$$;

revoke execute on function public.seed_default_message_templates(uuid) from public, anon, authenticated;
grant execute on function public.seed_default_message_templates(uuid) to service_role;

-- Widened (same signature — no caller ripple): every new tenant gets the
-- default reminder template registry, same as it already gets default
-- roles and class levels. Everything else here is the function's
-- existing, unchanged body (including the owner tenant_invitation row)
-- — only the one new seed call is added.
create or replace function public.provision_tenant(p_slug text, p_legal_name text, p_owner_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
begin
  if p_slug !~ '^[a-z0-9][a-z0-9-]{2,49}$' then
    raise exception 'TENANT_SLUG_INVALID' using errcode = '22023';
  end if;

  if exists (select 1 from public.tenant where lower(slug) = lower(p_slug)) then
    raise exception 'TENANT_SLUG_TAKEN' using errcode = '23505';
  end if;

  insert into public.tenant (slug, name, legal_name, status)
  values (p_slug, p_legal_name, p_legal_name, 'provisioning')
  returning id into v_tenant_id;

  perform public.seed_tenant_roles(v_tenant_id);
  perform public.seed_default_class_levels(v_tenant_id);
  perform public.seed_default_message_templates(v_tenant_id);

  insert into public.campus (tenant_id, code, name)
  values (v_tenant_id, 'MAIN', p_legal_name)
  returning id into v_campus_id;

  insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on, is_current, status)
  values (
    v_tenant_id,
    v_campus_id,
    to_char(current_date, 'YYYY') || '-' || to_char(current_date + interval '1 year', 'YY'),
    date_trunc('year', current_date)::date,
    (date_trunc('year', current_date) + interval '1 year' - interval '1 day')::date,
    true,
    'active'
  );

  insert into public.tenant_invitation (tenant_id, email, app_role)
  values (v_tenant_id, p_owner_email, 'owner');

  update public.tenant set status = 'active' where id = v_tenant_id;

  return v_tenant_id;
end;
$$;

create table public.outbound_message (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  enquiry_id      uuid not null references public.admission_enquiry(id) on delete cascade,
  reminder_kind   public.reminder_kind not null,
  followup_id     uuid references public.admission_followup(id) on delete cascade,
  test_sitting_id uuid references public.admission_test_sitting(id) on delete cascade,
  interview_id    uuid references public.admission_interview(id) on delete cascade,
  channel         public.followup_channel not null check (channel in ('whatsapp', 'sms')),
  template_id     text,
  locale          text not null check (locale in ('en', 'ur')),
  to_phone        text not null,
  payload         jsonb not null default '{}'::jsonb,
  status          public.outbound_status not null default 'queued',
  failure_code    text,
  provider_msg_id text,
  dedupe_key      text not null,
  created_at      timestamptz not null default clock_timestamp(),
  constraint uq_outbound_dedupe_key unique (dedupe_key),
  constraint chk_outbound_source check (
    (reminder_kind = 'followup_officer' and followup_id is not null and test_sitting_id is null and interview_id is null)
    or
    (reminder_kind = 'appointment_parent' and followup_id is null and (test_sitting_id is not null) <> (interview_id is not null))
  )
);

create index idx_outbound_message_enquiry on public.outbound_message (enquiry_id, reminder_kind, created_at);

create trigger outbound_message_audit after insert or update or delete on public.outbound_message
  for each row execute function app.tg_audit_row();

-- AC: exactly one outbound message row per (followup, reminder kind,
-- channel) no matter how many times the queueing function runs — the
-- unique dedupe_key, not a time-window check, is what makes re-running
-- the "cron" safe.
create or replace function public.fn_queue_followup_reminders()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row     record;
  v_phone   text;
  v_tmpl    text;
  v_count   int := 0;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- AC/defense-in-depth: an authenticated officer's manual "check now"
  -- only ever sweeps their own tenant (app.auth_tenant_id() is never
  -- null for them) — only a service_role caller (a real future cron,
  -- which has no tenant of its own) sweeps every tenant in one pass.
  for v_row in
    select f.id, f.tenant_id, f.campus_id, f.enquiry_id, f.assigned_to
      from public.admission_followup f
     where f.completed_at is null
       and f.due_at <= clock_timestamp() + interval '30 minutes'
       and (app.auth_tenant_id() is null or f.tenant_id = app.auth_tenant_id())
  loop
    if v_row.assigned_to is null then
      continue;
    end if;
    select phone_e164 into v_phone from public.app_user where user_id = v_row.assigned_to;
    if v_phone is null then
      continue;
    end if;

    select template_id into v_tmpl from public.message_template
     where tenant_id = v_row.tenant_id and code = 'followup_reminder' and channel = 'whatsapp' and locale = 'en';

    insert into public.outbound_message (
      tenant_id, campus_id, enquiry_id, reminder_kind, followup_id, channel, template_id, locale, to_phone, payload, dedupe_key
    ) values (
      v_row.tenant_id, v_row.campus_id, v_row.enquiry_id, 'followup_officer', v_row.id, 'whatsapp', v_tmpl, 'en', v_phone,
      jsonb_build_object('followup_id', v_row.id), v_row.id::text || ':followup_officer:whatsapp'
    )
    on conflict (dedupe_key) do nothing;
    if found then
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.fn_queue_followup_reminders() from public, anon;
grant execute on function public.fn_queue_followup_reminders() to authenticated, service_role;

-- AC: a parent who already has 2 messages in the trailing 24 hours gets a
-- 3rd row inserted as 'rate_capped' (visible to the officer), not simply
-- dropped — and AC: the enquiry's own child_name_ur presence selects the
-- Urdu-approved template.
create or replace function public.fn_queue_appointment_reminders()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row      record;
  v_locale   text;
  v_channel  public.followup_channel;
  v_tmpl     text;
  v_recent   int;
  v_status   public.outbound_status;
  v_count    int := 0;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- AC/defense-in-depth: same tenant-scoping rule as
  -- fn_queue_followup_reminders() — an authenticated officer only
  -- sweeps their own tenant; only service_role sweeps every tenant.
  for v_row in
    select
      aa.tenant_id, aa.campus_id, aa.enquiry_id,
      ae.phone_e164, ae.whatsapp_opt_in, ae.child_name_ur,
      ats.id as test_sitting_id, null::uuid as interview_id, 'test_reminder' as code, ats.starts_at
    from public.admission_test_sitting ats
    join public.admission_test_candidate atc on atc.sitting_id = ats.id and atc.cancelled_at is null
    join public.admission_application aa on aa.id = atc.application_id
    join public.admission_enquiry ae on ae.id = aa.enquiry_id
   where ats.starts_at <= clock_timestamp() + interval '24 hours' and ats.starts_at > clock_timestamp()
     and (app.auth_tenant_id() is null or aa.tenant_id = app.auth_tenant_id())
    union all
    select
      aa.tenant_id, aa.campus_id, aa.enquiry_id,
      ae.phone_e164, ae.whatsapp_opt_in, ae.child_name_ur,
      null::uuid as test_sitting_id, ai.id as interview_id, 'interview_reminder' as code, ai.starts_at
    from public.admission_interview ai
    join public.admission_application aa on aa.id = ai.application_id
    join public.admission_enquiry ae on ae.id = aa.enquiry_id
   where ai.status = 'scheduled' and ai.starts_at <= clock_timestamp() + interval '24 hours' and ai.starts_at > clock_timestamp()
     and (app.auth_tenant_id() is null or aa.tenant_id = app.auth_tenant_id())
  loop
    v_locale := case when v_row.child_name_ur is not null then 'ur' else 'en' end;
    v_channel := case when v_row.whatsapp_opt_in then 'whatsapp' else 'sms' end;

    -- AC/defense-in-depth: an advisory lock keyed on the enquiry
    -- serializes the count-then-insert rate-cap check — without it, two
    -- concurrent appointments due for the same enquiry could each read
    -- the same "2 already sent" count and both slip in as 'queued'
    -- instead of one correctly landing as 'rate_capped'. The same
    -- untestable-in-single-connection-pgTAP caveat already documented
    -- elsewhere in this codebase (FR-K10, FR-K16, FR-B07, FR-B11).
    perform pg_advisory_xact_lock(hashtextextended('appointment-reminder-rate-cap:' || v_row.enquiry_id::text, 0));

    select count(*) into v_recent from public.outbound_message
     where enquiry_id = v_row.enquiry_id and reminder_kind = 'appointment_parent'
       and created_at > clock_timestamp() - interval '24 hours';
    v_status := case when v_recent >= 2 then 'rate_capped' else 'queued' end;

    select template_id into v_tmpl from public.message_template
     where tenant_id = v_row.tenant_id and code = v_row.code and channel = v_channel and locale = v_locale;

    insert into public.outbound_message (
      tenant_id, campus_id, enquiry_id, reminder_kind, test_sitting_id, interview_id, channel, template_id, locale, to_phone,
      payload, status, dedupe_key
    ) values (
      v_row.tenant_id, v_row.campus_id, v_row.enquiry_id, 'appointment_parent', v_row.test_sitting_id, v_row.interview_id,
      v_channel, v_tmpl, v_locale, v_row.phone_e164,
      jsonb_build_object('starts_at', v_row.starts_at), v_status,
      coalesce(v_row.test_sitting_id, v_row.interview_id)::text || ':appointment_parent:' || v_channel
    )
    on conflict (dedupe_key) do nothing;
    if found then
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.fn_queue_appointment_reminders() from public, anon;
grant execute on function public.fn_queue_appointment_reminders() to authenticated, service_role;

-- Stands in for the delivery-status webhook a real WhatsApp provider
-- integration would call.
create or replace function public.mark_outbound_message_failed(p_message_id uuid, p_failure_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.outbound_message set status = 'failed', failure_code = p_failure_code
   where id = p_message_id and (v_tenant_id is null or tenant_id = v_tenant_id);
  if not found then
    raise exception 'MESSAGE_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function public.mark_outbound_message_failed(uuid, text) from public, anon;
grant execute on function public.mark_outbound_message_failed(uuid, text) to authenticated, service_role;

-- AC: a permanent WhatsApp failure falls back to SMS once 5 minutes have
-- passed, and the original row's failure_code is left untouched (never
-- cleared), so it's retained exactly as the AC asks.
create or replace function public.fn_process_sms_fallbacks()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row   record;
  v_tmpl  text;
  v_count int := 0;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- AC/defense-in-depth: same tenant-scoping rule as the two queue
  -- functions above.
  for v_row in
    select * from public.outbound_message
     where channel = 'whatsapp' and status = 'failed' and created_at <= clock_timestamp() - interval '5 minutes'
       and (app.auth_tenant_id() is null or tenant_id = app.auth_tenant_id())
  loop
    select template_id into v_tmpl from public.message_template
     where tenant_id = v_row.tenant_id and locale = v_row.locale and channel = 'sms'
       and code = case when v_row.reminder_kind = 'followup_officer' then 'followup_reminder'
                        when v_row.test_sitting_id is not null then 'test_reminder'
                        else 'interview_reminder' end;

    insert into public.outbound_message (
      tenant_id, campus_id, enquiry_id, reminder_kind, followup_id, test_sitting_id, interview_id, channel, template_id,
      locale, to_phone, payload, dedupe_key
    ) values (
      v_row.tenant_id, v_row.campus_id, v_row.enquiry_id, v_row.reminder_kind, v_row.followup_id, v_row.test_sitting_id,
      v_row.interview_id, 'sms', v_tmpl, v_row.locale, v_row.to_phone, v_row.payload,
      regexp_replace(v_row.dedupe_key, ':whatsapp$', ':sms')
    )
    on conflict (dedupe_key) do nothing;
    if found then
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.fn_process_sms_fallbacks() from public, anon;
grant execute on function public.fn_process_sms_fallbacks() to authenticated, service_role;

alter table public.message_template enable row level security;
alter table public.outbound_message enable row level security;

create policy message_template_tenant_read on public.message_template
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

-- AC: a rate-capped (or any queued/failed) reminder stays visible to the
-- officer, scoped the same as every other campus-facing table.
create policy outbound_message_campus_read on public.outbound_message
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
