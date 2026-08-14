-- Fix: suggest_substitutes() (FR-D13) reported every teacher in the
-- tenant as FREE for a slot at a campus the caller is not scoped to.
--
-- It has a role check — super_admin / owner / principal — but, unlike
-- its sibling create_substitution(), no campus check on p_slot_id at
-- all. create_substitution() has had one since it shipped:
--
--     if app.auth_role() not in ('super_admin','owner')
--        and not (v_slot.campus_id = any(app.auth_campus_ids()))
--     then raise FORBIDDEN
--
-- so a Principal naming a slot at another campus is refused by the
-- write, but the read that FEEDS that write answered in full — and
-- answered wrongly. The slot's own clock range comes from
--
--     public.resolve_bell_template_for_weekday(v_slot.campus_id, ...)
--
-- which 20260731770000_security_definer_campus_scope_audit.sql taught to
-- return NULL for an out-of-scope campus, so v_self_start came back
-- NULL, and is_free's own first branch is `v_self_start is null or ...`
-- — every candidate in the tenant was reported free, with no error. The
-- screen's ranking (is_free desc) then put the busiest teachers at the
-- top of the list.
--
-- 20260801020000 already repaired the IN-scope half of this function:
-- the busy-checks read app.v_slot_clock_time_unscoped, so a candidate
-- busy at another campus is no longer reported free. What was left is
-- the guard on the slot argument itself, which is what this file adds —
-- verbatim from create_substitution(), so the suggestion list can never
-- be more permissive than the write it feeds.
--
-- This is a NEW refusal path, so both halves are worth stating plainly:
--
--   * it refuses LOUDLY — 42501 FORBIDDEN, the same code and message
--     create_substitution() already raises for the same slot, which the
--     substitutions server action already surfaces. Never a silently
--     empty or silently wrong candidate list.
--   * the legitimate same-campus case is untouched: a Principal whose
--     claim covers the slot's campus, and any Owner or Super Admin,
--     reach exactly the same query they always did.
--
-- The empty-claim caveat that decided FR-F15's export fix the other way
-- (20260801030000: a teacher with no user_campus row claims '{}', and
-- `not (campus = any('{}'))` is true for EVERY campus, so refusing on
-- the claim alone would refuse that FR's central use case) does not
-- change the answer here. This function is closed to teaching roles
-- entirely — only super_admin, owner and principal reach it — and
-- create_substitution() ALREADY refuses a '{}'-claim Principal for the
-- identical slot. Adding a second, softer rule here would leave the
-- screen offering candidates the write then rejects, which is the exact
-- disagreement between read and write this function's own header says
-- it exists to prevent. A Principal with no user_campus row cannot
-- arrange substitutions today; that is one decision about one claim, and
-- it belongs in user_campus, not in a second copy of the rule.

create or replace function public.suggest_substitutes(p_slot_id uuid, p_sub_date date)
returns table (
  staff_id uuid, full_name text, is_free boolean, can_teach_subject boolean, periods_covered_today int
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid := app.auth_tenant_id();
  v_slot           public.timetable_slot%rowtype;
  v_shift          public.section_shift;
  v_class_level_id uuid;
  v_stream_id      uuid;
  v_self_start     time;
  v_self_end       time;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_slot from public.timetable_slot where id = p_slot_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  -- Verbatim from create_substitution(): this read must not answer for a
  -- slot the write would refuse.
  if app.auth_role() not in ('super_admin', 'owner') and not (v_slot.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if extract(dow from p_sub_date)::smallint <> v_slot.weekday then
    raise exception 'SUB_DATE_WEEKDAY_MISMATCH' using errcode = '23514';
  end if;

  select tv.shift into v_shift from public.timetable_version tv where tv.id = v_slot.timetable_version_id;
  select cs.class_level_id, cs.stream_id into v_class_level_id, v_stream_id
    from public.class_section cs where cs.id = v_slot.section_id;

  -- This slot's own campus passed the scope check above.
  select bp.start_time, bp.end_time into v_self_start, v_self_end
    from public.bell_period bp
   where bp.bell_template_id = public.resolve_bell_template_for_weekday(v_slot.campus_id, v_shift, v_slot.weekday)
     and bp.period_no = v_slot.period_no;

  return query
    select
      au.user_id,
      au.full_name,
      (
        v_self_start is null
        or (
          not exists (
            select 1 from app.v_slot_clock_time_unscoped vct
             where vct.tenant_id = v_tenant_id and vct.staff_id = au.user_id and vct.weekday = v_slot.weekday
               and vct.slot_id <> v_slot.id
               and public.timerange(vct.start_time, vct.end_time) && public.timerange(v_self_start, v_self_end)
          )
          and not exists (
            select 1
              from public.timetable_substitution other_sub
              join app.v_slot_clock_time_unscoped other_vct on other_vct.slot_id = other_sub.slot_id
             where other_sub.substitute_staff_id = au.user_id
               and other_sub.sub_date = p_sub_date
               and other_sub.status = 'active'
               and other_sub.slot_id <> p_slot_id
               and public.timerange(other_vct.start_time, other_vct.end_time) && public.timerange(v_self_start, v_self_end)
          )
        )
      ) as is_free,
      public.can_teach(au.user_id, v_slot.subject_id, v_class_level_id, v_stream_id) as can_teach_subject,
      (
        select count(*)::int from public.timetable_substitution ts2
         where ts2.substitute_staff_id = au.user_id and ts2.sub_date = p_sub_date and ts2.status = 'active'
      ) as periods_covered_today
    from public.app_user au
   where au.tenant_id = v_tenant_id
     and au.app_role in ('subject_teacher', 'class_teacher', 'head_of_department')
     and (v_slot.staff_id is null or au.user_id <> v_slot.staff_id)
    order by 3 desc, 4 desc, 5 asc, au.full_name asc;
end;
$$;

revoke execute on function public.suggest_substitutes(uuid, date) from public, anon;
grant execute on function public.suggest_substitutes(uuid, date) to authenticated;
