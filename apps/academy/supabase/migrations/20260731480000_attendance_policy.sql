-- FR-G01: attendance policy configuration per campus.
--
-- Module G (Attendance) is entirely new this session — this FR is
-- deliberately just the policy config, the one thing every later
-- Attendance FR (daily register, SMS alerts, lock windows, report
-- cards) needs to already exist and be resolvable for a given date
-- before any of them can be built correctly.
--
--   * Effective-dated, not update-in-place — every edit inserts a NEW
--     row rather than mutating the current one, and resolve_attendance_
--     policy() picks "the latest row whose effective_from is on or
--     before the target instant." This is the exact resolve_fee_
--     structure() pattern from FR-K03 (20260731190000_fee_structure_
--     versioning.sql): no separate effective_to/is_current bookkeeping
--     needed, "order by effective_from desc limit 1" is enough. This is
--     what makes AC3 true: a date before the edit still resolves the
--     OLD row (old lock_window_hours), a date at-or-after resolves the
--     new one — "already-locked days remain locked" is a property of
--     which policy row governs that day, not something G09 (attendance
--     lock, not built yet) needs its own bookkeeping for.
--   * resolve_attendance_status() (present/late) is built and tested
--     now even though nothing calls it yet (FR-G02's daily register
--     isn't built) — same "prove the resolution logic against the
--     policy config it will actually consume" posture as resolve_fee_
--     structure() itself.
--   * AC4 ("RLS ... rejects the write with 42501") is satisfied by the
--     write-only-through-a-function role check raising errcode 42501,
--     the same posture as every other mutation in this codebase — no
--     table here has ever had a direct INSERT/UPDATE grant to
--     authenticated, so a raw RLS write-policy rejection was never a
--     real path to begin with.

create table public.attendance_policy (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenant(id) on delete cascade,
  campus_id             uuid not null references public.campus(id) on delete cascade,
  session_id            uuid not null references public.academic_session(id) on delete cascade,
  mode                  text not null default 'daily' check (mode in ('daily', 'period')),
  start_time            time not null default '08:00',
  late_threshold_minutes int not null default 15 check (late_threshold_minutes >= 0),
  half_day_cutoff_time  time,
  lock_window_hours     int not null default 24 check (lock_window_hours > 0),
  min_attendance_pct    numeric(5, 2) check (min_attendance_pct is null or (min_attendance_pct >= 0 and min_attendance_pct <= 100)),
  saturday_working      boolean not null default false,
  effective_from        timestamptz not null default clock_timestamp(),
  updated_by            uuid references public.app_user(user_id),
  created_at            timestamptz not null default clock_timestamp()
);

create index idx_attendance_policy_lookup on public.attendance_policy (tenant_id, campus_id, session_id, effective_from desc);

create trigger attendance_policy_audit after insert or update or delete on public.attendance_policy
  for each row execute function app.tg_audit_row();

create or replace function public.set_attendance_policy(
  p_campus_id uuid, p_session_id uuid,
  p_mode text default 'daily', p_start_time time default '08:00', p_late_threshold_minutes int default 15,
  p_half_day_cutoff_time time default null, p_lock_window_hours int default 24,
  p_min_attendance_pct numeric default null, p_saturday_working boolean default false
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
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = v_tenant_id) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.attendance_policy (
    tenant_id, campus_id, session_id, mode, start_time, late_threshold_minutes,
    half_day_cutoff_time, lock_window_hours, min_attendance_pct, saturday_working, updated_by
  ) values (
    v_tenant_id, p_campus_id, p_session_id, p_mode, p_start_time, p_late_threshold_minutes,
    p_half_day_cutoff_time, p_lock_window_hours, p_min_attendance_pct, p_saturday_working, auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.set_attendance_policy(uuid, uuid, text, time, int, time, int, numeric, boolean) from public, anon;
grant execute on function public.set_attendance_policy(uuid, uuid, text, time, int, time, int, numeric, boolean) to authenticated;

-- AC1/AC3: null when nothing has ever been configured; otherwise the
-- policy actually in force at p_as_of, whether that's the current one
-- or one since superseded. jsonb, not the bare composite type — a NULL
-- public.attendance_policy does not reliably serialize as JSON null
-- across the PostgREST RPC boundary, the same reason resolve_branding()
-- (FR-A18) returns jsonb rather than a table rowtype.
create or replace function public.resolve_attendance_policy(p_campus_id uuid, p_session_id uuid, p_as_of timestamptz default clock_timestamp())
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', id, 'mode', mode, 'start_time', start_time, 'late_threshold_minutes', late_threshold_minutes,
    'half_day_cutoff_time', half_day_cutoff_time, 'lock_window_hours', lock_window_hours,
    'min_attendance_pct', min_attendance_pct, 'saturday_working', saturday_working, 'effective_from', effective_from
  )
    from public.attendance_policy
   where tenant_id = app.auth_tenant_id() and campus_id = p_campus_id and session_id = p_session_id
     and effective_from <= p_as_of
   order by effective_from desc
   limit 1;
$$;

revoke execute on function public.resolve_attendance_policy(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.resolve_attendance_policy(uuid, uuid, timestamptz) to authenticated;

-- AC2: present/late classification against whichever policy governs
-- p_as_of. Returns null (not an error) when unconfigured — the caller
-- (a future FR-G02 marking screen) is what turns that into the
-- blocking message the AC describes.
create or replace function public.resolve_attendance_status(p_campus_id uuid, p_session_id uuid, p_marked_time time, p_as_of timestamptz default clock_timestamp())
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_policy jsonb;
begin
  v_policy := public.resolve_attendance_policy(p_campus_id, p_session_id, p_as_of);
  if v_policy is null then
    return null;
  end if;

  if p_marked_time <= (v_policy ->> 'start_time')::time + make_interval(mins => (v_policy ->> 'late_threshold_minutes')::int) then
    return 'present';
  end if;
  return 'late';
end;
$$;

revoke execute on function public.resolve_attendance_status(uuid, uuid, time, timestamptz) from public, anon;
grant execute on function public.resolve_attendance_status(uuid, uuid, time, timestamptz) to authenticated;

alter table public.attendance_policy enable row level security;

create policy attendance_policy_campus_read on public.attendance_policy
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
