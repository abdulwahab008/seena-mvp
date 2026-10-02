-- FR-F03: Ramadan schedule override.
--
-- Not a new subsystem. FR-F02 built bell_calendar_rule with date_from/
-- date_to columns it never wrote to, and resolve_bell_template() already
-- understood date-range rules, precisely so this FR would be "add rows +
-- your own EXCLUDE constraint" (that file's own header says so). This
-- migration is therefore deliberately small, and everything it does add
-- hangs off the one resolver that already exists:
--
--   * ex_bell_rule_no_ambiguity  — the date-range half of the ambiguity
--     guard F02 could not yet build (it never wrote a date_from row, so
--     it could not produce the ambiguity the constraint guards against).
--   * a predicate fix in app.resolve_bell_template_unscoped for a rule
--     carrying BOTH a weekday and a date range — see below.
--   * update_bell_calendar_rule_dates() — the moon-sighting correction.
--
-- ── How the Ramadan window is defined ────────────────────────────────
-- As an ordinary bell_calendar_rule row with date_from/date_to set and
-- precedence 100 (versus 50 for weekday rules), per this FR's own
-- Supabase Objects. NOT a named calendar rule, NOT a tenant setting, NOT
-- a hijri-calendar table: Ramadan dates in Pakistan are not knowable in
-- advance — the Ruet-e-Hilal committee announces the sighting around
-- 21:00 the night before — so the only durable representation is "an
-- administrator-entered date range that can be corrected the next
-- morning". Anything computed from a hijri conversion would be wrong
-- roughly half the time and would not be correctable at all.
--
-- ── Ramadan Friday: what wins ────────────────────────────────────────
-- Both FR-F02's Friday shortening and this FR's Ramadan window apply on
-- a Ramadan Friday. Precedence decides, and the Ramadan rule is the
-- higher one (100 > 50), so a campus that only registers a plain
-- Ramadan date-range rule gets Ramadan timings on Ramadan Fridays —
-- AC1. A campus that wants a *third*, shorter still, Ramadan-Friday
-- schedule registers a rule carrying BOTH weekday = 5 and the Ramadan
-- date range, at a precedence above the general Ramadan rule (e.g. 110).
--
-- That layered shape is what forces the one predicate change here. The
-- old resolver matched a rule with both columns set on EVERY date in its
-- range, silently ignoring its own weekday — harmless while nothing
-- could create a date_from row, a live trap the moment this FR lets a
-- Principal create one. Both columns now have to hold, and at equal
-- precedence the specificity tiebreak runs date+weekday > date-only >
-- weekday-only. Pure-weekday and pure-date rules resolve exactly as they
-- did before; there is no behaviour change for anything F02 could write.
--
-- ── Published timetables are NOT re-rendered, and NOT frozen ─────────
-- Neither, because the question does not arise: a timetable_version owns
-- (weekday, period_no) slots and no clock times at all. Clock times are
-- resolved at read time, per date, through this resolver — so an already
-- published version renders under Ramadan timings for dates inside the
-- window and under its normal timings outside it, with no re-publish, no
-- clone, and no new version. That is exactly the property this FR's own
-- Notes demand ("never a materialised copy"): a one-day correction after
-- a moon sighting can never corrupt attendance already marked, because
-- there is nothing materialised to correct. AC2 is a consequence of the
-- architecture, not of any code in this file.
--
-- A section with 8 published slots on a day that resolves to a 6-period
-- Ramadan template keeps all 8 slot rows (AC3). Periods 7 and 8 simply
-- resolve to no bell_period, which teacher_timetable() already surfaces
-- as a NULL start_time/end_time through its LEFT JOIN LATERAL — the
-- teacher's own day view renders those as "Not held today" rather than
-- losing them.
--
-- ── Deliberately NOT changed ────────────────────────────────────────
--   * app.resolve_bell_template_for_weekday_unscoped() and the
--     v_slot_clock_time views built on it still filter `date_from is
--     null`, i.e. they ignore Ramadan rules entirely. That is correct,
--     not an oversight: they answer "what times does period 4 occupy in
--     the weekly grid", which is what TEACHER_CLASH / ROOM_CLASH /
--     suggest_substitutes() need. A teacher double-booked at 08:30 in
--     the normal grid is still double-booked in Ramadan — the clash is a
--     property of the grid, and re-deriving it per-date would make
--     clash detection depend on which date you happened to ask about.
--   * No bell_rule_audit table, despite this FR's Supabase Objects
--     naming one. bell_calendar_rule has carried app.tg_audit_row()
--     since F02, which already writes (row_id, actor_user_id,
--     actor_role, occurred_at, before jsonb, after jsonb,
--     changed_columns) to audit_log for every insert/update/delete — a
--     strict superset of (rule_id, changed_by, changed_at, old_row,
--     new_row). A second, table-specific audit trail would be a fork of
--     working machinery and a second thing to keep correct.

-- AC5: two rules of equal precedence with overlapping date ranges for
-- the same campus and shift are genuinely ambiguous — the resolver's
-- `limit 1` would pick one arbitrarily. Rejected at write time instead.
--
-- coalesce(date_to, date_from) rather than a bare date_to: an open-ended
-- daterange(x, null) is unbounded above and would vacuously collide with
-- every later rule, and the resolver already reads a null date_to as
-- "this one day only". The constraint's notion of a rule's extent has to
-- be the resolver's, or the two disagree about what overlaps.
alter table public.bell_calendar_rule
  add constraint ex_bell_rule_no_ambiguity
  exclude using gist (
    campus_id with =,
    shift with =,
    precedence with =,
    (daterange(date_from, coalesce(date_to, date_from), '[]')) with &&
  )
  where (date_from is not null);

create index idx_bell_rule_campus_precedence_dates
  on public.bell_calendar_rule (campus_id, shift, precedence, date_from, date_to)
  where date_from is not null;

-- Unchanged except for the two-column predicate and the specificity
-- tiebreak described in the header. Still tenant-scoped, still the
-- single source of truth, still pure.
create or replace function app.resolve_bell_template_unscoped(p_campus_id uuid, p_shift public.section_shift, p_date date)
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
         -- chk_bell_rule_shape guarantees at least one of the two is
         -- non-null, so a rule can never match unconditionally.
         and (date_from is null or p_date between date_from and coalesce(date_to, date_from))
         and (weekday is null or extract(dow from p_date)::smallint = weekday)
       order by precedence desc, (date_from is not null) desc, (weekday is not null) desc
       limit 1
    ),
    (
      select id from public.bell_template
       where campus_id = p_campus_id and shift = p_shift and tenant_id = app.auth_tenant_id() and is_default
    )
  );
$$;

-- Same signature, so create-or-replace: the exclusion violation is now
-- reachable and needs the same named-error treatment the unique
-- violation already gets, and a date-range rule defaults to precedence
-- 100 (this FR's own spec) while a weekday rule keeps 50.
create or replace function public.create_bell_calendar_rule(
  p_campus_id uuid,
  p_shift public.section_shift,
  p_bell_template_id uuid,
  p_weekday smallint default null,
  p_date_from date default null,
  p_date_to date default null,
  p_precedence smallint default null,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_precedence smallint := coalesce(p_precedence, case when p_date_from is not null then 100 else 50 end);
  v_id         uuid;
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
  if p_date_from is not null and p_date_to is not null and p_date_to < p_date_from then
    raise exception 'BELL_RULE_DATE_ORDER_INVALID' using errcode = '23514';
  end if;

  begin
    insert into public.bell_calendar_rule (tenant_id, campus_id, shift, bell_template_id, weekday, date_from, date_to, precedence, note)
    values (v_tenant_id, p_campus_id, p_shift, p_bell_template_id, p_weekday, p_date_from, p_date_to, v_precedence, p_note)
    returning id into v_id;
  exception
    when unique_violation then
      raise exception 'BELL_RULE_WEEKDAY_PRECEDENCE_DUPLICATE' using errcode = '23505';
    when exclusion_violation then
      raise exception 'BELL_RULE_DATE_RANGE_OVERLAP' using errcode = '23P01';
  end;

  return v_id;
end;
$$;

revoke execute on function public.create_bell_calendar_rule(uuid, public.section_shift, uuid, smallint, date, date, smallint, text) from public, anon;
grant execute on function public.create_bell_calendar_rule(uuid, public.section_shift, uuid, smallint, date, date, smallint, text) to authenticated;

-- AC2: the moon sighting shifts the start by a day and the Principal
-- corrects the range the next morning. A dedicated narrow mutator rather
-- than a general UPDATE policy on bell_calendar_rule: the dates are the
-- only field a correction ever touches, and the table has no write
-- policy at all today (every mutation goes through a function).
create or replace function public.update_bell_calendar_rule_dates(p_id uuid, p_date_from date, p_date_to date default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
  v_date_from date;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id, campus_id, date_from into v_tenant_id, v_campus_id, v_date_from
    from public.bell_calendar_rule where id = p_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'BELL_RULE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_date_from is null then
    raise exception 'BELL_RULE_NOT_DATE_RANGED' using errcode = '23514';
  end if;
  if p_date_from is null then
    raise exception 'BELL_RULE_SHAPE_INVALID' using errcode = '23514';
  end if;
  if p_date_to is not null and p_date_to < p_date_from then
    raise exception 'BELL_RULE_DATE_ORDER_INVALID' using errcode = '23514';
  end if;

  begin
    update public.bell_calendar_rule
       set date_from = p_date_from, date_to = p_date_to
     where id = p_id;
  exception
    when exclusion_violation then
      raise exception 'BELL_RULE_DATE_RANGE_OVERLAP' using errcode = '23P01';
  end;
end;
$$;

revoke execute on function public.update_bell_calendar_rule_dates(uuid, date, date) from public, anon;
grant execute on function public.update_bell_calendar_rule_dates(uuid, date, date) to authenticated;
