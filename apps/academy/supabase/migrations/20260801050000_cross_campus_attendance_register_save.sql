-- Fix: save_attendance_register() (FR-G02, and FR-G05's offline-sync
-- path through it) accepted attendance on a declared HOLIDAY, silently,
-- and refused legitimate marking with a misleading
-- POLICY_NOT_CONFIGURED.
--
-- This function deliberately does not authorize by campus. Its own
-- access rule is: an admin role, OR the class teacher of record for
-- this section on this date —
--
--     if app.auth_role() <> 'class_teacher' or not exists (
--       select 1 from public.section_class_teacher
--        where section_id = p_section_id and staff_id = auth.uid()
--          and validity @> p_attendance_date
--     ) then raise FORBIDDEN
--
-- — which is the whole point of FR-G02: the person who takes the
-- register is the person allocated to that section, and campus_ids has
-- nothing to do with it. But it then resolves two facts about the
-- section's campus through resolvers that
-- 20260731770000_security_definer_campus_scope_audit.sql gave a campus
-- guard, so both came back NULL for a caller the function had just
-- authorized:
--
--   resolve_attendance_holiday()  → NULL → `if v_holiday is not null`
--                                   never fires → a full register is
--                                   written on a declared holiday, with
--                                   no error and nothing to show it
--                                   should not exist;
--   resolve_attendance_policy()   → NULL → POLICY_NOT_CONFIGURED, on a
--                                   campus whose policy is configured
--                                   perfectly well — "contact your
--                                   Principal" for a problem the
--                                   Principal cannot see or fix.
--
-- Two populations reach it, and the second is the ordinary one: a class
-- teacher allocated to a section at a campus her claim does not cover,
-- and a teacher with no user_campus row at all, whose claim is '{}'.
-- `not (campus = any('{}'))` is true for EVERY campus, so an invited
-- teacher who has never been attached to a campus row hit both symptoms
-- on her own campus, on every date. FR-F15's export fix
-- (20260801030000) hit the identical shape.
--
-- Fix shape, exactly as 20260801010000 / 20260801020000 /
-- 20260801030000 established: the resolution logic moves to an
-- app.<resolver>_unscoped() that PostgREST does not expose (config.toml
-- exposes public and graphql_public only) and whose EXECUTE is revoked
-- from public, anon AND authenticated, so only a postgres-owned
-- SECURITY DEFINER function that has already run its own access check
-- can reach it; public.resolve_attendance_holiday() keeps the audit's
-- campus guard byte-for-byte for every ordinary caller. The policy
-- resolver was split the same way one migration earlier
-- (20260801040000) and is reused here rather than duplicated.
--
-- The tenant is passed explicitly rather than read from the claim, for
-- the reason 20260801040000 sets out in full: this function has already
-- loaded its class_section row with `tenant_id = app.auth_tenant_id()`,
-- so the tenant is known from data the caller was granted, and the
-- contract the revokes enforce is that every caller passes a tenant it
-- read off such a row — never one the caller supplied.
--
-- Nothing about the disclosure surface widens. The holiday name and the
-- lateness thresholds for the section she is marking are properties of
-- the register she was just authorized to write; the campus_id they are
-- resolved from is the section's own, never anything she passes.
--
-- FR-G05's offline path needs no change of its own: rpc_bulk_mark_
-- attendance() reaches both facts through this function, and its own
-- is_attendance_locked() call was corrected in 20260801040000.

create or replace function app.resolve_attendance_holiday_unscoped(p_tenant_id uuid, p_campus_id uuid, p_date date)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select name from public.holiday_calendar
   where tenant_id = p_tenant_id and (campus_id is null or campus_id = p_campus_id) and holiday_date = p_date
   order by campus_id nulls last
   limit 1;
$$;

revoke execute on function app.resolve_attendance_holiday_unscoped(uuid, uuid, date) from public, anon, authenticated;

-- Unchanged behaviour for every ordinary caller: an out-of-scope campus
-- still resolves to NULL, silently, exactly as the audit left it.
create or replace function public.resolve_attendance_holiday(p_campus_id uuid, p_date date)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then null
    else app.resolve_attendance_holiday_unscoped(app.auth_tenant_id(), p_campus_id, p_date)
  end;
$$;

revoke execute on function public.resolve_attendance_holiday(uuid, date) from public, anon;
grant execute on function public.resolve_attendance_holiday(uuid, date) to authenticated;

-- Byte-for-byte FR-G05's function apart from the two resolutions: the
-- holiday and the policy are now read for the SECTION's campus, in the
-- tenant that section belongs to, which is what this function's own
-- access rule already established the caller's right to.
create or replace function public.save_attendance_register(
  p_section_id uuid,
  p_attendance_date date,
  p_marks jsonb,
  p_marked_at timestamptz default null,
  p_source public.student_attendance_source default 'web',
  p_synced_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_section       public.class_section%rowtype;
  v_campus_tz     text;
  v_holiday       text;
  v_policy        jsonb;
  v_mark          record;
  v_arrival       time;
  v_marked_at     timestamptz := coalesce(p_marked_at, clock_timestamp());
  v_saved         int := 0;
begin
  select * into v_section from public.class_section where id = p_section_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    if app.auth_role() <> 'class_teacher' or not exists (
      select 1 from public.section_class_teacher
       where section_id = p_section_id and staff_id = auth.uid() and validity @> p_attendance_date
    ) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  v_holiday := app.resolve_attendance_holiday_unscoped(v_section.tenant_id, v_section.campus_id, p_attendance_date);
  if v_holiday is not null then
    raise exception using message = 'HOLIDAY:' || v_holiday, errcode = '55000';
  end if;

  v_policy := app.resolve_attendance_policy_unscoped(v_section.tenant_id, v_section.campus_id, v_section.session_id);
  if v_policy is null then
    raise exception 'POLICY_NOT_CONFIGURED' using errcode = '55000';
  end if;

  if public.is_attendance_locked(p_section_id, p_attendance_date) then
    raise exception 'ATT_LOCKED' using errcode = '55000';
  end if;

  select timezone into v_campus_tz from public.campus where id = v_section.campus_id;

  for v_mark in
    select * from jsonb_to_recordset(p_marks)
      as m(enrolment_id uuid, status public.student_attendance_status, arrival_time time, departure_time time)
  loop
    if not exists (
      select 1 from public.enrolment e join public.student s on s.id = e.student_id
       where e.id = v_mark.enrolment_id and e.section_id = p_section_id and e.status = 'active' and s.status = 'active'
    ) then
      continue;
    end if;

    -- FR-G06: an unset arrival_time on a 'late' mark defaults to the
    -- campus wall-clock time the mark was CAPTURED at, not sync time —
    -- v_marked_at is now the honest source for both.
    v_arrival := case
      when v_mark.status = 'late' and v_mark.arrival_time is null then (v_marked_at at time zone v_campus_tz)::time
      else v_mark.arrival_time
    end;

    insert into public.attendance_day (
      tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, marked_by,
      marked_at, source, synced_at, arrival_time, departure_time
    ) values (
      v_tenant_id, v_section.campus_id, v_section.session_id, p_section_id, v_mark.enrolment_id, p_attendance_date, v_mark.status, auth.uid(),
      v_marked_at, p_source, p_synced_at, v_arrival, v_mark.departure_time
    )
    on conflict (enrolment_id, attendance_date) do update
      set status = excluded.status, marked_by = excluded.marked_by, marked_at = excluded.marked_at,
          source = excluded.source, synced_at = excluded.synced_at,
          arrival_time = excluded.arrival_time, departure_time = excluded.departure_time;

    v_saved := v_saved + 1;
  end loop;

  return jsonb_build_object('saved', v_saved);
end;
$$;

revoke execute on function public.save_attendance_register(uuid, date, jsonb, timestamptz, public.student_attendance_source, timestamptz) from public, anon;
grant execute on function public.save_attendance_register(uuid, date, jsonb, timestamptz, public.student_attendance_source, timestamptz) to authenticated;
