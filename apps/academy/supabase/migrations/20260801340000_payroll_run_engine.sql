-- ═══════════════════════════════════════════════════════════════════════
-- Migration: 20260801340000_payroll_run_engine.sql
-- FR-L06 + FR-L07: Monthly payroll run generation, review, approval & lock
--
-- Implements end-to-end payroll computation, line component breakdown,
-- salary adjustments, role-gated approval workflow, and immutable run locking.
-- ═══════════════════════════════════════════════════════════════════════

create type public.payroll_run_status as enum (
  'draft',
  'pending_approval',
  'locked',
  'paid',
  'cancelled'
);

create table public.payroll_run (
  id                     uuid primary key default gen_random_uuid(),
  tenant_id              uuid not null references public.tenant(id) on delete cascade,
  campus_id              uuid not null references public.campus(id) on delete cascade,
  period_month           date not null, -- always 1st day of month
  status                 public.payroll_run_status not null default 'draft',
  total_gross_paisa      bigint not null default 0 check (total_gross_paisa >= 0),
  total_deductions_paisa bigint not null default 0 check (total_deductions_paisa >= 0),
  total_net_paisa        bigint not null default 0 check (total_net_paisa >= 0),
  employee_count         int not null default 0 check (employee_count >= 0),
  generated_by           uuid references auth.users(id),
  generated_at           timestamptz not null default now(),
  approved_by            uuid references auth.users(id),
  approved_at            timestamptz,
  locked_by              uuid references auth.users(id),
  locked_at              timestamptz,
  unique (campus_id, period_month)
);

create index idx_payroll_run_campus_period on public.payroll_run (campus_id, period_month);
create index idx_payroll_run_status on public.payroll_run (status);

create table public.payroll_run_line (
  id                         uuid primary key default gen_random_uuid(),
  payroll_run_id             uuid not null references public.payroll_run(id) on delete cascade,
  staff_id                   uuid not null references public.staff(id) on delete cascade,
  basic_paisa                bigint not null check (basic_paisa >= 0),
  gross_paisa                bigint not null check (gross_paisa >= 0),
  attendance_deduction_paisa bigint not null default 0 check (attendance_deduction_paisa >= 0),
  tax_withholding_paisa      bigint not null default 0 check (tax_withholding_paisa >= 0),
  loan_recovery_paisa        bigint not null default 0 check (loan_recovery_paisa >= 0),
  other_deductions_paisa     bigint not null default 0 check (other_deductions_paisa >= 0),
  net_paisa                  bigint not null check (net_paisa >= 0),
  unpaid_days                numeric(5, 2) not null default 0,
  payable_days               numeric(5, 2) not null default 26,
  status                     text not null default 'calculated' check (status in ('calculated', 'adjusted', 'flagged')),
  unique (payroll_run_id, staff_id)
);

create index idx_payroll_run_line_run on public.payroll_run_line (payroll_run_id);
create index idx_payroll_run_line_staff on public.payroll_run_line (staff_id);

create table public.payroll_run_line_component (
  id             uuid primary key default gen_random_uuid(),
  line_id        uuid not null references public.payroll_run_line(id) on delete cascade,
  component_id   uuid references public.salary_component(id),
  code           text not null,
  name_en        text not null,
  component_type text not null check (component_type in ('earning', 'deduction', 'employer_contribution')),
  amount_paisa   bigint not null default 0 check (amount_paisa >= 0),
  is_taxable     boolean not null default true
);

create index idx_payroll_line_comp_line on public.payroll_run_line_component (line_id);

create table public.payroll_adjustment (
  id              uuid primary key default gen_random_uuid(),
  line_id         uuid not null references public.payroll_run_line(id) on delete cascade,
  adjustment_type text not null check (adjustment_type in ('bonus', 'incentive', 'arrear', 'special_deduction', 'penalty')),
  amount_paisa    bigint not null,
  reason          text not null,
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now()
);

create index idx_payroll_adjustment_line on public.payroll_adjustment (line_id);

-- Audit triggers
create trigger payroll_run_audit after insert or update or delete on public.payroll_run
  for each row execute function app.tg_audit_row();

create trigger payroll_run_line_audit after insert or update or delete on public.payroll_run_line
  for each row execute function app.tg_audit_row();

create trigger payroll_adjustment_audit after insert or update or delete on public.payroll_adjustment
  for each row execute function app.tg_audit_row();

-- RLS
alter table public.payroll_run enable row level security;
alter table public.payroll_run_line enable row level security;
alter table public.payroll_run_line_component enable row level security;
alter table public.payroll_adjustment enable row level security;

create policy payroll_run_read on public.payroll_run
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
      or campus_id = any(app.auth_campus_ids())
    )
  );

create policy payroll_run_write on public.payroll_run
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
  );

create policy payroll_run_line_read on public.payroll_run_line
  for select to authenticated
  using (
    exists (
      select 1 from public.payroll_run r
      where r.id = payroll_run_id
        and r.tenant_id = app.auth_tenant_id()
        and (
          app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
          or r.campus_id = any(app.auth_campus_ids())
          or exists (select 1 from public.staff s where s.id = staff_id and s.user_id = auth.uid())
        )
    )
  );

create policy payroll_run_line_write on public.payroll_run_line
  for all to authenticated
  using (
    exists (
      select 1 from public.payroll_run r
      where r.id = payroll_run_id
        and r.tenant_id = app.auth_tenant_id()
        and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
    )
  )
  with check (
    exists (
      select 1 from public.payroll_run r
      where r.id = payroll_run_id
        and r.tenant_id = app.auth_tenant_id()
        and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
    )
  );

create policy payroll_line_comp_read on public.payroll_run_line_component
  for select to authenticated
  using (
    exists (
      select 1 from public.payroll_run_line l
      join public.payroll_run r on r.id = l.payroll_run_id
      where l.id = line_id
        and r.tenant_id = app.auth_tenant_id()
        and (
          app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
          or r.campus_id = any(app.auth_campus_ids())
          or exists (select 1 from public.staff s where s.id = l.staff_id and s.user_id = auth.uid())
        )
    )
  );

create policy payroll_line_comp_write on public.payroll_run_line_component
  for all to authenticated
  using (
    exists (
      select 1 from public.payroll_run_line l
      join public.payroll_run r on r.id = l.payroll_run_id
      where l.id = line_id
        and r.tenant_id = app.auth_tenant_id()
        and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
    )
  )
  with check (
    exists (
      select 1 from public.payroll_run_line l
      join public.payroll_run r on r.id = l.payroll_run_id
      where l.id = line_id
        and r.tenant_id = app.auth_tenant_id()
        and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
    )
  );

create policy payroll_adj_read on public.payroll_adjustment
  for select to authenticated
  using (
    exists (
      select 1 from public.payroll_run_line l
      join public.payroll_run r on r.id = l.payroll_run_id
      where l.id = line_id
        and r.tenant_id = app.auth_tenant_id()
        and (
          app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
          or r.campus_id = any(app.auth_campus_ids())
          or exists (select 1 from public.staff s where s.id = l.staff_id and s.user_id = auth.uid())
        )
    )
  );

create policy payroll_adj_write on public.payroll_adjustment
  for all to authenticated
  using (
    exists (
      select 1 from public.payroll_run_line l
      join public.payroll_run r on r.id = l.payroll_run_id
      where l.id = line_id
        and r.tenant_id = app.auth_tenant_id()
        and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
    )
  )
  with check (
    exists (
      select 1 from public.payroll_run_line l
      join public.payroll_run r on r.id = l.payroll_run_id
      where l.id = line_id
        and r.tenant_id = app.auth_tenant_id()
        and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
    )
  );

-- Immutability guard trigger: Prevents editing lines/adjustments on locked or paid runs
create or replace function public.fn_tg_guard_payroll_immutability()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.payroll_run_status;
begin
  if TG_TABLE_NAME = 'payroll_run' then
    if OLD.status in ('locked', 'paid') then
      -- Allow status change from locked -> paid
      if TG_OP = 'UPDATE' and OLD.status = 'locked' and NEW.status = 'paid' then
        return NEW;
      end if;
      raise exception 'PAYROLL_RUN_LOCKED: Cannot modify a locked or paid payroll run'
        using errcode = 'P0001';
    end if;
    return NEW;
  elsif TG_TABLE_NAME = 'payroll_run_line' then
    select status into v_status from public.payroll_run
    where id = coalesce(NEW.payroll_run_id, OLD.payroll_run_id);
    if v_status in ('locked', 'paid') then
      raise exception 'PAYROLL_RUN_LOCKED: Cannot modify lines of a locked or paid payroll run'
        using errcode = 'P0001';
    end if;
    return coalesce(NEW, OLD);
  elsif TG_TABLE_NAME in ('payroll_run_line_component', 'payroll_adjustment') then
    select r.status into v_status
    from public.payroll_run_line l
    join public.payroll_run r on r.id = l.payroll_run_id
    where l.id = coalesce(NEW.line_id, OLD.line_id);
    if v_status in ('locked', 'paid') then
      raise exception 'PAYROLL_RUN_LOCKED: Cannot modify components/adjustments of a locked or paid payroll run'
        using errcode = 'P0001';
    end if;
    return coalesce(NEW, OLD);
  end if;

  return coalesce(NEW, OLD);
end;
$$;

create trigger trg_payroll_run_immutability
  before update or delete on public.payroll_run
  for each row execute function public.fn_tg_guard_payroll_immutability();

create trigger trg_payroll_line_immutability
  before update or delete on public.payroll_run_line
  for each row execute function public.fn_tg_guard_payroll_immutability();

create trigger trg_payroll_comp_immutability
  before insert or update or delete on public.payroll_run_line_component
  for each row execute function public.fn_tg_guard_payroll_immutability();

create trigger trg_payroll_adj_immutability
  before insert or update or delete on public.payroll_adjustment
  for each row execute function public.fn_tg_guard_payroll_immutability();

-- ─────────────────────────────────────────────────────────────────────────────
-- Core Engine: Generate or recalculate a monthly payroll run
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.generate_payroll_run(
  p_campus_id   uuid,
  p_period_date date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id       uuid;
  v_period_month    date;
  v_period_end      date;
  v_run_id          uuid;
  v_run_status      public.payroll_run_status;
  v_cfg             record;
  v_payable_basis   numeric := 26;
  v_staff           record;
  v_structure       public.employee_salary_structure;
  v_unpaid_days     numeric := 0;
  v_basic           bigint := 0;
  v_gross           bigint := 0;
  v_att_ded         bigint := 0;
  v_taxable         bigint := 0;
  v_tax             bigint := 0;
  v_loan_rec        bigint := 0;
  v_other_ded       bigint := 0;
  v_net             bigint := 0;
  v_min_net         bigint := 0;
  v_line_id         uuid;
  v_comp            record;
  v_tot_gross       bigint := 0;
  v_tot_ded         bigint := 0;
  v_tot_net         bigint := 0;
  v_count           int := 0;
begin
  select tenant_id into v_tenant_id from public.campus where id = p_campus_id;
  if v_tenant_id is null then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Normalize to first day and last day of month
  v_period_month := date_trunc('month', p_period_date)::date;
  v_period_end   := (date_trunc('month', p_period_date) + interval '1 month - 1 day')::date;

  -- Acquire transaction-level lock to prevent concurrent generation races
  perform pg_advisory_xact_lock(hashtext('generate_payroll_run:' || p_campus_id::text || ':' || v_period_month::text));

  -- Check if a run already exists
  select id, status into v_run_id, v_run_status
  from public.payroll_run
  where campus_id = p_campus_id and period_month = v_period_month;

  if v_run_id is not null then
    if v_run_status in ('locked', 'paid') then
      raise exception 'PAYROLL_RUN_ALREADY_LOCKED' using errcode = 'P0001';
    end if;

    -- Clean up previous draft line items & recoveries
    delete from public.staff_loan_recovery where payroll_run_id = v_run_id;
    delete from public.payroll_run_line where payroll_run_id = v_run_id;
  else
    insert into public.payroll_run (
      tenant_id, campus_id, period_month, status, generated_by
    ) values (
      v_tenant_id, p_campus_id, v_period_month, 'draft', auth.uid()
    )
    returning id into v_run_id;
  end if;

  -- Read campus payroll configuration
  select payable_day_basis, net_pay_floor_pct
  into v_cfg
  from public.payroll_config
  where campus_id = p_campus_id;

  if v_cfg.payable_day_basis = 'calendar' then
    v_payable_basis := extract(day from v_period_end);
  elsif v_cfg.payable_day_basis = 'working' then
    v_payable_basis := 22;
  else
    v_payable_basis := 26;
  end if;

  -- Ensure default salary components exist
  perform public.seed_default_salary_components(v_tenant_id);

  -- Iterate through active staff in this campus
  for v_staff in
    select s.id, s.employee_code, s.full_name
    from public.staff s
    where s.campus_id = p_campus_id
      and s.employment_status = 'active'
    order by s.employee_code
  loop
    v_basic     := 0;
    v_gross     := 0;
    v_taxable   := 0;
    v_other_ded := 0;

    -- Unpaid absence days
    v_unpaid_days := public.fn_unpaid_days(v_staff.id, v_period_month, v_period_end);

    -- Active salary structure
    select * into v_structure
    from public.fn_active_salary_structure(v_staff.id, v_period_end);

    if v_structure.id is not null then
      v_basic := v_structure.basic_paisa;
    end if;

    -- Attendance deduction on basic
    v_att_ded := public.fn_attendance_deduction_paisa(
      v_staff.id, v_basic, v_period_month, v_period_end, v_payable_basis
    );

    -- Calculate all components
    for v_comp in
      select * from public.fn_salary_for_period(
        v_staff.id, v_period_month, v_period_end, v_payable_basis, v_unpaid_days
      )
    loop
      if v_comp.component_type = 'earning' then
        v_gross := v_gross + v_comp.amount_paisa;
        if v_comp.is_taxable then
          v_taxable := v_taxable + v_comp.taxable_paisa;
        end if;
      elsif v_comp.component_type = 'deduction' then
        v_other_ded := v_other_ded + v_comp.amount_paisa;
      end if;
    end loop;

    -- Monthly withholding tax on taxable income
    v_tax := public.fn_monthly_withholding_paisa(v_staff.id, v_taxable);

    -- Accrue loan recovery
    v_loan_rec := public.fn_accrue_loan_recovery(v_run_id, v_staff.id, v_period_month);

    -- Net pay calculation
    v_net := v_gross - (v_att_ded + v_tax + v_loan_rec + v_other_ded);

    -- Apply floor if configured
    if coalesce(v_cfg.net_pay_floor_pct, 0) > 0 and v_gross > 0 then
      v_min_net := round((v_gross::numeric * v_cfg.net_pay_floor_pct) / 100.0)::bigint;
      v_net := greatest(v_net, v_min_net);
    else
      v_net := greatest(0, v_net);
    end if;

    -- Insert payroll run line
    insert into public.payroll_run_line (
      payroll_run_id,
      staff_id,
      basic_paisa,
      gross_paisa,
      attendance_deduction_paisa,
      tax_withholding_paisa,
      loan_recovery_paisa,
      other_deductions_paisa,
      net_paisa,
      unpaid_days,
      payable_days,
      status
    ) values (
      v_run_id,
      v_staff.id,
      v_basic,
      v_gross,
      v_att_ded,
      v_tax,
      v_loan_rec,
      v_other_ded,
      v_net,
      v_unpaid_days,
      v_payable_basis,
      'calculated'
    )
    returning id into v_line_id;

    -- Insert line component breakdown
    for v_comp in
      select * from public.fn_salary_for_period(
        v_staff.id, v_period_month, v_period_end, v_payable_basis, v_unpaid_days
      )
    loop
      insert into public.payroll_run_line_component (
        line_id, component_id, code, name_en, component_type, amount_paisa, is_taxable
      ) values (
        v_line_id, v_comp.component_id, v_comp.code, v_comp.name_en, v_comp.component_type::text, v_comp.amount_paisa, v_comp.is_taxable
      );
    end loop;

    -- Accumulate run totals
    v_tot_gross := v_tot_gross + v_gross;
    v_tot_ded   := v_tot_ded + (v_att_ded + v_tax + v_loan_rec + v_other_ded);
    v_tot_net   := v_tot_net + v_net;
    v_count     := v_count + 1;
  end loop;

  -- Update run summary totals
  update public.payroll_run
  set
    total_gross_paisa      = v_tot_gross,
    total_deductions_paisa = v_tot_ded,
    total_net_paisa        = v_tot_net,
    employee_count         = v_count,
    generated_at           = now()
  where id = v_run_id;

  return v_run_id;
end;
$$;

revoke execute on function public.generate_payroll_run(uuid, date) from public, anon;
grant  execute on function public.generate_payroll_run(uuid, date) to authenticated;

-- Workflow functions
create or replace function public.fn_submit_payroll_for_approval(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if current_user <> 'postgres' and app.auth_role() not in ('super_admin', 'owner', 'hr_manager', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.payroll_run
  set status = 'pending_approval'
  where id = p_run_id and status = 'draft';

  if not found then
    raise exception 'RUN_NOT_FOUND_OR_NOT_DRAFT' using errcode = 'P0002';
  end if;
end;
$$;

create or replace function public.fn_approve_payroll_run(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if current_user <> 'postgres' and app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.payroll_run
  set
    approved_by = auth.uid(),
    approved_at = now()
  where id = p_run_id and status = 'pending_approval';

  if not found then
    raise exception 'RUN_NOT_FOUND_OR_NOT_PENDING' using errcode = 'P0002';
  end if;
end;
$$;

create or replace function public.fn_lock_payroll_run(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if current_user <> 'postgres' and app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.payroll_run
  set
    status = 'locked',
    locked_by = auth.uid(),
    locked_at = now()
  where id = p_run_id and status in ('draft', 'pending_approval');

  if not found then
    raise exception 'RUN_CANNOT_BE_LOCKED' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function public.fn_submit_payroll_for_approval(uuid) from public, anon;
grant  execute on function public.fn_submit_payroll_for_approval(uuid) to authenticated;
revoke execute on function public.fn_approve_payroll_run(uuid) from public, anon;
grant  execute on function public.fn_approve_payroll_run(uuid) to authenticated;
revoke execute on function public.fn_lock_payroll_run(uuid) from public, anon;
grant  execute on function public.fn_lock_payroll_run(uuid) to authenticated;
