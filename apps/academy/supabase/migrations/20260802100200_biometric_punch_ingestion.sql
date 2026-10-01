-- FR-D08: biometric punch ingestion pipeline.
--
-- The realistic integration for a ZKTeco box on a school LAN with no outbound
-- internet is a small on-premise agent that POSTs batches. The HTTP endpoint is
-- app/api/webhooks/biometric (HMAC-signed with the device key, no user JWT, at
-- most 1000 punches per call); everything that matters is here in the
-- database so it holds however the batch arrives:
--
--   * staff_biometric_punch stores the DEVICE-reported punch_time and the
--     server's received_at separately and is unique on (device, code,
--     punch_time), so an agent retry (or a batch replayed hours or days late,
--     out of order) inserts nothing twice. Device clock drift is corrected at
--     DERIVATION time with biometric_device.clock_offset_seconds, never by
--     rewriting what the device said.
--   * A punch whose staff_device_code maps to nobody is parked in
--     biometric_unmatched_punch; the rest of the batch is still ingested.
--     Mapping the code later (map_staff_device_code) releases the parked
--     punches and derives their days.
--   * derive_staff_attendance_from_punches(campus, date) turns punches into
--     staff_attendance rows (source 'biometric'): first punch after
--     start_time + grace is 'late', otherwise 'present'; a day with an in
--     punch and no out punch is 'present' (or 'late') with
--     anomaly = 'missing_out_punch' - an exception to review, never absent.
--   * Precedence matches the register's existing rule: an approved-leave row
--     is never touched, and a row a human marked by hand (source 'manual') is
--     never overwritten by the device - an HR correction must not be undone
--     by the next 30-minute run.
--
-- The punch tables have RLS on and NO policy: only service_role / the
-- security-definer functions below ever touch them. The device's api_key_hash
-- is column-revoked from authenticated; the HMAC secret is that hash (the
-- agent derives it as sha256(raw key)), so the raw key is shown once on
-- registration and never stored.

alter table public.staff_attendance add column if not exists anomaly text check (anomaly is null or anomaly in ('missing_out_punch'));
alter table public.staff_attendance add column if not exists first_punch_at timestamptz;
alter table public.staff_attendance add column if not exists last_punch_at timestamptz;
create index if not exists idx_staff_attendance_anomaly on public.staff_attendance (campus_id, att_date) where anomaly is not null;

create table public.campus_staff_attendance_rule (
  campus_id          uuid primary key references public.campus(id) on delete cascade,
  tenant_id          uuid not null references public.tenant(id) on delete cascade,
  start_time         time not null default '08:00',
  late_grace_minutes smallint not null default 10 check (late_grace_minutes between 0 and 240),
  -- an unlabeled punch this soon after the first one is a double tap, not a sign-out
  min_work_minutes   smallint not null default 30 check (min_work_minutes between 1 and 600),
  updated_at         timestamptz not null default now()
);
create index idx_staff_att_rule_tenant on public.campus_staff_attendance_rule (tenant_id);
create trigger campus_staff_attendance_rule_audit after insert or update or delete on public.campus_staff_attendance_rule
  for each row execute function app.tg_audit_row();
alter table public.campus_staff_attendance_rule enable row level security;
create policy staff_att_rule_read on public.campus_staff_attendance_rule for select to authenticated
  using (tenant_id = app.auth_tenant_id() and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));

create or replace function app.tg_seed_campus_staff_attendance_rule()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.campus_staff_attendance_rule (campus_id, tenant_id) values (new.id, new.tenant_id) on conflict (campus_id) do nothing;
  return new;
end;
$$;
create trigger campus_seed_staff_attendance_rule after insert on public.campus
  for each row execute function app.tg_seed_campus_staff_attendance_rule();
insert into public.campus_staff_attendance_rule (campus_id, tenant_id) select id, tenant_id from public.campus on conflict (campus_id) do nothing;

create or replace function public.set_campus_staff_attendance_rule(p_campus_id uuid, p_start_time time, p_grace_minutes smallint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() = 'hr_manager' and not (p_campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.campus_staff_attendance_rule set start_time = p_start_time, late_grace_minutes = p_grace_minutes, updated_at = now() where campus_id = p_campus_id;
end;
$$;
revoke execute on function public.set_campus_staff_attendance_rule(uuid, time, smallint) from public, anon;
grant execute on function public.set_campus_staff_attendance_rule(uuid, time, smallint) to authenticated;

-- ── devices and the code -> staff map ─────────────────────────────────────

create table public.biometric_device (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  device_serial        text not null check (device_serial ~ '^[A-Za-z0-9._-]{3,64}$'),
  label                text,
  api_key_hash         text not null,
  -- seconds the DEVICE clock runs ahead of true time (negative = behind)
  clock_offset_seconds integer not null default 0 check (clock_offset_seconds between -86400 and 86400),
  last_seen_at         timestamptz,
  is_active            boolean not null default true,
  created_at           timestamptz not null default now(),
  constraint uq_biometric_device_serial unique (device_serial)
);
create index idx_biometric_device_campus on public.biometric_device (campus_id);
create index idx_biometric_device_tenant on public.biometric_device (tenant_id);
create trigger biometric_device_audit after insert or update or delete on public.biometric_device
  for each row execute function app.tg_audit_row();
alter table public.biometric_device enable row level security;
create policy biometric_device_read on public.biometric_device for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager')
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
revoke select on public.biometric_device from authenticated;
grant select (id, tenant_id, campus_id, device_serial, label, clock_offset_seconds, last_seen_at, is_active, created_at) on public.biometric_device to authenticated;

create table public.staff_device_map (
  staff_id          uuid not null references public.staff(id) on delete cascade,
  device_id         uuid not null references public.biometric_device(id) on delete cascade,
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  staff_device_code text not null check (char_length(staff_device_code) between 1 and 40),
  created_at        timestamptz not null default now(),
  primary key (staff_id, device_id),
  constraint uq_device_staff_code unique (device_id, staff_device_code)
);
create index idx_staff_device_map_tenant on public.staff_device_map (tenant_id);
create trigger staff_device_map_audit after insert or update or delete on public.staff_device_map
  for each row execute function app.tg_audit_row();
alter table public.staff_device_map enable row level security;
create policy staff_device_map_read on public.staff_device_map for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager')
         and exists (select 1 from public.biometric_device d where d.id = device_id));

-- ── punches (service role / definer functions only) ───────────────────────

create table public.staff_biometric_punch (
  id                bigint generated always as identity primary key,
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  device_id         uuid not null references public.biometric_device(id) on delete cascade,
  staff_device_code text not null,
  punch_time        timestamptz not null,
  received_at       timestamptz not null default clock_timestamp(),
  direction         text not null default 'unknown' check (direction in ('in', 'out', 'unknown')),
  raw               jsonb,
  constraint uq_biometric_punch unique (device_id, staff_device_code, punch_time)
);
create index idx_biometric_punch_campus_time on public.staff_biometric_punch (campus_id, punch_time);
create index idx_biometric_punch_tenant on public.staff_biometric_punch (tenant_id);
alter table public.staff_biometric_punch enable row level security;

create table public.biometric_unmatched_punch (
  id                bigint generated always as identity primary key,
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  device_id         uuid not null references public.biometric_device(id) on delete cascade,
  staff_device_code text not null,
  punch_time        timestamptz not null,
  received_at       timestamptz not null default clock_timestamp(),
  direction         text not null default 'unknown' check (direction in ('in', 'out', 'unknown')),
  raw               jsonb,
  constraint uq_biometric_unmatched_punch unique (device_id, staff_device_code, punch_time)
);
create index idx_biometric_unmatched_campus on public.biometric_unmatched_punch (campus_id, received_at);
create index idx_biometric_unmatched_tenant on public.biometric_unmatched_punch (tenant_id);
alter table public.biometric_unmatched_punch enable row level security;

-- ── helpers ───────────────────────────────────────────────────────────────

-- Device-reported times arrive as ISO strings. Without a UTC offset they are
-- the device's wall clock, i.e. Pakistan time - never the server's session zone.
create or replace function app.fn_biometric_parse_ts(p_text text)
returns timestamptz
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_text is null or btrim(p_text) = '' then
    return null;
  end if;
  if btrim(p_text) ~ '(Z|[+-][0-9]{2}(:?[0-9]{2})?)$' then
    return btrim(p_text)::timestamptz;
  end if;
  return btrim(p_text)::timestamp at time zone 'Asia/Karachi';
end;
$$;

create or replace function app.fn_biometric_caller_can_manage(p_campus_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager')
         and (app.auth_role() in ('super_admin', 'owner') or p_campus_id = any (app.auth_campus_ids()));
$$;

-- ── derivation ────────────────────────────────────────────────────────────

create or replace function public.derive_staff_attendance_from_punches(p_campus uuid, p_date date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule public.campus_staff_attendance_rule%rowtype;
  v_tenant uuid;
  v_written integer;
begin
  select * into v_rule from public.campus_staff_attendance_rule where campus_id = p_campus;
  if not found then
    return 0;
  end if;
  v_tenant := v_rule.tenant_id;

  with eff as (
    select m.staff_id,
           p.punch_time - make_interval(secs => d.clock_offset_seconds) as t,
           p.direction
      from public.staff_biometric_punch p
      join public.biometric_device d on d.id = p.device_id
      join public.staff_device_map m on m.device_id = p.device_id and m.staff_device_code = p.staff_device_code
      join public.staff s on s.id = m.staff_id and s.tenant_id = v_tenant and s.employment_status <> 'exited'
     where p.campus_id = p_campus
       and p.punch_time >= (p_date::timestamp at time zone 'Asia/Karachi') - interval '1 day'
       and p.punch_time <  (p_date::timestamp at time zone 'Asia/Karachi') + interval '2 days'
  ), day_punches as (
    select * from eff where ((t at time zone 'Asia/Karachi')::date) = p_date
  ), firsts as (
    select staff_id, min(t) as first_t from day_punches group by staff_id
  ), agg as (
    select f.staff_id, f.first_t,
           (select max(dp.t) from day_punches dp
             where dp.staff_id = f.staff_id and dp.t > f.first_t
               and (dp.direction = 'out'
                    or (dp.direction = 'unknown' and dp.t >= f.first_t + make_interval(mins => v_rule.min_work_minutes)))) as out_t
      from firsts f
  )
  insert into public.staff_attendance (tenant_id, campus_id, staff_id, att_date, status, source, anomaly, first_punch_at, last_punch_at, marked_at)
  select v_tenant, p_campus, a.staff_id, p_date,
         case when (a.first_t at time zone 'Asia/Karachi')::time <= v_rule.start_time + make_interval(mins => v_rule.late_grace_minutes)
              then 'present'::public.attendance_status else 'late'::public.attendance_status end,
         'biometric'::public.attendance_source,
         case when a.out_t is null then 'missing_out_punch' end,
         a.first_t, a.out_t, now()
    from agg a
  on conflict (staff_id, att_date) do update
     set status = excluded.status, anomaly = excluded.anomaly, first_punch_at = excluded.first_punch_at,
         last_punch_at = excluded.last_punch_at, marked_at = now()
   where public.staff_attendance.source = 'biometric';
  get diagnostics v_written = row_count;
  return v_written;
end;
$$;
revoke execute on function public.derive_staff_attendance_from_punches(uuid, date) from public, anon, authenticated;

-- Cron body: re-derive the last three days for every campus that has a device,
-- which also heals a day whose punches arrived late.
create or replace function public.derive_recent_biometric_attendance()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  c record;
  d integer;
  v_today date := app.fn_karachi_today();
  v_total integer := 0;
begin
  for c in select distinct campus_id from public.biometric_device where is_active loop
    for d in 0..2 loop
      v_total := v_total + public.derive_staff_attendance_from_punches(c.campus_id, v_today - d);
    end loop;
  end loop;
  return v_total;
end;
$$;
revoke execute on function public.derive_recent_biometric_attendance() from public, anon, authenticated;

-- ── ingestion (called by the HMAC-verified endpoint with the service role) ─

create or replace function public.ingest_biometric_punches(p_device_id uuid, p_punches jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dev      public.biometric_device%rowtype;
  e          jsonb;
  v_code     text;
  v_time     timestamptz;
  v_dir      text;
  v_rows     integer;
  v_inserted integer := 0;
  v_dups     integer := 0;
  v_unmatched integer := 0;
  v_rejected integer := 0;
  v_dates    date[] := '{}';
  v_date     date;
begin
  if p_punches is null or jsonb_typeof(p_punches) <> 'array' then
    raise exception 'PUNCHES_NOT_ARRAY' using errcode = '22023';
  end if;
  if jsonb_array_length(p_punches) > 1000 then
    raise exception 'BATCH_TOO_LARGE' using errcode = '54000';
  end if;
  select * into v_dev from public.biometric_device where id = p_device_id and is_active;
  if not found then
    raise exception 'DEVICE_NOT_FOUND' using errcode = 'P0002';
  end if;

  for e in select * from jsonb_array_elements(p_punches) loop
    begin
      v_code := nullif(btrim(e ->> 'code'), '');
      v_time := app.fn_biometric_parse_ts(e ->> 'time');
      v_dir := lower(coalesce(nullif(btrim(e ->> 'direction'), ''), 'unknown'));
      if v_dir not in ('in', 'out', 'unknown') then
        v_dir := 'unknown';
      end if;
      if v_code is null or v_time is null then
        v_rejected := v_rejected + 1;
        continue;
      end if;
    exception when others then
      v_rejected := v_rejected + 1;
      continue;
    end;

    if exists (select 1 from public.staff_device_map m where m.device_id = p_device_id and m.staff_device_code = v_code) then
      insert into public.staff_biometric_punch (tenant_id, campus_id, device_id, staff_device_code, punch_time, direction, raw)
      values (v_dev.tenant_id, v_dev.campus_id, p_device_id, v_code, v_time, v_dir, e)
      on conflict (device_id, staff_device_code, punch_time) do nothing;
      get diagnostics v_rows = row_count;
      if v_rows = 1 then
        v_inserted := v_inserted + 1;
        v_date := ((v_time - make_interval(secs => v_dev.clock_offset_seconds)) at time zone 'Asia/Karachi')::date;
        if not (v_date = any (v_dates)) then
          v_dates := v_dates || v_date;
        end if;
      else
        v_dups := v_dups + 1;
      end if;
    else
      insert into public.biometric_unmatched_punch (tenant_id, campus_id, device_id, staff_device_code, punch_time, direction, raw)
      values (v_dev.tenant_id, v_dev.campus_id, p_device_id, v_code, v_time, v_dir, e)
      on conflict (device_id, staff_device_code, punch_time) do nothing;
      get diagnostics v_rows = row_count;
      if v_rows = 1 then
        v_unmatched := v_unmatched + 1;
      else
        v_dups := v_dups + 1;
      end if;
    end if;
  end loop;

  update public.biometric_device set last_seen_at = clock_timestamp() where id = p_device_id;

  foreach v_date in array v_dates loop
    perform public.derive_staff_attendance_from_punches(v_dev.campus_id, v_date);
  end loop;

  return jsonb_build_object(
    'received', jsonb_array_length(p_punches), 'inserted', v_inserted, 'duplicates', v_dups,
    'unmatched', v_unmatched, 'rejected', v_rejected, 'derived_dates', to_jsonb(v_dates));
end;
$$;
revoke execute on function public.ingest_biometric_punches(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.ingest_biometric_punches(uuid, jsonb) to service_role;

-- ── HR: devices, mapping, exceptions ──────────────────────────────────────

-- Returns the raw key ONCE; only sha256(raw) is stored (and used as the HMAC secret).
create or replace function public.register_biometric_device(p_campus_id uuid, p_device_serial text, p_label text default null)
returns table (device_id uuid, api_key text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := encode(extensions.gen_random_bytes(24), 'hex');
  v_id  uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() = 'hr_manager' and not (p_campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.biometric_device (tenant_id, campus_id, device_serial, label, api_key_hash)
  values (app.auth_tenant_id(), p_campus_id, p_device_serial, nullif(btrim(p_label), ''), encode(extensions.digest(v_key, 'sha256'), 'hex'))
  returning id into v_id;
  return query select v_id, v_key;
exception when unique_violation then
  raise exception 'DEVICE_SERIAL_TAKEN' using errcode = '23505';
end;
$$;
revoke execute on function public.register_biometric_device(uuid, text, text) from public, anon;
grant execute on function public.register_biometric_device(uuid, text, text) to authenticated;

create or replace function public.set_biometric_device_clock_offset(p_device_id uuid, p_offset_seconds integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dev public.biometric_device%rowtype;
begin
  select * into v_dev from public.biometric_device where id = p_device_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'DEVICE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') or not app.fn_biometric_caller_can_manage(v_dev.campus_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.biometric_device set clock_offset_seconds = p_offset_seconds where id = p_device_id;
end;
$$;
revoke execute on function public.set_biometric_device_clock_offset(uuid, integer) from public, anon;
grant execute on function public.set_biometric_device_clock_offset(uuid, integer) to authenticated;

-- Map a device code to a staff member, release the punches parked for that
-- code, and derive the affected days.
create or replace function public.map_staff_device_code(p_device_id uuid, p_staff_device_code text, p_staff_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dev   public.biometric_device%rowtype;
  v_moved integer := 0;
  v_date  date;
begin
  select * into v_dev from public.biometric_device where id = p_device_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'DEVICE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') or not app.fn_biometric_caller_can_manage(v_dev.campus_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.staff where id = p_staff_id and tenant_id = v_dev.tenant_id) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if char_length(btrim(coalesce(p_staff_device_code, ''))) = 0 then
    raise exception 'CODE_REQUIRED' using errcode = '22023';
  end if;
  begin
    insert into public.staff_device_map (staff_id, device_id, tenant_id, staff_device_code)
    values (p_staff_id, p_device_id, v_dev.tenant_id, btrim(p_staff_device_code))
    on conflict (staff_id, device_id) do update set staff_device_code = excluded.staff_device_code;
  exception when unique_violation then
    raise exception 'DEVICE_CODE_TAKEN' using errcode = '23505';
  end;

  with moved as (
    delete from public.biometric_unmatched_punch u
     where u.device_id = p_device_id and u.staff_device_code = btrim(p_staff_device_code)
    returning u.*
  ), ins as (
    insert into public.staff_biometric_punch (tenant_id, campus_id, device_id, staff_device_code, punch_time, received_at, direction, raw)
    select tenant_id, campus_id, device_id, staff_device_code, punch_time, received_at, direction, raw from moved
    on conflict (device_id, staff_device_code, punch_time) do nothing
    returning punch_time
  )
  select count(*) into v_moved from ins;

  for v_date in
    select distinct ((p.punch_time - make_interval(secs => v_dev.clock_offset_seconds)) at time zone 'Asia/Karachi')::date
      from public.staff_biometric_punch p
     where p.device_id = p_device_id and p.staff_device_code = btrim(p_staff_device_code)
  loop
    perform public.derive_staff_attendance_from_punches(v_dev.campus_id, v_date);
  end loop;
  return v_moved;
end;
$$;
revoke execute on function public.map_staff_device_code(uuid, text, uuid) from public, anon;
grant execute on function public.map_staff_device_code(uuid, text, uuid) to authenticated;

create or replace function public.list_biometric_exceptions(p_campus_id uuid, p_from date, p_to date)
returns table (att_date date, staff_id uuid, employee_code text, full_name text, status public.attendance_status, anomaly text, first_punch_at timestamptz, last_punch_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app.fn_biometric_caller_can_manage(p_campus_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  return query
    select a.att_date, a.staff_id, s.employee_code, s.full_name, a.status, a.anomaly, a.first_punch_at, a.last_punch_at
      from public.staff_attendance a
      join public.staff s on s.id = a.staff_id
     where a.campus_id = p_campus_id and a.tenant_id = app.auth_tenant_id()
       and a.att_date between p_from and p_to and a.anomaly is not null and a.source = 'biometric'
     order by a.att_date desc, s.full_name;
end;
$$;
revoke execute on function public.list_biometric_exceptions(uuid, date, date) from public, anon;
grant execute on function public.list_biometric_exceptions(uuid, date, date) to authenticated;

create or replace function public.list_unmatched_biometric_punches(p_campus_id uuid)
returns table (device_id uuid, device_serial text, staff_device_code text, punches bigint, first_punch timestamptz, last_punch timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app.fn_biometric_caller_can_manage(p_campus_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
    select u.device_id, d.device_serial, u.staff_device_code, count(*), min(u.punch_time), max(u.punch_time)
      from public.biometric_unmatched_punch u
      join public.biometric_device d on d.id = u.device_id
     where u.campus_id = p_campus_id and u.tenant_id = app.auth_tenant_id()
     group by u.device_id, d.device_serial, u.staff_device_code
     order by max(u.punch_time) desc;
end;
$$;
revoke execute on function public.list_unmatched_biometric_punches(uuid) from public, anon;
grant execute on function public.list_unmatched_biometric_punches(uuid) to authenticated;

-- every 30 minutes
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('biometric-derive', '*/30 * * * *', 'select public.derive_recent_biometric_attendance();');
  end if;
exception
  when others then null;
end;
$$;
