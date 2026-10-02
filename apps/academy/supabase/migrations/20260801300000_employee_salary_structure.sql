-- ═══════════════════════════════════════════════════════════════════════
-- Migration: 20260801300000_employee_salary_structure.sql
-- FR-L02: Effective-dated salary structure per employee
--
-- Tracks salary structure revisions over time without overwriting history,
-- enforces non-overlapping date ranges per staff member via GiST exclusion,
-- and provides arrears tracking and period component evaluation.
-- ═══════════════════════════════════════════════════════════════════════

create extension if not exists btree_gist;

create table public.employee_salary_structure (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  campus_id           uuid not null references public.campus(id) on delete cascade,
  staff_id            uuid not null references public.staff(id) on delete cascade,
  validity            daterange not null,
  basic_paisa         bigint not null check (basic_paisa >= 0),
  component_overrides jsonb not null default '{}'::jsonb,
  approved_by         uuid references auth.users(id),
  approved_at         timestamptz,
  created_at          timestamptz not null default now(),
  created_by          uuid references auth.users(id),
  constraint ex_salary_structure_no_overlap
    exclude using gist (staff_id with =, validity with &&)
);

create index idx_salary_structure_staff_validity
  on public.employee_salary_structure using gist (staff_id, validity);

create index idx_salary_structure_campus
  on public.employee_salary_structure (campus_id);

create trigger salary_structure_audit after insert or update or delete on public.employee_salary_structure
  for each row execute function app.tg_audit_row();

-- Arrears table for retrospective salary adjustments
create table public.payroll_arrear (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  staff_id      uuid not null references public.staff(id) on delete cascade,
  source_period date not null,
  target_run_id uuid,
  amount_paisa  bigint not null,
  reason        text not null,
  status        text not null default 'pending' check (status in ('pending', 'applied', 'cancelled')),
  created_at    timestamptz not null default now(),
  created_by    uuid references auth.users(id)
);

create index idx_payroll_arrear_staff_status
  on public.payroll_arrear (staff_id, status);

create trigger payroll_arrear_audit after insert or update or delete on public.payroll_arrear
  for each row execute function app.tg_audit_row();

-- RLS
alter table public.employee_salary_structure enable row level security;
alter table public.payroll_arrear enable row level security;

create policy salary_structure_read on public.employee_salary_structure
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
      or exists (select 1 from public.staff s where s.id = staff_id and s.user_id = auth.uid())
    )
  );

create policy salary_structure_write on public.employee_salary_structure
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'hr_manager')
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'hr_manager')
  );

create policy payroll_arrear_read on public.payroll_arrear
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
      or exists (select 1 from public.staff s where s.id = staff_id and s.user_id = auth.uid())
    )
  );

create policy payroll_arrear_write on public.payroll_arrear
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
  );

-- Function: active salary structure for a date
create or replace function public.fn_active_salary_structure(
  p_staff_id uuid,
  p_on_date  date default current_date
)
returns public.employee_salary_structure
language sql
stable
security definer
set search_path = ''
as $$
  select *
  from public.employee_salary_structure
  where staff_id = p_staff_id
    and validity @> p_on_date
  order by upper(validity) desc nulls first
  limit 1;
$$;

revoke execute on function public.fn_active_salary_structure(uuid, date) from public, anon;
grant  execute on function public.fn_active_salary_structure(uuid, date) to authenticated;

-- Function: evaluate salary components for an employee in a period
create or replace function public.fn_salary_for_period(
  p_staff_id     uuid,
  p_period_start date,
  p_period_end   date,
  p_payable_days numeric default 26,
  p_unpaid_days  numeric default 0
)
returns table (
  component_id        uuid,
  code                text,
  name_en             text,
  component_type      public.salary_component_type,
  calc_method         public.salary_calc_method,
  amount_paisa        bigint,
  is_taxable          boolean,
  taxable_paisa       bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_structure public.employee_salary_structure;
  v_basic     bigint := 0;
  v_tenant_id uuid;
  v_comp      record;
  v_amt       bigint;
  v_taxable   bigint;
  v_override  text;
begin
  select tenant_id into v_tenant_id from public.staff where id = p_staff_id;
  if v_tenant_id is null then
    return;
  end if;

  select * into v_structure from public.fn_active_salary_structure(p_staff_id, p_period_end);
  if v_structure.id is null then
    -- Fallback: find structure overlapping period start
    select * into v_structure from public.fn_active_salary_structure(p_staff_id, p_period_start);
  end if;

  if v_structure.id is not null then
    v_basic := v_structure.basic_paisa;
  end if;

  for v_comp in
    select
      c.id,
      c.code,
      c.name_en,
      c.component_type,
      c.calc_method,
      c.calc_value_paisa,
      c.calc_pct,
      c.is_taxable,
      c.exemption_cap_pct,
      c.prorates_on_absence
    from public.salary_component c
    where c.tenant_id = v_tenant_id
      and c.effective_from <= p_period_end
      and (c.effective_to is null or c.effective_to >= p_period_start)
    order by
      case when c.code = 'BASIC' then 1
           when c.component_type = 'earning' then 2
           when c.component_type = 'deduction' then 3
           else 4 end,
      c.code
  loop
    if v_comp.code = 'BASIC' then
      v_amt := public.fn_evaluate_component(
        'fixed_paisa',
        v_basic,
        0,
        v_basic,
        0,
        p_payable_days,
        p_unpaid_days,
        v_comp.prorates_on_absence
      );
    else
      -- Check if structure has an explicit override in jsonb
      v_override := v_structure.component_overrides ->> v_comp.code;
      if v_override is not null and v_override ~ '^[0-9]+$' then
        v_amt := public.fn_evaluate_component(
          'fixed_paisa',
          v_override::bigint,
          0,
          v_basic,
          0,
          p_payable_days,
          p_unpaid_days,
          v_comp.prorates_on_absence
        );
      else
        v_amt := public.fn_evaluate_component(
          v_comp.calc_method,
          v_comp.calc_value_paisa,
          v_comp.calc_pct,
          v_basic,
          0,
          p_payable_days,
          p_unpaid_days,
          v_comp.prorates_on_absence
        );
      end if;
    end if;

    if v_comp.is_taxable then
      if v_comp.exemption_cap_pct > 0 then
        v_taxable := round(v_amt::numeric * (1.0 - (v_comp.exemption_cap_pct / 100.0)))::bigint;
      else
        v_taxable := v_amt;
      end if;
    else
      v_taxable := 0;
    end if;

    component_id   := v_comp.id;
    code           := v_comp.code;
    name_en        := v_comp.name_en;
    component_type := v_comp.component_type;
    calc_method    := v_comp.calc_method;
    amount_paisa   := v_amt;
    is_taxable     := v_comp.is_taxable;
    taxable_paisa  := v_taxable;

    return next;
  end loop;
end;
$$;

revoke execute on function public.fn_salary_for_period(uuid, date, date, numeric, numeric) from public, anon;
grant  execute on function public.fn_salary_for_period(uuid, date, date, numeric, numeric) to authenticated;
