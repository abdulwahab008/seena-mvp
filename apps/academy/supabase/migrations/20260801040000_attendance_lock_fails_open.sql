-- Fix: is_attendance_locked() (FR-G09) reported a LOCKED day as UNLOCKED.
--
-- The function has no role check and no campus check of its own — by
-- design: "is this section's register still open" is a property of the
-- SECTION, the same answer for everyone who asks. But it reads the
-- window it needs from resolve_attendance_policy(), and
-- 20260731770000_security_definer_campus_scope_audit.sql gave that
-- resolver a campus guard: a campus outside the CALLER's campus_ids
-- claim resolves to NULL. The function then ran straight into
--
--     if v_policy is null then return false;   -- "not locked"
--
-- so an unresolvable policy became an affirmative "this day is open".
-- Of the four defects this guard left behind this is the only one that
-- fails OPEN, and it fails open on a control whose entire job is to
-- stop attendance being rewritten after the fact: save_attendance_
-- register() and rpc_bulk_mark_attendance() both gate on it, and it is
-- itself granted to authenticated, so it is directly RPC-reachable.
--
-- Two populations hit it, and the second is the ordinary one:
--   * a class teacher marking a section at a campus her claim does not
--     cover — FR-G02 authorizes her by section_class_teacher, never by
--     campus, precisely so that she can;
--   * a teacher with no user_campus row at all, whose claim is '{}'.
--     `not (campus = any('{}'))` is true for EVERY campus, so she got
--     "unlocked" for her own campus, on every date, forever. FR-F15's
--     export fix (20260801030000) hit the identical shape.
--
-- Three things change here.
--
-- 1. The policy is resolved through app.resolve_attendance_policy_
--    unscoped(), the same split 20260801010000 / 20260801020000 /
--    20260801030000 established for the bell-template and branding
--    resolvers: the resolution logic moves into `app`, the public
--    wrapper keeps the audit's campus guard byte-for-byte for every
--    ordinary caller, and only a postgres-owned SECURITY DEFINER
--    function that has already established its own access rule reaches
--    the internal one. It has no PostgREST surface (config.toml exposes
--    public and graphql_public only) and EXECUTE is revoked from
--    public, anon AND authenticated.
--
--    Unlike the three earlier unscoped resolvers this one takes its
--    tenant explicitly instead of reading app.auth_tenant_id(). That is
--    not a tenant escape hatch — it is the opposite. Those resolvers are
--    called with a campus id the CALLER supplied, so pinning the tenant
--    to the caller's own claim is what stops them naming a foreign
--    tenant's campus. Here the campus and session come from a
--    class_section row this function loaded by primary key, so the
--    tenant that owns the policy is already known from the data, and
--    binding it to the row rather than to the claim is what makes the
--    answer independent of who is asking — which is the whole defect.
--    The contract, enforced by the revokes, is that every caller passes
--    a tenant it read off a row it has already established the caller's
--    right to, never one the caller passed in.
--
--    It also matters for the one legitimate caller that has no claim at
--    all. sweep_attendance_locks() is granted to service_role and its
--    own body branches on `app.auth_tenant_id() is null` to sweep every
--    tenant — but with the policy pinned to the caller's claim, a
--    tenant-less caller resolves NO policy for ANY section, so the cron
--    swept nothing before this migration and would have locked
--    EVERYTHING after it once the null case stopped meaning "open".
--    Pinning to the section's tenant is what makes both callers correct
--    at once.
--
-- 2. An unresolvable policy now means LOCKED, not open. After (1) the
--    only way to reach that state is that no attendance_policy row
--    exists for this section's campus and session at all — and in that
--    state save_attendance_register(), the sole writer, already refuses
--    every write with POLICY_NOT_CONFIGURED. So "locked" is not merely
--    the fail-safe answer, it is the accurate one: the register cannot
--    be written, which is exactly what this function reports. The more
--    specific POLICY_NOT_CONFIGURED still reaches the user on the
--    online path, because save_attendance_register() checks the policy
--    before it checks the lock; on the queued offline path (FR-G05) the
--    submission is now routed into FR-G10's correction requests rather
--    than raising and rolling back the ledger row that records it.
--
-- 3. The section lookup is tenant-checked, and now runs before the
--    attendance_lock short-circuit rather than after it. Both are
--    required by (1): the section's tenant is what the policy is
--    resolved against, so a caller must not be able to make this
--    function answer about a section belonging to somebody else's
--    tenant. A tenant-less service_role caller is exempt, which is the
--    same sweep-every-tenant mode sweep_attendance_locks() already
--    declares.
--
-- A section that does not exist (or is not the caller's) still returns
-- false, unchanged. That is not the fail-open this file is about: there
-- is no register there to lock, and save_attendance_register() refuses
-- it with SECTION_NOT_FOUND before ever asking. The new fail-closed rule
-- is about a register that DOES exist whose open window cannot be
-- determined.
--
-- resolve_attendance_lock_info() (AC3, the register's "Locked at ..."
-- banner) had the same defect twice over: it delegates the decision to
-- is_attendance_locked(), and it recomputed the displayed deadline
-- through the guarded resolver itself, so an out-of-scope or empty-claim
-- caller who did somehow see a lock got a banner with no time on it.
-- Both are fixed here.

create or replace function app.resolve_attendance_policy_unscoped(
  p_tenant_id uuid,
  p_campus_id uuid,
  p_session_id uuid,
  p_as_of timestamptz default clock_timestamp()
)
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
   where tenant_id = p_tenant_id and campus_id = p_campus_id and session_id = p_session_id
     and effective_from <= p_as_of
   order by effective_from desc
   limit 1;
$$;

revoke execute on function app.resolve_attendance_policy_unscoped(uuid, uuid, uuid, timestamptz) from public, anon, authenticated;

-- Unchanged behaviour for every ordinary caller: the audit's campus
-- guard, and an out-of-scope campus still resolving to NULL silently.
create or replace function public.resolve_attendance_policy(p_campus_id uuid, p_session_id uuid, p_as_of timestamptz default clock_timestamp())
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then null
    else app.resolve_attendance_policy_unscoped(app.auth_tenant_id(), p_campus_id, p_session_id, p_as_of)
  end;
$$;

revoke execute on function public.resolve_attendance_policy(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.resolve_attendance_policy(uuid, uuid, timestamptz) to authenticated;

-- AC1/AC4, unchanged in intent: true once now() is past start_time +
-- lock_window_hours on attendance_date in Asia/Karachi wall-clock time,
-- computed live, with an existing attendance_lock row short-circuiting
-- straight to true. What changes is that the window is now resolved from
-- the section rather than from whoever is asking, and that a window
-- which cannot be resolved no longer reads as "open".
create or replace function public.is_attendance_locked(p_section_id uuid, p_date date)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_section   public.class_section%rowtype;
  v_policy    jsonb;
  v_deadline  timestamptz;
begin
  select * into v_section from public.class_section where id = p_section_id;
  -- A tenant-less caller is service_role running sweep_attendance_locks()
  -- across every tenant, which that function's own body already declares.
  if not found or (v_tenant_id is not null and v_section.tenant_id <> v_tenant_id) then
    return false;
  end if;

  if exists (select 1 from public.attendance_lock where section_id = p_section_id and attendance_date = p_date) then
    return true;
  end if;

  v_policy := app.resolve_attendance_policy_unscoped(v_section.tenant_id, v_section.campus_id, v_section.session_id);
  if v_policy is null then
    -- No policy exists for this campus and session, so there is no open
    -- window — and save_attendance_register() refuses every write here
    -- with POLICY_NOT_CONFIGURED anyway. Reporting "open" would be both
    -- unsafe and untrue.
    return true;
  end if;

  v_deadline := ((p_date + (v_policy ->> 'start_time')::time)::timestamp at time zone 'Asia/Karachi')
                + make_interval(hours => (v_policy ->> 'lock_window_hours')::int);

  return clock_timestamp() > v_deadline;
end;
$$;

revoke execute on function public.is_attendance_locked(uuid, date) from public, anon;
grant execute on function public.is_attendance_locked(uuid, date) to authenticated, service_role;

-- AC3: what the register screen shows on a locked day — the real
-- recorded timestamp once something has swept or manually locked it, or
-- the theoretical deadline when the window has simply elapsed. That
-- deadline is now resolved the same way the lock decision itself is.
create or replace function public.resolve_attendance_lock_info(p_section_id uuid, p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_lock      public.attendance_lock%rowtype;
  v_section   public.class_section%rowtype;
  v_policy    jsonb;
  v_deadline  timestamptz;
begin
  select * into v_section from public.class_section where id = p_section_id and tenant_id = v_tenant_id;
  if not found then
    return jsonb_build_object('locked', false);
  end if;

  select * into v_lock from public.attendance_lock where section_id = p_section_id and attendance_date = p_date;
  if found then
    return jsonb_build_object('locked', true, 'locked_at', v_lock.locked_at, 'locked_by', v_lock.locked_by);
  end if;

  if not public.is_attendance_locked(p_section_id, p_date) then
    return jsonb_build_object('locked', false);
  end if;

  v_policy := app.resolve_attendance_policy_unscoped(v_section.tenant_id, v_section.campus_id, v_section.session_id);
  v_deadline := ((p_date + (v_policy ->> 'start_time')::time)::timestamp at time zone 'Asia/Karachi')
                + make_interval(hours => (v_policy ->> 'lock_window_hours')::int);

  return jsonb_build_object('locked', true, 'locked_at', v_deadline, 'locked_by', null);
end;
$$;

revoke execute on function public.resolve_attendance_lock_info(uuid, date) from public, anon;
grant execute on function public.resolve_attendance_lock_info(uuid, date) to authenticated;
