-- ═══════════════════════════════════════════════════════════════════════
-- Migration: 20260801310000_payroll_config_and_attendance_deduction.sql
-- FR-L04: Attendance-linked salary deduction & campus payroll configuration
--
-- Provides campus-level payroll rules (payable day basis, late marks per absence,
-- net pay floor), and functions to compute unpaid absence days and corresponding
-- salary deductions from staff attendance and approved leaves.
-- ═══════════════════════════════════════════════════════════════════════

create table public.payroll_config (
  campus_id              uuid primary key references public.campus(id) on delete cascade,
  tenant_id              uuid not null references public.tenant(id) on delete cascade,
  payable_day_basis      text not null default 'fixed_26' check (payable_day_basis in ('calendar', 'working', 'fixed_26')),
  late_marks_per_absence int not null default 3 check (late_marks_per_absence >= 1),
  net_pay_floor_pct      numeric(5, 2) not null default 0 check (net_pay_floor_pct >= 0 and net_pay_floor_pct <= 100),
  updated_by             uuid references auth.users(id),
  updated_at             timestamptz not null default now()
);

create trigger payroll_config_audit after insert or update or delete on public.payroll_config
  for each row execute function app.tg_audit_row();

-- RLS
alter table public.payroll_config enable row level security;

create policy payroll_config_read on public.payroll_config
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
  );

create policy payroll_config_write on public.payroll_config
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'hr_manager')
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'hr_manager')
  );

-- Auto-seed payroll_config when a campus is created
create or replace function app.tg_seed_campus_payroll_config()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.payroll_config (campus_id, tenant_id)
  values (NEW.id, NEW.tenant_id)
  on conflict (campus_id) do nothing;
  return NEW;
end;
$$;

create trigger campus_seed_payroll_config after insert on public.campus
  for each row execute function app.tg_seed_campus_payroll_config();

-- Populate payroll_config for any existing campuses
insert into public.payroll_config (campus_id, tenant_id)
select id, tenant_id from public.campus
on conflict (campus_id) do nothing;

-- Function to compute unpaid absence days for a staff member in a period
create or replace function public.fn_unpaid_days(
  p_staff_id     uuid,
  p_period_start date,
  p_period_end   date
)
returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_campus_id            uuid;
  v_late_per_absence     int := 3;
  v_absent_count         int := 0;
  v_half_day_count       int := 0;
  v_late_count           int := 0;
  v_unpaid_leave_days    numeric := 0;
  v_unpaid_days          numeric := 0;
begin
  select campus_id into v_campus_id from public.staff where id = p_staff_id;
  if v_campus_id is null then
    return 0;
  end if;

  select late_marks_per_absence into v_late_per_absence
  from public.payroll_config
  where campus_id = v_campus_id;
  v_late_per_absence := coalesce(v_late_per_absence, 3);

  -- 1. Tally staff attendance records (excluding those covered by approved paid leave)
  select
    count(*) filter (where sa.status = 'absent' and not exists (
      select 1 from public.leave_application la
      join public.leave_type lt on lt.id = la.leave_type_id
      where la.staff_id = p_staff_id
        and la.status = 'approved'
        and lt.is_paid = true
        and sa.att_date between la.from_date and la.to_date
    )),
    count(*) filter (where sa.status = 'half_day' and not exists (
      select 1 from public.leave_application la
      join public.leave_type lt on lt.id = la.leave_type_id
      where la.staff_id = p_staff_id
        and la.status = 'approved'
        and lt.is_paid = true
        and sa.att_date between la.from_date and la.to_date
    )),
    count(*) filter (where sa.status = 'late')
  into v_absent_count, v_half_day_count, v_late_count
  from public.staff_attendance sa
  where sa.staff_id = p_staff_id
    and sa.att_date between p_period_start and p_period_end;

  -- 2. Tally approved unpaid leave applications that fall within the period
  select coalesce(sum(la.working_days), 0)
  into v_unpaid_leave_days
  from public.leave_application la
  join public.leave_type lt on lt.id = la.leave_type_id
  where la.staff_id = p_staff_id
    and la.status = 'approved'
    and lt.is_paid = false
    and la.from_date <= p_period_end
    and la.to_date >= p_period_start;

  -- Compute total unpaid days
  v_unpaid_days := v_absent_count
                 + (v_half_day_count * 0.5)
                 + (floor(v_late_count / v_late_per_absence))
                 + v_unpaid_leave_days;

  return round(v_unpaid_days, 2);
end;
$$;

revoke execute on function public.fn_unpaid_days(uuid, date, date) from public, anon;
grant  execute on function public.fn_unpaid_days(uuid, date, date) to authenticated;

-- Function to calculate the monetary deduction for attendance absences
create or replace function public.fn_attendance_deduction_paisa(
  p_staff_id     uuid,
  p_basic_paisa  bigint,
  p_period_start date,
  p_period_end   date,
  p_payable_days numeric default 26
)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_unpaid_days numeric;
  v_basis_days  numeric := coalesce(p_payable_days, 26);
begin
  if v_basis_days <= 0 or coalesce(p_basic_paisa, 0) <= 0 then
    return 0;
  end if;

  v_unpaid_days := public.fn_unpaid_days(p_staff_id, p_period_start, p_period_end);
  if v_unpaid_days <= 0 then
    return 0;
  end if;

  return round((p_basic_paisa::numeric * v_unpaid_days) / v_basis_days)::bigint;
end;
$$;

revoke execute on function public.fn_attendance_deduction_paisa(uuid, bigint, date, date, numeric) from public, anon;
grant  execute on function public.fn_attendance_deduction_paisa(uuid, bigint, date, date, numeric) to authenticated;
