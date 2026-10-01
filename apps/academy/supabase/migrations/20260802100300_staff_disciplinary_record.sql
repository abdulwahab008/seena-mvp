-- FR-D15: restricted disciplinary action record.
--
-- Warnings, show-cause notices, inquiries, suspensions and terminations form an
-- APPEND-ONLY trail that only HR, the Owner and (for rows they issued
-- themselves) the issuer can read. The show-cause / response / inquiry /
-- outcome sequence is the school's defence in a contested termination, so:
--
--   * every timestamp is server-generated (issued_on, created_at, responded_at
--     come from the database clock inside the RPC; no client supplies them),
--   * rows are immutable: UPDATE and DELETE are revoked from every API role AND
--     a trigger refuses them for anyone else (a cascade from deleting the whole
--     school/staff record is the only exception, via trigger depth),
--   * a correction, a staff response or an outcome is a NEW row that points at
--     the row it replaces with supersedes_id (one successor per row).
--
-- An unanswered show-cause becomes overdue the day response_due_on is reached
-- (7-day notice issued on day 1 => due on day 8). The daily job flags them.
--
-- Suspensions live in staff_suspension (linked to the disciplinary row). A
-- suspension is in force unless a later row supersedes its disciplinary row
-- (a corrected date range, or a 'reinstatement'). While it is in force
-- is_staff_suspended() is true, effective_app_role() reads 'read_only', and the
-- teacher's published timetable periods surface in the substitution feed
-- (get_suspension_cover_feed / get_suspended_teachers, used by the Substitutions
-- page). Making EVERY write policy honour 'read_only' is not retrofitted here:
-- the function is the single place to ask, and the substitution feed - the part
-- that otherwise leaves classes uncovered on day one - is wired in.
--
-- The audit trail must not leak what the table hides: description, response and
-- outcome are added to audit_redacted_column so a Principal reading audit_log
-- sees [redacted] for them.

create type public.disciplinary_action_type as enum ('warning', 'show_cause', 'inquiry', 'suspension', 'termination', 'reinstatement');

create table public.staff_disciplinary (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  staff_id        uuid not null references public.staff(id) on delete cascade,
  action_type     public.disciplinary_action_type not null,
  issued_on       date not null default app.fn_karachi_today(),
  issued_by       uuid references public.app_user(user_id),
  description     text not null check (char_length(btrim(description)) between 1 and 4000),
  response_due_on date,
  staff_response  text check (staff_response is null or char_length(staff_response) <= 4000),
  responded_at    timestamptz,
  outcome         text check (outcome is null or char_length(outcome) <= 2000),
  supersedes_id   uuid references public.staff_disciplinary(id),
  created_at      timestamptz not null default now(),
  constraint chk_show_cause_deadline check (action_type <> 'show_cause' or response_due_on is not null),
  constraint chk_response_stamped check ((staff_response is null) = (responded_at is null))
);
create index idx_disciplinary_staff on public.staff_disciplinary (staff_id, created_at desc);
create index idx_disciplinary_tenant on public.staff_disciplinary (tenant_id);
create index idx_disciplinary_campus on public.staff_disciplinary (campus_id);
create index idx_disciplinary_due on public.staff_disciplinary (tenant_id, response_due_on) where action_type = 'show_cause';
create unique index uq_disciplinary_supersedes on public.staff_disciplinary (supersedes_id) where supersedes_id is not null;

create table public.staff_suspension (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  staff_id        uuid not null references public.staff(id) on delete cascade,
  from_date       date not null,
  to_date         date not null,
  disciplinary_id uuid not null references public.staff_disciplinary(id),
  created_at      timestamptz not null default now(),
  constraint chk_suspension_range check (to_date >= from_date)
);
create index idx_suspension_staff on public.staff_suspension (staff_id);
create index idx_suspension_staff_daterange on public.staff_suspension using gist (staff_id, daterange(from_date, to_date, '[]'));
create index idx_suspension_tenant on public.staff_suspension (tenant_id);
create index idx_suspension_disciplinary on public.staff_suspension (disciplinary_id);

-- Overdue show-cause flags written by the daily job (flagging is idempotent).
create table public.staff_showcause_overdue_flag (
  disciplinary_id uuid primary key references public.staff_disciplinary(id) on delete cascade,
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  flagged_on      date not null default app.fn_karachi_today()
);
create index idx_showcause_flag_tenant on public.staff_showcause_overdue_flag (tenant_id, flagged_on);

create or replace function app.tg_prevent_disciplinary_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- A cascade from removing the whole tenant / staff record runs inside the
  -- referential-integrity trigger (depth > 1); nothing a user can issue does.
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  raise exception 'DISCIPLINARY_IMMUTABLE' using errcode = '42501', detail = 'Enter a correction as a new row referencing supersedes_id.';
end;
$$;

create trigger trg_prevent_disciplinary_mutation before update or delete on public.staff_disciplinary
  for each row execute function app.tg_prevent_disciplinary_mutation();
create trigger trg_prevent_suspension_mutation before update or delete on public.staff_suspension
  for each row execute function app.tg_prevent_disciplinary_mutation();
create trigger trg_staff_disciplinary_no_truncate before truncate on public.staff_disciplinary
  for each statement execute function app.tg_table_no_truncate();
create trigger trg_staff_suspension_no_truncate before truncate on public.staff_suspension
  for each statement execute function app.tg_table_no_truncate();

create trigger staff_disciplinary_audit after insert or update or delete on public.staff_disciplinary
  for each row execute function app.tg_audit_row();
create trigger staff_suspension_audit after insert or update or delete on public.staff_suspension
  for each row execute function app.tg_audit_row();
insert into public.audit_redacted_column (table_name, column_name) values
  ('staff_disciplinary', 'description'), ('staff_disciplinary', 'staff_response'), ('staff_disciplinary', 'outcome')
on conflict do nothing;

revoke all on table public.staff_disciplinary from anon, authenticated;
revoke all on table public.staff_suspension from anon, authenticated;
revoke all on table public.staff_showcause_overdue_flag from anon, authenticated;
grant select on public.staff_disciplinary to authenticated;
grant select on public.staff_suspension to authenticated;
grant select on public.staff_showcause_overdue_flag to authenticated;

alter table public.staff_disciplinary enable row level security;
alter table public.staff_suspension enable row level security;
alter table public.staff_showcause_overdue_flag enable row level security;

-- HR and the Owner read everything; anyone else reads only the rows they issued.
create policy disciplinary_hr_owner_only on public.staff_disciplinary for select to authenticated
  using (tenant_id = app.auth_tenant_id() and (app.auth_role() in ('hr_manager', 'owner') or issued_by = (select auth.uid())));
create policy suspension_hr_owner_only on public.staff_suspension for select to authenticated
  using (tenant_id = app.auth_tenant_id() and (app.auth_role() in ('hr_manager', 'owner')
         or exists (select 1 from public.staff_disciplinary d where d.id = disciplinary_id and d.issued_by = (select auth.uid()))));
create policy showcause_flag_hr_owner_only on public.staff_showcause_overdue_flag for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('hr_manager', 'owner'));

-- ── suspension state ──────────────────────────────────────────────────────

create or replace function public.is_staff_suspended(p_staff uuid, p_date date default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.staff_suspension s
      join public.staff st on st.id = s.staff_id
     where s.staff_id = p_staff
       and st.tenant_id = app.auth_tenant_id()
       and coalesce(p_date, app.fn_karachi_today()) between s.from_date and s.to_date
       and not exists (select 1 from public.staff_disciplinary succ where succ.supersedes_id = s.disciplinary_id)
  );
$$;
revoke execute on function public.is_staff_suspended(uuid, date) from public, anon;
grant execute on function public.is_staff_suspended(uuid, date) to authenticated;

-- The role a person effectively holds today: 'read_only' during a suspension.
create or replace function public.effective_app_role(p_user_id uuid default null, p_date date default null)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when exists (select 1 from public.staff st where st.user_id = coalesce(p_user_id, (select auth.uid())) and st.tenant_id = app.auth_tenant_id()
                          and public.is_staff_suspended(st.id, p_date)) then 'read_only'
           else (select au.app_role::text from public.app_user au where au.user_id = coalesce(p_user_id, (select auth.uid())) and au.tenant_id = app.auth_tenant_id())
         end;
$$;
revoke execute on function public.effective_app_role(uuid, date) from public, anon;
grant execute on function public.effective_app_role(uuid, date) to authenticated;

-- ── write path ────────────────────────────────────────────────────────────

create or replace function app.fn_disciplinary_staff_check(p_staff_id uuid)
returns public.staff
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_staff public.staff%rowtype;
begin
  if app.auth_role() not in ('hr_manager', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_staff from public.staff where id = p_staff_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() = 'principal' and not (v_staff.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return v_staff;
end;
$$;
revoke execute on function app.fn_disciplinary_staff_check(uuid) from public, anon, authenticated;

create or replace function public.issue_disciplinary_action(
  p_staff_id uuid, p_action_type public.disciplinary_action_type, p_description text,
  p_response_days smallint default null, p_suspend_from date default null, p_suspend_to date default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff public.staff%rowtype;
  v_id    uuid;
  v_today date := app.fn_karachi_today();
begin
  v_staff := app.fn_disciplinary_staff_check(p_staff_id);
  if p_action_type = 'termination' and app.auth_role() not in ('hr_manager', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_action_type = 'reinstatement' then
    raise exception 'USE_REINSTATE' using errcode = '22023';
  end if;
  if p_action_type = 'show_cause' and (p_response_days is null or p_response_days not between 1 and 60) then
    raise exception 'RESPONSE_DAYS_REQUIRED' using errcode = '22023';
  end if;
  if p_action_type = 'suspension' and (p_suspend_from is null or p_suspend_to is null or p_suspend_to < p_suspend_from) then
    raise exception 'SUSPENSION_DATES_INVALID' using errcode = '22023';
  end if;

  insert into public.staff_disciplinary (tenant_id, campus_id, staff_id, action_type, issued_on, issued_by, description, response_due_on)
  values (v_staff.tenant_id, v_staff.campus_id, p_staff_id, p_action_type, v_today, (select auth.uid()), btrim(p_description),
          case when p_action_type = 'show_cause' then v_today + p_response_days end)
  returning id into v_id;

  if p_action_type = 'suspension' then
    insert into public.staff_suspension (tenant_id, staff_id, from_date, to_date, disciplinary_id)
    values (v_staff.tenant_id, p_staff_id, p_suspend_from, p_suspend_to, v_id);
  end if;
  return v_id;
end;
$$;
revoke execute on function public.issue_disciplinary_action(uuid, public.disciplinary_action_type, text, smallint, date, date) from public, anon;
grant execute on function public.issue_disciplinary_action(uuid, public.disciplinary_action_type, text, smallint, date, date) to authenticated;

-- A correction, a staff response or an outcome: a NEW row referencing the row it replaces.
create or replace function public.supersede_disciplinary_record(
  p_supersedes_id uuid, p_description text default null, p_staff_response text default null, p_outcome text default null,
  p_suspend_from date default null, p_suspend_to date default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old   public.staff_disciplinary%rowtype;
  v_id    uuid;
  v_susp  public.staff_suspension%rowtype;
begin
  if app.auth_role() not in ('hr_manager', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_old from public.staff_disciplinary where id = p_supersedes_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'RECORD_NOT_FOUND' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.staff_disciplinary where supersedes_id = p_supersedes_id) then
    raise exception 'ALREADY_SUPERSEDED' using errcode = '23505';
  end if;
  if v_old.action_type = 'reinstatement' then
    raise exception 'RECORD_NOT_CORRECTABLE' using errcode = '22023';
  end if;
  if p_staff_response is not null and char_length(btrim(p_staff_response)) = 0 then
    raise exception 'RESPONSE_EMPTY' using errcode = '22023';
  end if;

  insert into public.staff_disciplinary (
    tenant_id, campus_id, staff_id, action_type, issued_on, issued_by, description, response_due_on,
    staff_response, responded_at, outcome, supersedes_id
  ) values (
    v_old.tenant_id, v_old.campus_id, v_old.staff_id, v_old.action_type, app.fn_karachi_today(), (select auth.uid()),
    coalesce(nullif(btrim(p_description), ''), v_old.description), v_old.response_due_on,
    case when p_staff_response is null then v_old.staff_response else btrim(p_staff_response) end,
    case when p_staff_response is null then v_old.responded_at else clock_timestamp() end,
    coalesce(nullif(btrim(p_outcome), ''), v_old.outcome), p_supersedes_id
  ) returning id into v_id;

  if v_old.action_type = 'suspension' then
    select * into v_susp from public.staff_suspension where disciplinary_id = p_supersedes_id;
    if found then
      insert into public.staff_suspension (tenant_id, staff_id, from_date, to_date, disciplinary_id)
      values (v_old.tenant_id, v_old.staff_id, coalesce(p_suspend_from, v_susp.from_date), coalesce(p_suspend_to, v_susp.to_date), v_id);
    end if;
  end if;
  return v_id;
end;
$$;
revoke execute on function public.supersede_disciplinary_record(uuid, text, text, text, date, date) from public, anon;
grant execute on function public.supersede_disciplinary_record(uuid, text, text, text, date, date) to authenticated;

-- Ends a suspension early: a 'reinstatement' row supersedes the suspension row.
create or replace function public.reinstate_suspended_staff(p_suspension_disciplinary_id uuid, p_note text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old public.staff_disciplinary%rowtype;
  v_id  uuid;
begin
  if app.auth_role() not in ('hr_manager', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_old from public.staff_disciplinary
   where id = p_suspension_disciplinary_id and tenant_id = app.auth_tenant_id() and action_type = 'suspension';
  if not found then
    raise exception 'RECORD_NOT_FOUND' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.staff_disciplinary where supersedes_id = p_suspension_disciplinary_id) then
    raise exception 'ALREADY_SUPERSEDED' using errcode = '23505';
  end if;
  insert into public.staff_disciplinary (tenant_id, campus_id, staff_id, action_type, issued_on, issued_by, description, supersedes_id)
  values (v_old.tenant_id, v_old.campus_id, v_old.staff_id, 'reinstatement', app.fn_karachi_today(), (select auth.uid()),
          coalesce(nullif(btrim(p_note), ''), 'Suspension lifted'), p_suspension_disciplinary_id)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.reinstate_suspended_staff(uuid, text) from public, anon;
grant execute on function public.reinstate_suspended_staff(uuid, text) to authenticated;

-- ── worklists ─────────────────────────────────────────────────────────────

-- Unanswered show-cause notices whose deadline day has arrived. Only the head
-- of a chain counts, so a correction that carries no response stays overdue and
-- a recorded response clears it.
create or replace function public.list_overdue_showcause(p_today date default null)
returns table (disciplinary_id uuid, staff_id uuid, employee_code text, staff_name text, issued_on date, response_due_on date, days_overdue integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := coalesce(p_today, app.fn_karachi_today());
begin
  if app.auth_role() not in ('hr_manager', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
    select d.id, d.staff_id, s.employee_code, s.full_name, d.issued_on, d.response_due_on, (v_today - d.response_due_on)::integer
      from public.staff_disciplinary d
      join public.staff s on s.id = d.staff_id
     where d.tenant_id = app.auth_tenant_id()
       and d.action_type = 'show_cause'
       and d.staff_response is null
       and d.response_due_on <= v_today
       and not exists (select 1 from public.staff_disciplinary succ where succ.supersedes_id = d.id)
     order by d.response_due_on, s.full_name;
end;
$$;
revoke execute on function public.list_overdue_showcause(date) from public, anon;
grant execute on function public.list_overdue_showcause(date) to authenticated;

create or replace function public.list_staff_disciplinary(p_staff_id uuid)
returns table (id uuid, action_type public.disciplinary_action_type, issued_on date, issued_by_name text, description text, response_due_on date,
               staff_response text, responded_at timestamptz, outcome text, supersedes_id uuid, created_at timestamptz, superseded boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('hr_manager', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
    select d.id, d.action_type, d.issued_on, u.full_name, d.description, d.response_due_on, d.staff_response, d.responded_at, d.outcome,
           d.supersedes_id, d.created_at, exists (select 1 from public.staff_disciplinary x where x.supersedes_id = d.id)
      from public.staff_disciplinary d
      left join public.app_user u on u.user_id = d.issued_by
     where d.staff_id = p_staff_id and d.tenant_id = app.auth_tenant_id()
     order by d.created_at, d.id;
end;
$$;
revoke execute on function public.list_staff_disciplinary(uuid) from public, anon;
grant execute on function public.list_staff_disciplinary(uuid) to authenticated;

-- Daily job (03:00 PKT): flag every overdue show-cause once.
create or replace function public.flag_overdue_showcause(p_today date default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := coalesce(p_today, app.fn_karachi_today());
  v_n integer;
begin
  insert into public.staff_showcause_overdue_flag (disciplinary_id, tenant_id, flagged_on)
  select d.id, d.tenant_id, v_today
    from public.staff_disciplinary d
   where d.action_type = 'show_cause' and d.staff_response is null and d.response_due_on <= v_today
     and not exists (select 1 from public.staff_disciplinary succ where succ.supersedes_id = d.id)
  on conflict (disciplinary_id) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.flag_overdue_showcause(date) from public, anon, authenticated;

-- 03:00 PKT = 22:00 UTC the day before.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('showcause-overdue', '0 22 * * *', 'select public.flag_overdue_showcause();');
  end if;
exception
  when others then null;
end;
$$;

-- ── suspension feeds the substitution engine ──────────────────────────────

create or replace function public.get_suspended_teachers(p_campus_id uuid, p_date date)
returns table (staff_user_id uuid, full_name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'hr_manager')
     or (app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
    select s.user_id, s.full_name
      from public.staff s
     where s.tenant_id = app.auth_tenant_id() and s.user_id is not null and s.campus_id = p_campus_id
       and public.is_staff_suspended(s.id, p_date)
     order by s.full_name;
end;
$$;
revoke execute on function public.get_suspended_teachers(uuid, date) from public, anon;
grant execute on function public.get_suspended_teachers(uuid, date) to authenticated;

-- Every published timetable period a suspended teacher would have taught on
-- each date in the range, with any substitution already arranged. Carries no
-- disciplinary detail - only that the teacher is unavailable.
create or replace function public.get_suspension_cover_feed(p_campus_id uuid, p_from date, p_to date)
returns table (sub_date date, staff_user_id uuid, staff_name text, slot_id uuid, period_no smallint, section_name text, subject_code text,
               substitution_id uuid, substitute_staff_id uuid, substitution_status public.substitution_status)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'hr_manager')
     or (app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_to < p_from or p_to - p_from > 92 then
    raise exception 'RANGE_INVALID' using errcode = '22023';
  end if;
  return query
    select d::date, s.user_id, s.full_name, ts.id, ts.period_no, cs.name, sj.code, sub.id, sub.substitute_staff_id, sub.status
      from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
      join public.staff s on s.tenant_id = app.auth_tenant_id() and s.campus_id = p_campus_id and s.user_id is not null
      join public.timetable_slot ts on ts.staff_id = s.user_id and ts.campus_id = p_campus_id and ts.weekday = extract(dow from d)::smallint
      join public.timetable_version tv on tv.id = ts.timetable_version_id and tv.status = 'PUBLISHED' and tv.validity @> d::date
      join public.class_section cs on cs.id = ts.section_id
      join public.subject sj on sj.id = ts.subject_id
      left join public.timetable_substitution sub on sub.slot_id = ts.id and sub.sub_date = d::date
     where public.is_staff_suspended(s.id, d::date)
     order by d::date, ts.period_no, s.full_name;
end;
$$;
revoke execute on function public.get_suspension_cover_feed(uuid, date, date) from public, anon;
grant execute on function public.get_suspension_cover_feed(uuid, date, date) to authenticated;
