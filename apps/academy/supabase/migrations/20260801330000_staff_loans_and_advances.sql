-- ═══════════════════════════════════════════════════════════════════════
-- Migration: 20260801330000_staff_loans_and_advances.sql
-- FR-L03: Staff loans and advances recovery
--
-- Tracks staff loans and salary advances, monthly recovery installments,
-- and automatic loan closing when outstanding balance reaches zero.
-- ═══════════════════════════════════════════════════════════════════════

create table public.staff_loan (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenant(id) on delete cascade,
  campus_id             uuid not null references public.campus(id) on delete cascade,
  staff_id              uuid not null references public.staff(id) on delete cascade,
  loan_type             text not null default 'loan' check (loan_type in ('loan', 'salary_advance')),
  principal_paisa       bigint not null check (principal_paisa > 0),
  installment_paisa     bigint not null check (installment_paisa > 0),
  disbursed_at          date not null default current_date,
  repayment_start_month date not null,
  total_repaid_paisa    bigint not null default 0 check (total_repaid_paisa >= 0),
  status                text not null default 'active' check (status in ('active', 'paused', 'closed', 'written_off')),
  approved_by           uuid references auth.users(id),
  notes                 text,
  created_at            timestamptz not null default now(),
  created_by            uuid references auth.users(id)
);

create index idx_staff_loan_staff_status on public.staff_loan (staff_id, status);
create index idx_staff_loan_campus on public.staff_loan (campus_id);

create table public.staff_loan_recovery (
  id             uuid primary key default gen_random_uuid(),
  loan_id        uuid not null references public.staff_loan(id) on delete cascade,
  payroll_run_id uuid,
  amount_paisa   bigint not null check (amount_paisa > 0),
  recovered_at   timestamptz not null default now(),
  notes          text
);

create index idx_staff_loan_recovery_loan on public.staff_loan_recovery (loan_id);
create index idx_staff_loan_recovery_run on public.staff_loan_recovery (payroll_run_id);

-- Audit triggers
create trigger staff_loan_audit after insert or update or delete on public.staff_loan
  for each row execute function app.tg_audit_row();

create trigger staff_loan_recovery_audit after insert or update or delete on public.staff_loan_recovery
  for each row execute function app.tg_audit_row();

-- RLS
alter table public.staff_loan enable row level security;
alter table public.staff_loan_recovery enable row level security;

create policy staff_loan_read on public.staff_loan
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
      or exists (select 1 from public.staff s where s.id = staff_id and s.user_id = auth.uid())
    )
  );

create policy staff_loan_write on public.staff_loan
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
  );

create policy staff_loan_recovery_read on public.staff_loan_recovery
  for select to authenticated
  using (
    exists (
      select 1 from public.staff_loan l
      where l.id = loan_id
        and l.tenant_id = app.auth_tenant_id()
        and (
          app.auth_role() in ('super_admin', 'owner')
          or l.campus_id = any(app.auth_campus_ids())
          or exists (select 1 from public.staff s where s.id = l.staff_id and s.user_id = auth.uid())
        )
    )
  );

create policy staff_loan_recovery_write on public.staff_loan_recovery
  for all to authenticated
  using (
    exists (
      select 1 from public.staff_loan l
      where l.id = loan_id
        and l.tenant_id = app.auth_tenant_id()
        and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
    )
  )
  with check (
    exists (
      select 1 from public.staff_loan l
      where l.id = loan_id
        and l.tenant_id = app.auth_tenant_id()
        and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
    )
  );

-- Trigger to update total_repaid_paisa and close loan when fully paid
create or replace function public.fn_tg_update_loan_repayment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total_repaid bigint;
  v_principal    bigint;
begin
  select coalesce(sum(amount_paisa), 0)
  into v_total_repaid
  from public.staff_loan_recovery
  where loan_id = coalesce(NEW.loan_id, OLD.loan_id);

  select principal_paisa into v_principal
  from public.staff_loan
  where id = coalesce(NEW.loan_id, OLD.loan_id);

  update public.staff_loan
  set
    total_repaid_paisa = v_total_repaid,
    status = case
      when v_total_repaid >= v_principal and status = 'active' then 'closed'
      when v_total_repaid < v_principal and status = 'closed' then 'active'
      else status
    end
  where id = coalesce(NEW.loan_id, OLD.loan_id);

  return coalesce(NEW, OLD);
end;
$$;

create trigger trg_update_loan_repayment
  after insert or update or delete on public.staff_loan_recovery
  for each row execute function public.fn_tg_update_loan_repayment();

-- View for loans with calculated outstanding balance
create or replace view public.v_staff_loan_summary
with (security_invoker = true)
as
select
  l.id,
  l.tenant_id,
  l.campus_id,
  l.staff_id,
  s.full_name as staff_name,
  s.employee_code,
  l.loan_type,
  l.principal_paisa,
  l.installment_paisa,
  l.disbursed_at,
  l.repayment_start_month,
  l.total_repaid_paisa,
  greatest(0, l.principal_paisa - l.total_repaid_paisa) as outstanding_paisa,
  l.status,
  l.approved_by,
  l.notes,
  l.created_at
from public.staff_loan l
join public.staff s on s.id = l.staff_id;

-- Function: Accrue loan recovery during payroll run
create or replace function public.fn_accrue_loan_recovery(
  p_payroll_run_id uuid,
  p_staff_id       uuid,
  p_period_month   date
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_loan             record;
  v_outstanding      bigint;
  v_recovery_amt     bigint;
  v_total_accrued    bigint := 0;
begin
  for v_loan in
    select id, principal_paisa, installment_paisa, total_repaid_paisa
    from public.staff_loan
    where staff_id = p_staff_id
      and status = 'active'
      and repayment_start_month <= p_period_month
    order by disbursed_at asc
  loop
    v_outstanding := greatest(0, v_loan.principal_paisa - v_loan.total_repaid_paisa);
    if v_outstanding > 0 then
      v_recovery_amt := least(v_loan.installment_paisa, v_outstanding);

      if v_recovery_amt > 0 then
        insert into public.staff_loan_recovery (
          loan_id, payroll_run_id, amount_paisa, notes
        ) values (
          v_loan.id, p_payroll_run_id, v_recovery_amt, 'Payroll deduction for ' || to_char(p_period_month, 'Mon YYYY')
        );

        v_total_accrued := v_total_accrued + v_recovery_amt;
      end if;
    end if;
  end loop;

  return v_total_accrued;
end;
$$;

revoke execute on function public.fn_accrue_loan_recovery(uuid, uuid, date) from public, anon;
grant  execute on function public.fn_accrue_loan_recovery(uuid, uuid, date) to authenticated;
