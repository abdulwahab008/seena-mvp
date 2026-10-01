-- FR-P03: driver and crew register with licence-expiry and class enforcement.
--
-- A driver must hold a licence that is valid on the trip date and whose class
-- covers the vehicle: a vehicle of more than 14 seats needs HTV or PSV, a
-- smaller one is fine on LTV. A licence is valid through its expiry date (expiring
-- 2026-08-15 means a trip on the 14th and 15th is fine, the 16th is refused).
-- A stale police verification is a WARNING (returned by the check, shown on the
-- assignment screen), never a block, so a lapsed verification does not strand a
-- route at 06:30.
--
-- Attendant is a crew role of its own (girls' routes expect a female attendant).
-- CNIC is unique per school and is regulated personal data: the transport_crew
-- table itself is readable only by Transport Manager, HR Manager, Principal,
-- Owner and Super Admin; everyone else (class teacher, and so on) reads the
-- crew through v_transport_crew_public / v_transport_route_crew, where the CNIC
-- is masked (35202-xxxxxxx-1) unless the caller is one of those roles.
--
-- Deviation from the object list: the views are not security_invoker. They
-- cannot be, because an invoker view over the PII-gated table would return no
-- rows to the very users the mask exists for. They are security_barrier views
-- that apply the campus scope themselves and mask by caller role.

create type public.transport_crew_role as enum ('driver', 'conductor', 'attendant');
create type public.transport_licence_class as enum ('LTV', 'HTV', 'PSV');

create table public.transport_crew (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  campus_id           uuid not null references public.campus(id) on delete cascade,
  staff_id            uuid references public.staff(id) on delete set null,
  full_name           text not null check (char_length(btrim(full_name)) between 2 and 120),
  cnic                text not null check (cnic ~ '^[0-9]{5}-[0-9]{7}-[0-9]$'),
  phone               text check (phone is null or char_length(phone) <= 20),
  crew_role           public.transport_crew_role not null,
  licence_no          text check (licence_no is null or char_length(licence_no) <= 40),
  licence_class       public.transport_licence_class,
  licence_expires_on  date,
  police_verified_on  date,
  blood_group         text check (blood_group is null or blood_group in ('A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-')),
  active              boolean not null default true,
  created_at          timestamptz not null default now(),
  constraint uq_crew_cnic unique (tenant_id, cnic),
  constraint chk_driver_licence check (crew_role <> 'driver' or (licence_no is not null and licence_class is not null and licence_expires_on is not null))
);
create index idx_crew_scope on public.transport_crew (tenant_id, campus_id);
create index idx_crew_staff on public.transport_crew (staff_id);

create table public.transport_trip_assignment (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  route_id       uuid not null references public.transport_route(id) on delete cascade,
  shift          public.transport_shift not null,
  vehicle_id     uuid not null references public.transport_vehicle(id),
  driver_id      uuid not null references public.transport_crew(id),
  conductor_id   uuid references public.transport_crew(id),
  attendant_id   uuid references public.transport_crew(id),
  effective_from date not null,
  effective_to   date,
  override_id    uuid references public.transport_vehicle_override(id),
  created_by     uuid references auth.users(id),
  created_at     timestamptz not null default now(),
  constraint chk_assignment_span check (effective_to is null or effective_to >= effective_from),
  -- effective_to is the last day of service; the range is half open.
  constraint ex_assignment_route exclude using gist (route_id with =, daterange(effective_from, coalesce(effective_to + 1, 'infinity'), '[)') with &&),
  constraint ex_assignment_vehicle exclude using gist (vehicle_id with =, shift with =, daterange(effective_from, coalesce(effective_to + 1, 'infinity'), '[)') with &&),
  constraint ex_assignment_driver exclude using gist (driver_id with =, shift with =, daterange(effective_from, coalesce(effective_to + 1, 'infinity'), '[)') with &&)
);
create index idx_assignment_route on public.transport_trip_assignment (route_id, effective_from);
create index idx_assignment_scope on public.transport_trip_assignment (tenant_id, campus_id);
create index idx_assignment_vehicle on public.transport_trip_assignment (vehicle_id);
create index idx_assignment_driver on public.transport_trip_assignment (driver_id);
create index idx_assignment_conductor on public.transport_trip_assignment (conductor_id);
create index idx_assignment_attendant on public.transport_trip_assignment (attendant_id);
create index idx_assignment_override on public.transport_trip_assignment (override_id);

create trigger transport_crew_audit after insert or update or delete on public.transport_crew
  for each row execute function app.tg_audit_row();
create trigger transport_trip_assignment_audit after insert or update or delete on public.transport_trip_assignment
  for each row execute function app.tg_audit_row();

alter table public.transport_crew enable row level security;
alter table public.transport_trip_assignment enable row level security;
create policy transport_crew_pii_read on public.transport_crew for select to authenticated
  using (app.fn_campus_scope(tenant_id, campus_id)
         and app.auth_role() in ('transport_manager', 'hr_manager', 'principal', 'super_admin', 'owner'));
create policy transport_trip_assignment_campus_scope on public.transport_trip_assignment for select to authenticated
  using (app.fn_campus_scope(tenant_id, campus_id) and app.auth_role() not in ('parent', 'student'));

create or replace function app.fn_mask_cnic(p_cnic text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_cnic ~ '^[0-9]{5}-[0-9]{7}-[0-9]$' then substr(p_cnic, 1, 5) || '-xxxxxxx-' || right(p_cnic, 1) else null end;
$$;
grant execute on function app.fn_mask_cnic(text) to authenticated;

create or replace function app.fn_crew_sees_cnic()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('transport_manager', 'hr_manager', 'principal', 'super_admin', 'owner');
$$;
grant execute on function app.fn_crew_sees_cnic() to authenticated;

create view public.v_transport_crew_public with (security_barrier = true) as
select c.id, c.tenant_id, c.campus_id, c.full_name, c.crew_role, c.phone,
       case when app.fn_crew_sees_cnic() then c.cnic else app.fn_mask_cnic(c.cnic) end as cnic,
       c.licence_class, c.licence_expires_on, c.police_verified_on, c.blood_group, c.active
  from public.transport_crew c
 where app.fn_campus_scope(c.tenant_id, c.campus_id) and app.auth_role() not in ('parent', 'student');
revoke all on public.v_transport_crew_public from anon;
grant select on public.v_transport_crew_public to authenticated;

-- What the printed route sheet shows: today's vehicle and crew for each route.
create view public.v_transport_route_crew with (security_barrier = true) as
select a.id as assignment_id, a.tenant_id, a.campus_id, a.route_id, a.shift, a.effective_from, a.effective_to,
       v.reg_no as vehicle_reg_no, v.seat_capacity,
       d.full_name as driver_name, d.phone as driver_phone,
       case when app.fn_crew_sees_cnic() then d.cnic else app.fn_mask_cnic(d.cnic) end as driver_cnic,
       co.full_name as conductor_name, at.full_name as attendant_name
  from public.transport_trip_assignment a
  join public.transport_vehicle v on v.id = a.vehicle_id
  join public.transport_crew d on d.id = a.driver_id
  left join public.transport_crew co on co.id = a.conductor_id
  left join public.transport_crew at on at.id = a.attendant_id
 where app.fn_campus_scope(a.tenant_id, a.campus_id) and app.auth_role() not in ('parent', 'student')
   and a.effective_from <= app.fn_karachi_today() and (a.effective_to is null or a.effective_to >= app.fn_karachi_today());
revoke all on public.v_transport_route_crew from anon;
grant select on public.v_transport_route_crew to authenticated;

-- ── Eligibility ─────────────────────────────────────────────────────────────
create or replace function app.fn_licence_rank(p_class public.transport_licence_class)
returns int
language sql
immutable
set search_path = ''
as $$
  select case p_class when 'LTV' then 1 else 2 end;
$$;

-- Raises when the driver may not drive the vehicle on p_on; returns a warning
-- code (POLICE_VERIFICATION_MISSING / POLICE_VERIFICATION_STALE) or null.
create or replace function app.fn_driver_assert(p_crew_id uuid, p_vehicle_id uuid, p_on date)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_c public.transport_crew%rowtype;
  v_v public.transport_vehicle%rowtype;
begin
  select * into v_c from public.transport_crew where id = p_crew_id;
  if not found then
    raise exception 'CREW_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into v_v from public.transport_vehicle where id = p_vehicle_id;
  if not found then
    raise exception 'VEHICLE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_c.crew_role <> 'driver' then
    raise exception 'NOT_A_DRIVER';
  end if;
  if not v_c.active then
    raise exception 'CREW_INACTIVE';
  end if;
  if v_c.licence_expires_on < p_on then
    raise exception 'LICENCE_EXPIRED' using detail = 'Licence expired on ' || v_c.licence_expires_on;
  end if;
  if app.fn_licence_rank(v_c.licence_class) < (case when v_v.seat_capacity > 14 then 2 else 1 end) then
    raise exception 'LICENCE_CLASS_INSUFFICIENT' using detail = v_c.licence_class || ' licence on a ' || v_v.seat_capacity || '-seat vehicle';
  end if;
  if v_c.police_verified_on is null then
    return 'POLICE_VERIFICATION_MISSING';
  end if;
  if v_c.police_verified_on < p_on - 365 then
    return 'POLICE_VERIFICATION_STALE';
  end if;
  return null;
end;
$$;
revoke execute on function app.fn_driver_assert(uuid, uuid, date) from public, anon, authenticated;

create or replace function public.assert_driver_eligible(p_crew_id uuid, p_vehicle_id uuid, p_on date)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.transport_crew where id = p_crew_id and tenant_id = app.auth_tenant_id())
     or not exists (select 1 from public.transport_vehicle where id = p_vehicle_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CREW_NOT_FOUND' using errcode = 'P0002';
  end if;
  return app.fn_driver_assert(p_crew_id, p_vehicle_id, p_on);
end;
$$;
revoke execute on function public.assert_driver_eligible(uuid, uuid, date) from public, anon;
grant execute on function public.assert_driver_eligible(uuid, uuid, date) to authenticated;

-- ── Writes ──────────────────────────────────────────────────────────────────
create or replace function public.save_transport_crew(
  p_campus_id uuid, p_full_name text, p_cnic text, p_crew_role public.transport_crew_role, p_phone text default null,
  p_licence_no text default null, p_licence_class public.transport_licence_class default null, p_licence_expires_on date default null,
  p_police_verified_on date default null, p_blood_group text default null, p_staff_id uuid default null, p_active boolean default true, p_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_id     uuid;
  v_digits text := regexp_replace(coalesce(p_cnic, ''), '\D', '', 'g');
  v_cnic   text;
begin
  if app.auth_role() not in ('transport_manager', 'hr_manager', 'principal', 'super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select tenant_id into v_tenant from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id();
  if v_tenant is null then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (p_campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if length(v_digits) <> 13 then
    raise exception 'CNIC_INVALID' using errcode = '22023';
  end if;
  v_cnic := substr(v_digits, 1, 5) || '-' || substr(v_digits, 6, 7) || '-' || substr(v_digits, 13, 1);
  if p_staff_id is not null and not exists (select 1 from public.staff where id = p_staff_id and tenant_id = v_tenant) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_crew_role = 'driver' and (p_licence_no is null or p_licence_class is null or p_licence_expires_on is null) then
    raise exception 'LICENCE_REQUIRED' using errcode = '23514';
  end if;
  if p_id is null then
    insert into public.transport_crew (tenant_id, campus_id, staff_id, full_name, cnic, phone, crew_role, licence_no, licence_class, licence_expires_on, police_verified_on, blood_group, active)
    values (v_tenant, p_campus_id, p_staff_id, btrim(p_full_name), v_cnic, nullif(btrim(p_phone), ''), p_crew_role, nullif(btrim(p_licence_no), ''), p_licence_class, p_licence_expires_on, p_police_verified_on, nullif(p_blood_group, ''), p_active)
    returning id into v_id;
  else
    update public.transport_crew
       set staff_id = p_staff_id, full_name = btrim(p_full_name), cnic = v_cnic, phone = nullif(btrim(p_phone), ''), crew_role = p_crew_role,
           licence_no = nullif(btrim(p_licence_no), ''), licence_class = p_licence_class, licence_expires_on = p_licence_expires_on,
           police_verified_on = p_police_verified_on, blood_group = nullif(p_blood_group, ''), active = p_active
     where id = p_id and tenant_id = v_tenant and campus_id = p_campus_id returning id into v_id;
    if v_id is null then
      raise exception 'CREW_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'DUPLICATE_CNIC' using errcode = '23505';
end;
$$;
revoke execute on function public.save_transport_crew(uuid, text, text, public.transport_crew_role, text, text, public.transport_licence_class, date, date, text, uuid, boolean, uuid) from public, anon;
grant execute on function public.save_transport_crew(uuid, text, text, public.transport_crew_role, text, text, public.transport_licence_class, date, date, text, uuid, boolean, uuid) to authenticated;

-- Assigns a vehicle and crew to a route for a span of dates. Both the vehicle
-- document block (FR-P02) and the driver check run on the first and last day.
-- A Principal can pass an override reason, which records a named override of the
-- vehicle block (covering the span, or 30 days when open-ended) and links it.
create or replace function public.assign_transport_trip(
  p_route_id uuid, p_vehicle_id uuid, p_driver_id uuid, p_from date, p_to date default null,
  p_conductor_id uuid default null, p_attendant_id uuid default null, p_override_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_route    public.transport_route%rowtype;
  v_veh      public.transport_vehicle%rowtype;
  v_tenant   uuid;
  v_override uuid;
  v_warn     text;
  v_id       uuid;
  v_to       date := p_to;
begin
  select * into v_route from public.transport_route where id = p_route_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ROUTE_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_tenant := app.fn_transport_assert_manager(v_route.campus_id);
  select * into v_veh from public.transport_vehicle where id = p_vehicle_id and tenant_id = v_tenant and campus_id = v_route.campus_id;
  if not found then
    raise exception 'VEHICLE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.transport_crew where id = p_driver_id and tenant_id = v_tenant and campus_id = v_route.campus_id) then
    raise exception 'CREW_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_conductor_id is not null and not exists (select 1 from public.transport_crew where id = p_conductor_id and tenant_id = v_tenant and campus_id = v_route.campus_id and crew_role = 'conductor') then
    raise exception 'CONDUCTOR_INVALID' using errcode = '22023';
  end if;
  if p_attendant_id is not null and not exists (select 1 from public.transport_crew where id = p_attendant_id and tenant_id = v_tenant and campus_id = v_route.campus_id and crew_role = 'attendant') then
    raise exception 'ATTENDANT_INVALID' using errcode = '22023';
  end if;
  if p_to is not null and p_to < p_from then
    raise exception 'SPAN_INVALID' using errcode = '22023';
  end if;

  if nullif(btrim(p_override_reason), '') is not null then
    if app.auth_role() not in ('owner', 'super_admin', 'principal') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if char_length(btrim(p_override_reason)) < 10 then
      raise exception 'REASON_MIN_LENGTH_10' using errcode = '23514';
    end if;
    if app.fn_vehicle_block_reason(p_vehicle_id, p_from) is not null or (v_to is not null and app.fn_vehicle_block_reason(p_vehicle_id, v_to) is not null) then
      insert into public.transport_vehicle_override (tenant_id, campus_id, vehicle_id, valid_from, valid_to, reason, approved_by)
      values (v_tenant, v_route.campus_id, p_vehicle_id, p_from, coalesce(v_to, p_from + 30), btrim(p_override_reason), (select auth.uid()))
      returning id into v_override;
    end if;
  end if;

  perform app.fn_vehicle_assert(p_vehicle_id, p_from);
  if v_to is not null then
    perform app.fn_vehicle_assert(p_vehicle_id, v_to);
  end if;
  v_warn := app.fn_driver_assert(p_driver_id, p_vehicle_id, p_from);
  if v_to is not null then
    v_warn := coalesce(app.fn_driver_assert(p_driver_id, p_vehicle_id, v_to), v_warn);
  end if;

  insert into public.transport_trip_assignment (tenant_id, campus_id, route_id, shift, vehicle_id, driver_id, conductor_id, attendant_id, effective_from, effective_to, override_id, created_by)
  values (v_tenant, v_route.campus_id, p_route_id, v_route.shift, p_vehicle_id, p_driver_id, p_conductor_id, p_attendant_id, p_from, v_to, v_override, (select auth.uid()))
  returning id into v_id;
  return jsonb_build_object('assignment_id', v_id, 'warning', v_warn, 'override_id', v_override);
exception when exclusion_violation then
  raise exception 'ASSIGNMENT_CONFLICT' using errcode = '23P01';
end;
$$;
revoke execute on function public.assign_transport_trip(uuid, uuid, uuid, date, date, uuid, uuid, text) from public, anon;
grant execute on function public.assign_transport_trip(uuid, uuid, uuid, date, date, uuid, uuid, text) to authenticated;

create or replace function public.end_transport_assignment(p_assignment_id uuid, p_last_day date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a public.transport_trip_assignment%rowtype;
begin
  select * into v_a from public.transport_trip_assignment where id = p_assignment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ASSIGNMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_transport_assert_manager(v_a.campus_id);
  if p_last_day < v_a.effective_from then
    raise exception 'SPAN_INVALID' using errcode = '22023';
  end if;
  update public.transport_trip_assignment set effective_to = p_last_day where id = p_assignment_id;
end;
$$;
revoke execute on function public.end_transport_assignment(uuid, date) from public, anon;
grant execute on function public.end_transport_assignment(uuid, date) to authenticated;
