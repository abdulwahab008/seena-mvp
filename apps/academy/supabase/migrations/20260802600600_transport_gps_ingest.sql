-- FR-P06: GPS telemetry ingest hook.
--
-- Deliberately a v2 feature behind the tenant flag transport_gps (default off).
-- The ping table is the only write-heavy hot table in the product: it is
-- range-partitioned by day on pinged_at (the device's own fix time), kept out of
-- every transactional join, and has NO client access at all (RLS enabled, no
-- policy; partitions are locked down as they are created). Parents never
-- subscribe to it. They subscribe to transport_vehicle_position_latest, one row
-- per vehicle, which is the only table in the realtime publication, and whose RLS
-- policy lets a parent see only vehicles serving a route their child is
-- allocated to.
--
-- ingest_vehicle_pings() is the one write path (service role only, called by the
-- webhook route after it has authenticated the device key or the vendor HMAC).
-- It rejects when the flag is off (the route answers 404 and nothing is written),
-- accepts batches of up to 100 pings, tolerates out-of-order and repeated vendor
-- pings (unique on vehicle + fix time, latest position only moves forward) and
-- rejects absurd fixes (bad coordinates, future or very stale timestamps).
--
-- Retention: raw pings live 30 days. Before a day partition is dropped its
-- per-vehicle distance and top speed are rolled into transport_trip_distance_daily
-- (kept). Summaries and partitions are per UTC day; a school-run (05:00 to 15:00
-- PKT) never straddles the boundary. Deviation from the object list: the ping row
-- carries pinged_at (the partition key) instead of a separate device_ts, because a
-- partition key cannot be a generated column.
--
-- Scheduling: transport_ping_purge daily 22:00 UTC and
-- transport_partition_create_ahead weekly, registered when pg_cron exists.

insert into public.feature_flag (code, label, description, default_enabled, is_beta)
values ('transport_gps', 'Live bus tracking', 'Accept GPS pings from bus trackers and show live bus position to parents.', false, true)
on conflict (code) do nothing;

create table public.transport_vehicle_ping (
  tenant_id   uuid not null,
  vehicle_id  uuid not null,
  lat         numeric(9, 6) not null check (lat between -90 and 90),
  lng         numeric(9, 6) not null check (lng between -180 and 180),
  speed_kmh   numeric(5, 1) check (speed_kmh is null or speed_kmh between 0 and 300),
  heading     smallint check (heading is null or heading between 0 and 360),
  pinged_at   timestamptz not null,
  ingested_at timestamptz not null default now()
) partition by range (pinged_at);
create unique index uq_ping_vehicle_time on public.transport_vehicle_ping (vehicle_id, pinged_at);
alter table public.transport_vehicle_ping enable row level security;
revoke all on public.transport_vehicle_ping from anon, authenticated;

create table public.transport_vehicle_position_latest (
  vehicle_id uuid primary key references public.transport_vehicle(id) on delete cascade,
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  lat        numeric(9, 6) not null,
  lng        numeric(9, 6) not null,
  speed_kmh  numeric(5, 1),
  heading    smallint,
  pinged_at  timestamptz not null,
  updated_at timestamptz not null default now()
);
create index idx_position_scope on public.transport_vehicle_position_latest (tenant_id, campus_id);

create table public.transport_trip_distance_daily (
  vehicle_id     uuid not null references public.transport_vehicle(id) on delete cascade,
  day            date not null,
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  distance_km    numeric(8, 2) not null,
  ping_count     int not null,
  max_speed_kmh  numeric(5, 1),
  primary key (vehicle_id, day)
);
create index idx_distance_tenant on public.transport_trip_distance_daily (tenant_id, day);

-- Device keys: the secret is shown once at creation and stored only as a hash.
create table public.transport_gps_credential (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  label       text not null check (char_length(btrim(label)) between 1 and 80),
  secret_hash text not null,
  active      boolean not null default true,
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now()
);
create index idx_gps_credential_tenant on public.transport_gps_credential (tenant_id);
alter table public.transport_gps_credential enable row level security;
-- no policy: the hash never leaves the database

-- Vehicles serving a route a signed-in parent's child is allocated to.
create or replace function app.fn_parent_vehicle_ids()
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct ta.vehicle_id), '{}'::uuid[])
    from public.transport_trip_assignment ta
   where ta.tenant_id = app.auth_tenant_id()
     and ta.route_id = any (app.fn_parent_route_ids())
     and ta.effective_from <= app.fn_karachi_today() and (ta.effective_to is null or ta.effective_to >= app.fn_karachi_today());
$$;
revoke execute on function app.fn_parent_vehicle_ids() from public, anon;
grant execute on function app.fn_parent_vehicle_ids() to authenticated;

alter table public.transport_vehicle_position_latest enable row level security;
alter table public.transport_trip_distance_daily enable row level security;
create policy gps_staff_read on public.transport_vehicle_position_latest for select to authenticated
  using (app.fn_campus_scope(tenant_id, campus_id) and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager'));
create policy gps_parent_route_scope on public.transport_vehicle_position_latest for select to authenticated
  using (tenant_id = app.auth_tenant_id() and vehicle_id = any (app.fn_parent_vehicle_ids()));
create policy transport_distance_staff_read on public.transport_trip_distance_daily for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager'));

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.transport_vehicle_position_latest;
  end if;
exception
  when duplicate_object then null;
end;
$$;

-- ── Partitions ──────────────────────────────────────────────────────────────
create or replace function app.fn_ensure_ping_partition(p_day date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := 'transport_vehicle_ping_' || to_char(p_day, 'YYYYMMDD');
begin
  if to_regclass('public.' || v_name) is not null then
    return;
  end if;
  begin
    execute format('create table public.%I partition of public.transport_vehicle_ping for values from (%L) to (%L)',
                   v_name, p_day::text || ' 00:00:00+00', (p_day + 1)::text || ' 00:00:00+00');
    execute format('alter table public.%I enable row level security', v_name);
    execute format('revoke all on table public.%I from anon, authenticated', v_name);
  exception when duplicate_table then
    null;
  end;
end;
$$;
revoke execute on function app.fn_ensure_ping_partition(date) from public, anon, authenticated;

create or replace function public.transport_partition_create_ahead(p_days int default 14, p_from date default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from date := coalesce(p_from, (now() at time zone 'UTC')::date);
  i int;
begin
  for i in -1 .. p_days loop
    perform app.fn_ensure_ping_partition(v_from + i);
  end loop;
  return p_days + 2;
end;
$$;
revoke execute on function public.transport_partition_create_ahead(int, date) from public, anon, authenticated;
grant execute on function public.transport_partition_create_ahead(int, date) to service_role;

select public.transport_partition_create_ahead(14);

-- ── Ingest ──────────────────────────────────────────────────────────────────
-- p_pings: [{vehicle_id | reg_no, lat, lng, speed_kmh?, heading?, device_ts}]
create or replace function public.ingest_vehicle_pings(p_tenant_id uuid, p_pings jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ev        jsonb;
  v_veh     public.transport_vehicle%rowtype;
  v_ts      timestamptz;
  v_lat     numeric;
  v_lng     numeric;
  v_speed   numeric;
  v_head    numeric;
  v_acc int := 0; v_dup int := 0; v_rej int := 0;
  v_rows int;
begin
  if not app.feature_enabled_for(p_tenant_id, 'transport_gps') then
    raise exception 'FEATURE_OFF' using errcode = '42501';
  end if;
  if jsonb_typeof(p_pings) <> 'array' then
    raise exception 'PINGS_INVALID' using errcode = '22023';
  end if;
  if jsonb_array_length(p_pings) > 100 then
    raise exception 'BATCH_TOO_LARGE' using errcode = '22023';
  end if;
  for ev in select * from jsonb_array_elements(p_pings) loop
    begin
      v_ts := (ev ->> 'device_ts')::timestamptz;
      v_lat := (ev ->> 'lat')::numeric;
      v_lng := (ev ->> 'lng')::numeric;
      v_speed := nullif(ev ->> 'speed_kmh', '')::numeric;
      v_head := nullif(ev ->> 'heading', '')::numeric;
      if v_lat not between -90 and 90 or v_lng not between -180 and 180 or v_ts > now() + interval '5 minutes' or v_ts < now() - interval '3 days'
         or coalesce(v_speed, 0) not between 0 and 300 or coalesce(v_head, 0) not between 0 and 360 then
        v_rej := v_rej + 1;
        continue;
      end if;
    exception when others then
      v_rej := v_rej + 1;
      continue;
    end;
    select * into v_veh from public.transport_vehicle
     where tenant_id = p_tenant_id
       and ((ev ->> 'vehicle_id') is not null and id = (ev ->> 'vehicle_id')::uuid or (ev ->> 'vehicle_id') is null and reg_no = upper(btrim(ev ->> 'reg_no')));
    if not found then
      v_rej := v_rej + 1;
      continue;
    end if;
    perform app.fn_ensure_ping_partition((v_ts at time zone 'UTC')::date);
    insert into public.transport_vehicle_ping (tenant_id, vehicle_id, lat, lng, speed_kmh, heading, pinged_at)
    values (p_tenant_id, v_veh.id, v_lat, v_lng, v_speed, v_head::smallint, v_ts)
    on conflict (vehicle_id, pinged_at) do nothing;
    get diagnostics v_rows = row_count;
    if v_rows = 0 then
      v_dup := v_dup + 1;
      continue;
    end if;
    v_acc := v_acc + 1;
    insert into public.transport_vehicle_position_latest (vehicle_id, tenant_id, campus_id, lat, lng, speed_kmh, heading, pinged_at, updated_at)
    values (v_veh.id, p_tenant_id, v_veh.campus_id, v_lat, v_lng, v_speed, v_head::smallint, v_ts, now())
    on conflict (vehicle_id) do update
      set lat = excluded.lat, lng = excluded.lng, speed_kmh = excluded.speed_kmh, heading = excluded.heading, pinged_at = excluded.pinged_at, updated_at = now()
      where public.transport_vehicle_position_latest.pinged_at < excluded.pinged_at;
  end loop;
  return jsonb_build_object('accepted', v_acc, 'duplicates', v_dup, 'rejected', v_rej);
end;
$$;
revoke execute on function public.ingest_vehicle_pings(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.ingest_vehicle_pings(uuid, jsonb) to service_role;

-- ── Device keys ─────────────────────────────────────────────────────────────
-- Returns "<credential id>.<secret>" once; only the hash is stored.
create or replace function public.create_gps_credential(p_label text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_secret text := encode(extensions.gen_random_bytes(24), 'hex');
  v_id     uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'transport_manager', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.transport_gps_credential (tenant_id, label, secret_hash, created_by)
  values (app.auth_tenant_id(), btrim(p_label), encode(extensions.digest(v_secret, 'sha256'), 'hex'), (select auth.uid()))
  returning id into v_id;
  return v_id::text || '.' || v_secret;
end;
$$;
revoke execute on function public.create_gps_credential(text) from public, anon;
grant execute on function public.create_gps_credential(text) to authenticated;

-- Used by the webhook route (service role): the tenant a device key belongs to, or null.
create or replace function public.verify_gps_credential(p_key text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.tenant_id
    from public.transport_gps_credential c
   where c.active
     and p_key ~ '^[0-9a-f-]{36}\.[0-9a-f]{48}$'
     and c.id = split_part(p_key, '.', 1)::uuid
     and c.secret_hash = encode(extensions.digest(split_part(p_key, '.', 2), 'sha256'), 'hex');
$$;
revoke execute on function public.verify_gps_credential(text) from public, anon, authenticated;
grant execute on function public.verify_gps_credential(text) to service_role;

-- ── Daily summary and retention ─────────────────────────────────────────────
create or replace function public.transport_roll_daily_distance(p_day date)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  perform app.fn_ensure_ping_partition(p_day);
  insert into public.transport_trip_distance_daily (vehicle_id, day, tenant_id, distance_km, ping_count, max_speed_kmh)
  select vehicle_id, p_day, tenant_id, round(coalesce(sum(step), 0)::numeric, 2), count(*), max(speed_kmh)
    from (
      select p.vehicle_id, p.tenant_id, p.speed_kmh,
             case when lag(p.lat) over w is null then null
                  else 2 * 6371 * asin(sqrt(least(1::double precision, power(sin(radians(p.lat - lag(p.lat) over w) / 2), 2)
                    + cos(radians(lag(p.lat) over w)) * cos(radians(p.lat)) * power(sin(radians(p.lng - lag(p.lng) over w) / 2), 2)))) end as step
        from public.transport_vehicle_ping p
       where p.pinged_at >= (p_day::text || ' 00:00:00+00')::timestamptz and p.pinged_at < ((p_day + 1)::text || ' 00:00:00+00')::timestamptz
      window w as (partition by p.vehicle_id order by p.pinged_at)
    ) s
   group by vehicle_id, tenant_id
  on conflict (vehicle_id, day) do update
    set distance_km = excluded.distance_km, ping_count = excluded.ping_count, max_speed_kmh = excluded.max_speed_kmh;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.transport_roll_daily_distance(date) from public, anon, authenticated;
grant execute on function public.transport_roll_daily_distance(date) to service_role;

-- Rolls up and drops every day partition older than the retention window.
create or replace function public.transport_ping_purge(p_today date default null, p_retention_days int default 30)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := coalesce(p_today, (now() at time zone 'UTC')::date);
  r       record;
  v_day   date;
  v_n     int := 0;
begin
  for r in
    select c.relname
      from pg_inherits i
      join pg_class c on c.oid = i.inhrelid
     where i.inhparent = 'public.transport_vehicle_ping'::regclass and c.relname ~ '^transport_vehicle_ping_[0-9]{8}$'
  loop
    v_day := to_date(right(r.relname, 8), 'YYYYMMDD');
    if v_day < v_today - p_retention_days then
      perform public.transport_roll_daily_distance(v_day);
      execute format('drop table public.%I', r.relname);
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.transport_ping_purge(date, int) from public, anon, authenticated;
grant execute on function public.transport_ping_purge(date, int) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('transport_ping_purge', '0 22 * * *', 'select public.transport_ping_purge();');
    perform cron.schedule('transport_partition_create_ahead', '0 21 * * 0', 'select public.transport_partition_create_ahead(14);');
  end if;
exception
  when others then null;
end;
$$;
