-- FR-F02: Friday shortened schedule (via a general campus bell-calendar
-- resolver that FR-F03's Ramadan override will reuse without a schema
-- change — that's why bell_calendar_rule already carries date_from/
-- date_to columns even though this FR only ever writes weekday rules).
--
-- Scope cuts (Module F's timetable builder, F04, doesn't exist yet):
--   * ORPHANED_SLOT / v_orphaned_timetable_slots needs timetable_slot,
--     which is F04's table. Not built — same "gate what exists today"
--     precedent as FR-E10's room registry and this batch's own
--     bell_template migration.
--   * The Friday print AC needs an actual timetable grid to print. Not
--     built for the same reason.
--   * ex_bell_rule_no_ambiguity (the date-range EXCLUDE constraint) is
--     FR-F03's own — this FR never writes a date_from rule, so it can't
--     yet produce the ambiguity that constraint guards against. What IS
--     built now, because it's a real risk within this FR's own scope: a
--     partial unique index preventing two weekday rules at the same
--     campus+shift+weekday+precedence, which would make resolution
--     genuinely ambiguous.
--
-- resolve_bell_template() is written to already understand date_from/
-- date_to rules (ordering a date-range rule as more specific than a
-- weekday rule at equal precedence) even though nothing can create one
-- yet — so FR-F03 only has to add rows and its own EXCLUDE constraint,
-- never touch this function.

create table public.bell_calendar_rule (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  shift            public.section_shift not null,
  bell_template_id uuid not null references public.bell_template(id) on delete cascade,
  weekday          smallint,
  date_from        date,
  date_to          date,
  precedence       smallint not null default 50,
  note             text,
  created_at       timestamptz not null default now(),
  constraint chk_bell_rule_shape check (weekday is not null or date_from is not null),
  constraint chk_bell_rule_weekday_range check (weekday is null or weekday between 0 and 6),
  constraint chk_bell_rule_date_order check (date_from is null or date_to is null or date_to >= date_from)
);

-- Real ambiguity risk within this FR's own scope: two weekday rules for
-- the same campus+shift+weekday+precedence would make resolution
-- non-deterministic.
create unique index uq_bell_rule_weekday_precedence on public.bell_calendar_rule (campus_id, shift, weekday, precedence)
  where weekday is not null and date_from is null;
create index idx_bell_rule_campus_weekday on public.bell_calendar_rule (campus_id, shift, weekday) where weekday is not null;
create index idx_bell_rule_campus_dates on public.bell_calendar_rule (campus_id, shift, date_from, date_to) where date_from is not null;

create trigger bell_calendar_rule_audit after insert or update or delete on public.bell_calendar_rule
  for each row execute function app.tg_audit_row();

-- The single source of truth for "what bell template applies on this
-- date" — pure and side-effect free (FR-F03's own Notes: never a
-- materialised copy, since a one-day Ramadan correction must not corrupt
-- already-marked attendance). Precedence wins first; at equal precedence
-- a date-range rule is more specific than a weekday rule.
create or replace function public.resolve_bell_template(p_campus_id uuid, p_shift public.section_shift, p_date date)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select bell_template_id
        from public.bell_calendar_rule
       where campus_id = p_campus_id
         and shift = p_shift
         and tenant_id = app.auth_tenant_id()
         and (
           (date_from is not null and p_date between date_from and coalesce(date_to, date_from))
           or (weekday is not null and date_from is null and extract(dow from p_date)::smallint = weekday)
         )
       order by precedence desc, (date_from is not null) desc
       limit 1
    ),
    (
      select id from public.bell_template
       where campus_id = p_campus_id and shift = p_shift and tenant_id = app.auth_tenant_id() and is_default
    )
  );
$$;

revoke execute on function public.resolve_bell_template(uuid, public.section_shift, date) from public, anon;
grant execute on function public.resolve_bell_template(uuid, public.section_shift, date) to authenticated;

create or replace function public.create_bell_calendar_rule(
  p_campus_id uuid,
  p_shift public.section_shift,
  p_bell_template_id uuid,
  p_weekday smallint default null,
  p_date_from date default null,
  p_date_to date default null,
  p_precedence smallint default 50,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid;
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
  if not exists (select 1 from public.bell_template where id = p_bell_template_id and tenant_id = v_tenant_id and campus_id = p_campus_id and shift = p_shift) then
    raise exception 'BELL_TEMPLATE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_weekday is null and p_date_from is null then
    raise exception 'BELL_RULE_SHAPE_INVALID' using errcode = '23514';
  end if;
  if p_weekday is not null and (p_weekday < 0 or p_weekday > 6) then
    raise exception 'BELL_RULE_WEEKDAY_INVALID' using errcode = '23514';
  end if;

  begin
    insert into public.bell_calendar_rule (tenant_id, campus_id, shift, bell_template_id, weekday, date_from, date_to, precedence, note)
    values (v_tenant_id, p_campus_id, p_shift, p_bell_template_id, p_weekday, p_date_from, p_date_to, p_precedence, p_note)
    returning id into v_id;
  exception
    when unique_violation then
      raise exception 'BELL_RULE_WEEKDAY_PRECEDENCE_DUPLICATE' using errcode = '23505';
  end;

  return v_id;
end;
$$;

revoke execute on function public.create_bell_calendar_rule(uuid, public.section_shift, uuid, smallint, date, date, smallint, text) from public, anon;
grant execute on function public.create_bell_calendar_rule(uuid, public.section_shift, uuid, smallint, date, date, smallint, text) to authenticated;

create or replace function public.delete_bell_calendar_rule(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id, campus_id into v_tenant_id, v_campus_id from public.bell_calendar_rule where id = p_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'BELL_RULE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  delete from public.bell_calendar_rule where id = p_id;
end;
$$;

revoke execute on function public.delete_bell_calendar_rule(uuid) from public, anon;
grant execute on function public.delete_bell_calendar_rule(uuid) to authenticated;

alter table public.bell_calendar_rule enable row level security;

create policy bell_rule_campus_scope on public.bell_calendar_rule
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
