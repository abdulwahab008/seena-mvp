-- ═══════════════════════════════════════════════════════════════════════
-- Migration: 20260801290000_salary_component_catalogue.sql
-- FR-L01: Salary component catalogue
--
-- Introduces public.salary_component for configuring earnings, deductions,
-- and employer contributions with fixed or percentage-based calculation rules,
-- absence proration, and taxability/exemption rules.
-- ═══════════════════════════════════════════════════════════════════════

create type public.salary_component_type as enum (
  'earning',
  'deduction',
  'employer_contribution'
);

create type public.salary_calc_method as enum (
  'fixed_paisa',
  'pct_of_basic',
  'pct_of_gross'
);

create table public.salary_component (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  code                 text not null,
  name_en              text not null,
  name_ur              text,
  component_type       public.salary_component_type not null default 'earning',
  calc_method          public.salary_calc_method not null default 'fixed_paisa',
  calc_value_paisa     bigint not null default 0 check (calc_value_paisa >= 0),
  calc_pct             numeric(7, 4) not null default 0 check (calc_pct >= 0 and calc_pct <= 100),
  is_taxable           boolean not null default true,
  exemption_cap_pct    numeric(5, 2) not null default 0 check (exemption_cap_pct >= 0 and exemption_cap_pct <= 100),
  prorates_on_absence  boolean not null default true,
  effective_from       date not null default current_date,
  effective_to         date,
  created_at           timestamptz not null default now(),
  created_by           uuid references auth.users(id),
  constraint chk_salary_component_dates check (effective_to is null or effective_to >= effective_from)
);

-- Unique index per tenant on active code
create unique index uq_salary_component_tenant_code
  on public.salary_component (tenant_id, lower(code))
  where effective_to is null;

create index idx_salary_component_tenant_type
  on public.salary_component (tenant_id, component_type);

-- Audit trigger
create trigger salary_component_audit after insert or update or delete on public.salary_component
  for each row execute function app.tg_audit_row();

-- RLS
alter table public.salary_component enable row level security;

create policy salary_component_tenant_read on public.salary_component
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create policy salary_component_hr_write on public.salary_component
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'hr_manager')
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'hr_manager')
  );

-- Function to evaluate a salary component's paisa amount
create or replace function public.fn_evaluate_component(
  p_calc_method         public.salary_calc_method,
  p_calc_value_paisa    bigint,
  p_calc_pct            numeric,
  p_basic_paisa         bigint,
  p_gross_paisa         bigint default 0,
  p_payable_days        numeric default 26,
  p_unpaid_days         numeric default 0,
  p_prorates_on_absence boolean default true
)
returns bigint
language plpgsql
immutable
as $$
declare
  v_base_paisa bigint := 0;
  v_result     bigint := 0;
begin
  if p_calc_method = 'fixed_paisa' then
    v_base_paisa := coalesce(p_calc_value_paisa, 0);
  elsif p_calc_method = 'pct_of_basic' then
    v_base_paisa := round((coalesce(p_basic_paisa, 0)::numeric * coalesce(p_calc_pct, 0)) / 100.0)::bigint;
  elsif p_calc_method = 'pct_of_gross' then
    v_base_paisa := round((coalesce(p_gross_paisa, 0)::numeric * coalesce(p_calc_pct, 0)) / 100.0)::bigint;
  end if;

  if p_prorates_on_absence and coalesce(p_payable_days, 26) > 0 and coalesce(p_unpaid_days, 0) > 0 then
    declare
      v_effective_days numeric := greatest(0.0, p_payable_days - p_unpaid_days);
    begin
      v_result := round((v_base_paisa::numeric * v_effective_days) / p_payable_days)::bigint;
    end;
  else
    v_result := v_base_paisa;
  end if;

  return greatest(0, v_result);
end;
$$;

revoke execute on function public.fn_evaluate_component(public.salary_calc_method, bigint, numeric, bigint, bigint, numeric, numeric, boolean) from public, anon;
grant  execute on function public.fn_evaluate_component(public.salary_calc_method, bigint, numeric, bigint, bigint, numeric, numeric, boolean) to authenticated;

-- Default seed procedure for tenant salary components
create or replace function public.seed_default_salary_components(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- 1. BASIC SALARY
  insert into public.salary_component (
    tenant_id, code, name_en, name_ur, component_type, calc_method, calc_value_paisa, is_taxable, prorates_on_absence
  ) values (
    p_tenant_id, 'BASIC', 'Basic Salary', 'بنیادی تنخواہ', 'earning', 'fixed_paisa', 0, true, true
  ) on conflict do nothing;

  -- 2. HOUSE RENT ALLOWANCE (45% of Basic)
  insert into public.salary_component (
    tenant_id, code, name_en, name_ur, component_type, calc_method, calc_pct, is_taxable, prorates_on_absence
  ) values (
    p_tenant_id, 'HOUSE_RENT', 'House Rent Allowance', 'کرایہ مکان الاؤنس', 'earning', 'pct_of_basic', 45.0, true, true
  ) on conflict do nothing;

  -- 3. MEDICAL ALLOWANCE (10% of Basic, exempt under Pakistani tax law up to 10%)
  insert into public.salary_component (
    tenant_id, code, name_en, name_ur, component_type, calc_method, calc_pct, is_taxable, exemption_cap_pct, prorates_on_absence
  ) values (
    p_tenant_id, 'MEDICAL', 'Medical Allowance', 'طبی الاؤنس', 'earning', 'pct_of_basic', 10.0, true, 100.0, true
  ) on conflict do nothing;

  -- 4. CONVEYANCE ALLOWANCE (Fixed 5,000 PKR = 500,000 paisa)
  insert into public.salary_component (
    tenant_id, code, name_en, name_ur, component_type, calc_method, calc_value_paisa, is_taxable, prorates_on_absence
  ) values (
    p_tenant_id, 'CONVEYANCE', 'Conveyance Allowance', 'سواری الاؤنس', 'earning', 'fixed_paisa', 500000, true, true
  ) on conflict do nothing;

  -- 5. DEARNESS ALLOWANCE (Fixed 0)
  insert into public.salary_component (
    tenant_id, code, name_en, name_ur, component_type, calc_method, calc_value_paisa, is_taxable, prorates_on_absence
  ) values (
    p_tenant_id, 'DEARNESS', 'Dearness Allowance', 'مہنگائی الاؤنس', 'earning', 'fixed_paisa', 0, true, true
  ) on conflict do nothing;

  -- 6. EOBI EMPLOYEE CONTRIBUTION (Fixed 260 PKR = 26,000 paisa)
  insert into public.salary_component (
    tenant_id, code, name_en, name_ur, component_type, calc_method, calc_value_paisa, is_taxable, prorates_on_absence
  ) values (
    p_tenant_id, 'EOBI_EE', 'EOBI Employee Contribution', 'ای او بی آئی ملازم حصہ', 'deduction', 'fixed_paisa', 26000, false, false
  ) on conflict do nothing;

  -- 7. EOBI EMPLOYER CONTRIBUTION (Fixed 1,300 PKR = 130,000 paisa)
  insert into public.salary_component (
    tenant_id, code, name_en, name_ur, component_type, calc_method, calc_value_paisa, is_taxable, prorates_on_absence
  ) values (
    p_tenant_id, 'EOBI_ER', 'EOBI Employer Contribution', 'ای او بی آئی آجر حصہ', 'employer_contribution', 'fixed_paisa', 130000, false, false
  ) on conflict do nothing;
end;
$$;

revoke execute on function public.seed_default_salary_components(uuid) from public, anon;
grant  execute on function public.seed_default_salary_components(uuid) to authenticated;
