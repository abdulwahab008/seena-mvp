-- Three money movements that never reached the books:
--
--   staff loan paid out          Dr 1300 Advances to staff   Cr 1000 Cash
--   lump-sum repayment           Dr 1000 Cash                Cr 1300 (a security deposit paid in cash: Cr 2300)
--   school's EOBI and PF share   Dr 5000 Salaries            Cr 2400, added to the payroll voucher
--
-- And a student's refundable fee (a security deposit) is money held for the
-- family, not income: it now credits 2300 instead of the head's income account.
--
-- Monthly loan deductions already post through the payroll voucher, so only
-- recoveries without a payroll run post here. A security deposit is collected,
-- never paid out, so its creation posts nothing.
--
-- Payroll vouchers already posted keep their old amounts; the employer share
-- for those months needs a journal voucher.

alter table public.journal_entry drop constraint journal_entry_source_kind_check;
alter table public.journal_entry add constraint journal_entry_source_kind_check
  check (source_kind in ('fee_payment', 'expense_voucher', 'payroll_accrual', 'payroll_payment', 'inv_sale', 'petty_cash', 'opening', 'year_close',
                         'staff_loan', 'staff_loan_recovery'));

create or replace function app.fn_gl_post_fee_payment(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  p       public.fee_payment%rowtype;
  v_lines jsonb;
  v_alloc bigint;
begin
  select * into p from public.fee_payment where id = p_id;
  if not found or p.mode = 'adjustment' then
    return null;
  end if;
  select coalesce(sum(amount_paisa), 0) into v_alloc from public.fee_payment_allocation where payment_id = p_id;
  select jsonb_build_array(jsonb_build_object('code', case p.mode when 'cash' then '1000' else '1010' end, 'debit', p.amount_paisa))
         || coalesce(jsonb_agg(jsonb_build_object('code', x.code, 'credit', x.amount, 'memo', x.name)), '[]'::jsonb)
         || jsonb_build_array(jsonb_build_object('code', '2200', 'credit', greatest(p.amount_paisa - v_alloc, 0), 'memo', 'Paid in advance'))
    into v_lines
    from (select case when h.is_refundable then '2300' else app.fn_gl_code(p.tenant_id, h.gl_code, '4000') end as code,
                 string_agg(distinct h.name_en, ', ') as name, sum(fa.amount_paisa) as amount
            from public.fee_payment_allocation fa
            join public.fee_head h on h.id = fa.fee_head_id
           where fa.payment_id = p_id
           group by 1) x;
  return app.fn_gl_post_system(p.tenant_id, p.value_date,
    'Fee received' || coalesce(' · ' || p.reference_no, ''), 'fee_payment', p.id, v_lines);
end;
$$;

create or replace function app.fn_gl_post_staff_loan(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  l public.staff_loan%rowtype;
  v_name text;
begin
  select * into l from public.staff_loan where id = p_id;
  if not found or l.loan_type = 'security_deposit' then
    return null;
  end if;
  select full_name into v_name from public.staff where id = l.staff_id;
  return app.fn_gl_post_system(l.tenant_id, l.disbursed_at,
    case l.loan_type when 'salary_advance' then 'Salary advance to ' else 'Staff loan to ' end || coalesce(v_name, 'staff'), 'staff_loan', l.id,
    jsonb_build_array(jsonb_build_object('code', '1300', 'debit', l.principal_paisa), jsonb_build_object('code', '1000', 'credit', l.principal_paisa)));
end;
$$;

create or replace function app.fn_gl_post_staff_loan_recovery(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.staff_loan_recovery%rowtype;
  l public.staff_loan%rowtype;
  v_name text;
begin
  select * into r from public.staff_loan_recovery where id = p_id;
  if not found or r.payroll_run_id is not null then
    return null;
  end if;
  select * into l from public.staff_loan where id = r.loan_id;
  select full_name into v_name from public.staff where id = l.staff_id;
  return app.fn_gl_post_system(l.tenant_id, (r.recovered_at at time zone 'Asia/Karachi')::date,
    case when l.loan_type = 'security_deposit' then 'Security deposit paid by ' else 'Loan repaid by ' end || coalesce(v_name, 'staff'), 'staff_loan_recovery', r.id,
    jsonb_build_array(jsonb_build_object('code', '1000', 'debit', r.amount_paisa),
                      jsonb_build_object('code', case when l.loan_type = 'security_deposit' then '2300' else '1300' end, 'credit', r.amount_paisa)));
end;
$$;

create or replace function app.fn_gl_post_payroll(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r     public.payroll_run%rowtype;
  v_net bigint; v_tax bigint; v_loan bigint; v_deposit bigint; v_employer bigint;
  v_month text;
begin
  select * into r from public.payroll_run where id = p_id;
  if not found or r.status not in ('locked', 'paid') then
    return;
  end if;
  select coalesce(sum(net_paisa), 0), coalesce(sum(tax_withholding_paisa + other_deductions_paisa), 0), coalesce(sum(loan_recovery_paisa), 0)
    into v_net, v_tax, v_loan
    from public.payroll_run_line where payroll_run_id = p_id;
  select coalesce(sum(r2.amount_paisa), 0) into v_deposit
    from public.staff_loan_recovery r2 join public.staff_loan l on l.id = r2.loan_id
   where r2.payroll_run_id = p_id and l.loan_type = 'security_deposit';
  select coalesce(sum(c.amount_paisa), 0) into v_employer
    from public.payroll_run_line_component c join public.payroll_run_line pl on pl.id = c.line_id
   where pl.payroll_run_id = p_id and c.component_type = 'employer_contribution';
  v_month := to_char(r.period_month, 'Mon YYYY');
  -- Debit is built from the credits so the voucher balances whatever the
  -- line arithmetic; attendance deductions are pay never earned, not a payable.
  perform app.fn_gl_post_system(r.tenant_id, (coalesce(r.locked_at, now()) at time zone 'Asia/Karachi')::date,
    'Salaries for ' || v_month, 'payroll_accrual', r.id,
    jsonb_build_array(
      jsonb_build_object('code', '5000', 'debit', v_net + v_tax + v_loan + v_employer),
      jsonb_build_object('code', '2100', 'credit', v_net, 'memo', 'Net pay'),
      jsonb_build_object('code', '2400', 'credit', v_tax, 'memo', 'Tax and deductions'),
      jsonb_build_object('code', '2400', 'credit', v_employer, 'memo', 'School''s EOBI and PF share'),
      jsonb_build_object('code', '1300', 'credit', v_loan - v_deposit, 'memo', 'Loan recoveries'),
      jsonb_build_object('code', '2300', 'credit', v_deposit, 'memo', 'Staff security deposits')));
  if r.status = 'paid' then
    perform app.fn_gl_post_system(r.tenant_id, (now() at time zone 'Asia/Karachi')::date,
      'Salaries paid for ' || v_month, 'payroll_payment', r.id,
      jsonb_build_array(jsonb_build_object('code', '2100', 'debit', v_net), jsonb_build_object('code', '1010', 'credit', v_net)));
  end if;
end;
$$;

revoke execute on function app.fn_gl_post_staff_loan(uuid) from public, anon, authenticated;
revoke execute on function app.fn_gl_post_staff_loan_recovery(uuid) from public, anon, authenticated;

create or replace function app.tg_gl_post()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  case tg_table_name
    when 'fee_payment' then perform app.fn_gl_post_fee_payment(new.id);
    when 'expense_voucher' then perform app.fn_gl_post_expense_voucher(new.id);
    when 'payroll_run' then perform app.fn_gl_post_payroll(new.id);
    when 'inv_sale' then perform app.fn_gl_post_inv_sale(new.id);
    when 'petty_cash_txn' then perform app.fn_gl_post_petty_cash(new.id);
    when 'staff_loan' then perform app.fn_gl_post_staff_loan(new.id);
    when 'staff_loan_recovery' then perform app.fn_gl_post_staff_loan_recovery(new.id);
  end case;
  return null;
end;
$$;

create trigger staff_loan_gl_post after insert on public.staff_loan
  for each row execute function app.tg_gl_post();
create trigger staff_loan_recovery_gl_post after insert on public.staff_loan_recovery
  for each row when (new.payroll_run_id is null) execute function app.tg_gl_post();

create or replace function public.post_ledger_backfill()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_before int;
  v_after  int;
  r record;
begin
  perform app.fn_assert_accountant();
  select count(*) into v_before from public.journal_entry where tenant_id = v_tenant and source_kind is not null;
  for r in select id from public.fee_payment where tenant_id = v_tenant order by value_date, received_at loop
    perform app.fn_gl_post_fee_payment(r.id);
  end loop;
  for r in select id from public.expense_voucher where tenant_id = v_tenant and status = 'paid' order by paid_at loop
    perform app.fn_gl_post_expense_voucher(r.id);
  end loop;
  for r in select id from public.payroll_run where tenant_id = v_tenant and status in ('locked', 'paid') order by period_month loop
    perform app.fn_gl_post_payroll(r.id);
  end loop;
  for r in select id from public.inv_sale where tenant_id = v_tenant order by sold_at loop
    perform app.fn_gl_post_inv_sale(r.id);
  end loop;
  for r in select id from public.petty_cash_txn where tenant_id = v_tenant order by created_at loop
    perform app.fn_gl_post_petty_cash(r.id);
  end loop;
  for r in select id from public.staff_loan where tenant_id = v_tenant order by disbursed_at, created_at loop
    perform app.fn_gl_post_staff_loan(r.id);
  end loop;
  for r in select x.id from public.staff_loan_recovery x join public.staff_loan l on l.id = x.loan_id
            where l.tenant_id = v_tenant and x.payroll_run_id is null order by x.recovered_at loop
    perform app.fn_gl_post_staff_loan_recovery(r.id);
  end loop;
  select count(*) into v_after from public.journal_entry where tenant_id = v_tenant and source_kind is not null;
  return v_after - v_before;
end;
$$;
