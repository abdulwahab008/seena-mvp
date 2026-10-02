-- FR-S06: WhatsApp digest template delivery.
--
-- WhatsApp only lets a business message someone outside the 24-hour service
-- window with an APPROVED template whose structure Meta froze at approval. A
-- digest therefore never goes out as free-form text: it is a template message
-- with exactly the declared number of variables, or it does not go out on
-- WhatsApp at all. When WhatsApp refuses (re-engagement, a template error), the
-- same figures are re-sent as SMS inside a minute and the delivery row records
-- channel_used = 'sms' and fallback_of = the WhatsApp attempt.
--
-- Mapping onto the existing communication schema (FR-M01..M04), which this
-- extends rather than duplicates:
--   wa_template      -> the tenant's approved templates (+ report_key, variable_count);
--                       the WABA language is wa_template.language ('en', 'ur'), the
--                       approval state is wa_template.status
--   outbox           -> report_delivery (S05) is the digest outbox: variables,
--                       template_name, channel_used, error_code (provider code),
--                       fallback_of. A recipient only ever reads their own rows
--                       (report_delivery_self), so no one reads another user's variables.
--
-- The WABA access token is NEVER a client-visible env var: it lives in Supabase
-- Vault and is read by the server worker through digest_provider_secret()
-- (service_role only).
--
-- Not built here: the Meta template submission/approval itself (a Meta-side,
-- days-long process). Templates are registered with their approval status as Meta
-- reports it (the existing WhatsApp Compliance screen / sync_wa_template_status).

alter table public.wa_template
  add column if not exists report_key     text references public.digest_report(report_key),
  add column if not exists variable_count int check (variable_count is null or variable_count >= 0);
create index if not exists idx_wa_template_report on public.wa_template (tenant_id, report_key, language) where report_key is not null;

alter table public.digest_report add column if not exists wa_template_name text;
update public.digest_report set wa_template_name = 'daily_summary_v1' where report_key = 'group_daily_summary';

alter table public.report_delivery
  add column if not exists channel_used  text check (channel_used in ('email', 'sms', 'whatsapp', 'in_app')),
  add column if not exists fallback_of   uuid references public.report_delivery(id) on delete set null,
  add column if not exists template_name text,
  add column if not exists variables     jsonb;
create index if not exists idx_report_delivery_fallback on public.report_delivery (fallback_of) where fallback_of is not null;

-- Standard digest template, English. Design note: Meta approval freezes the
-- variable count, so a template with spare slots is cheaper than a re-approval;
-- this one uses exactly the five the daily summary needs.
create or replace function public.seed_digest_wa_templates(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' and (app.auth_tenant_id() is distinct from p_tenant_id or app.auth_role() not in ('owner', 'super_admin')) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.wa_template (tenant_id, meta_template_name, category, status, language, body_text, report_key, variable_count)
  values (p_tenant_id, 'daily_summary_v1', 'UTILITY', 'APPROVED', 'en',
          'Group summary for {{1}}: collected PKR {{2}}, outstanding PKR {{3}}, attendance {{4}}, {{5}} students enrolled.', 'group_daily_summary', 5)
  on conflict (tenant_id, meta_template_name, language) do update set report_key = excluded.report_key, variable_count = excluded.variable_count;
end;
$$;
revoke execute on function public.seed_digest_wa_templates(uuid) from public, anon;
grant execute on function public.seed_digest_wa_templates(uuid) to authenticated, service_role;

do $$
declare r record;
begin
  for r in select id from public.tenant loop
    insert into public.wa_template (tenant_id, meta_template_name, category, status, language, body_text, report_key, variable_count)
    values (r.id, 'daily_summary_v1', 'UTILITY', 'APPROVED', 'en',
            'Group summary for {{1}}: collected PKR {{2}}, outstanding PKR {{3}}, attendance {{4}}, {{5}} students enrolled.', 'group_daily_summary', 5)
    on conflict (tenant_id, meta_template_name, language) do nothing;
  end loop;
end;
$$;

-- The approved template for this tenant, report and language, with the right variable count.
create or replace function app.fn_digest_wa_template(p_tenant_id uuid, p_report_key text, p_language text)
returns public.wa_template
language sql
stable
security definer
set search_path = ''
as $$
  select t.* from public.wa_template t
    join public.digest_report r on r.report_key = t.report_key
   where t.tenant_id = p_tenant_id and t.report_key = p_report_key and t.language = p_language
     and t.status = 'APPROVED' and t.variable_count = r.variable_count
   order by t.updated_at desc limit 1;
$$;
revoke execute on function app.fn_digest_wa_template(uuid, text, text) from public, anon, authenticated;

-- AC4: choosing WhatsApp is checked at SAVE time, naming the missing template.
create or replace function public.upsert_digest_subscription(
  p_report_key text, p_cadence text, p_run_at_local time, p_channel text,
  p_timezone text default 'Asia/Karachi', p_params jsonb default '{}'::jsonb, p_language_code text default 'en'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_rep  public.digest_report%rowtype;
  v_id   uuid;
begin
  if v_uid is null or app.auth_tenant_id() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;
  select * into v_rep from public.digest_report where report_key = p_report_key;
  if not found or not (app.auth_role() = any (v_rep.allowed_roles)) then
    raise exception 'REPORT_NOT_AVAILABLE' using errcode = '42501';
  end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_timezone) then
    raise exception 'TIMEZONE_INVALID' using errcode = '22023';
  end if;
  if p_channel in ('sms', 'whatsapp') and not exists (select 1 from public.app_user where user_id = v_uid and phone_e164 is not null) then
    raise exception 'CHANNEL_CONTACT_MISSING' using errcode = '22023', hint = 'Add a mobile number to your profile first';
  end if;
  if p_channel = 'whatsapp' and (app.fn_digest_wa_template(app.auth_tenant_id(), p_report_key, p_language_code)).id is null then
    raise exception 'WA_TEMPLATE_MISSING: % (%)', coalesce(v_rep.wa_template_name, p_report_key), p_language_code using errcode = '22023',
      hint = 'No approved WhatsApp template for this report and language';
  end if;

  insert into public.report_subscription (tenant_id, user_id, report_key, params_json, cadence, run_at_local, timezone, channel, language_code)
  values (app.auth_tenant_id(), v_uid, p_report_key, coalesce(p_params, '{}'::jsonb), p_cadence, p_run_at_local, p_timezone, p_channel, p_language_code)
  on conflict (user_id, report_key, channel, cadence, run_at_local)
  do update set params_json = excluded.params_json, timezone = excluded.timezone, language_code = excluded.language_code, is_active = true
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.upsert_digest_subscription(text, text, time, text, text, jsonb, text) from public, anon;
grant execute on function public.upsert_digest_subscription(text, text, time, text, text, jsonb, text) to authenticated;

-- ── dispatcher: resolve the channel and template once, at dispatch ────────

create or replace function public.dispatch_due_digests(p_now timestamptz default now())
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  s        record;
  v_local  timestamp;
  v_slot   timestamptz;
  v_id     uuid;
  v_pay    jsonb;
  v_tmpl   public.wa_template;
  v_chan   text;
  v_tname  text;
  v_empty  boolean;
  v_n      int := 0;
begin
  for s in
    select sub.* from public.report_subscription sub
      join public.app_user u on u.user_id = sub.user_id and u.status = 'active'
     where sub.is_active
  loop
    v_local := p_now at time zone s.timezone;
    v_slot := (v_local::date + s.run_at_local) at time zone s.timezone;
    if not (v_slot <= p_now and p_now < v_slot + interval '30 minutes') then
      continue;
    end if;
    if s.cadence = 'weekly' and extract(isodow from v_local)::int <> coalesce((s.params_json ->> 'weekday')::int, 1) then continue; end if;
    if s.cadence = 'monthly' and extract(day from v_local)::int <> coalesce((s.params_json ->> 'day_of_month')::int, 1) then continue; end if;

    v_pay := app.fn_digest_build(s.tenant_id, s.user_id, s.report_key, s.params_json);
    v_empty := coalesce((v_pay ->> 'row_count')::int, 0) = 0;
    v_chan := s.channel;
    v_tname := null;
    if v_chan = 'whatsapp' then
      v_tmpl := app.fn_digest_wa_template(s.tenant_id, s.report_key, s.language_code);
      if v_tmpl.id is null then
        -- the template was withdrawn since the subscription was saved: never free-form, go straight to SMS
        v_chan := 'sms';
      else
        v_tname := v_tmpl.meta_template_name;
      end if;
    end if;

    insert into public.report_delivery (tenant_id, subscription_id, scheduled_for, attempt_no, status, next_attempt_at, payload, channel_used, template_name, variables)
    values (s.tenant_id, s.id, v_slot, 1,
            case when v_empty then 'skipped_empty' else 'pending' end,
            case when v_empty then null else v_slot end,
            v_pay, v_chan, v_tname, case when v_chan = 'whatsapp' then v_pay -> 'variables' else null end)
    on conflict (subscription_id, scheduled_for, attempt_no) do nothing
    returning id into v_id;
    if v_id is null then continue; end if;
    v_n := v_n + 1;

    if v_chan = 'in_app' and not v_empty then
      insert into public.user_notification (tenant_id, user_id, kind, title, body, link)
      values (s.tenant_id, s.user_id, 'report_digest', 'Group daily summary', v_pay ->> 'text', '/dashboard/owner');
      update public.report_delivery set status = 'sent', delivered_at = p_now, next_attempt_at = null, provider_msg_id = 'in_app:' || v_id where id = v_id;
    end if;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.dispatch_due_digests(timestamptz) from public, anon, authenticated;
grant execute on function public.dispatch_due_digests(timestamptz) to service_role;

-- ── worker: the effective channel and template travel with the claim ──────

drop function if exists public.claim_digest_deliveries(int, timestamptz);
create function public.claim_digest_deliveries(p_limit int default 20, p_now timestamptz default now())
returns table (delivery_id uuid, tenant_id uuid, channel text, language_code text, to_msisdn text, to_email text, title text, body text, variables jsonb, attempt_no int, template_name text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with due as (
    select d.id from public.report_delivery d
      join public.report_subscription s on s.id = d.subscription_id and s.is_active
     where d.status = 'pending' and d.next_attempt_at <= p_now
     order by d.next_attempt_at
     for update of d skip locked
     limit least(greatest(p_limit, 1), 100)
  ), leased as (
    update public.report_delivery d set next_attempt_at = p_now + interval '10 minutes' from due where d.id = due.id returning d.*
  )
  select l.id, l.tenant_id, coalesce(l.channel_used, s.channel), s.language_code, u.phone_e164, au.email::text, 'Group daily summary'::text,
         l.payload ->> 'text', case when coalesce(l.channel_used, s.channel) = 'whatsapp' then l.variables else l.payload -> 'variables' end, l.attempt_no,
         case when coalesce(l.channel_used, s.channel) = 'whatsapp' then l.template_name end
    from leased l
    join public.report_subscription s on s.id = l.subscription_id
    join public.app_user u on u.user_id = s.user_id
    join auth.users au on au.id = s.user_id;
end;
$$;
revoke execute on function public.claim_digest_deliveries(int, timestamptz) from public, anon, authenticated;
grant execute on function public.claim_digest_deliveries(int, timestamptz) to service_role;

-- ── result handling: retry transient errors, fall back to SMS on WhatsApp refusals ──

create or replace function app.fn_wa_fallback_error(p_code text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  -- 131047 re-engagement message (outside the 24 h window); 132000-132016 template
  -- errors (missing, paused, disabled, parameter mismatch); WA_* are our own pre-send checks
  select coalesce(p_code ~ '^(131047|1320(0[0-9]|1[0-6]))$' or p_code like 'WA\_%', false);
$$;

create or replace function public.record_digest_attempt_result(
  p_delivery_id uuid, p_ok boolean, p_provider_msg_id text default null, p_error text default null, p_transient boolean default false,
  p_now timestamptz default now(), p_error_code text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d       public.report_delivery%rowtype;
  v_chan  text;
  v_tries int;
  v_next  int;
begin
  select * into d from public.report_delivery where id = p_delivery_id and status = 'pending' for update;
  if not found then
    return;
  end if;
  v_chan := coalesce(d.channel_used, (select s.channel from public.report_subscription s where s.id = d.subscription_id));
  if p_ok then
    update public.report_delivery set status = 'sent', provider_msg_id = p_provider_msg_id, error = null, error_code = null, delivered_at = p_now, next_attempt_at = null, channel_used = v_chan where id = d.id;
    return;
  end if;

  update public.report_delivery
     set status = 'failed', error = left(p_error, 1000), error_code = left(p_error_code, 100), next_attempt_at = null, channel_used = v_chan
   where id = d.id;
  select coalesce(max(x.attempt_no), 0) + 1 into v_next from public.report_delivery x where x.subscription_id = d.subscription_id and x.scheduled_for = d.scheduled_for;

  if v_chan = 'whatsapp' and app.fn_wa_fallback_error(p_error_code) then
    -- same figures, by SMS, due immediately (the worker polls every minute: well inside 60 s)
    insert into public.report_delivery (tenant_id, subscription_id, scheduled_for, attempt_no, status, next_attempt_at, payload, channel_used, fallback_of)
    values (d.tenant_id, d.subscription_id, d.scheduled_for, v_next, 'pending', p_now, d.payload, 'sms', d.id)
    on conflict do nothing;
    return;
  end if;

  select count(*) into v_tries from public.report_delivery x
   where x.subscription_id = d.subscription_id and x.scheduled_for = d.scheduled_for and x.channel_used = v_chan;
  if p_transient and v_tries < 3 then
    insert into public.report_delivery (tenant_id, subscription_id, scheduled_for, attempt_no, status, next_attempt_at, payload, channel_used, template_name, variables, fallback_of)
    values (d.tenant_id, d.subscription_id, d.scheduled_for, v_next, 'pending',
            d.scheduled_for + case when v_tries = 1 then interval '5 minutes' else interval '25 minutes' end, d.payload, v_chan, d.template_name, d.variables, d.fallback_of)
    on conflict do nothing;
  end if;
end;
$$;
revoke execute on function public.record_digest_attempt_result(uuid, boolean, text, text, boolean, timestamptz, text) from public, anon, authenticated;
grant execute on function public.record_digest_attempt_result(uuid, boolean, text, text, boolean, timestamptz, text) to service_role;

-- The status screen also shows the channel that finally carried the message.
drop view if exists public.v_report_subscription_status;
create view public.v_report_subscription_status with (security_invoker = true) as
select s.id, s.tenant_id, s.user_id, s.report_key, d.display_name, s.cadence, s.run_at_local, s.timezone, s.channel, s.language_code, s.is_active,
       l.scheduled_for as last_scheduled_for, l.status as last_status, l.attempt_no as last_attempt_no, l.error as last_error, l.error_code as last_error_code,
       l.provider_msg_id as last_provider_msg_id, l.delivered_at as last_delivered_at, l.channel_used as last_channel_used, (l.fallback_of is not null) as last_was_fallback
  from public.report_subscription s
  join public.digest_report d on d.report_key = s.report_key
  left join lateral (
    select x.* from public.report_delivery x where x.subscription_id = s.id order by x.scheduled_for desc, x.attempt_no desc limit 1
  ) l on true;
grant select on public.v_report_subscription_status to authenticated;

-- ── WABA token: Vault, read by the server worker only ─────────────────────

create or replace function public.digest_provider_secret(p_name text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_secret text;
begin
  if p_name not in ('whatsapp_waba_token', 'whatsapp_phone_number_id') then
    raise exception 'SECRET_NOT_ALLOWED' using errcode = '42501';
  end if;
  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1' into v_secret using p_name;
  exception when others then
    return null;
  end;
  return v_secret;
end;
$$;
revoke execute on function public.digest_provider_secret(text) from public, anon, authenticated;
grant execute on function public.digest_provider_secret(text) to service_role;
