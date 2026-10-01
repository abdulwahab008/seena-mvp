-- FR-Q01: hostel block, room and bed inventory.
--
-- Accommodation is modelled down to the individual bed so occupancy and vacancy
-- are facts, not a warden's estimate. Gender belongs to the BLOCK, never the room:
-- a girls' block cannot hold a boy (assert_bed_gender, called by every
-- allocation path). A room's beds are rows in hostel_bed with a stable identity
-- (bed_code like IQ-105-B3 = block code, room number, bed number). Changing a
-- room's bed_count NEVER regenerates beds: allocations, gate passes and billing
-- reference bed ids. Raising the count adds (or reactivates) beds; lowering it
-- retires the highest-numbered beds, and is refused with BED_OCCUPIED if any of
-- them is occupied. A room set out_of_service leaves the available-bed count but
-- its allocations are untouched (they stay billable).
--
-- Who runs the hostel: Owner, Super Admin, Principal, Vice Principal, plus the
-- warden named on a block (hostel_block.warden_staff_id -> staff.user_id), for
-- their own campus. hostel_bed.status 'occupied' is maintained by the allocation
-- functions (FR-Q02); this migration only reads it.

create type public.hostel_gender as enum ('male', 'female');
create type public.hostel_room_type as enum ('single', 'double', 'triple', 'quad', 'dorm');
create type public.hostel_room_status as enum ('in_service', 'out_of_service');
create type public.hostel_bed_status as enum ('available', 'occupied', 'retired');

create table public.hostel_block (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  code             text not null check (code ~ '^[A-Z0-9]{1,6}$'),
  name             text not null check (char_length(btrim(name)) between 1 and 80),
  gender           public.hostel_gender not null,
  warden_staff_id  uuid references public.staff(id) on delete set null,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  constraint uq_hostel_block_code unique (tenant_id, campus_id, code)
);
create index idx_hostel_block_scope on public.hostel_block (tenant_id, campus_id);
create index idx_hostel_block_warden on public.hostel_block (warden_staff_id);

create table public.hostel_room (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  block_id   uuid not null references public.hostel_block(id) on delete cascade,
  room_no    text not null check (room_no ~ '^[A-Za-z0-9]{1,8}$'),
  floor      int not null default 1 check (floor between 0 and 30),
  room_type  public.hostel_room_type not null default 'quad',
  bed_count  int not null check (bed_count between 1 and 40),
  status     public.hostel_room_status not null default 'in_service',
  created_at timestamptz not null default now(),
  constraint uq_room_no unique (block_id, room_no)
);
create index idx_hostel_room_scope on public.hostel_room (tenant_id, campus_id);

create table public.hostel_bed (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  room_id    uuid not null references public.hostel_room(id) on delete cascade,
  bed_no     int not null check (bed_no > 0),
  bed_code   text not null,
  status     public.hostel_bed_status not null default 'available',
  created_at timestamptz not null default now(),
  constraint uq_bed_no unique (room_id, bed_no)
);
create index idx_hostel_bed_scope on public.hostel_bed (tenant_id, campus_id);
create unique index uq_hostel_bed_code on public.hostel_bed (tenant_id, campus_id, bed_code);

create trigger hostel_block_audit after insert or update or delete on public.hostel_block
  for each row execute function app.tg_audit_row();
create trigger hostel_room_audit after insert or update or delete on public.hostel_room
  for each row execute function app.tg_audit_row();

-- Hostel staff of a campus: the Principal's side plus the block warden.
create or replace function app.fn_hostel_staff(p_tenant uuid, p_campus uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_tenant = app.auth_tenant_id()
     and (app.auth_role() in ('owner', 'super_admin')
          or (p_campus = any (app.auth_campus_ids())
              and (app.auth_role() in ('principal', 'vice_principal')
                   or exists (select 1 from public.hostel_block b join public.staff s on s.id = b.warden_staff_id
                               where b.tenant_id = p_tenant and b.campus_id = p_campus and s.user_id = (select auth.uid())))));
$$;
revoke execute on function app.fn_hostel_staff(uuid, uuid) from public, anon;
grant execute on function app.fn_hostel_staff(uuid, uuid) to authenticated;

-- Principal-side management (not the warden): blocks, rooms, tariffs.
create or replace function app.fn_hostel_assert_manager(p_campus_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal') then
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
revoke execute on function app.fn_hostel_assert_manager(uuid) from public, anon, authenticated;

-- Operations (allocation, gate pass, visitors): Principal side or the block warden.
create or replace function app.fn_hostel_assert_staff(p_campus_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  select tenant_id into v_tenant from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id();
  if v_tenant is null then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app.fn_hostel_staff(v_tenant, p_campus_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return v_tenant;
end;
$$;
revoke execute on function app.fn_hostel_assert_staff(uuid) from public, anon, authenticated;

alter table public.hostel_block enable row level security;
alter table public.hostel_room enable row level security;
alter table public.hostel_bed enable row level security;
create policy hostel_block_campus_scope on public.hostel_block for select to authenticated using (app.fn_hostel_staff(tenant_id, campus_id));
create policy hostel_room_campus_scope on public.hostel_room for select to authenticated using (app.fn_hostel_staff(tenant_id, campus_id));
create policy hostel_bed_campus_scope on public.hostel_bed for select to authenticated using (app.fn_hostel_staff(tenant_id, campus_id));

create or replace function app.fn_hostel_bed_occupied(p_bed_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.hostel_bed where id = p_bed_id and status = 'occupied');
$$;
revoke execute on function app.fn_hostel_bed_occupied(uuid) from public, anon, authenticated;

-- Keeps the beds of a room in step with bed_count without ever regenerating them.
create or replace function app.tg_sync_beds_on_room()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
  b      record;
begin
  select code into v_code from public.hostel_block where id = new.block_id;
  -- Lowering the count: refuse if any bed that would be retired is occupied.
  for b in select id, bed_no from public.hostel_bed where room_id = new.id and bed_no > new.bed_count and status <> 'retired' loop
    if app.fn_hostel_bed_occupied(b.id) then
      raise exception 'BED_OCCUPIED' using errcode = '23514', detail = 'Bed ' || b.bed_no || ' of room ' || new.room_no || ' is occupied';
    end if;
  end loop;
  update public.hostel_bed set status = 'retired' where room_id = new.id and bed_no > new.bed_count and status <> 'retired';
  -- Raising it: reactivate retired beds, then add the missing ones.
  update public.hostel_bed set status = 'available' where room_id = new.id and bed_no <= new.bed_count and status = 'retired';
  insert into public.hostel_bed (tenant_id, campus_id, room_id, bed_no, bed_code)
  select new.tenant_id, new.campus_id, new.id, g, v_code || '-' || new.room_no || '-B' || g
    from generate_series(1, new.bed_count) g
   where not exists (select 1 from public.hostel_bed x where x.room_id = new.id and x.bed_no = g);
  return null;
end;
$$;
create trigger trg_sync_beds_on_room after insert or update of bed_count on public.hostel_room
  for each row execute function app.tg_sync_beds_on_room();

-- A room's block and room number (hence every bed code) cannot change once created.
create or replace function app.tg_hostel_room_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.block_id <> old.block_id or new.room_no <> old.room_no then
    raise exception 'ROOM_IDENTITY_IMMUTABLE' using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger trg_hostel_room_immutable before update on public.hostel_room
  for each row execute function app.tg_hostel_room_immutable();

-- ── Writes ──────────────────────────────────────────────────────────────────
-- Creates a block with p_rooms rooms of p_beds_per_room beds. Rooms are numbered
-- by floor: 101..110, 201..210 with the default 10 rooms to a floor.
create or replace function public.create_hostel_block(
  p_campus_id uuid, p_code text, p_name text, p_gender public.hostel_gender, p_rooms int, p_beds_per_room int,
  p_rooms_per_floor int default 10, p_room_type public.hostel_room_type default 'quad', p_warden_staff_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.fn_hostel_assert_manager(p_campus_id);
  v_id     uuid;
  i        int;
begin
  if p_rooms < 1 or p_rooms > 400 or p_beds_per_room < 1 or p_beds_per_room > 40 or p_rooms_per_floor < 1 or p_rooms_per_floor > 99 then
    raise exception 'BLOCK_SIZE_INVALID' using errcode = '22023';
  end if;
  if p_warden_staff_id is not null and not exists (select 1 from public.staff where id = p_warden_staff_id and tenant_id = v_tenant) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into public.hostel_block (tenant_id, campus_id, code, name, gender, warden_staff_id)
  values (v_tenant, p_campus_id, upper(btrim(p_code)), btrim(p_name), p_gender, p_warden_staff_id)
  returning id into v_id;
  for i in 0 .. p_rooms - 1 loop
    insert into public.hostel_room (tenant_id, campus_id, block_id, room_no, floor, room_type, bed_count)
    values (v_tenant, p_campus_id, v_id, ((i / p_rooms_per_floor + 1) * 100 + (i % p_rooms_per_floor) + 1)::text, i / p_rooms_per_floor + 1, p_room_type, p_beds_per_room);
  end loop;
  return v_id;
exception when unique_violation then
  raise exception 'BLOCK_CODE_EXISTS' using errcode = '23505';
end;
$$;
revoke execute on function public.create_hostel_block(uuid, text, text, public.hostel_gender, int, int, int, public.hostel_room_type, uuid) from public, anon;
grant execute on function public.create_hostel_block(uuid, text, text, public.hostel_gender, int, int, int, public.hostel_room_type, uuid) to authenticated;

create or replace function public.update_hostel_block(p_block_id uuid, p_name text, p_warden_staff_id uuid default null, p_active boolean default true)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b public.hostel_block%rowtype;
begin
  select * into v_b from public.hostel_block where id = p_block_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'BLOCK_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_hostel_assert_manager(v_b.campus_id);
  if p_warden_staff_id is not null and not exists (select 1 from public.staff where id = p_warden_staff_id and tenant_id = v_b.tenant_id) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  update public.hostel_block set name = btrim(p_name), warden_staff_id = p_warden_staff_id, active = p_active where id = p_block_id;
end;
$$;
revoke execute on function public.update_hostel_block(uuid, text, uuid, boolean) from public, anon;
grant execute on function public.update_hostel_block(uuid, text, uuid, boolean) to authenticated;

create or replace function public.add_hostel_room(p_block_id uuid, p_room_no text, p_bed_count int, p_room_type public.hostel_room_type default 'quad', p_floor int default 1)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b  public.hostel_block%rowtype;
  v_id uuid;
begin
  select * into v_b from public.hostel_block where id = p_block_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'BLOCK_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_hostel_assert_manager(v_b.campus_id);
  insert into public.hostel_room (tenant_id, campus_id, block_id, room_no, floor, room_type, bed_count)
  values (v_b.tenant_id, v_b.campus_id, p_block_id, btrim(p_room_no), p_floor, p_room_type, p_bed_count)
  returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'ROOM_EXISTS' using errcode = '23505';
end;
$$;
revoke execute on function public.add_hostel_room(uuid, text, int, public.hostel_room_type, int) from public, anon;
grant execute on function public.add_hostel_room(uuid, text, int, public.hostel_room_type, int) to authenticated;

-- Change a room's bed count, type or status. Beds are never regenerated.
create or replace function public.update_hostel_room(p_room_id uuid, p_bed_count int, p_room_type public.hostel_room_type, p_status public.hostel_room_status)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r public.hostel_room%rowtype;
begin
  select * into v_r from public.hostel_room where id = p_room_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ROOM_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_hostel_assert_manager(v_r.campus_id);
  update public.hostel_room set bed_count = p_bed_count, room_type = p_room_type, status = p_status where id = p_room_id;
end;
$$;
revoke execute on function public.update_hostel_room(uuid, int, public.hostel_room_type, public.hostel_room_status) from public, anon;
grant execute on function public.update_hostel_room(uuid, int, public.hostel_room_type, public.hostel_room_status) to authenticated;

-- GENDER_MISMATCH unless the student's gender matches the block of the bed.
create or replace function public.assert_bed_gender(p_student_id uuid, p_bed_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_sg public.gender;
  v_bg public.hostel_gender;
begin
  select s.gender into v_sg from public.student s where s.id = p_student_id and s.tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  select b.gender into v_bg
    from public.hostel_bed d join public.hostel_room r on r.id = d.room_id join public.hostel_block b on b.id = r.block_id
   where d.id = p_bed_id and d.tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'BED_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_sg::text is distinct from v_bg::text then
    raise exception 'GENDER_MISMATCH' using errcode = '23514';
  end if;
end;
$$;
revoke execute on function public.assert_bed_gender(uuid, uuid) from public, anon;
grant execute on function public.assert_bed_gender(uuid, uuid) to authenticated;

-- Occupancy by block: the beds a warden can still offer.
create view public.v_hostel_occupancy with (security_invoker = true) as
select b.id as block_id, b.tenant_id, b.campus_id, b.code, b.name, b.gender,
       count(distinct r.id) as rooms,
       count(d.id) filter (where d.status <> 'retired') as beds_total,
       count(d.id) filter (where d.status = 'occupied') as beds_occupied,
       count(d.id) filter (where d.status = 'available' and r.status = 'in_service') as beds_available,
       count(d.id) filter (where d.status <> 'retired' and r.status = 'out_of_service') as beds_out_of_service
  from public.hostel_block b
  left join public.hostel_room r on r.block_id = b.id
  left join public.hostel_bed d on d.room_id = r.id
 group by b.id;
revoke all on public.v_hostel_occupancy from anon;
grant select on public.v_hostel_occupancy to authenticated;
