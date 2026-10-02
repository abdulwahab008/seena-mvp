-- Fix: teacher_timetable() silently rendered blank clock times for a
-- period at a campus outside the caller's own campus_ids claim.
--
-- 20260731770000_security_definer_campus_scope_audit.sql hardened
-- resolve_bell_template() to return NULL for a campus the caller is not
-- scoped to. That guard is correct and closed a real cross-tenant-ish
-- leak for DIRECT callers, and it stays exactly as it is. But that audit
-- classified 56 functions by their own p_campus_id argument and never
-- looked at who CALLS the resolvers — and teacher_timetable() (FR-F12)
-- is deliberately cross-campus: its own header says Ms Ayesha's
-- campus_ids claim may not cover every campus she teaches at, which is
-- the entire reason that FR exists. So its bell lookup for a foreign-
-- campus period started returning NULL, the lateral join produced a NULL
-- start_time/end_time, and /my-timetable rendered that period with empty
-- times — no error, no warning, wrong data on screen.
--
-- Fix shape: split the resolver in two, which is what it always was
-- semantically —
--
--   app.resolve_bell_template_unscoped()  the actual resolution logic
--                                         (unchanged from FR-F02/F03,
--                                         still tenant-scoped)
--   public.resolve_bell_template()        that logic behind the campus
--                                         guard, for everyone else
--
-- and let ONLY a SECURITY DEFINER caller that has already established
-- the caller's right to the rows it is timing reach the internal one.
-- Rejected alternatives: re-implementing the bell precedence rules
-- inline in teacher_timetable() (FR-F03's own note is explicit that
-- resolve_bell_template is the single source of truth for "which
-- template applies on this date" — a second copy would drift on the next
-- calendar rule), and widening public.resolve_bell_template's guard to
-- "any campus where you have a timetable_slot" (that puts a
-- teacher-shaped exception inside a function every role calls, and
-- re-opens exactly the surface the audit closed).
--
-- Why the internal variant does not become a general-purpose bypass:
--   * it lives in `app`, which PostgREST does not expose (config.toml
--     schemas = public, graphql_public), so it has no HTTP surface at
--     all;
--   * EXECUTE is revoked from public, anon AND authenticated — the same
--     treatment app.fn_allocate_gr_number / app.fn_next_receipt_no /
--     app.fn_plan_line_period_charges already get. A SECURITY INVOKER
--     view or function that tried to route around the guard gets
--     "permission denied for function"; only a SECURITY DEFINER function
--     owned by postgres can call it, and those are exactly the functions
--     that ran their own access check first;
--   * it is a CAMPUS-scope escape hatch, never a tenant one: the
--     tenant_id = app.auth_tenant_id() predicate is still in the body, so
--     it cannot reach another tenant's bell templates even from a
--     definer context.
--
-- teacher_timetable() has already established the caller's right to
-- these rows before it resolves a single time: it raises FORBIDDEN
-- unless the caller IS the teacher, or holds principal / hr_manager /
-- super_admin / owner. Nothing about the times leaks more than the row
-- they hang off — campus_code, section, subject and room for that same
-- foreign-campus period were already being returned.
--
-- Not changed here, reported instead (same latent shape, different
-- blast radius, and neither is this defect):
--   * public.v_slot_clock_time joins resolve_bell_template_for_weekday()
--     on the SLOT's campus, and upsert_timetable_slot()'s TEACHER_CLASH
--     check queries that view tenant-wide by staff_id — deliberately, so
--     a teacher shared across campuses cannot be double-booked. For a
--     principal scoped to one campus, the competing slot at the other
--     campus now drops out of the view and the clash goes undetected.
--   * public.timetable_export_payload() resolves the print sheet's
--     period times through resolve_bell_template(v_job.campus_id, ...),
--     and request_timetable_export()'s teacher branch does not campus-
--     check the version — so a teacher exporting a foreign-campus sheet
--     gets 'periods': [] and a timetable with no clock times.

-- The resolution logic itself, byte-for-byte what FR-F02 shipped and
-- FR-F03 extended: precedence wins first, and at equal precedence a
-- date-range rule is more specific than a weekday rule.
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

revoke execute on function app.resolve_bell_template_unscoped(uuid, public.section_shift, date) from public, anon, authenticated;

-- Unchanged behaviour for every ordinary caller: an out-of-scope campus
-- still resolves to NULL, silently, exactly as the audit migration left
-- it (the silent-empty-result convention the other `language sql`
-- resolvers use, not a raised FORBIDDEN).
create or replace function public.resolve_bell_template(p_campus_id uuid, p_shift public.section_shift, p_date date)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then null
    else app.resolve_bell_template_unscoped(p_campus_id, p_shift, p_date)
  end;
$$;

create or replace function public.teacher_timetable(p_staff_id uuid, p_week_start date)
returns table (
  weekday          smallint,
  occurs_on        date,
  period_no        smallint,
  start_time       time,
  end_time         time,
  campus_code      text,
  section_id       uuid,
  section_name     text,
  class_level_name text,
  subject_code     text,
  subject_name_en  text,
  room_code        text,
  is_substitution  boolean,
  absent_teacher_name text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_monday    date := date_trunc('week', p_week_start)::date;
begin
  if p_staff_id <> (select auth.uid()) and app.auth_role() not in ('principal', 'hr_manager', 'super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  return query
    select
      ts.weekday,
      (v_monday + (ts.weekday - 1))::date as occurs_on,
      ts.period_no,
      bp.start_time,
      bp.end_time,
      c.code as campus_code,
      ts.section_id,
      cs.name as section_name,
      cl.name_en as class_level_name,
      subj.code as subject_code,
      subj.name_en as subject_name_en,
      r.code as room_code,
      false as is_substitution,
      null::text as absent_teacher_name
    from public.timetable_slot ts
    join public.timetable_version tv on tv.id = ts.timetable_version_id and tv.status = 'PUBLISHED'
    join public.class_section cs on cs.id = ts.section_id
    join public.class_level cl on cl.id = cs.class_level_id
    join public.campus c on c.id = ts.campus_id
    join public.subject subj on subj.id = ts.subject_id
    left join public.room r on r.id = ts.room_id
    -- Unscoped deliberately: the role/self check above already granted
    -- this caller these rows, and this FR's whole point is the campuses
    -- her own claim does not cover.
    left join lateral (
      select bp_inner.start_time, bp_inner.end_time
        from public.bell_period bp_inner
       where bp_inner.bell_template_id = app.resolve_bell_template_unscoped(ts.campus_id, tv.shift, (v_monday + (ts.weekday - 1))::date)
         and bp_inner.period_no = ts.period_no
    ) bp on true
    where ts.staff_id = p_staff_id and ts.tenant_id = v_tenant_id and ts.weekday between 1 and 6

    union all

    -- AC: today's (or any day this week's) substitution coverage renders
    -- alongside her regular grid, distinctly flagged, naming who she's
    -- covering for.
    select
      extract(dow from sub.sub_date)::smallint,
      sub.sub_date,
      slot2.period_no,
      bp2.start_time,
      bp2.end_time,
      c2.code,
      slot2.section_id,
      cs2.name,
      cl2.name_en,
      subj2.code,
      subj2.name_en,
      r2.code,
      true,
      absent_au.full_name
    from public.timetable_substitution sub
    join public.timetable_slot slot2 on slot2.id = sub.slot_id
    join public.timetable_version tv2 on tv2.id = slot2.timetable_version_id
    join public.class_section cs2 on cs2.id = slot2.section_id
    join public.class_level cl2 on cl2.id = cs2.class_level_id
    join public.campus c2 on c2.id = slot2.campus_id
    join public.subject subj2 on subj2.id = slot2.subject_id
    left join public.room r2 on r2.id = slot2.room_id
    left join public.app_user absent_au on absent_au.user_id = sub.absent_staff_id
    left join lateral (
      select bp2_inner.start_time, bp2_inner.end_time
        from public.bell_period bp2_inner
       where bp2_inner.bell_template_id = app.resolve_bell_template_unscoped(slot2.campus_id, tv2.shift, sub.sub_date)
         and bp2_inner.period_no = slot2.period_no
    ) bp2 on true
    where sub.substitute_staff_id = p_staff_id and sub.tenant_id = v_tenant_id
      and sub.status = 'active' and sub.sub_date between v_monday and v_monday + 5;
end;
$$;
