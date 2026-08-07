-- FR-F01: bell template definition (per campus + shift bell timings).
--
-- Scope cuts (rest of Module F Timetable doesn't exist yet — this is the
-- first Timetable FR built, and it's the one everything else in that
-- module depends on: F04's draft slot builder and F05's clash detection
-- both need bell_period's resolved time ranges, and D13's substitute
-- screen / D03's teach-scope guard both need timetable_slot, which is
-- F04's table, not this FR's):
--   * is_locked exists and IS enforced (editing a segment's time on a
--     locked template is rejected with BELL_TEMPLATE_LOCKED), but nothing
--     sets it to true yet. The AC's "referenced by a published timetable
--     version" trigger (trg_lock_bell_template_on_publish) belongs on
--     timetable_version, which doesn't exist. That future FR flips
--     is_locked via a plain UPDATE — no schema change needed here.
--   * "the timetable builder refuses to start without a nominated
--     default" is a gate on a builder screen that doesn't exist yet
--     (that's F04). What's built instead: set_bell_template_default()
--     plus a UI banner on this FR's own admin screen showing which
--     shifts still lack one — same "gate what exists today" precedent
--     as FR-E10's room registry.
--
-- Period numbering is intentionally NOT the segment's array position:
-- period_no is assigned only to TEACHING segments, sequentially, and left
-- null for BREAK/ASSEMBLY/PRAYER segments — that's the whole point of the
-- FR (Notion Notes: "every school in the country counts the next teaching
-- slot as period 5, not segment 6").

create extension if not exists btree_gist;

-- Postgres ships range types over date/int/numeric/timestamp but not
-- `time` — bell_period's overlap EXCLUDE constraint needs one.
create type public.timerange as range (subtype = time);

create type public.bell_segment_kind as enum ('TEACHING', 'BREAK', 'ASSEMBLY', 'PRAYER');

create table public.bell_template (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  shift      public.section_shift not null,
  code       text not null,
  name       text not null,
  is_default boolean not null default false,
  is_locked  boolean not null default false,
  created_at timestamptz not null default now()
);

create unique index uq_bell_template_campus_shift_code on public.bell_template (campus_id, shift, code);
-- AC: a campus+shift can have at most one default template.
create unique index uq_bell_default on public.bell_template (campus_id, shift) where is_default;
create index idx_bell_template_campus on public.bell_template (campus_id);

create trigger bell_template_audit after insert or update or delete on public.bell_template
  for each row execute function app.tg_audit_row();

create table public.bell_period (
  id               uuid primary key default gen_random_uuid(),
  bell_template_id uuid not null references public.bell_template(id) on delete cascade,
  segment_ordinal  smallint not null,
  period_no        smallint,
  kind             public.bell_segment_kind not null,
  start_time       time not null,
  end_time         time not null,
  constraint chk_bell_period_time_order check (end_time > start_time),
  constraint chk_bell_period_no_only_teaching check (
    (kind = 'TEACHING' and period_no is not null) or (kind <> 'TEACHING' and period_no is null)
  ),
  -- Redundant DB-level backstop for the app-level pairwise check in
  -- create_bell_template/update_bell_period_time below — same "app check
  -- + DB constraint" pattern as create_homework's DESCRIPTION_TOO_LONG.
  constraint ex_bell_period_no_overlap exclude using gist (
    bell_template_id with =,
    public.timerange(start_time, end_time) with &&
  )
);

create unique index uq_bell_period_template_ordinal on public.bell_period (bell_template_id, segment_ordinal);
create index idx_bell_period_template_period_no on public.bell_period (bell_template_id, period_no);

-- Composes a whole template (assembly, teaching periods, breaks) from one
-- ordered JSON array in a single transaction, auto-numbering period_no.
-- p_segments shape: [{"kind":"ASSEMBLY","start_time":"07:45","end_time":"08:00"}, ...]
create or replace function public.create_bell_template(
  p_campus_id uuid,
  p_shift public.section_shift,
  p_code text,
  p_name text,
  p_segments jsonb,
  p_is_default boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid := app.auth_tenant_id();
  v_template_id uuid;
  v_count       int;
  v_idx         int;
  v_seg         jsonb;
  v_kind        public.bell_segment_kind;
  v_period_no   smallint := 0;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_count := jsonb_array_length(p_segments);
  if v_count is null or v_count < 1 then
    raise exception 'BELL_TEMPLATE_EMPTY' using errcode = '22023';
  end if;

  -- Named overlap check ahead of the EXCLUDE constraint, so the caller
  -- gets "segments 3 and 4" instead of a raw exclusion_violation.
  for v_idx in 0 .. v_count - 2 loop
    for j in v_idx + 1 .. v_count - 1 loop
      if (p_segments -> v_idx ->> 'start_time')::time < (p_segments -> j ->> 'end_time')::time
         and (p_segments -> j ->> 'start_time')::time < (p_segments -> v_idx ->> 'end_time')::time then
        raise exception 'BELL_PERIOD_OVERLAP: segments % and %', v_idx + 1, j + 1 using errcode = '23514';
      end if;
    end loop;
  end loop;

  begin
    insert into public.bell_template (tenant_id, campus_id, shift, code, name)
    values (v_tenant_id, p_campus_id, p_shift, p_code, p_name)
    returning id into v_template_id;
  exception
    when unique_violation then
      raise exception 'BELL_TEMPLATE_CODE_DUPLICATE' using errcode = '23505';
  end;

  for v_idx in 0 .. v_count - 1 loop
    v_seg := p_segments -> v_idx;
    v_kind := (v_seg ->> 'kind')::public.bell_segment_kind;
    if v_kind = 'TEACHING' then
      v_period_no := v_period_no + 1;
    end if;
    insert into public.bell_period (bell_template_id, segment_ordinal, period_no, kind, start_time, end_time)
    values (
      v_template_id,
      v_idx + 1,
      case when v_kind = 'TEACHING' then v_period_no else null end,
      v_kind,
      (v_seg ->> 'start_time')::time,
      (v_seg ->> 'end_time')::time
    );
  end loop;

  if p_is_default then
    perform public.set_bell_template_default(v_template_id);
  end if;

  return v_template_id;
end;
$$;

revoke execute on function public.create_bell_template(uuid, public.section_shift, text, text, jsonb, boolean) from public, anon;
grant execute on function public.create_bell_template(uuid, public.section_shift, text, text, jsonb, boolean) to authenticated;

create or replace function public.set_bell_template_default(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
  v_shift     public.section_shift;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id, campus_id, shift into v_tenant_id, v_campus_id, v_shift
    from public.bell_template where id = p_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'BELL_TEMPLATE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.bell_template set is_default = false
   where campus_id = v_campus_id and shift = v_shift and is_default and id <> p_id;
  update public.bell_template set is_default = true where id = p_id;
end;
$$;

revoke execute on function public.set_bell_template_default(uuid) from public, anon;
grant execute on function public.set_bell_template_default(uuid) to authenticated;

create or replace function public.update_bell_period_time(p_period_id uuid, p_start_time time, p_end_time time)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_template_id     uuid;
  v_tenant_id       uuid;
  v_campus_id       uuid;
  v_is_locked       boolean;
  v_ordinal         smallint;
  v_conflict_ordinal smallint;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_end_time <= p_start_time then
    raise exception 'BELL_PERIOD_TIME_ORDER_INVALID' using errcode = '23514';
  end if;

  select bp.bell_template_id, bp.segment_ordinal, bt.tenant_id, bt.campus_id, bt.is_locked
    into v_template_id, v_ordinal, v_tenant_id, v_campus_id, v_is_locked
    from public.bell_period bp
    join public.bell_template bt on bt.id = bp.bell_template_id
   where bp.id = p_period_id;

  if v_template_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'BELL_PERIOD_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_is_locked then
    raise exception 'BELL_TEMPLATE_LOCKED' using errcode = '55000';
  end if;

  select bp.segment_ordinal into v_conflict_ordinal
    from public.bell_period bp
   where bp.bell_template_id = v_template_id
     and bp.id <> p_period_id
     and bp.start_time < p_end_time and p_start_time < bp.end_time
   limit 1;
  if found then
    raise exception 'BELL_PERIOD_OVERLAP: segments % and %', v_ordinal, v_conflict_ordinal using errcode = '23514';
  end if;

  update public.bell_period set start_time = p_start_time, end_time = p_end_time where id = p_period_id;
end;
$$;

revoke execute on function public.update_bell_period_time(uuid, time, time) from public, anon;
grant execute on function public.update_bell_period_time(uuid, time, time) to authenticated;

alter table public.bell_template enable row level security;
alter table public.bell_period enable row level security;

create policy bell_template_campus_scope on public.bell_template
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy bell_period_campus_scope on public.bell_period
  for select to authenticated
  using (
    exists (
      select 1 from public.bell_template bt
       where bt.id = bell_period.bell_template_id
         and bt.tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or bt.campus_id = any(app.auth_campus_ids()))
    )
  );
