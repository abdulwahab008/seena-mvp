-- FR-G09: attendance lock after configured window.
--
--   * This FR turns out to be the authoritative source for the lock
--     formula FR-G02 only approximated: this AC's own numbers
--     (lock_window_hours=6, start_time=08:00, a 14:01 submit on the
--     SAME date is already locked) mean the deadline is start_time +
--     lock_window_hours on the attendance date itself — not "the whole
--     next day plus a grace window," which is what FR-G02's
--     save_attendance_register() computed before this migration
--     corrects it. Every earlier caller (rpc_bulk_mark_attendance,
--     FR-G04) inherits the fix for free since they all delegate to
--     save_attendance_register().
--   * is_attendance_locked() computes the lock LIVE from the policy and
--     current time — it does not require an attendance_lock row to
--     exist first. This is exactly AC2's own point: enforcement must
--     not depend on a cron sweep having already run. The attendance_
--     lock table exists only to (a) let a Principal force an early
--     manual lock and (b) remember a timestamp for the "Locked at ..."
--     banner once something has actually recorded it, not to gate the
--     lock decision itself.
--   * The policy consulted is whichever one governs NOW (resolve_
--     attendance_policy's own default as-of), not whichever one was in
--     effect back on the attendance date itself — "is this now locked"
--     is a question about today's rule, the same policy save_
--     attendance_register() already checks marks against. Resolving
--     as-of the attendance date would make a school's very first policy
--     (created today) unable to lock anything dated before its own
--     effective_from, since no policy existed "back then" to consult —
--     exactly wrong for a brand-new tenant trying to lock old dates.
--   * sweep_attendance_locks() is this session's usual "not wired to a
--     schedule (no pg_cron locally)" pattern (FR-B16, FR-K13, FR-D12,
--     FR-B05): a plain, correct, tested function a real cron would
--     call, granted to service_role, not actually scheduled.
--   * Asia/Karachi is hardcoded, matching the AC's own literal wording
--     — every tenant/campus row in this schema already defaults its
--     own `timezone` column to 'Asia/Karachi' too, so this is not a
--     divergence from the rest of the schema, just not yet threading
--     that column through generically for a single-country-market app
--     where nothing else does either.
--   * The raised code is 'ATT_LOCKED', the AC's own literal string —
--     FR-G02 shipped with the placeholder 'ATTENDANCE_LOCKED' before
--     this FR existed to specify the real one.

create type public.attendance_lock_source as enum ('cron', 'manual');

create table public.attendance_lock (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  section_id      uuid not null references public.class_section(id) on delete cascade,
  attendance_date date not null,
  locked_at       timestamptz not null default clock_timestamp(),
  locked_by       public.attendance_lock_source not null,
  locked_by_user  uuid references public.app_user(user_id),
  constraint uq_attendance_lock_section_date unique (section_id, attendance_date)
);

create index idx_att_lock_lookup on public.attendance_lock (section_id, attendance_date);

create trigger attendance_lock_audit after insert or update or delete on public.attendance_lock
  for each row execute function app.tg_audit_row();

-- AC1/AC4: true once now() is past start_time + lock_window_hours on
-- attendance_date, in Asia/Karachi wall-clock time, regardless of the
-- server's own timezone — computed live, an existing attendance_lock
-- row (if any) short-circuits straight to true without recomputing.
create or replace function public.is_attendance_locked(p_section_id uuid, p_date date)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_section  public.class_section%rowtype;
  v_policy   jsonb;
  v_deadline timestamptz;
begin
  if exists (select 1 from public.attendance_lock where section_id = p_section_id and attendance_date = p_date) then
    return true;
  end if;

  select * into v_section from public.class_section where id = p_section_id;
  if not found then
    return false;
  end if;

  v_policy := public.resolve_attendance_policy(v_section.campus_id, v_section.session_id);
  if v_policy is null then
    return false;
  end if;

  v_deadline := ((p_date + (v_policy ->> 'start_time')::time)::timestamp at time zone 'Asia/Karachi')
                + make_interval(hours => (v_policy ->> 'lock_window_hours')::int);

  return clock_timestamp() > v_deadline;
end;
$$;

revoke execute on function public.is_attendance_locked(uuid, date) from public, anon;
grant execute on function public.is_attendance_locked(uuid, date) to authenticated, service_role;

-- AC3: what the register screen shows on a locked day — locked_at is the
-- real recorded timestamp once something has swept/manually locked it,
-- or the theoretical deadline itself when the window has simply elapsed
-- with nothing having recorded that yet.
create or replace function public.resolve_attendance_lock_info(p_section_id uuid, p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_lock     public.attendance_lock%rowtype;
  v_section  public.class_section%rowtype;
  v_policy   jsonb;
  v_deadline timestamptz;
begin
  select * into v_lock from public.attendance_lock where section_id = p_section_id and attendance_date = p_date;
  if found then
    return jsonb_build_object('locked', true, 'locked_at', v_lock.locked_at, 'locked_by', v_lock.locked_by);
  end if;

  if not public.is_attendance_locked(p_section_id, p_date) then
    return jsonb_build_object('locked', false);
  end if;

  select * into v_section from public.class_section where id = p_section_id;
  v_policy := public.resolve_attendance_policy(v_section.campus_id, v_section.session_id);
  v_deadline := ((p_date + (v_policy ->> 'start_time')::time)::timestamp at time zone 'Asia/Karachi')
                + make_interval(hours => (v_policy ->> 'lock_window_hours')::int);

  return jsonb_build_object('locked', true, 'locked_at', v_deadline, 'locked_by', null);
end;
$$;

revoke execute on function public.resolve_attendance_lock_info(uuid, date) from public, anon;
grant execute on function public.resolve_attendance_lock_info(uuid, date) to authenticated;

create or replace function public.lock_attendance_now(p_section_id uuid, p_date date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_section public.class_section%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_section from public.class_section where id = p_section_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.attendance_lock (tenant_id, campus_id, section_id, attendance_date, locked_by, locked_by_user)
  values (app.auth_tenant_id(), v_section.campus_id, p_section_id, p_date, 'manual', auth.uid())
  on conflict (section_id, attendance_date) do nothing;
end;
$$;

revoke execute on function public.lock_attendance_now(uuid, date) from public, anon;
grant execute on function public.lock_attendance_now(uuid, date) to authenticated;

-- Not wired to a schedule (no pg_cron locally) — a real cron would call
-- this hourly, same posture as every other "cron" function this session
-- (FR-B16, FR-K13, FR-D12, FR-B05). Sweeps every section/date whose
-- window has live-elapsed and records it, tenant-wide for service_role,
-- own-tenant-only for an authenticated admin's manual "run now".
create or replace function public.sweep_attendance_locks()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row   record;
  v_count int := 0;
begin
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  for v_row in
    select distinct ad.tenant_id, ad.campus_id, ad.section_id, ad.attendance_date
      from public.attendance_day ad
     where (app.auth_tenant_id() is null or ad.tenant_id = app.auth_tenant_id())
       and ad.attendance_date >= current_date - 60
       and not exists (
         select 1 from public.attendance_lock al
          where al.section_id = ad.section_id and al.attendance_date = ad.attendance_date
       )
       and public.is_attendance_locked(ad.section_id, ad.attendance_date)
  loop
    insert into public.attendance_lock (tenant_id, campus_id, section_id, attendance_date, locked_by)
    values (v_row.tenant_id, v_row.campus_id, v_row.section_id, v_row.attendance_date, 'cron')
    on conflict (section_id, attendance_date) do nothing;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.sweep_attendance_locks() from public, anon;
grant execute on function public.sweep_attendance_locks() to authenticated, service_role;

-- AC1: save_attendance_register() now delegates its lock decision to
-- is_attendance_locked() (start_time + lock_window_hours on the
-- attendance date itself, in Asia/Karachi) and raises the AC's own
-- literal error code — everything else in the function is unchanged
-- from FR-G02.
create or replace function public.save_attendance_register(p_section_id uuid, p_attendance_date date, p_marks jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_section       public.class_section%rowtype;
  v_holiday       text;
  v_policy        jsonb;
  v_mark          record;
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

  for v_mark in select * from jsonb_to_recordset(p_marks) as m(enrolment_id uuid, status public.student_attendance_status)
  loop
    if not exists (
      select 1 from public.enrolment e join public.student s on s.id = e.student_id
       where e.id = v_mark.enrolment_id and e.section_id = p_section_id and e.status = 'active' and s.status = 'active'
    ) then
      continue;
    end if;

    insert into public.attendance_day (
      tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, marked_by
    ) values (
      v_tenant_id, v_section.campus_id, v_section.session_id, p_section_id, v_mark.enrolment_id, p_attendance_date, v_mark.status, auth.uid()
    )
    on conflict (enrolment_id, attendance_date) do update
      set status = excluded.status, marked_by = excluded.marked_by, marked_at = clock_timestamp();

    v_saved := v_saved + 1;
  end loop;

  return jsonb_build_object('saved', v_saved);
end;
$$;

revoke execute on function public.save_attendance_register(uuid, date, jsonb) from public, anon;
grant execute on function public.save_attendance_register(uuid, date, jsonb) to authenticated;

alter table public.attendance_lock enable row level security;

create policy attendance_lock_campus_read on public.attendance_lock
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
