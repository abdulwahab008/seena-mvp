-- FR-G04: mark-all-present then exceptions flow.
--
--   * rpc_bulk_mark_attendance() is a thin wrapper around FR-G02's
--     save_attendance_register() — it computes one full marks array
--     (every active enrolment defaulted to 'present', p_exceptions
--     overriding by enrolment_id) and delegates to that function
--     verbatim, so the role check, holiday block, lock-window check and
--     the struck-off/active-both-tables filter are exercised exactly
--     once, in one place, not re-implemented here. "0 exceptions, 40
--     rows written" (AC1) falls out of this for free: the computed
--     array already has all 40 present entries before
--     save_attendance_register() ever runs.
--   * The AC's tap-cycle sequence is "present -> absent -> late -> leave
--     -> present," but this schema's enum (FR-G02) is ('present',
--     'absent', 'late', 'half_day', 'excused') — no 'leave' value.
--     'excused' is the same concept (an authorized absence) under a
--     different name; the UI's cycle uses it in the AC's fourth slot
--     rather than minting a redundant enum value for a naming
--     difference alone.
--   * The AC's own "exactly 2 tap events are recorded in the UI
--     instrumentation" is a client-side analytics assertion — this
--     codebase has no analytics/telemetry pipeline anywhere (confirmed
--     by grep), so that specific instrumentation is out of scope, same
--     posture as every other "infra that doesn't exist yet" scope cut
--     this session. What IS built and tested: the real functional
--     behavior the instrumentation would have been measuring — a
--     teacher who touches nothing and submits still writes all 40
--     rows, at the cost of exactly one round trip.

create or replace function public.rpc_bulk_mark_attendance(p_section_id uuid, p_date date, p_exceptions jsonb default '[]'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_marks jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('enrolment_id', e.id, 'status', coalesce(x.status, 'present'))), '[]'::jsonb)
    into v_marks
    from public.enrolment e
    join public.student s on s.id = e.student_id
    left join jsonb_to_recordset(p_exceptions) as x(enrolment_id uuid, status public.student_attendance_status) on x.enrolment_id = e.id
   where e.section_id = p_section_id and e.status = 'active' and s.status = 'active';

  return public.save_attendance_register(p_section_id, p_date, v_marks);
end;
$$;

revoke execute on function public.rpc_bulk_mark_attendance(uuid, date, jsonb) from public, anon;
grant execute on function public.rpc_bulk_mark_attendance(uuid, date, jsonb) to authenticated;
