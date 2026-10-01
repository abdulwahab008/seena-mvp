-- FR-D20: teacher workload variance report.
--
-- mv_teacher_weekly_load holds, per teacher and ISO week (from eight weeks back to
-- four weeks ahead of the refresh), how many periods the PUBLISHED timetable gives
-- them, how many of those they actually delivered, how many substitution periods
-- they covered for colleagues, and the periods per week their contract says.
--
--   timetabled_periods   the teacher's own published slots in the week (holidays
--                        included: the timetable is what it is)
--   delivered_periods    timetabled minus the periods on a holiday, on a day of
--                        approved leave, or covered by someone else (an active
--                        substitution). Never includes substitution work.
--   substituted_periods  periods the teacher covered FOR OTHERS (active
--                        timetable_substitution rows where they are the substitute) -
--                        reported separately, never merged into the base load, which is
--                        what lets a visiting lecturer be paid per period actually taught
--   variance             timetabled - contracted (null when no contract figure is on file)
--
-- A materialized view cannot enforce RLS, so it is not granted to any API role at
-- all. get_teacher_workload() is the only reader: it asserts the caller's role and
-- that the campus is one of the campuses in their JWT (owner / super admin: any
-- campus of their school), then returns the campus's teachers for the week. It
-- reads the view as filtered rows only, so a campus can never be seen by another.
--
-- The view is rebuilt daily at 02:30 PKT (pg_cron, guarded) and on demand
-- (refresh_teacher_load). The refresh is CONCURRENTLY, so reads continue during it,
-- which is why the view carries the unique index uq_mv_teacher_week. A refresh
-- rebuilds the whole view (one query over published timetables), not one campus.

create materialized view public.mv_teacher_weekly_load as
with weeks as (
  select (g)::date as week_start
    from generate_series(date_trunc('week', app.fn_karachi_today())::date - 56, date_trunc('week', app.fn_karachi_today())::date + 28, interval '7 days') g
), days as (
  select w.week_start, (w.week_start + n)::date as d
    from weeks w cross join generate_series(0, 6) n
), slot_days as (
  select s.id as staff_id, s.tenant_id, s.campus_id, s.user_id, dd.week_start, dd.d, ts.id as slot_id
    from public.staff s
    join public.timetable_slot ts on ts.staff_id = s.user_id and ts.tenant_id = s.tenant_id
    join public.timetable_version tv on tv.id = ts.timetable_version_id and tv.status = 'PUBLISHED'
    join days dd on tv.validity @> dd.d and extract(dow from dd.d)::smallint = ts.weekday
   where s.user_id is not null
), flagged as (
  select sd.*,
         exists (select 1 from public.leave_application la
                  where la.staff_id = sd.staff_id and la.status = 'approved' and sd.d between la.from_date and la.to_date) as on_leave,
         exists (select 1 from public.holiday_calendar h
                  where h.tenant_id = sd.tenant_id and h.holiday_date = sd.d and (h.campus_id is null or h.campus_id = sd.campus_id)) as on_holiday,
         exists (select 1 from public.timetable_substitution sub
                  where sub.slot_id = sd.slot_id and sub.sub_date = sd.d and sub.status = 'active' and sub.substitute_staff_id <> sd.user_id) as covered_by_other
    from slot_days sd
), own as (
  select staff_id, tenant_id, campus_id, user_id, week_start,
         count(*)::int as timetabled_periods,
         count(*) filter (where not on_leave and not on_holiday and not covered_by_other)::int as delivered_periods
    from flagged
   group by staff_id, tenant_id, campus_id, user_id, week_start
), cover as (
  select s.id as staff_id, s.tenant_id, s.campus_id, s.user_id, date_trunc('week', sub.sub_date)::date as week_start, count(*)::int as substituted_periods
    from public.timetable_substitution sub
    join public.staff s on s.user_id = sub.substitute_staff_id and s.tenant_id = sub.tenant_id
   where sub.status = 'active'
     and sub.sub_date >= date_trunc('week', app.fn_karachi_today())::date - 56 and sub.sub_date < date_trunc('week', app.fn_karachi_today())::date + 35
   group by s.id, s.tenant_id, s.campus_id, s.user_id, date_trunc('week', sub.sub_date)::date
), keys as (
  select staff_id, tenant_id, campus_id, user_id, week_start from own
  union
  select staff_id, tenant_id, campus_id, user_id, week_start from cover
)
select k.tenant_id, k.campus_id, k.staff_id, k.user_id,
       to_char(k.week_start, 'IYYY-"W"IW') as iso_week, k.week_start,
       coalesce(o.timetabled_periods, 0) as timetabled_periods,
       coalesce(c.substituted_periods, 0) as substituted_periods,
       coalesce(o.delivered_periods, 0) as delivered_periods,
       coalesce(o.timetabled_periods, 0) - coalesce(o.delivered_periods, 0) as not_delivered_periods,
       ct.contracted_periods_per_week::int as contracted_periods,
       case when ct.contracted_periods_per_week is null then null else coalesce(o.timetabled_periods, 0) - ct.contracted_periods_per_week::int end as variance
  from keys k
  left join own o on o.staff_id = k.staff_id and o.week_start = k.week_start
  left join cover c on c.staff_id = k.staff_id and c.week_start = k.week_start
  left join lateral (
    select sc.contracted_periods_per_week
      from public.staff_contract sc
     where sc.staff_id = k.staff_id and sc.start_date <= k.week_start + 6 and (sc.end_date is null or sc.end_date >= k.week_start)
     order by sc.start_date desc
     limit 1
  ) ct on true
with data;

create unique index uq_mv_teacher_week on public.mv_teacher_weekly_load (staff_id, iso_week);
create index idx_mv_teacher_campus_week on public.mv_teacher_weekly_load (campus_id, iso_week);
revoke all on public.mv_teacher_weekly_load from public, anon, authenticated;

create or replace function app.fn_refresh_teacher_load()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  refresh materialized view concurrently public.mv_teacher_weekly_load;
end;
$$;
revoke execute on function app.fn_refresh_teacher_load() from public, anon, authenticated;

-- Reading the report needs a campus the caller belongs to; refreshing needs the same.
create or replace function app.fn_workload_campus_ok(p_campus_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'hr_manager', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function app.fn_workload_campus_ok(uuid) from public, anon, authenticated;

create or replace function public.refresh_teacher_load(p_campus uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.fn_workload_campus_ok(p_campus);
  perform app.fn_refresh_teacher_load();
end;
$$;
revoke execute on function public.refresh_teacher_load(uuid) from public, anon;
grant execute on function public.refresh_teacher_load(uuid) to authenticated;

create or replace function public.get_teacher_workload(p_campus uuid, p_iso_week text)
returns table (
  staff_id uuid, staff_name text, employee_code text, iso_week text, week_start date,
  timetabled_periods integer, substituted_periods integer, delivered_periods integer, not_delivered_periods integer,
  contracted_periods integer, variance integer, is_overloaded boolean, all_not_delivered boolean, as_of timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.fn_workload_campus_ok(p_campus);
  if p_iso_week !~ '^[0-9]{4}-W[0-9]{2}$' then
    raise exception 'ISO_WEEK_INVALID' using errcode = '22023';
  end if;
  return query
    select m.staff_id, s.full_name, s.employee_code, m.iso_week, m.week_start,
           m.timetabled_periods, m.substituted_periods, m.delivered_periods, m.not_delivered_periods,
           m.contracted_periods, m.variance, coalesce(m.variance, 0) > 0,
           m.timetabled_periods > 0 and m.delivered_periods = 0, now()
      from public.mv_teacher_weekly_load m
      join public.staff s on s.id = m.staff_id
     where m.campus_id = p_campus and m.tenant_id = app.auth_tenant_id() and m.iso_week = p_iso_week
     order by s.full_name, s.employee_code;
end;
$$;
revoke execute on function public.get_teacher_workload(uuid, text) from public, anon;
grant execute on function public.get_teacher_workload(uuid, text) to authenticated;

-- 02:30 PKT = 21:30 UTC the day before.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('refresh-teacher-load', '30 21 * * *', 'select app.fn_refresh_teacher_load();');
  end if;
exception
  when others then null;
end;
$$;
