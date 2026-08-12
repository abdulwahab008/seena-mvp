-- FR-G05: offline attendance capture and sync.
--
--   * Nothing new is built on the write path: attendance_day already has
--     marked_at and a `source` enum that already contains 'offline_sync'
--     (FR-G02 shipped both), and save_attendance_register() is still the
--     one and only writer. This migration threads three facts through it
--     that it previously invented for itself — WHEN the mark was captured
--     (marked_at), WHERE it came from (source), and WHEN it reached the
--     server (synced_at, the one genuinely new column) — and wraps
--     rpc_bulk_mark_attendance() in an idempotency ledger.
--   * marked_at previously meant "when the server wrote it"; for an
--     offline capture AC3 requires it to mean "when the teacher tapped
--     it" (08:20), with the write time recorded separately as synced_at
--     (14:00). The online path is unchanged by construction: p_marked_at
--     defaults to null, which resolves to clock_timestamp(), and
--     p_synced_at stays null, exactly what every row written before this
--     migration has.
--   * Exactly-once with the ORIGINAL result replayed (AC2), not merely
--     "ignore the duplicate": the first call for an idempotency_key
--     stores its own return value verbatim in attendance_sync_log.response
--     and every later call for that key returns that stored jsonb without
--     re-executing anything. Two layers guard it — pg_advisory_xact_lock
--     on the key serializes genuinely concurrent retries (the same
--     pattern request_attendance_correction() and the timetable clash
--     checks already use), and uq_att_sync_idem is the hard backstop if
--     they ever land in different sessions past the lock.
--   * An idempotency key is only ever minted by the device queue, so its
--     presence IS the offline signal: p_idempotency_key non-null means
--     "this is a replayable queued submission" and implies source =
--     'offline_sync'. A null key is the ordinary online submit and takes
--     the pre-existing code path untouched, ledger included — no log row,
--     no behavioural change, same {"saved": n} return shape the existing
--     UI, pgTAP and e2e specs already assert on.
--   * AC4 (locked between capture and sync) must RETURN, not raise: a
--     raised exception would roll back the very correction requests and
--     ledger row that stop the submission being silently dropped. So the
--     queued path checks is_attendance_locked() itself, before calling
--     save_attendance_register(), and on a locked date routes into
--     FR-G10/G11's existing request_attendance_correction() — one request
--     per captured mark that actually DISAGREES with what is on record
--     (a mark the server already agrees with needs no correction), each
--     carrying the device capture time in its reason so the approving
--     Principal can see why it arrived late. The literal string the AC
--     names, 'attendance_locked', is returned in the response rather than
--     raised as an errcode for the same reason.
--   * Known limitation, NOT introduced here and deliberately not fixed
--     here: approve_attendance_correction() (FR-G11) raises
--     ATTENDANCE_DAY_NOT_FOUND when no attendance_day row exists for the
--     (enrolment, date) being corrected, because that FR's premise is
--     amending an EXISTING mark. So a correction raised by this migration
--     for a locked date that was never marked at all is requested and
--     visible but not approvable until that function learns to insert.
--     Fixing it means changing FR-G11's own already-shipped function, so
--     it is flagged rather than folded into this FR.
--   * 'rejected_stale' covers the other real replay hazard the enum the
--     FR itself suggests already anticipates: the register was re-marked
--     on the server (another device, or the same teacher back online)
--     AFTER this submission was captured. Applying it would silently
--     overwrite newer truth with older, so the whole submission is
--     rejected as a unit — the register is submitted as a unit, and
--     capture time is the ordering key precisely because marked_at now
--     carries it.

alter table public.attendance_day add column synced_at timestamptz;

create type public.attendance_sync_result as enum ('applied', 'rejected_locked', 'rejected_stale');

create table public.attendance_sync_log (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  section_id      uuid not null references public.class_section(id) on delete cascade,
  idempotency_key uuid not null,
  teacher_id      uuid references public.app_user(user_id),
  attendance_date date not null,
  payload         jsonb not null,
  captured_at     timestamptz not null,
  synced_at       timestamptz not null,
  result          public.attendance_sync_result not null,
  response        jsonb not null,
  error_text      text
);

create unique index uq_att_sync_idem on public.attendance_sync_log (idempotency_key);
create index idx_att_sync_section_date on public.attendance_sync_log (section_id, attendance_date);

create trigger attendance_sync_log_audit after insert or update or delete on public.attendance_sync_log
  for each row execute function app.tg_audit_row();

-- AC3: marked_at is the device capture time and source records where the
-- mark came from; synced_at is when it actually reached us. All three
-- default to exactly what this function did before (clock_timestamp(),
-- 'web', null), so every existing caller is unaffected. Dropped and
-- recreated rather than `create or replace`d with extra defaulted
-- arguments — those would be a second, distinct function and every
-- existing 3-argument call would become ambiguous.
drop function public.save_attendance_register(uuid, date, jsonb);

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

  v_holiday := public.resolve_attendance_holiday(v_section.campus_id, p_attendance_date);
  if v_holiday is not null then
    raise exception using message = 'HOLIDAY:' || v_holiday, errcode = '55000';
  end if;

  v_policy := public.resolve_attendance_policy(v_section.campus_id, v_section.session_id);
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

-- AC1/AC2/AC3/AC4. Same drop-then-recreate reasoning as above.
drop function public.rpc_bulk_mark_attendance(uuid, date, jsonb);

create or replace function public.rpc_bulk_mark_attendance(
  p_section_id uuid,
  p_date date,
  p_exceptions jsonb default '[]'::jsonb,
  p_idempotency_key uuid default null,
  p_captured_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid := app.auth_tenant_id();
  v_section     public.class_section%rowtype;
  v_campus_tz   text;
  v_marks       jsonb;
  v_log         public.attendance_sync_log%rowtype;
  v_captured_at timestamptz;
  v_synced_at   timestamptz := clock_timestamp();
  v_newest      timestamptz;
  v_mark        record;
  v_correction  uuid;
  v_corrections uuid[] := '{}'::uuid[];
  v_skipped     int := 0;
  v_result      public.attendance_sync_result;
  v_error       text;
  v_response    jsonb;
begin
  -- The roster is expanded server-side at SYNC time, not capture time —
  -- a student struck off while the device was offline is dropped by
  -- save_attendance_register()'s own both-tables-active filter, and one
  -- enrolled since capture is defaulted present rather than left unmarked.
  select coalesce(
    jsonb_agg(jsonb_build_object(
      'enrolment_id', e.id,
      'status', coalesce(x.status, 'present'),
      'arrival_time', x.arrival_time,
      'departure_time', x.departure_time
    )),
    '[]'::jsonb
  )
    into v_marks
    from public.enrolment e
    join public.student s on s.id = e.student_id
    left join jsonb_to_recordset(p_exceptions)
      as x(enrolment_id uuid, status public.student_attendance_status, arrival_time time, departure_time time)
      on x.enrolment_id = e.id
   where e.section_id = p_section_id and e.status = 'active' and s.status = 'active';

  if p_idempotency_key is null then
    return public.save_attendance_register(p_section_id, p_date, v_marks);
  end if;

  select * into v_section from public.class_section where id = p_section_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_captured_at := coalesce(p_captured_at, v_synced_at);

  -- AC2: serialize every concurrent retry of one key behind the first,
  -- so the loser sees the winner's committed ledger row rather than
  -- racing it into a second write.
  perform pg_advisory_xact_lock(hashtextextended('att-sync:' || p_idempotency_key::text, 0));

  select * into v_log from public.attendance_sync_log where idempotency_key = p_idempotency_key;
  if found then
    if v_log.tenant_id <> v_tenant_id then
      raise exception 'IDEMPOTENCY_KEY_CONFLICT' using errcode = '23505';
    end if;
    -- The ORIGINAL result, verbatim — a replay is indistinguishable from
    -- the call it replays, which is the whole point of AC2.
    return v_log.response;
  end if;

  if public.is_attendance_locked(p_section_id, p_date) then
    v_result := 'rejected_locked';
    v_error := 'attendance_locked';
    select timezone into v_campus_tz from public.campus where id = v_section.campus_id;

    for v_mark in
      select * from jsonb_to_recordset(v_marks) as m(enrolment_id uuid, status public.student_attendance_status)
    loop
      if exists (
        select 1 from public.attendance_day
         where enrolment_id = v_mark.enrolment_id and attendance_date = p_date and status = v_mark.status
      ) then
        continue;
      end if;

      -- request_attendance_correction() allows exactly one pending
      -- request per (enrolment, date) — a second queued submission for
      -- the same locked date skips rather than failing the whole sync.
      if exists (
        select 1 from public.attendance_correction_request
         where enrolment_id = v_mark.enrolment_id and attendance_date = p_date and status = 'pending'
      ) then
        v_skipped := v_skipped + 1;
        continue;
      end if;

      v_correction := public.request_attendance_correction(
        v_mark.enrolment_id,
        p_date,
        v_mark.status,
        'Captured offline at ' || to_char(v_captured_at at time zone v_campus_tz, 'YYYY-MM-DD HH24:MI')
          || ', synced after this date was locked'
      );
      v_corrections := v_corrections || v_correction;
    end loop;

    v_response := jsonb_build_object(
      'result', 'rejected_locked',
      'error', 'attendance_locked',
      'saved', 0,
      'corrections_requested', cardinality(v_corrections),
      'corrections_skipped', v_skipped,
      'correction_ids', to_jsonb(v_corrections)
    );
  else
    select max(marked_at) into v_newest
      from public.attendance_day
     where section_id = p_section_id and attendance_date = p_date;

    if v_newest is not null and v_newest > v_captured_at then
      v_result := 'rejected_stale';
      v_error := 'attendance_stale';
      v_response := jsonb_build_object(
        'result', 'rejected_stale',
        'error', 'attendance_stale',
        'saved', 0,
        'server_marked_at', v_newest
      );
    else
      v_result := 'applied';
      v_response := public.save_attendance_register(p_section_id, p_date, v_marks, v_captured_at, 'offline_sync', v_synced_at)
                    || jsonb_build_object('result', 'applied');
    end if;
  end if;

  insert into public.attendance_sync_log (
    tenant_id, campus_id, section_id, idempotency_key, teacher_id, attendance_date,
    payload, captured_at, synced_at, result, response, error_text
  ) values (
    v_tenant_id, v_section.campus_id, p_section_id, p_idempotency_key, auth.uid(), p_date,
    p_exceptions, v_captured_at, v_synced_at, v_result, v_response, v_error
  );

  return v_response;
end;
$$;

revoke execute on function public.rpc_bulk_mark_attendance(uuid, date, jsonb, uuid, timestamptz) from public, anon;
grant execute on function public.rpc_bulk_mark_attendance(uuid, date, jsonb, uuid, timestamptz) to authenticated;

alter table public.attendance_sync_log enable row level security;

-- Select only: the SECURITY DEFINER function above is the sole writer, so
-- no client can forge, edit or erase its own sync history.
create policy attendance_sync_log_campus_read on public.attendance_sync_log
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
