-- FR-P01: bus routes with ordered stops and slab-driven fares.
--
-- A route is an ordered list of stops. The sequence is guarded by a
-- DEFERRABLE INITIALLY DEFERRED unique constraint so a re-order is one UPDATE
-- statement that renumbers every affected stop: the uniqueness check runs when
-- the statement (transaction) ends, so no duplicate sequence is ever visible and
-- no temporary negative-sequence shuffle is needed.
--
-- Fares are never typed per student. A stop points at a fare slab; a slab is a
-- series of dated versions of the same code (Zone B 3,500 from one date, 3,900
-- from the next). The amount a student pays for a month is resolved from the
-- slab version in force, so a fuel-driven revision re-prices every student on the
-- zone with no per-student edit. Money is bigint paisa.
--
-- All writes go through SECURITY DEFINER functions; tables only expose SELECT
-- policies (campus scoped). The same stop name on two routes is allowed.

create extension if not exists btree_gist;

create type public.transport_shift as enum ('morning', 'afternoon');

-- Campus-scope check shared by every transport and hostel table policy.
create or replace function app.fn_campus_scope(p_tenant uuid, p_campus uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_tenant = app.auth_tenant_id()
     and (app.auth_role() in ('owner', 'super_admin') or p_campus = any (app.auth_campus_ids()));
$$;
grant execute on function app.fn_campus_scope(uuid, uuid) to authenticated;

-- Roles that run the transport office. Returns the campus's tenant id.
create or replace function app.fn_transport_assert_manager(p_campus_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select tenant_id into v_tenant from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id();
  if v_tenant is null then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (p_campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return v_tenant;
end;
$$;
revoke execute on function app.fn_transport_assert_manager(uuid) from public, anon, authenticated;

create table public.transport_fare_slab (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  code                 text not null check (char_length(btrim(code)) between 1 and 20),
  name                 text not null check (char_length(btrim(name)) between 1 and 80),
  monthly_amount_paisa bigint not null check (monthly_amount_paisa > 0),
  effective_from       date not null,
  created_by           uuid references auth.users(id),
  created_at           timestamptz not null default now(),
  constraint uq_fare_slab_version unique (tenant_id, campus_id, code, effective_from)
);
create index idx_fare_slab_scope on public.transport_fare_slab (tenant_id, campus_id, code, effective_from desc);

create table public.transport_route (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  code       text not null check (char_length(btrim(code)) between 1 and 20),
  name       text not null check (char_length(btrim(name)) between 1 and 120),
  shift      public.transport_shift not null,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  constraint uq_route_code unique (tenant_id, campus_id, code)
);
create index idx_route_scope on public.transport_route (tenant_id, campus_id);

create table public.transport_stop (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  route_id     uuid not null references public.transport_route(id) on delete cascade,
  seq          int not null check (seq > 0),
  name         text not null check (char_length(btrim(name)) between 1 and 120),
  name_ur      text check (name_ur is null or char_length(name_ur) <= 120),
  lat          numeric(9, 6) check (lat is null or lat between -90 and 90),
  lng          numeric(9, 6) check (lng is null or lng between -180 and 180),
  pickup_time  time,
  drop_time    time,
  fare_slab_id uuid references public.transport_fare_slab(id),
  created_at   timestamptz not null default now(),
  constraint uq_stop_seq unique (route_id, seq) deferrable initially deferred
);
create index idx_stop_route on public.transport_stop (route_id, seq);
create index idx_stop_scope on public.transport_stop (tenant_id, campus_id);
create index idx_stop_slab on public.transport_stop (fare_slab_id);

create trigger transport_fare_slab_audit after insert or update or delete on public.transport_fare_slab
  for each row execute function app.tg_audit_row();
create trigger transport_route_audit after insert or update or delete on public.transport_route
  for each row execute function app.tg_audit_row();
create trigger transport_stop_audit after insert or update or delete on public.transport_stop
  for each row execute function app.tg_audit_row();

alter table public.transport_fare_slab enable row level security;
alter table public.transport_route enable row level security;
alter table public.transport_stop enable row level security;
create policy transport_fare_slab_campus_scope on public.transport_fare_slab for select to authenticated
  using (app.fn_campus_scope(tenant_id, campus_id) and app.auth_role() not in ('parent', 'student'));
create policy transport_route_campus_scope on public.transport_route for select to authenticated
  using (app.fn_campus_scope(tenant_id, campus_id) and app.auth_role() not in ('parent', 'student'));
create policy transport_stop_campus_scope on public.transport_stop for select to authenticated
  using (app.fn_campus_scope(tenant_id, campus_id) and app.auth_role() not in ('parent', 'student'));

-- The amount a slab charges on a date: the version of the same code with the
-- latest effective_from on or before that date (the earliest version if the
-- date precedes them all). The app. variant has no caller filter, for cron.
create or replace function app.fn_slab_amount(p_slab_id uuid, p_on date)
returns bigint
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select v.monthly_amount_paisa from public.transport_fare_slab v
      where v.tenant_id = s.tenant_id and v.campus_id = s.campus_id and v.code = s.code and v.effective_from <= p_on
      order by v.effective_from desc limit 1),
    (select v.monthly_amount_paisa from public.transport_fare_slab v
      where v.tenant_id = s.tenant_id and v.campus_id = s.campus_id and v.code = s.code
      order by v.effective_from asc limit 1))
    from public.transport_fare_slab s where s.id = p_slab_id;
$$;
revoke execute on function app.fn_slab_amount(uuid, date) from public, anon, authenticated;

create or replace function public.transport_slab_amount(p_slab_id uuid, p_on date)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select app.fn_slab_amount(s.id, p_on) from public.transport_fare_slab s where s.id = p_slab_id and s.tenant_id = app.auth_tenant_id();
$$;
revoke execute on function public.transport_slab_amount(uuid, date) from public, anon;
grant execute on function public.transport_slab_amount(uuid, date) to authenticated, service_role;

create or replace function public.save_transport_route(p_campus_id uuid, p_code text, p_name text, p_shift public.transport_shift, p_active boolean default true, p_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.fn_transport_assert_manager(p_campus_id);
  v_id     uuid;
begin
  if p_id is null then
    insert into public.transport_route (tenant_id, campus_id, code, name, shift, active)
    values (v_tenant, p_campus_id, btrim(p_code), btrim(p_name), p_shift, p_active) returning id into v_id;
  else
    update public.transport_route set code = btrim(p_code), name = btrim(p_name), shift = p_shift, active = p_active
     where id = p_id and tenant_id = v_tenant and campus_id = p_campus_id returning id into v_id;
    if v_id is null then
      raise exception 'ROUTE_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'ROUTE_CODE_EXISTS' using errcode = '23505';
end;
$$;
revoke execute on function public.save_transport_route(uuid, text, text, public.transport_shift, boolean, uuid) from public, anon;
grant execute on function public.save_transport_route(uuid, text, text, public.transport_shift, boolean, uuid) to authenticated;

-- Saving a slab with a new effective date adds a version; with an existing
-- effective date it corrects that version.
create or replace function public.save_fare_slab(p_campus_id uuid, p_code text, p_name text, p_monthly_amount_paisa bigint, p_effective_from date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.fn_transport_assert_manager(p_campus_id);
  v_id     uuid;
begin
  if p_monthly_amount_paisa is null or p_monthly_amount_paisa <= 0 then
    raise exception 'AMOUNT_MUST_BE_POSITIVE' using errcode = '23514';
  end if;
  insert into public.transport_fare_slab (tenant_id, campus_id, code, name, monthly_amount_paisa, effective_from, created_by)
  values (v_tenant, p_campus_id, btrim(p_code), btrim(p_name), p_monthly_amount_paisa, p_effective_from, (select auth.uid()))
  on conflict (tenant_id, campus_id, code, effective_from)
  do update set monthly_amount_paisa = excluded.monthly_amount_paisa, name = excluded.name
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.save_fare_slab(uuid, text, text, bigint, date) from public, anon;
grant execute on function public.save_fare_slab(uuid, text, text, bigint, date) to authenticated;

create or replace function public.add_transport_stop(
  p_route_id uuid, p_name text, p_name_ur text default null, p_lat numeric default null, p_lng numeric default null,
  p_pickup_time time default null, p_drop_time time default null, p_fare_slab_id uuid default null, p_seq int default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_route public.transport_route%rowtype;
  v_max   int;
  v_seq   int;
  v_id    uuid;
begin
  select * into v_route from public.transport_route where id = p_route_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'ROUTE_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_transport_assert_manager(v_route.campus_id);
  if p_fare_slab_id is not null and not exists (
       select 1 from public.transport_fare_slab where id = p_fare_slab_id and tenant_id = v_route.tenant_id and campus_id = v_route.campus_id) then
    raise exception 'SLAB_NOT_FOUND' using errcode = 'P0002';
  end if;
  select coalesce(max(seq), 0) into v_max from public.transport_stop where route_id = p_route_id;
  v_seq := least(coalesce(p_seq, v_max + 1), v_max + 1);
  if v_seq < 1 then
    raise exception 'SEQ_INVALID' using errcode = '22023';
  end if;
  update public.transport_stop set seq = seq + 1 where route_id = p_route_id and seq >= v_seq;
  insert into public.transport_stop (tenant_id, campus_id, route_id, seq, name, name_ur, lat, lng, pickup_time, drop_time, fare_slab_id)
  values (v_route.tenant_id, v_route.campus_id, p_route_id, v_seq, btrim(p_name), nullif(btrim(p_name_ur), ''), p_lat, p_lng, p_pickup_time, p_drop_time, p_fare_slab_id)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.add_transport_stop(uuid, text, text, numeric, numeric, time, time, uuid, int) from public, anon;
grant execute on function public.add_transport_stop(uuid, text, text, numeric, numeric, time, time, uuid, int) to authenticated;

create or replace function public.update_transport_stop(
  p_stop_id uuid, p_name text, p_name_ur text default null, p_lat numeric default null, p_lng numeric default null,
  p_pickup_time time default null, p_drop_time time default null, p_fare_slab_id uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stop public.transport_stop%rowtype;
begin
  select * into v_stop from public.transport_stop where id = p_stop_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STOP_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_transport_assert_manager(v_stop.campus_id);
  if p_fare_slab_id is not null and not exists (
       select 1 from public.transport_fare_slab where id = p_fare_slab_id and tenant_id = v_stop.tenant_id and campus_id = v_stop.campus_id) then
    raise exception 'SLAB_NOT_FOUND' using errcode = 'P0002';
  end if;
  update public.transport_stop
     set name = btrim(p_name), name_ur = nullif(btrim(p_name_ur), ''), lat = p_lat, lng = p_lng,
         pickup_time = p_pickup_time, drop_time = p_drop_time, fare_slab_id = p_fare_slab_id
   where id = p_stop_id;
end;
$$;
revoke execute on function public.update_transport_stop(uuid, text, text, numeric, numeric, time, time, uuid) from public, anon;
grant execute on function public.update_transport_stop(uuid, text, text, numeric, numeric, time, time, uuid) to authenticated;

-- Drag a stop to a new position: one UPDATE renumbers every stop in between.
create or replace function public.move_transport_stop(p_stop_id uuid, p_new_seq int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stop public.transport_stop%rowtype;
  v_max  int;
  v_new  int;
begin
  select * into v_stop from public.transport_stop where id = p_stop_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STOP_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_transport_assert_manager(v_stop.campus_id);
  perform 1 from public.transport_route where id = v_stop.route_id for update;
  select max(seq) into v_max from public.transport_stop where route_id = v_stop.route_id;
  v_new := greatest(1, least(coalesce(p_new_seq, 1), v_max));
  if v_new = v_stop.seq then
    return;
  end if;
  update public.transport_stop
     set seq = case when id = p_stop_id then v_new
                    when v_new < v_stop.seq then seq + 1
                    else seq - 1 end
   where route_id = v_stop.route_id
     and seq between least(v_new, v_stop.seq) and greatest(v_new, v_stop.seq);
end;
$$;
revoke execute on function public.move_transport_stop(uuid, int) from public, anon;
grant execute on function public.move_transport_stop(uuid, int) to authenticated;

-- Removing a stop closes the gap. A stop that students are allocated to cannot
-- be removed (the allocation foreign key refuses).
create or replace function public.remove_transport_stop(p_stop_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stop public.transport_stop%rowtype;
begin
  select * into v_stop from public.transport_stop where id = p_stop_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STOP_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_transport_assert_manager(v_stop.campus_id);
  perform 1 from public.transport_route where id = v_stop.route_id for update;
  delete from public.transport_stop where id = p_stop_id;
  update public.transport_stop set seq = seq - 1 where route_id = v_stop.route_id and seq > v_stop.seq;
exception when foreign_key_violation then
  raise exception 'STOP_IN_USE' using errcode = '23503';
end;
$$;
revoke execute on function public.remove_transport_stop(uuid) from public, anon;
grant execute on function public.remove_transport_stop(uuid) to authenticated;

-- Printed route sheet and parent portal read the same view: stops in order with
-- pickup and drop times and the fare in force today.
create view public.v_transport_route_sheet with (security_invoker = true) as
select r.id as route_id, r.tenant_id, r.campus_id, r.code as route_code, r.name as route_name, r.shift, r.active,
       s.id as stop_id, s.seq, s.name as stop_name, s.name_ur as stop_name_ur, s.lat, s.lng, s.pickup_time, s.drop_time,
       sl.code as slab_code, sl.name as slab_name, cur.monthly_amount_paisa
  from public.transport_route r
  join public.transport_stop s on s.route_id = r.id
  left join public.transport_fare_slab sl on sl.id = s.fare_slab_id
  left join lateral (
    select v.monthly_amount_paisa from public.transport_fare_slab v
     where v.tenant_id = sl.tenant_id and v.campus_id = sl.campus_id and v.code = sl.code and v.effective_from <= current_date
     order by v.effective_from desc limit 1) cur on true;
revoke all on public.v_transport_route_sheet from anon;
grant select on public.v_transport_route_sheet to authenticated;
