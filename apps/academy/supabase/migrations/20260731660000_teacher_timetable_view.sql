-- FR-F12: per-teacher timetable view.
--
-- Design notes:
--   * teacher_timetable(p_staff_id, p_week_start) IS built as the FR's own
--     literally-named SECURITY DEFINER function — unlike F11's guardian-
--     facing read (where a plain security_invoker view sufficed), this
--     one genuinely needs procedural work a view cannot do: resolving
--     REAL clock times per occurrence date via resolve_bell_template()
--     (FR-F02, already Ramadan-aware) means a distinct call per (campus,
--     shift, date) — that's exactly what a set-returning function is for,
--     not a plain join.
--   * No separate timetable_slot_self_read RLS policy. The function is
--     SECURITY DEFINER and is the only intended read path for a
--     teacher's OWN cross-campus schedule (the whole point of this FR:
--     Ms. Ayesha's own campus_ids claim may not even cover every campus
--     she teaches at, so a plain RLS policy checked via a raw table read
--     wouldn't help her see the foreign-campus periods anyway) — adding
--     one would just be a second, less-controlled path to the same rows,
--     the same "function is the only necessary gate" reasoning already
--     applied to every write this session.
--   * The AC's own "RLS returns zero rows" for a Teacher requesting
--     another teacher's schedule is implemented as a raised FORBIDDEN
--     instead — matching every other access-controlled function in this
--     codebase (none of them silently return empty; they explain why).
--   * "Every unoccupied period marked Free" is left to the client: the
--     function returns only OCCUPIED periods (real ones and substitution
--     coverage) plus their real times; the UI pads the grid with the
--     union of period numbers actually returned, exactly how the existing
--     staff timetable-grid.tsx already pads its own 8-period default grid
--     — inventing a second, DB-side padding scheme for a purely
--     presentational concern would be speculative.
--   * The 60KB-payload / ETag / 24h-cache / offline-first Edge Function
--     is not built — same "data layer only" scope cut as FR-K11's own
--     three-copy challan PDF and FR-F15's not-yet-built print/export.
--     teacher_timetable() is the data layer that Edge Function would
--     eventually wrap.

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
    left join lateral (
      select bp_inner.start_time, bp_inner.end_time
        from public.bell_period bp_inner
       where bp_inner.bell_template_id = public.resolve_bell_template(ts.campus_id, tv.shift, (v_monday + (ts.weekday - 1))::date)
         and bp_inner.period_no = ts.period_no
    ) bp on true
    where ts.staff_id = p_staff_id and ts.tenant_id = v_tenant_id and ts.weekday between 1 and 6

    union all

    -- AC: today's (or any day this week's) substitution coverage renders
    -- alongside her regular grid, distinctly flagged, naming who she's
    -- covering for and what.
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
       where bp2_inner.bell_template_id = public.resolve_bell_template(slot2.campus_id, tv2.shift, sub.sub_date)
         and bp2_inner.period_no = slot2.period_no
    ) bp2 on true
    where sub.substitute_staff_id = p_staff_id and sub.tenant_id = v_tenant_id
      and sub.status = 'active' and sub.sub_date between v_monday and v_monday + 5;
end;
$$;

revoke execute on function public.teacher_timetable(uuid, date) from public, anon;
grant execute on function public.teacher_timetable(uuid, date) to authenticated;
