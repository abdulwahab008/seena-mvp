-- FR-F08: soft constraint advisory warnings.
--
-- The counterpart to Module F's hard constraints, and deliberately the
-- opposite shape from them in every respect that matters:
--
--   hard (F05/F06/F07)   raised as an exception from upsert_timetable_
--                        slot() at write time, SQLSTATE 23514, the write
--                        does not happen.
--   soft (this FR)       returned as ROWS from validate_timetable_
--                        version(), each tagged with a `severity`
--                        column, at read time, on demand.
--
-- ── Why a warning can never be mistaken for a refusal ────────────────
-- Because the two travel over different channels, not different values
-- of the same one. A refusal is a raised exception: PostgREST turns it
-- into a non-2xx response and supabase-js populates `error`, so a caller
-- that ignores it gets no data at all. A warning is a row in a normal
-- 2xx result set. There is no code path in which a caller "checks for
-- errors" and accidentally trips over a warning, and none in which a
-- warning silently aborts a write. publish_timetable() proves it: it
-- calls the validator, counts the WARNING rows, and publishes anyway —
-- warnings have no ability to block, structurally, not by convention.
--
-- ── Why a warning can't be silently ignored either ───────────────────
-- publish_timetable() stores the accepted count on the version row
-- (warning_count, already on timetable_version since FR-F09) and the
-- builder screen renders it against the published version. That is this
-- FR's own Notes: "storing the accepted warning count on the published
-- version keeps the compromise visible at review time". A Principal can
-- publish over 40 warnings; they cannot publish over 40 warnings without
-- the number being on the record.
--
-- ── Live, never stored ───────────────────────────────────────────────
-- No timetable_conflict table and no mv_teacher_daily_load, despite both
-- appearing in this FR's Supabase Objects. A stored conflict set is
-- wrong the instant a slot moves, and the ACs are about a draft being
-- actively edited ("Mr. Imran holds 7 periods on Tuesday" is a fact
-- about the grid as it stands, not as it stood at 23:30 last night).
-- The specced nightly `refresh_mv_teacher_daily_load()` cron would
-- guarantee the Principal sees yesterday's answer while dragging today's
-- slots — a materialised view here buys staleness, not speed, for a
-- query that reads one indexed version's slots. v_teacher_daily_load is
-- therefore an ordinary security_invoker view with the same columns the
-- spec names, and there is no cron (this codebase has no pg_cron locally
-- either — same "not wired to a schedule" note FR-B16/K13/D12/G05
-- already carry).
--
-- The one deliberate snapshot is warning_count at publish, above.
--
-- ── What counts as a soft constraint ─────────────────────────────────
-- The three the FR names, configurable per campus (timetable_constraint,
-- AC5), plus two that already exist and were previously invisible in any
-- single place:
--   TEACHER_OVERLOADED     more periods in a day than max_periods_per_day
--   TEACHER_CONSECUTIVE    an unbroken run longer than max_consecutive_periods
--   ISOLATED_FREE_PERIOD   exactly one free period between two taught ones
--   SLOT_UNASSIGNED        FR-F09's own existing warning — a scheduled
--                          period with nobody teaching it. It WAS
--                          warning_count's entire definition (that FR's
--                          header says it scoped it narrowly precisely
--                          because nothing defined "warning" yet). Folded
--                          into the taxonomy rather than left as a
--                          parallel rule, so warning_count keeps its old
--                          meaning as a strict subset of its new one.
--   ROOM_OVER_CAPACITY     FR-F06's timetable_room_capacity_warning rows,
--                          reported here as well. That table stays
--                          exactly as it is — it is written at slot-write
--                          time and rendered per-cell in the grid, which
--                          is a genuinely different surface. This FR does
--                          not fork it; it reads it, so "what is wrong
--                          with this version" has one answer.
-- Subject-spread-across-the-week and room-type mismatch are NOT included:
-- neither is in this FR's own ACs, and neither has the data to be
-- computed honestly today (there is no subject-spread policy, and `room`
-- has no room-type column to mismatch against).
--
-- Hard errors are reported in the same pass, as ERROR rows, so the panel
-- is a single call. Within one version every slot shares a campus and a
-- shift, hence one bell template per weekday, so "same period_no" IS
-- "overlapping clock time" — the clock-time views (v_slot_clock_time /
-- app.v_slot_clock_time_unscoped) buy nothing here and are left to the
-- write-time checks that genuinely need them, where the competing slot
-- can live in another version at another campus. That cross-version,
-- cross-campus physical invariant remains upsert_timetable_slot()'s job
-- and is not re-implemented here; this function answers the narrower
-- question "is THIS draft internally consistent".

create table public.timetable_constraint (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  key        text not null,
  int_value  int,
  is_enabled boolean not null default true,
  updated_by uuid references public.app_user(user_id),
  updated_at timestamptz not null default now(),
  constraint chk_timetable_constraint_key check (key in ('max_periods_per_day', 'max_consecutive_periods', 'flag_isolated_free_period')),
  constraint chk_timetable_constraint_value check (int_value is null or int_value > 0)
);

create unique index idx_constraint_campus_key on public.timetable_constraint (campus_id, key);

create trigger timetable_constraint_audit after insert or update or delete on public.timetable_constraint
  for each row execute function app.tg_audit_row();

-- Seeded for every campus that exists, so a Principal can see and tune
-- the three knobs rather than discovering them from a warning.
insert into public.timetable_constraint (tenant_id, campus_id, key, int_value)
select c.tenant_id, c.id, d.key, d.int_value
  from public.campus c
  cross join (values
    ('max_periods_per_day', 7),
    ('max_consecutive_periods', 4),
    ('flag_isolated_free_period', null::int)
  ) as d(key, int_value)
on conflict do nothing;

alter table public.timetable_constraint enable row level security;

create policy timetable_constraint_campus_scope on public.timetable_constraint
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'none')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- A campus created after this migration has no seeded rows, so the
-- resolvers fall back to the same built-in defaults rather than silently
-- evaluating nothing. Internal (`app`, no PostgREST surface, execute
-- revoked from authenticated): they take a campus_id their only caller
-- has already access-checked.
create or replace function app.timetable_constraint_enabled(p_campus_id uuid, p_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select tc.is_enabled from public.timetable_constraint tc where tc.campus_id = p_campus_id and tc.key = p_key),
    true
  );
$$;

revoke execute on function app.timetable_constraint_enabled(uuid, text) from public, anon, authenticated;

create or replace function app.timetable_constraint_int(p_campus_id uuid, p_key text, p_default int)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select tc.int_value from public.timetable_constraint tc where tc.campus_id = p_campus_id and tc.key = p_key),
    p_default
  );
$$;

revoke execute on function app.timetable_constraint_int(uuid, text, int) from public, anon, authenticated;

create or replace function public.set_timetable_constraint(
  p_campus_id uuid,
  p_key text,
  p_int_value int default null,
  p_is_enabled boolean default true
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
  if not exists (select 1 from public.campus c where c.id = p_campus_id and c.tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_key not in ('max_periods_per_day', 'max_consecutive_periods', 'flag_isolated_free_period') then
    raise exception 'CONSTRAINT_KEY_UNKNOWN' using errcode = '23514';
  end if;
  if p_key <> 'flag_isolated_free_period' and coalesce(p_int_value, 0) < 1 then
    raise exception 'CONSTRAINT_VALUE_INVALID' using errcode = '23514';
  end if;

  insert into public.timetable_constraint (tenant_id, campus_id, key, int_value, is_enabled, updated_by, updated_at)
  values (v_tenant_id, p_campus_id, p_key, p_int_value, p_is_enabled, auth.uid(), now())
  on conflict (campus_id, key) do update
    set int_value = excluded.int_value,
        is_enabled = excluded.is_enabled,
        updated_by = excluded.updated_by,
        updated_at = excluded.updated_at
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.set_timetable_constraint(uuid, text, int, boolean) from public, anon;
grant execute on function public.set_timetable_constraint(uuid, text, int, boolean) to authenticated;

-- The spec's mv_teacher_daily_load, as a live view — see the header.
create or replace view public.v_teacher_daily_load with (security_invoker = true) as
select
  ts.timetable_version_id as version_id,
  ts.staff_id,
  ts.weekday,
  count(distinct ts.period_no)::int as period_count
from public.timetable_slot ts
where ts.staff_id is not null
group by ts.timetable_version_id, ts.staff_id, ts.weekday;

revoke all on public.v_teacher_daily_load from public, anon;
grant select on public.v_teacher_daily_load to authenticated;

create or replace function public.validate_timetable_version(p_version_id uuid)
returns table (
  severity   text,
  code       text,
  detail     text,
  staff_id   uuid,
  section_id uuid,
  room_id    uuid,
  weekday    smallint,
  period_no  smallint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_campus_id     uuid;
  -- NULL means "this constraint is switched off for the campus", which
  -- every comparison below then fails, so it contributes no warnings
  -- (AC5) — rather than a second `if` around each branch.
  v_max_per_day   int;
  v_max_consec    int;
  v_flag_isolated boolean;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tv.campus_id into v_campus_id
    from public.timetable_version tv where tv.id = p_version_id and tv.tenant_id = v_tenant_id;
  if v_campus_id is null then
    raise exception 'VERSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if app.timetable_constraint_enabled(v_campus_id, 'max_periods_per_day') then
    v_max_per_day := app.timetable_constraint_int(v_campus_id, 'max_periods_per_day', 7);
  end if;
  if app.timetable_constraint_enabled(v_campus_id, 'max_consecutive_periods') then
    v_max_consec := app.timetable_constraint_int(v_campus_id, 'max_consecutive_periods', 4);
  end if;
  v_flag_isolated := app.timetable_constraint_enabled(v_campus_id, 'flag_isolated_free_period');

  return query
  with slot as (
    select ts.id, ts.section_id, ts.staff_id, ts.room_id, ts.weekday, ts.period_no
      from public.timetable_slot ts
     where ts.timetable_version_id = p_version_id
  ),
  -- distinct: a teacher double-booked in the same period (an ERROR in
  -- its own right, below) must not also inflate her day's load.
  taught as (
    select distinct s.staff_id, s.weekday, s.period_no from slot s where s.staff_id is not null
  ),
  run as (
    select t.staff_id, t.weekday,
           t.period_no - (row_number() over (partition by t.staff_id, t.weekday order by t.period_no))::int as grp
      from taught t
  ),
  run_length as (
    select r.staff_id, r.weekday, count(*)::int as len from run r group by r.staff_id, r.weekday, r.grp
  ),
  -- A gap of exactly one period between two taught periods. A run of two
  -- or more free periods gives nxt - period_no >= 3 and raises nothing.
  gap as (
    select g.staff_id, g.weekday, (g.period_no + 1)::smallint as free_period
      from (
        select t.staff_id, t.weekday, t.period_no,
               lead(t.period_no) over (partition by t.staff_id, t.weekday order by t.period_no) as nxt
          from taught t
      ) g
     where g.nxt - g.period_no = 2
  )

  select 'ERROR'::text, 'TEACHER_CLASH'::text,
         format('%s sections at period %s, %s', count(*), s.period_no, to_char(date '2024-01-07' + s.weekday::int, 'FMDay')),
         s.staff_id, null::uuid, null::uuid, s.weekday, s.period_no
    from slot s
   where s.staff_id is not null
   group by s.staff_id, s.weekday, s.period_no
  having count(*) > 1

  union all

  select 'ERROR'::text, 'ROOM_CLASH'::text,
         format('%s sections at period %s, %s', count(*), s.period_no, to_char(date '2024-01-07' + s.weekday::int, 'FMDay')),
         null::uuid, null::uuid, s.room_id, s.weekday, s.period_no
    from slot s
   where s.room_id is not null
   group by s.room_id, s.weekday, s.period_no
  having count(*) > 1

  union all

  select 'WARNING'::text, 'TEACHER_OVERLOADED'::text,
         format('%s > %s, %s', l.period_count, v_max_per_day, to_char(date '2024-01-07' + l.weekday::int, 'FMDay')),
         l.staff_id, null::uuid, null::uuid, l.weekday, null::smallint
    from public.v_teacher_daily_load l
   where l.version_id = p_version_id and l.period_count > v_max_per_day

  union all

  select 'WARNING'::text, 'TEACHER_CONSECUTIVE'::text,
         format('%s > %s', max(rl.len), v_max_consec),
         rl.staff_id, null::uuid, null::uuid, rl.weekday, null::smallint
    from run_length rl
   group by rl.staff_id, rl.weekday
  having max(rl.len) > v_max_consec

  union all

  select 'WARNING'::text, 'ISOLATED_FREE_PERIOD'::text,
         format('%s period %s', to_char(date '2024-01-07' + g.weekday::int, 'FMDay'), g.free_period),
         g.staff_id, null::uuid, null::uuid, g.weekday, g.free_period
    from gap g
   where v_flag_isolated

  union all

  select 'WARNING'::text, 'SLOT_UNASSIGNED'::text,
         format('%s period %s', to_char(date '2024-01-07' + s.weekday::int, 'FMDay'), s.period_no),
         null::uuid, s.section_id, null::uuid, s.weekday, s.period_no
    from slot s
   where s.staff_id is null

  union all

  select 'WARNING'::text, 'ROOM_OVER_CAPACITY'::text,
         format('%s > %s', w.total_students, w.room_capacity),
         null::uuid, null::uuid, w.room_id, w.weekday, w.period_no
    from public.timetable_room_capacity_warning w
   where w.timetable_version_id = p_version_id

   order by 1, 2, 7, 8;
end;
$$;

revoke execute on function public.validate_timetable_version(uuid) from public, anon;
grant execute on function public.validate_timetable_version(uuid) to authenticated;

-- AC4: publish still succeeds with warnings and stores their count. The
-- only change from FR-F09's version is where that count comes from —
-- previously an inline "slots with no teacher" query, now the validator's
-- own WARNING rows, of which that query is one branch (SLOT_UNASSIGNED).
create or replace function public.publish_timetable(
  p_version_id uuid, p_effective_from date, p_override_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_version    public.timetable_version%rowtype;
  v_summary    text;
  v_warnings   int;
  v_prior_id   uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_version from public.timetable_version where id = p_version_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'VERSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_version.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_version.status <> 'DRAFT' then
    raise exception 'VERSION_NOT_DRAFT' using errcode = '55000';
  end if;

  select string_agg(v.section_name || ' ' || v.subject_code || ' ' || v.scheduled_periods || '/' || v.required_periods, ', ' order by v.section_name, v.subject_code)
    into v_summary
    from public.v_scheduled_vs_required_periods v
   where v.timetable_version_id = p_version_id and v.scheduled_periods < v.required_periods;

  if v_summary is not null then
    if p_override_reason is null or length(btrim(p_override_reason)) < 10 then
      raise exception 'QUOTA_SHORTFALL: %', v_summary using errcode = '23514';
    end if;

    insert into public.timetable_publish_exception (
      tenant_id, timetable_version_id, section_id, subject_id, required_periods, scheduled_periods, reason, created_by
    )
    select v_tenant_id, p_version_id, v.section_id, v.subject_id, v.required_periods, v.scheduled_periods, p_override_reason, auth.uid()
      from public.v_scheduled_vs_required_periods v
     where v.timetable_version_id = p_version_id and v.scheduled_periods < v.required_periods;
  end if;

  -- Soft constraints are counted, never consulted: there is no branch
  -- below in which v_warnings can prevent the publish.
  select count(*)::int into v_warnings
    from public.validate_timetable_version(p_version_id) c
   where c.severity = 'WARNING';

  select id into v_prior_id from public.timetable_version
   where campus_id = v_version.campus_id and session_id = v_version.session_id and status = 'PUBLISHED' and effective_to is null
     and id <> p_version_id and effective_from < p_effective_from;
  if v_prior_id is not null then
    update public.timetable_version set status = 'SUPERSEDED', effective_to = p_effective_from - 1 where id = v_prior_id;
  end if;

  begin
    update public.timetable_version
       set status = 'PUBLISHED', effective_from = p_effective_from, effective_to = null,
           published_by = auth.uid(), published_at = clock_timestamp(), warning_count = v_warnings
     where id = p_version_id;
  exception
    when exclusion_violation then
      raise exception 'VERSION_RANGE_OVERLAP' using errcode = '23P01';
  end;

  return p_version_id;
end;
$$;

revoke execute on function public.publish_timetable(uuid, date, text) from public, anon;
grant execute on function public.publish_timetable(uuid, date, text) to authenticated;
