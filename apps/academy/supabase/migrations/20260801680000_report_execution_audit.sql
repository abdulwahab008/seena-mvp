-- FR-S11: report execution and export audit.
--
-- Append-only is enforced by STATEMENT-level triggers, so an UPDATE or DELETE
-- fails with 'audit_append_only' for every role including a tenant super
-- admin — even when RLS would have matched no rows. (PECA 2016 s.38: a school
-- group exporting minors' CNIC and B-Form data needs a defensible trail, and
-- "the app never updates it" is not a defence; the database must refuse.)

create table public.report_pii_column (
  column_pattern text primary key,
  note           text
);
alter table public.report_pii_column enable row level security;
create policy report_pii_column_read on public.report_pii_column for select to authenticated using (true);

insert into public.report_pii_column (column_pattern, note) values
  ('cnic', 'National ID'), ('b_?form', 'Child registration certificate'), ('phone', 'Phone number'),
  ('mobile', 'Phone number'), ('address', 'Home address'), ('email', 'Email address'), ('dob|date_of_birth|birth', 'Date of birth');

create table public.report_audit (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  user_id      uuid not null references auth.users(id),
  report_key   text not null check (length(btrim(report_key)) > 0),
  dataset_key  text not null,
  filters_json jsonb not null default '{}'::jsonb,
  row_count    int not null default 0 check (row_count >= 0),
  contains_pii boolean not null,
  reason       text,
  destination  text not null default 'screen' check (destination in ('screen', 'csv', 'xlsx', 'pdf', 'api')),
  ip           inet,
  executed_at  timestamptz not null default clock_timestamp(),
  constraint pii_export_needs_reason check (not contains_pii or length(btrim(coalesce(reason, ''))) >= 20)
);
create index idx_report_audit_user_time on public.report_audit (tenant_id, user_id, executed_at desc);

create or replace function app.fn_report_audit_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'audit_append_only' using errcode = '42501', hint = 'report_audit rows can never be changed or removed';
end;
$$;
create trigger trg_report_audit_append_only before update or delete on public.report_audit
  for each statement execute function app.fn_report_audit_append_only();
create trigger trg_report_audit_no_truncate before truncate on public.report_audit
  for each statement execute function app.fn_report_audit_append_only();

create table public.report_audit_alert (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  user_id      uuid not null references auth.users(id),
  report_keys  text[] not null,
  pii_report_count int not null,
  window_start timestamptz not null,
  alert_day    date not null,
  created_at   timestamptz not null default now(),
  constraint uq_report_audit_alert_user_day unique (tenant_id, user_id, alert_day)
);
create index idx_report_audit_alert_tenant on public.report_audit_alert (tenant_id, created_at desc);

alter table public.report_audit enable row level security;
alter table public.report_audit_alert enable row level security;

create policy report_audit_insert_own on public.report_audit
  for insert to authenticated
  with check (tenant_id = app.auth_tenant_id() and user_id = (select auth.uid()));
create policy report_audit_read_owner_or_super_admin on public.report_audit
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin'));
create policy report_audit_alert_read_owner on public.report_audit_alert
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin'));

create or replace function public.fn_report_contains_pii(p_dataset_key text, p_columns_json jsonb)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
      from jsonb_array_elements_text(case when jsonb_typeof(p_columns_json) = 'array' then p_columns_json else '[]'::jsonb end) c(name)
      join public.report_pii_column p on lower(c.name) ~ p.column_pattern
  );
$$;
revoke execute on function public.fn_report_contains_pii(text, jsonb) from public, anon;
grant execute on function public.fn_report_contains_pii(text, jsonb) to authenticated;

-- Every report run and export goes through here: the caller cannot choose the
-- user, the tenant, or whether the PII flag is set.
create or replace function public.record_report_run(
  p_report_key text, p_dataset_key text, p_columns jsonb, p_filters jsonb, p_row_count int,
  p_reason text default null, p_destination text default 'screen', p_ip text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pii boolean := public.fn_report_contains_pii(p_dataset_key, p_columns);
  v_id  uuid;
begin
  if (select auth.uid()) is null or app.auth_tenant_id() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;
  if v_pii and length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'REASON_REQUIRED_FOR_PII_EXPORT' using errcode = '22023', hint = 'Give a reason of at least 20 characters';
  end if;

  insert into public.report_audit (tenant_id, user_id, report_key, dataset_key, filters_json, row_count, contains_pii, reason, destination, ip)
  values (app.auth_tenant_id(), (select auth.uid()), p_report_key, p_dataset_key, coalesce(p_filters, '{}'::jsonb), greatest(p_row_count, 0),
          v_pii, nullif(btrim(p_reason), ''), p_destination, app.fn_parse_request_ip(p_ip))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.record_report_run(text, text, jsonb, jsonb, int, text, text, text) from public, anon;
grant execute on function public.record_report_run(text, text, jsonb, jsonb, int, text, text, text) to authenticated;

-- The audit list is itself a report: exporting it writes a further audit row.
create or replace function public.export_report_audit(p_user_id uuid default null, p_from timestamptz default null, p_to timestamptz default null, p_ip text default null)
returns setof public.report_audit
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  if app.auth_role() not in ('owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select count(*) into v_count from public.report_audit
   where tenant_id = app.auth_tenant_id()
     and (p_user_id is null or user_id = p_user_id)
     and (p_from is null or executed_at >= p_from) and (p_to is null or executed_at < p_to);

  perform public.record_report_run('report_audit', 'report_audit', '["user_id","report_key","executed_at","ip"]'::jsonb,
    jsonb_build_object('user_id', p_user_id, 'from', p_from, 'to', p_to), v_count, null, 'csv', p_ip);

  return query
  select * from public.report_audit
   where tenant_id = app.auth_tenant_id()
     and (p_user_id is null or user_id = p_user_id)
     and (p_from is null or executed_at >= p_from) and (p_to is null or executed_at < p_to)
   order by executed_at desc;
end;
$$;
revoke execute on function public.export_report_audit(uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.export_report_audit(uuid, timestamptz, timestamptz, text) to authenticated;

-- Hourly: more than 3 PII-bearing exports by one user in 24 hours alerts the owner.
create or replace function public.check_pii_export_alerts()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  with hits as (
    select tenant_id, user_id, array_agg(distinct report_key order by report_key) as keys, count(*)::int as n
      from public.report_audit
     where contains_pii and executed_at > now() - interval '24 hours'
     group by tenant_id, user_id
    having count(*) > 3
  ), ins as (
    insert into public.report_audit_alert (tenant_id, user_id, report_keys, pii_report_count, window_start, alert_day)
    select tenant_id, user_id, keys, n, now() - interval '24 hours', app.fn_karachi_today() from hits
    on conflict (tenant_id, user_id, alert_day) do update set report_keys = excluded.report_keys, pii_report_count = excluded.pii_report_count
    returning 1
  )
  select count(*)::int into v_n from ins;
  return v_n;
end;
$$;
revoke execute on function public.check_pii_export_alerts() from public, anon, authenticated;
grant execute on function public.check_pii_export_alerts() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('pii_export_alert', '0 * * * *', 'select public.check_pii_export_alerts();');
  end if;
exception
  when others then null;
end;
$$;
