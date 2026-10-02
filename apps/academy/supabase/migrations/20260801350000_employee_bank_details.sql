-- ═══════════════════════════════════════════════════════════════════════
-- Migration: 20260801350000_employee_bank_details.sql
-- FR-L09: Employee bank details & bank file transfer formats
--
-- Supports direct bank salary disbursements with IBAN validation,
-- verification workflow, and multi-bank file format definitions.
-- ═══════════════════════════════════════════════════════════════════════

create table public.bank_file_format (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name       text not null,
  specs      jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.employee_bank_detail (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  staff_id       uuid not null references public.staff(id) on delete cascade,
  bank_name      text not null,
  branch_code    text,
  account_title  text not null,
  account_number text not null,
  iban           text,
  is_verified    boolean not null default false,
  verified_by    uuid references auth.users(id),
  verified_at    timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (staff_id)
);

create index idx_employee_bank_detail_staff on public.employee_bank_detail (staff_id);
create index idx_employee_bank_detail_campus on public.employee_bank_detail (campus_id);

-- Audit triggers
create trigger employee_bank_detail_audit after insert or update or delete on public.employee_bank_detail
  for each row execute function app.tg_audit_row();

-- RLS
alter table public.bank_file_format enable row level security;
alter table public.employee_bank_detail enable row level security;

create policy bank_file_format_read on public.bank_file_format
  for select to authenticated
  using (true);

create policy employee_bank_detail_read on public.employee_bank_detail
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
      or campus_id = any(app.auth_campus_ids())
      or exists (select 1 from public.staff s where s.id = staff_id and s.user_id = auth.uid())
    )
  );

create policy employee_bank_detail_write on public.employee_bank_detail
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
  );

-- Function: Validate Pakistan or international IBAN
create or replace function public.fn_validate_iban(p_iban text)
returns boolean
language plpgsql
immutable
as $$
declare
  v_clean text;
begin
  if p_iban is null or trim(p_iban) = '' then
    return true; -- optional field
  end if;

  -- Strip spaces and hyphens
  v_clean := upper(regexp_replace(p_iban, '[^A-Za-z0-9]', '', 'g'));

  -- Pakistan IBAN: 24 characters starting with PK, followed by 2 digits, 4 alphanumeric bank code, and 16 digits
  if v_clean ~ '^PK[0-9]{2}[A-Z0-9]{4}[0-9]{16}$' then
    return true;
  end if;

  -- General international IBAN: 15 to 34 characters starting with 2 letters and 2 digits
  if v_clean ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$' then
    return true;
  end if;

  return false;
end;
$$;

revoke execute on function public.fn_validate_iban(text) from public, anon;
grant  execute on function public.fn_validate_iban(text) to authenticated;

-- Seed common Pakistani bank disbursement formats
insert into public.bank_file_format (code, name, specs)
values
  ('1LINK_FT', '1LINK Interbank Funds Transfer (CSV)', '{"delimiter": ",", "header": true, "columns": ["SrNo", "BeneficiaryAccount", "BeneficiaryName", "BankCode", "Amount", "Reference"]}'::jsonb),
  ('HBL_CORP', 'HBL Corporate Bulk Payment Format', '{"delimiter": ",", "header": false, "columns": ["TransType", "DebitAccount", "CreditAccount", "Amount", "BeneficiaryName", "Particulars"]}'::jsonb),
  ('MEEZAN_BULK', 'Meezan Bank Batch Disbursement (TXT)', '{"fixed_width": true, "record_length": 150}'::jsonb),
  ('EXCEL_GENERIC', 'Generic Salary Disbursement Schedule (XLSX/CSV)', '{"delimiter": ",", "header": true, "columns": ["EmployeeCode", "Name", "Bank", "AccountNumber", "IBAN", "NetSalary"]}'::jsonb)
on conflict (code) do nothing;
