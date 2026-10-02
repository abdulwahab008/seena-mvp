-- FR-D10 (leave balance ledger) and FR-D11 (leave application with atomic
-- hold), shipped together: D11's own AC requires a real balance to check
-- against, so D10 has to exist first, and nothing exercises D10 without a
-- caller like D11's apply_for_leave().
--
-- Scope cuts:
--   * FR-D12 (multi-step escalating approval chain) is NOT built here.
--     fn_decide_leave_application is a single-step Principal/HR/Owner
--     approve-or-reject — no leave_approval_chain, no SLA escalation, no
--     self-approval skip rule. It still does the two things D11's own AC
--     actually needs proven: the hold reverses atomically on rejection,
--     and approval writes staff_attendance rows. The full chain is
--     substantial enough (escalation cron, self-approval routing) to be
--     its own batch.
--   * FR-D07 (manual daily attendance marking) is NOT built — no
--     mark_staff_attendance_bulk(), no LEAVE_LOCKED guard against
--     overwriting a leave-sourced row. staff_attendance exists (D11's
--     approval path needs somewhere to write on-leave rows to) with the
--     shape D07 will need, but the bulk-marking screen and its source-
--     precedence enforcement (leave > biometric > manual) are deferred to
--     when D07 is actually built.
--   * D10's "accrual" (monthly_accrual running automatically) has no
--     cron locally — fn_grant_leave_balance is a manual/on-demand grant,
--     callable by whatever eventually drives an accrual schedule.

create type public.leave_ledger_entry_type as enum (
  'grant', 'accrual', 'hold', 'hold_release', 'consumption', 'encashment', 'carry_forward'
);

-- Append-only: the balance is always sum(days), never a mutable column —
-- the same reasoning as gr_ledger (FR-C01) and audit_log, so "why is my
-- balance wrong" always has an inspectable trail.
create table public.leave_ledger (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  staff_id      uuid not null references public.staff(id) on delete cascade,
  leave_type_id uuid not null references public.leave_type(id),
  entry_type    public.leave_ledger_entry_type not null,
  -- Positive for grant/accrual/hold_release/carry_forward, negative for
  -- hold/consumption/encashment.
  days          numeric(5, 2) not null,
  reference_id  uuid,
  created_at    timestamptz not null default now(),
  created_by    uuid references public.app_user(user_id)
);

create index idx_leave_ledger_staff_type on public.leave_ledger (staff_id, leave_type_id, created_at);

create or replace function public.fn_leave_balance(p_staff_id uuid, p_leave_type_id uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(days), 0) from public.leave_ledger where staff_id = p_staff_id and leave_type_id = p_leave_type_id;
$$;

revoke execute on function public.fn_leave_balance(uuid, uuid) from public, anon;
grant execute on function public.fn_leave_balance(uuid, uuid) to authenticated;

create or replace function public.fn_grant_leave_balance(p_staff_id uuid, p_leave_type_id uuid, p_days numeric, p_entry_type public.leave_ledger_entry_type default 'grant')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id into v_tenant_id from public.staff where id = p_staff_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, created_by)
  values (v_tenant_id, p_staff_id, p_leave_type_id, p_entry_type, p_days, auth.uid());
end;
$$;

revoke execute on function public.fn_grant_leave_balance(uuid, uuid, numeric, public.leave_ledger_entry_type) from public, anon;
grant execute on function public.fn_grant_leave_balance(uuid, uuid, numeric, public.leave_ledger_entry_type) to authenticated;

alter table public.leave_ledger enable row level security;

create policy leave_ledger_self_or_hr_read on public.leave_ledger
  for select to authenticated
  using (
    app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager')
    or exists (select 1 from public.staff s where s.id = leave_ledger.staff_id and s.user_id = auth.uid())
  );

-- ── D11: holiday_calendar, staff_attendance, leave_application ────────

create table public.holiday_calendar (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid references public.campus(id) on delete cascade, -- null = tenant-wide
  holiday_date date not null,
  name         text not null
);

create index idx_holiday_calendar_tenant_date on public.holiday_calendar (tenant_id, holiday_date);

create or replace function public.add_holiday(p_holiday_date date, p_name text, p_campus_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.holiday_calendar (tenant_id, campus_id, holiday_date, name)
  values (app.auth_tenant_id(), p_campus_id, p_holiday_date, p_name)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.add_holiday(date, text, uuid) from public, anon;
grant execute on function public.add_holiday(date, text, uuid) to authenticated;

-- Eid, Ashura and public holidays are announced by moon sighting days in
-- advance and cannot be hardcoded — this always reads the live calendar,
-- never a static weekday/holiday table.
create or replace function public.working_days_between(p_campus_id uuid, p_from date, p_to date)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::numeric
    from generate_series(p_from, p_to, interval '1 day') as d(day)
   where extract(dow from d.day) <> 0 -- Sunday is the weekly off day
     and not exists (
       select 1 from public.holiday_calendar h
        where h.holiday_date = d.day::date
          and h.tenant_id = app.auth_tenant_id()
          and (h.campus_id = p_campus_id or h.campus_id is null)
     );
$$;

revoke execute on function public.working_days_between(uuid, date, date) from public, anon;
grant execute on function public.working_days_between(uuid, date, date) to authenticated;

create type public.attendance_status as enum ('present', 'absent', 'on_leave', 'half_day', 'late');
create type public.attendance_source as enum ('manual', 'biometric', 'leave');

create table public.staff_attendance (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant(id) on delete cascade,
  campus_id uuid not null references public.campus(id) on delete cascade,
  staff_id  uuid not null references public.staff(id) on delete cascade,
  att_date  date not null,
  status    public.attendance_status not null,
  source    public.attendance_source not null default 'manual',
  marked_by uuid references public.app_user(user_id),
  remarks   text,
  marked_at timestamptz not null default now(),
  unique (staff_id, att_date)
);

create index idx_staff_attendance_campus_date on public.staff_attendance (campus_id, att_date);
create index idx_staff_attendance_staff_date on public.staff_attendance (staff_id, att_date);

alter table public.staff_attendance enable row level security;

create policy staff_attendance_campus_scope on public.staff_attendance
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())
      or exists (select 1 from public.staff s where s.id = staff_attendance.staff_id and s.user_id = auth.uid())
    )
  );

create type public.leave_application_status as enum ('pending', 'approved', 'rejected', 'cancelled');

create table public.leave_application (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  staff_id         uuid not null references public.staff(id) on delete cascade,
  leave_type_id    uuid not null references public.leave_type(id),
  from_date        date not null,
  to_date          date not null,
  is_half_day      boolean not null default false,
  working_days     numeric(5, 2) not null,
  reason           text,
  status           public.leave_application_status not null default 'pending',
  decided_by       uuid references public.app_user(user_id),
  decided_at       timestamptz,
  decision_comment text,
  submitted_at     timestamptz not null default now(),
  constraint chk_leave_dates check (to_date >= from_date)
);

create index idx_leave_app_staff_status on public.leave_application (staff_id, status);
create index idx_leave_app_campus_daterange on public.leave_application (campus_id, from_date, to_date);

create trigger leave_application_audit after insert or update or delete on public.leave_application
  for each row execute function app.tg_audit_row();

create or replace function public.apply_for_leave(
  p_staff_id      uuid,
  p_leave_type_id uuid,
  p_from_date     date,
  p_to_date       date,
  p_is_half_day   boolean default false,
  p_reason        text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff        public.staff%rowtype;
  v_working_days numeric;
  v_balance      numeric;
  v_app_id       uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager')
     and not exists (select 1 from public.staff where id = p_staff_id and user_id = auth.uid()) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_staff from public.staff where id = p_staff_id;
  if not found then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- The canonical race is two browser tabs against one balance — this
  -- lock serialises concurrent applications for the same (staff, leave
  -- type) pair so the balance check below is never stale by the time the
  -- hold is inserted.
  perform pg_advisory_xact_lock(hashtextextended(p_staff_id::text || p_leave_type_id::text, 0));

  if p_is_half_day then
    v_working_days := 0.5;
  else
    v_working_days := public.working_days_between(v_staff.campus_id, p_from_date, p_to_date);
  end if;

  v_balance := public.fn_leave_balance(p_staff_id, p_leave_type_id);
  if v_working_days > v_balance then
    raise exception 'INSUFFICIENT_BALANCE'
      using errcode = '23514', detail = format('available=%s requested=%s', v_balance, v_working_days);
  end if;

  insert into public.leave_application (
    tenant_id, campus_id, staff_id, leave_type_id, from_date, to_date, is_half_day, working_days, reason
  ) values (
    v_staff.tenant_id, v_staff.campus_id, p_staff_id, p_leave_type_id, p_from_date, p_to_date, p_is_half_day, v_working_days, p_reason
  )
  returning id into v_app_id;

  insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
  values (v_staff.tenant_id, p_staff_id, p_leave_type_id, 'hold', -v_working_days, v_app_id, auth.uid());

  return v_app_id;
end;
$$;

revoke execute on function public.apply_for_leave(uuid, uuid, date, date, boolean, text) from public, anon;
grant execute on function public.apply_for_leave(uuid, uuid, date, date, boolean, text) to authenticated;

-- Single-step stand-in for the full FR-D12 approval chain — see the
-- migration header for exactly what's deferred.
create or replace function public.fn_decide_leave_application(
  p_application_id uuid, p_decision public.leave_application_status, p_comment text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app public.leave_application%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'INVALID_DECISION' using errcode = '22023';
  end if;

  select * into v_app from public.leave_application where id = p_application_id and status = 'pending';
  if not found then
    raise exception 'APPLICATION_NOT_PENDING' using errcode = '55000';
  end if;

  update public.leave_application
     set status = p_decision, decided_by = auth.uid(), decided_at = now(), decision_comment = p_comment
   where id = p_application_id;

  if p_decision = 'approved' then
    insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
    values (v_app.tenant_id, v_app.staff_id, v_app.leave_type_id, 'hold_release', v_app.working_days, p_application_id, auth.uid());
    insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
    values (v_app.tenant_id, v_app.staff_id, v_app.leave_type_id, 'consumption', -v_app.working_days, p_application_id, auth.uid());

    insert into public.staff_attendance (tenant_id, campus_id, staff_id, att_date, status, source, marked_by)
    select v_app.tenant_id, v_app.campus_id, v_app.staff_id, d::date,
           case when v_app.is_half_day then 'half_day'::public.attendance_status else 'on_leave'::public.attendance_status end,
           'leave', auth.uid()
      from generate_series(v_app.from_date, v_app.to_date, interval '1 day') as d
    on conflict (staff_id, att_date) do update set status = excluded.status, source = 'leave';
  else
    -- Reversed in the same transaction as the rejection — a rejected
    -- application must never permanently eat a teacher's balance.
    insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
    values (v_app.tenant_id, v_app.staff_id, v_app.leave_type_id, 'hold_release', v_app.working_days, p_application_id, auth.uid());
  end if;
end;
$$;

revoke execute on function public.fn_decide_leave_application(uuid, public.leave_application_status, text) from public, anon;
grant execute on function public.fn_decide_leave_application(uuid, public.leave_application_status, text) to authenticated;

alter table public.leave_application enable row level security;

create policy leave_app_self_or_approver_read on public.leave_application
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager')
      or exists (select 1 from public.staff s where s.id = leave_application.staff_id and s.user_id = auth.uid())
    )
  );
