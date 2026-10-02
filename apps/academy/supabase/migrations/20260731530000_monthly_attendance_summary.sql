-- FR-G14: monthly attendance summary computation.
--
--   * FR-G11 already created attendance_monthly_summary as a reference
--     stub, in a shape that didn't yet match this FR's own "Supabase
--     Objects" spec (which names the table attendance_month_summary —
--     no "ly" — with working_days/leave_days/attendance_pct/computed_at/
--     recomputed_at columns; two other not-yet-built FRs, the report
--     card attendance feed and the concession-eligibility feed, already
--     reference that exact name). This migration renames the table and
--     reshapes its columns to match, then redefines
--     approve_attendance_correction() (its only other writer) to match
--     — a table rename doesn't retarget a PL/pgSQL function's own
--     hardcoded SQL text, so the function has to be redefined too, and
--     the pre-existing FR-G11 pgTAP test that seeds this table by hand
--     is updated to match in the same commit.
--   * working_days deliberately reuses working_days_between() (FR-D11's
--     leave-debiting helper: Sunday off, plus any holiday_calendar row)
--     verbatim rather than building the "Supabase Objects" note's
--     academic_calendar_day table — that table would be a second,
--     parallel source of truth for the same concept holiday_calendar
--     already owns tenant-wide, with no AC that actually needs anything
--     holiday_calendar + a fixed weekly-off day can't already express.
--   * The denominator is clipped per-enrolment (AC2's own trap): a
--     student who joined on the 15th gets working_days_between() over
--     [greatest(month_start, joined_on), least(month_end,
--     coalesce(left_on, month_end))], not the full month. An enrolment
--     whose window doesn't overlap the month at all gets no summary row.
--   * present_days is the weighted numerator, not a raw headcount:
--     present and late both weigh 1, half_day weighs 0.5, absent and
--     excused (leave) weigh 0 — an excused/leave day is still a day the
--     student wasn't in class, just not a disciplinary absence, which is
--     why it's tracked separately in leave_days rather than folded into
--     absent_days. attendance_pct = present_days / working_days * 100,
--     rounded to 2dp, and NULL (not 0) when working_days = 0 (AC3) —
--     the FR's own note: a false 0% would cascade into a wrong shortage
--     warning or a wrongly denied concession.
--   * AC4's "recompute" is compute_month_attendance() called again for
--     the same campus/year/month — idempotent via ON CONFLICT DO
--     UPDATE, which advances recomputed_at and clears stale but leaves
--     computed_at (the original run's timestamp) untouched, exactly
--     matching the AC's own wording that recomputed_at is what advances.
--   * No pg_cron locally, same as every other "System"-actor function
--     this session has built (FR-B16, FR-K13, FR-D12, FR-B05, FR-G09):
--     a real, tested, service_role-grantable function a cron would call
--     daily for the current+previous month, not actually scheduled.
--     Note the inherited limitation this carries from working_days_
--     between(): that helper resolves holidays via app.auth_tenant_id(),
--     which is NULL with no JWT — a future service-role/cron caller
--     would see zero holiday exclusions. Every existing caller of that
--     helper (leave application, all three of them) always has a JWT,
--     so this has never bitten anything yet; flagged as a follow-up
--     rather than touched here since working_days_between() is shared,
--     already-tested infrastructure well outside this FR's scope.

alter table public.attendance_monthly_summary rename to attendance_month_summary;
alter table public.attendance_month_summary rename column late_days to late_count;
alter table public.attendance_month_summary rename column half_days to half_day_count;
alter table public.attendance_month_summary drop column finalized_at;
alter table public.attendance_month_summary
  add column working_days   int not null default 0,
  add column leave_days     int not null default 0,
  add column attendance_pct numeric(5, 2),
  add column computed_at    timestamptz,
  add column recomputed_at  timestamptz;
alter table public.attendance_month_summary alter column present_days type numeric(5, 2);

create or replace function public.compute_month_attendance(p_campus_id uuid, p_year int, p_month int)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_month_start date := make_date(p_year, p_month, 1);
  v_month_end   date := (v_month_start + interval '1 month' - interval '1 day')::date;
  v_row         record;
  v_from        date;
  v_to          date;
  v_working     int;
  v_present     numeric(5, 2);
  v_absent      int;
  v_late        int;
  v_half        int;
  v_leave       int;
  v_count       int := 0;
begin
  if app.auth_tenant_id() is not null then
    if app.auth_role() not in ('super_admin', 'owner', 'principal') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
      raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;

  for v_row in
    select e.id as enrolment_id, e.tenant_id, e.campus_id, e.session_id, e.joined_on, e.left_on
      from public.enrolment e
     where e.campus_id = p_campus_id
       and e.joined_on <= v_month_end
       and (e.left_on is null or e.left_on >= v_month_start)
  loop
    v_from := greatest(v_month_start, v_row.joined_on);
    v_to   := least(v_month_end, coalesce(v_row.left_on, v_month_end));

    if v_from > v_to then
      v_working := 0;
    else
      v_working := public.working_days_between(p_campus_id, v_from, v_to)::int;
    end if;

    select
      coalesce(sum(case status when 'present' then 1 when 'late' then 1 when 'half_day' then 0.5 else 0 end), 0),
      count(*) filter (where status = 'absent'),
      count(*) filter (where status = 'late'),
      count(*) filter (where status = 'half_day'),
      count(*) filter (where status = 'excused')
      into v_present, v_absent, v_late, v_half, v_leave
      from public.attendance_day
     where enrolment_id = v_row.enrolment_id
       and attendance_date between v_from and v_to;

    insert into public.attendance_month_summary (
      tenant_id, campus_id, session_id, enrolment_id, year, month,
      working_days, present_days, absent_days, late_count, half_day_count, leave_days,
      attendance_pct, computed_at
    ) values (
      v_row.tenant_id, v_row.campus_id, v_row.session_id, v_row.enrolment_id, p_year, p_month,
      v_working, v_present, v_absent, v_late, v_half, v_leave,
      case when v_working = 0 then null else round(v_present / v_working * 100, 2) end,
      clock_timestamp()
    )
    on conflict (enrolment_id, year, month) do update
       set working_days   = excluded.working_days,
           present_days   = excluded.present_days,
           absent_days    = excluded.absent_days,
           late_count     = excluded.late_count,
           half_day_count = excluded.half_day_count,
           leave_days     = excluded.leave_days,
           attendance_pct = excluded.attendance_pct,
           recomputed_at  = clock_timestamp(),
           stale          = false;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.compute_month_attendance(uuid, int, int) from public, anon;
grant execute on function public.compute_month_attendance(uuid, int, int) to authenticated, service_role;

-- Redefined only because the table it references was just renamed and
-- reshaped above (see header) — every other line is identical to the
-- FR-G11 migration's own version.
create or replace function public.approve_attendance_correction(p_correction_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_req       public.attendance_correction_request%rowtype;
  v_old       public.student_attendance_status;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_req from public.attendance_correction_request where id = p_correction_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'CORRECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'CORRECTION_NOT_PENDING' using errcode = '55000';
  end if;

  select status into v_old from public.attendance_day where enrolment_id = v_req.enrolment_id and attendance_date = v_req.attendance_date;
  if not found then
    raise exception 'ATTENDANCE_DAY_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.attendance_day
     set status = v_req.new_status, corrected = true
   where enrolment_id = v_req.enrolment_id and attendance_date = v_req.attendance_date;

  insert into public.attendance_audit (
    tenant_id, campus_id, session_id, enrolment_id, attendance_date, old_status, new_status, reason,
    requested_by, approved_by, source_correction_id
  ) values (
    v_tenant_id, v_req.campus_id, v_req.session_id, v_req.enrolment_id, v_req.attendance_date, v_old, v_req.new_status, v_req.reason,
    v_req.requested_by, auth.uid(), v_req.id
  );

  update public.attendance_correction_request
     set status = 'approved', decided_by = auth.uid(), decided_at = clock_timestamp(), decision_note = p_note
   where id = p_correction_id;

  -- AC4: flags the enclosing month's summary stale so a recompute picks
  -- this correction up. A no-op if that month hasn't been computed yet.
  update public.attendance_month_summary
     set stale = true
   where enrolment_id = v_req.enrolment_id
     and year = extract(year from v_req.attendance_date)::smallint
     and month = extract(month from v_req.attendance_date)::smallint;
end;
$$;
