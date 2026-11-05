-- Audit BUG-03: a new school had no attendance policy, and is_attendance_locked() fails closed
-- without one, so every register read "Locked — this date can no longer be edited" from day one.
-- Every campus now gets the documented defaults (08:00 start, 24-hour edit window) for each
-- session it runs in, the moment that campus or session exists. A principal can still change
-- them under Attendance Policy; set_attendance_policy() adds a newer effective-dated row.

create or replace function app.seed_default_attendance_policy(p_tenant_id uuid, p_campus_id uuid, p_session_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.attendance_policy (tenant_id, campus_id, session_id, effective_from)
  select p_tenant_id, p_campus_id, p_session_id, coalesce(s.starts_on::timestamptz, clock_timestamp())
    from public.academic_session s
   where s.id = p_session_id
     and not exists (select 1 from public.attendance_policy p where p.campus_id = p_campus_id and p.session_id = p_session_id);
$$;

revoke execute on function app.seed_default_attendance_policy(uuid, uuid, uuid) from public, anon, authenticated;

create or replace function app.tg_session_default_attendance_policy()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  c record;
begin
  for c in select id from public.campus where tenant_id = new.tenant_id and (new.campus_id is null or id = new.campus_id) loop
    perform app.seed_default_attendance_policy(new.tenant_id, c.id, new.id);
  end loop;
  return new;
end;
$$;

create or replace function app.tg_campus_default_attendance_policy()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  s record;
begin
  for s in select id from public.academic_session where tenant_id = new.tenant_id and campus_id is null loop
    perform app.seed_default_attendance_policy(new.tenant_id, new.id, s.id);
  end loop;
  return new;
end;
$$;

drop trigger if exists academic_session_default_attendance_policy on public.academic_session;
create trigger academic_session_default_attendance_policy after insert on public.academic_session
  for each row execute function app.tg_session_default_attendance_policy();

drop trigger if exists campus_default_attendance_policy on public.campus;
create trigger campus_default_attendance_policy after insert on public.campus
  for each row execute function app.tg_campus_default_attendance_policy();

-- Backfill every campus and session pair that exists today.
select app.seed_default_attendance_policy(s.tenant_id, c.id, s.id)
  from public.academic_session s
  join public.campus c on c.tenant_id = s.tenant_id and (s.campus_id is null or s.campus_id = c.id);
