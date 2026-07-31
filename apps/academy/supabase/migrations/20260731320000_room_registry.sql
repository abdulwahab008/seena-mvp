-- FR-E10: room and venue registry.
--
-- Scope cuts (Module F Timetable doesn't exist yet):
--   * AC "room 205 marked inactive... referenced by a published timetable
--     version... publish lists those slots as blocking errors" needs
--     timetable_version/timetable_slot, which don't exist. Not built.
--   * AC "room referenced by any published timetable slot... deletion
--     blocked with ROOM_IN_USE" — same reason. No delete_room function
--     at all — same "is_active=false is the only removal path for now"
--     precedent set by class_level (pre-E02) and subject (pre-E06):
--     swap the trigger for a real usage check once F ships.
--   * "Chemistry practical period... Science Lab rooms listed above
--     Classroom" is built as a reusable, room-type-preference-ordered
--     suggestion function (suggest_rooms_for_type) a future timetable
--     "pick a room" screen would call directly — there is no period/slot
--     concept yet to attach it to.
--   * ROOM_CAPACITY_EXCEEDED is built as a standalone, callable check
--     (check_room_capacity) against a section's live enrolled headcount,
--     for the same reason — no slot exists yet to raise a non-blocking
--     warning on.
--
-- Room codes are unique per campus, not per tenant (AC: two campuses can
-- both have a room '101') — matches class_section's own per-campus
-- naming convention.

create type public.room_type_enum as enum ('CLASSROOM', 'SCIENCE_LAB', 'COMPUTER_LAB', 'HALL', 'LIBRARY', 'PRAYER_AREA');

create table public.room (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  code          text not null,
  name          text not null,
  room_type     public.room_type_enum not null default 'CLASSROOM',
  capacity      int not null,
  block_label   text,
  is_active     boolean not null default true,
  inactive_from date,
  created_at    timestamptz not null default now(),
  constraint chk_room_capacity check (capacity > 0)
);

create unique index uq_room_campus_code on public.room (campus_id, code);
create index idx_room_campus_type_active on public.room (campus_id, room_type, is_active);
create index idx_room_campus_active on public.room (campus_id) where is_active;

create trigger room_audit after insert or update or delete on public.room
  for each row execute function app.tg_audit_row();

create or replace function public.create_room(
  p_campus_id uuid, p_code text, p_name text, p_room_type public.room_type_enum, p_capacity int, p_block_label text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  -- Checked explicitly (not just left to chk_room_capacity) so the caller
  -- gets a named error rather than a raw constraint-violation message —
  -- same pattern as create_section's CAPACITY_OUT_OF_RANGE.
  if p_capacity < 1 then
    raise exception 'CAPACITY_MUST_BE_POSITIVE' using errcode = '23514';
  end if;

  begin
    insert into public.room (tenant_id, campus_id, code, name, room_type, capacity, block_label)
    values (app.auth_tenant_id(), p_campus_id, p_code, p_name, p_room_type, p_capacity, p_block_label)
    returning id into v_id;
  exception
    when unique_violation then
      raise exception 'ROOM_CODE_DUPLICATE' using errcode = '23505';
  end;

  return v_id;
end;
$$;

revoke execute on function public.create_room(uuid, text, text, public.room_type_enum, int, text) from public, anon;
grant execute on function public.create_room(uuid, text, text, public.room_type_enum, int, text) to authenticated;

create or replace function public.set_room_active(p_id uuid, p_is_active boolean, p_inactive_from date default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id into v_tenant_id from public.room where id = p_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'ROOM_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.room
     set is_active = p_is_active, inactive_from = case when p_is_active then null else coalesce(p_inactive_from, current_date) end
   where id = p_id;
end;
$$;

revoke execute on function public.set_room_active(uuid, boolean, date) from public, anon;
grant execute on function public.set_room_active(uuid, boolean, date) to authenticated;

-- The AC's own worked example: a 42-strength section in a 30-capacity
-- room is a non-blocking warning, never an error — there is no slot to
-- attach the warning to yet, so this returns the raw comparison for a
-- future timetable screen (or this module's own UI) to render.
create or replace function public.check_room_capacity(p_room_id uuid, p_section_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_room_tenant    uuid;
  v_capacity       int;
  v_section_tenant uuid;
  v_strength       int;
begin
  select tenant_id, capacity into v_room_tenant, v_capacity from public.room where id = p_room_id;
  if v_room_tenant is null or v_room_tenant <> app.auth_tenant_id() then
    raise exception 'ROOM_NOT_FOUND' using errcode = 'P0002';
  end if;

  select tenant_id into v_section_tenant from public.class_section where id = p_section_id;
  if v_section_tenant is null or v_section_tenant <> app.auth_tenant_id() then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  select count(*)::int into v_strength from public.enrolment where section_id = p_section_id and status = 'active';

  return jsonb_build_object('room_capacity', v_capacity, 'section_strength', v_strength, 'exceeded', v_strength > v_capacity);
end;
$$;

revoke execute on function public.check_room_capacity(uuid, uuid) from public, anon;
grant execute on function public.check_room_capacity(uuid, uuid) to authenticated;

-- Active rooms of the preferred type first (e.g. Science Lab for a
-- Chemistry practical), then every other active room — both tiers
-- alphabetical by code.
create or replace function public.suggest_rooms_for_type(p_campus_id uuid, p_preferred_room_type public.room_type_enum)
returns setof public.room
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.room
   where tenant_id = app.auth_tenant_id() and campus_id = p_campus_id and is_active
   order by (room_type = p_preferred_room_type) desc, code;
$$;

revoke execute on function public.suggest_rooms_for_type(uuid, public.room_type_enum) from public, anon;
grant execute on function public.suggest_rooms_for_type(uuid, public.room_type_enum) to authenticated;

alter table public.room enable row level security;

create policy room_campus_scope on public.room
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
