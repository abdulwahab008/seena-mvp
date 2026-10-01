-- FR-S05: scheduled report digest subscriptions.
--
-- ONE dispatcher, not one cron entry per subscription: a per-subscription pg_cron
-- job cannot be cleaned up reliably when a user is deleted and the cron table
-- becomes the real source of truth. `digest_dispatcher` runs every 5 minutes,
-- selects the subscriptions whose local slot has just arrived, and writes a
-- report_delivery row. The unique index uq_delivery_attempt makes that
-- idempotent (a second tick, or a second dispatcher, cannot double-send).
--
-- A subscription stores LOCAL time plus an IANA timezone, never a UTC instant:
-- Pakistan has no DST today, but a group that opens a Gulf campus breaks any
-- UTC-normalised assumption.
--
-- Delivery is a queue of attempts. The dispatcher decides WHAT to send and when;
-- a worker (app/api/internal/digests/run, behind the worker secret) claims due
-- attempts, hands them to a transport adapter and reports the result through
-- record_digest_attempt_result(), which owns the retry rule: a transient provider
-- error is retried twice, at 5 and 25 minutes after the scheduled time; a
-- permanent error is final. Deactivating a subscription cancels its not-yet-sent
-- attempts, so nothing orphaned fires at 20:00.
--
-- What is sent comes from digest_report: a registry of report keys and who may
-- subscribe to them. The 'group_daily_summary' builder reads the nightly
-- aggregate (FR-S01) for the subscriber's own campuses; if there is nothing to
-- report the delivery is written as 'skipped_empty' and no message goes out.

create table public.digest_report (
  report_key     text primary key check (report_key ~ '^[a-z][a-z0-9_]+$'),
  display_name   text not null,
  allowed_roles  text[] not null,
  variable_count int not null default 0 check (variable_count >= 0)
);
alter table public.digest_report enable row level security;
create policy digest_report_read on public.digest_report for select to authenticated using (true);

insert into public.digest_report (report_key, display_name, allowed_roles, variable_count) values
  ('group_daily_summary', 'Group daily summary', array['owner', 'super_admin', 'principal', 'vice_principal', 'accountant'], 5);

create table public.report_subscription (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant(id) on delete cascade,
  user_id            uuid not null references auth.users(id) on delete cascade,
  report_key         text not null references public.digest_report(report_key),
  params_json        jsonb not null default '{}'::jsonb,
  cadence            text not null default 'daily' check (cadence in ('daily', 'weekly', 'monthly')),
  run_at_local       time not null,
  timezone           text not null default 'Asia/Karachi',
  channel            text not null check (channel in ('email', 'sms', 'whatsapp', 'in_app')),
  language_code      text not null default 'en' check (language_code ~ '^[a-z]{2}(_[A-Z]{2})?$'),
  is_active          boolean not null default true,
  created_at         timestamptz not null default now(),
  constraint uq_report_subscription unique (user_id, report_key, channel, cadence, run_at_local)
);
create index idx_report_subscription_due on public.report_subscription (run_at_local) where is_active;
create index idx_report_subscription_tenant on public.report_subscription (tenant_id);

create table public.report_delivery (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  subscription_id uuid not null references public.report_subscription(id) on delete cascade,
  scheduled_for   timestamptz not null,
  attempt_no      int not null default 1 check (attempt_no between 1 and 8),
  status          text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'skipped_empty', 'cancelled')),
  next_attempt_at timestamptz,
  payload         jsonb,
  provider_msg_id text,
  error           text,
  error_code      text,
  delivered_at    timestamptz,
  created_at      timestamptz not null default clock_timestamp()
);
create unique index uq_delivery_attempt on public.report_delivery (subscription_id, scheduled_for, attempt_no);
create index idx_report_delivery_due on public.report_delivery (next_attempt_at) where status = 'pending';
create index idx_report_delivery_tenant on public.report_delivery (tenant_id);

create trigger report_subscription_audit after insert or update or delete on public.report_subscription
  for each row execute function app.tg_audit_row();

alter table public.report_subscription enable row level security;
alter table public.report_delivery enable row level security;
-- report_subscription_self: a digest is personal; not even an owner reads a colleague's.
create policy report_subscription_self on public.report_subscription for select to authenticated
  using (user_id = (select auth.uid()) and tenant_id = app.auth_tenant_id());
create policy report_delivery_self on public.report_delivery for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and exists (select 1 from public.report_subscription s where s.id = subscription_id and s.user_id = (select auth.uid())));

-- ── formatting: full figures, thousands separators, never "1.8M" ──────────
create or replace function app.fn_fmt_amount(p_paisa bigint)
returns text
language sql
immutable
set search_path = ''
as $$
  select to_char(round(p_paisa / 100.0), 'FM999,999,999,999,990');
$$;

-- ── what a digest says ────────────────────────────────────────────────────
-- Builds the digest for one subscriber from the latest aggregate day (within a
-- week) across their own campuses. row_count = 0 means "nothing to report".
create or replace function app.fn_digest_build(p_tenant_id uuid, p_user_id uuid, p_report_key text, p_params jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role     public.app_role;
  v_campuses uuid[];
  v_day      date;
  r          record;
begin
  if p_report_key <> 'group_daily_summary' then
    raise exception 'REPORT_NOT_FOUND' using errcode = 'P0002';
  end if;
  select u.app_role into v_role from public.app_user u where u.user_id = p_user_id and u.tenant_id = p_tenant_id;
  select coalesce(array_agg(uc.campus_id), '{}') into v_campuses
    from public.user_campus uc where uc.user_id = p_user_id and uc.tenant_id = p_tenant_id and uc.is_active;
  if cardinality(v_campuses) = 0 and v_role in ('owner', 'super_admin') then
    select coalesce(array_agg(c.id), '{}') into v_campuses from public.campus c where c.tenant_id = p_tenant_id;
  end if;

  select max(a.day) into v_day from public.agg_campus_day a
   where a.tenant_id = p_tenant_id and a.campus_id = any (v_campuses) and a.day between app.fn_karachi_today() - 7 and app.fn_karachi_today();
  if v_day is null then
    return jsonb_build_object('row_count', 0);
  end if;

  select count(*)::int as n, coalesce(sum(a.collected_paisa), 0)::bigint as collected, coalesce(sum(a.outstanding_paisa), 0)::bigint as outstanding,
         coalesce(sum(a.present_count), 0)::int as present, coalesce(sum(a.enrolled_count), 0)::int as enrolled
    into r
    from public.agg_campus_day a
   where a.tenant_id = p_tenant_id and a.campus_id = any (v_campuses) and a.day = v_day;

  return jsonb_build_object(
    'row_count', r.n,
    'as_of', v_day,
    'figures', jsonb_build_object('collected_paisa', r.collected, 'outstanding_paisa', r.outstanding, 'present', r.present, 'enrolled', r.enrolled),
    'variables', jsonb_build_array(
      to_char(v_day, 'DD Mon YYYY'),
      app.fn_fmt_amount(r.collected),
      app.fn_fmt_amount(r.outstanding),
      coalesce(to_char(round(r.present * 100.0 / nullif(r.enrolled, 0), 1), 'FM990.0'), '0.0') || '%',
      to_char(r.enrolled, 'FM999,999,990')),
    'text', format('Group daily summary for %s: collected PKR %s, outstanding PKR %s, attendance %s, %s students enrolled.',
                   to_char(v_day, 'DD Mon YYYY'), app.fn_fmt_amount(r.collected), app.fn_fmt_amount(r.outstanding),
                   coalesce(to_char(round(r.present * 100.0 / nullif(r.enrolled, 0), 1), 'FM990.0'), '0.0') || '%', to_char(r.enrolled, 'FM999,999,990')));
end;
$$;
revoke execute on function app.fn_digest_build(uuid, uuid, text, jsonb) from public, anon, authenticated;

-- ── managing subscriptions ────────────────────────────────────────────────

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
  if p_channel = 'sms' and not exists (select 1 from public.app_user where user_id = v_uid and phone_e164 is not null) then
    raise exception 'CHANNEL_CONTACT_MISSING' using errcode = '22023', hint = 'Add a mobile number to your profile first';
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

-- Deactivating cancels what has not been sent, so nothing fires after the click.
create or replace function public.set_digest_subscription_active(p_subscription_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.report_subscription set is_active = p_active
   where id = p_subscription_id and user_id = (select auth.uid());
  if not found then
    raise exception 'SUBSCRIPTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not p_active then
    update public.report_delivery set status = 'cancelled', next_attempt_at = null
     where subscription_id = p_subscription_id and status = 'pending';
  end if;
end;
$$;
revoke execute on function public.set_digest_subscription_active(uuid, boolean) from public, anon;
grant execute on function public.set_digest_subscription_active(uuid, boolean) to authenticated;

create or replace function public.delete_digest_subscription(p_subscription_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.report_subscription where id = p_subscription_id and user_id = (select auth.uid());
  if not found then
    raise exception 'SUBSCRIPTION_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.delete_digest_subscription(uuid) from public, anon;
grant execute on function public.delete_digest_subscription(uuid) to authenticated;

-- The subscription screen: each subscription with the outcome of its latest slot.
create view public.v_report_subscription_status with (security_invoker = true) as
select s.id, s.tenant_id, s.user_id, s.report_key, d.display_name, s.cadence, s.run_at_local, s.timezone, s.channel, s.language_code, s.is_active,
       l.scheduled_for as last_scheduled_for, l.status as last_status, l.attempt_no as last_attempt_no, l.error as last_error, l.error_code as last_error_code, l.provider_msg_id as last_provider_msg_id,
       l.delivered_at as last_delivered_at
  from public.report_subscription s
  join public.digest_report d on d.report_key = s.report_key
  left join lateral (
    select x.* from public.report_delivery x where x.subscription_id = s.id order by x.scheduled_for desc, x.attempt_no desc limit 1
  ) l on true;
grant select on public.v_report_subscription_status to authenticated;

-- ── dispatcher: cron every 5 minutes, service_role only ───────────────────

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
  v_n      int := 0;
begin
  for s in
    select sub.* from public.report_subscription sub
      join public.app_user u on u.user_id = sub.user_id and u.status = 'active'
     where sub.is_active
  loop
    v_local := p_now at time zone s.timezone;
    v_slot := (v_local::date + s.run_at_local) at time zone s.timezone;
    -- the slot opened within the last 30 minutes: tolerates a missed tick without re-sending yesterday's
    if not (v_slot <= p_now and p_now < v_slot + interval '30 minutes') then
      continue;
    end if;
    if s.cadence = 'weekly' and extract(isodow from v_local)::int <> coalesce((s.params_json ->> 'weekday')::int, 1) then continue; end if;
    if s.cadence = 'monthly' and extract(day from v_local)::int <> coalesce((s.params_json ->> 'day_of_month')::int, 1) then continue; end if;

    v_pay := app.fn_digest_build(s.tenant_id, s.user_id, s.report_key, s.params_json);
    insert into public.report_delivery (tenant_id, subscription_id, scheduled_for, attempt_no, status, next_attempt_at, payload)
    values (s.tenant_id, s.id, v_slot, 1,
            case when coalesce((v_pay ->> 'row_count')::int, 0) = 0 then 'skipped_empty' else 'pending' end,
            case when coalesce((v_pay ->> 'row_count')::int, 0) = 0 then null else v_slot end,
            v_pay)
    on conflict (subscription_id, scheduled_for, attempt_no) do nothing
    returning id into v_id;
    if v_id is null then continue; end if;
    v_n := v_n + 1;

    if s.channel = 'in_app' and coalesce((v_pay ->> 'row_count')::int, 0) > 0 then
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

-- ── worker side: claim due attempts, report results ───────────────────────

create or replace function public.claim_digest_deliveries(p_limit int default 20, p_now timestamptz default now())
returns table (delivery_id uuid, tenant_id uuid, channel text, language_code text, to_msisdn text, to_email text, title text, body text, variables jsonb, attempt_no int, template_name text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- a claimed attempt is leased for 10 minutes so a crashed worker cannot lose it nor two workers double-send
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
  select l.id, l.tenant_id, s.channel, s.language_code, u.phone_e164, au.email::text, 'Group daily summary'::text, l.payload ->> 'text', l.payload -> 'variables', l.attempt_no, null::text
    from leased l
    join public.report_subscription s on s.id = l.subscription_id
    join public.app_user u on u.user_id = s.user_id
    join auth.users au on au.id = s.user_id;
end;
$$;
revoke execute on function public.claim_digest_deliveries(int, timestamptz) from public, anon, authenticated;
grant execute on function public.claim_digest_deliveries(int, timestamptz) to service_role;

create or replace function public.record_digest_attempt_result(
  p_delivery_id uuid, p_ok boolean, p_provider_msg_id text default null, p_error text default null, p_transient boolean default false, p_now timestamptz default now(), p_error_code text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d       public.report_delivery%rowtype;
  v_retry int;
begin
  select * into d from public.report_delivery where id = p_delivery_id and status = 'pending' for update;
  if not found then
    return;
  end if;
  if p_ok then
    update public.report_delivery set status = 'sent', provider_msg_id = p_provider_msg_id, error = null, delivered_at = p_now, next_attempt_at = null where id = d.id;
    return;
  end if;

  update public.report_delivery set status = 'failed', error = left(p_error, 1000), error_code = left(p_error_code, 100), next_attempt_at = null where id = d.id;
  v_retry := d.attempt_no;  -- attempts so far for this slot (no fallback rows exist before FR-S06)
  if p_transient and v_retry < 3 then
    insert into public.report_delivery (tenant_id, subscription_id, scheduled_for, attempt_no, status, next_attempt_at, payload)
    values (d.tenant_id, d.subscription_id, d.scheduled_for, d.attempt_no + 1, 'pending',
            d.scheduled_for + case when v_retry = 1 then interval '5 minutes' else interval '25 minutes' end, d.payload)
    on conflict do nothing;
  end if;
end;
$$;
revoke execute on function public.record_digest_attempt_result(uuid, boolean, text, text, boolean, timestamptz, text) from public, anon, authenticated;
grant execute on function public.record_digest_attempt_result(uuid, boolean, text, text, boolean, timestamptz, text) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('digest_dispatcher', '*/5 * * * *', 'select public.dispatch_due_digests();');
  end if;
exception
  when others then null;
end;
$$;
