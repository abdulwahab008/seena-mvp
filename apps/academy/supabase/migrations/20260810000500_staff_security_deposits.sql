-- Staff security deposits: a fixed amount the school holds from a staff
-- member's salary, collected in monthly instalments and paid back at exit.
-- They ride the staff loan rails (payroll already deducts an instalment each
-- month until the target is reached), with three differences: payroll books
-- them as a liability (2300) instead of a loan receivable (1300), the exit
-- settlement refunds what was collected instead of recovering what is left,
-- and paying the settlement marks the deposit refunded.

alter table public.staff_loan drop constraint staff_loan_loan_type_check;
alter table public.staff_loan add constraint staff_loan_loan_type_check check (loan_type in ('loan', 'salary_advance', 'security_deposit'));
alter table public.staff_loan add column refunded_at timestamptz;

create or replace function public.create_staff_security_deposit(p_staff_id uuid, p_target_paisa bigint, p_installment_paisa bigint, p_start_month date, p_notes text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff public.staff%rowtype;
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_staff from public.staff where id = p_staff_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_target_paisa is null or p_target_paisa <= 0 or p_installment_paisa is null or p_installment_paisa <= 0 or p_installment_paisa > p_target_paisa then
    raise exception 'AMOUNT_INVALID' using errcode = '22023';
  end if;
  if exists (select 1 from public.staff_loan where staff_id = p_staff_id and loan_type = 'security_deposit' and refunded_at is null and status <> 'written_off') then
    raise exception 'DEPOSIT_EXISTS' using errcode = '23505';
  end if;
  insert into public.staff_loan (tenant_id, campus_id, staff_id, loan_type, principal_paisa, installment_paisa, repayment_start_month, notes, approved_by, created_by)
  values (v_staff.tenant_id, v_staff.campus_id, p_staff_id, 'security_deposit', p_target_paisa, p_installment_paisa,
          date_trunc('month', p_start_month)::date, nullif(btrim(p_notes), ''), auth.uid(), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.create_staff_security_deposit(uuid, bigint, bigint, date, text) from public, anon;
grant execute on function public.create_staff_security_deposit(uuid, bigint, bigint, date, text) to authenticated;

create or replace function app.fn_gl_post_payroll(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r     public.payroll_run%rowtype;
  v_net bigint; v_tax bigint; v_loan bigint; v_deposit bigint;
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
  v_month := to_char(r.period_month, 'Mon YYYY');
  -- Debit is built from the credits so the voucher balances whatever the
  -- line arithmetic; attendance deductions are pay never earned, not a payable.
  perform app.fn_gl_post_system(r.tenant_id, (coalesce(r.locked_at, now()) at time zone 'Asia/Karachi')::date,
    'Salaries for ' || v_month, 'payroll_accrual', r.id,
    jsonb_build_array(
      jsonb_build_object('code', '5000', 'debit', v_net + v_tax + v_loan),
      jsonb_build_object('code', '2100', 'credit', v_net, 'memo', 'Net pay'),
      jsonb_build_object('code', '2400', 'credit', v_tax, 'memo', 'Tax and deductions'),
      jsonb_build_object('code', '1300', 'credit', v_loan - v_deposit, 'memo', 'Loan recoveries'),
      jsonb_build_object('code', '2300', 'credit', v_deposit, 'memo', 'Staff security deposits')));
  if r.status = 'paid' then
    perform app.fn_gl_post_system(r.tenant_id, (now() at time zone 'Asia/Karachi')::date,
      'Salaries paid for ' || v_month, 'payroll_payment', r.id,
      jsonb_build_array(jsonb_build_object('code', '2100', 'debit', v_net), jsonb_build_object('code', '1010', 'credit', v_net)));
  end if;
end;
$$;

create or replace function app.fn_settlement_lines(p_exit_id uuid)
returns table (line_type public.settlement_line_type, description text, amount_paisa bigint, sign smallint, sort_order smallint,
               leave_type_id uuid, leave_days numeric, loan_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_exit    public.staff_exit%rowtype;
  v_staff   public.staff%rowtype;
  v_gross   numeric(12, 2);
  v_gross_p bigint;
  v_daily_p bigint;
  v_start   date;
  v_days    integer;
  v_dim     integer;
  v_amount  bigint;
  lt        record;
  ln        record;
  v_bal     numeric;
  v_unused  numeric;
  v_enc     numeric;
  v_order   smallint := 10;
begin
  select * into v_exit from public.staff_exit where id = p_exit_id;
  if not found then
    raise exception 'EXIT_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into v_staff from public.staff where id = v_exit.staff_id;

  select p.gross_salary into v_gross
    from public.staff_contract c join public.staff_contract_pay p on p.contract_id = c.id
   where c.staff_id = v_exit.staff_id
   order by (c.start_date <= v_exit.last_working_date and (c.end_date is null or c.end_date >= v_exit.last_working_date)) desc, c.start_date desc
   limit 1;
  if v_gross is null then
    raise exception 'NO_SALARY_ON_FILE' using errcode = '22023';
  end if;
  v_gross_p := round(v_gross * 100)::bigint;
  v_daily_p := round(v_gross_p / 30.0)::bigint;

  -- salary for the final (part) month
  v_start := greatest(date_trunc('month', v_exit.last_working_date)::date, v_staff.doj);
  v_days := v_exit.last_working_date - v_start + 1;
  v_dim := extract(day from (date_trunc('month', v_exit.last_working_date) + interval '1 month - 1 day'))::integer;
  if v_days > 0 then
    v_amount := round(v_gross_p::numeric * v_days / v_dim)::bigint;
    return query select 'salary'::public.settlement_line_type,
      format('Salary %s to %s (%s of %s days)', to_char(v_start, 'DD Mon YYYY'), to_char(v_exit.last_working_date, 'DD Mon YYYY'), v_days, v_dim),
      v_amount, 1::smallint, 1::smallint, null::uuid, null::numeric, null::uuid;
  end if;

  -- encashable leave only: the leave type decides, nothing is hardcoded
  for lt in
    select t.id, t.name_en, t.encashment_cap_days
      from public.leave_type t
     where t.tenant_id = v_exit.tenant_id and t.is_encashable and t.is_active
     order by t.code
  loop
    -- read the ledger directly: fn_leave_balance() is scoped to the caller's own role, and the Accountant is not an HR role
    select coalesce(sum(ll.days), 0) into v_bal from public.leave_ledger ll where ll.staff_id = v_exit.staff_id and ll.leave_type_id = lt.id;
    v_unused := greatest(v_bal, 0);
    v_enc := least(v_unused, coalesce(lt.encashment_cap_days, v_unused));
    if v_enc > 0 then
      return query select 'leave_encashment'::public.settlement_line_type,
        format('%s encashment: %s day(s)%s at %s per day', lt.name_en, app.fn_days_text(v_enc),
               case when lt.encashment_cap_days is not null and v_unused > lt.encashment_cap_days
                    then format(' (%s unused, capped at %s)', app.fn_days_text(v_unused), app.fn_days_text(lt.encashment_cap_days)) else '' end,
               to_char(v_daily_p / 100.0, 'FM999,999,990.00')),
        round(v_enc * v_daily_p)::bigint, 1::smallint, v_order, lt.id, v_enc, null::uuid;
      v_order := v_order + 1;
    end if;
  end loop;

  -- notice shortfall carried from the exit
  if v_exit.notice_shortfall_days > 0 then
    return query select 'notice_recovery'::public.settlement_line_type,
      format('Notice shortfall recovery: %s day(s) at %s per day', v_exit.notice_shortfall_days, to_char(v_daily_p / 100.0, 'FM999,999,990.00')),
      v_exit.notice_shortfall_days * v_daily_p, (-1)::smallint, 50::smallint, null::uuid, null::numeric, null::uuid;
  end if;

  -- outstanding loans and advances
  v_order := 60;
  for ln in
    select l.id, l.loan_type, l.principal_paisa - l.total_repaid_paisa as outstanding
      from public.staff_loan l
     where l.staff_id = v_exit.staff_id and l.status in ('active', 'paused') and l.principal_paisa - l.total_repaid_paisa > 0
       and l.loan_type <> 'security_deposit'
     order by l.disbursed_at, l.id
  loop
    return query select 'advance_recovery'::public.settlement_line_type,
      format('Outstanding %s recovery', replace(ln.loan_type, '_', ' ')), ln.outstanding, (-1)::smallint, v_order, null::uuid, null::numeric, ln.id;
    v_order := v_order + 1;
  end loop;

  -- security deposits collected from salary are paid back
  v_order := 80;
  for ln in
    select l.id, l.total_repaid_paisa as held
      from public.staff_loan l
     where l.staff_id = v_exit.staff_id and l.loan_type = 'security_deposit' and l.refunded_at is null and l.total_repaid_paisa > 0
     order by l.disbursed_at, l.id
  loop
    return query select 'other'::public.settlement_line_type, 'Security deposit refund'::text, ln.held, 1::smallint, v_order, null::uuid, null::numeric, ln.id;
    v_order := v_order + 1;
  end loop;
end;
$$;
revoke execute on function app.fn_settlement_lines(uuid) from public, anon, authenticated;

create or replace function public.mark_settlement_paid(p_settlement_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s public.staff_settlement%rowtype;
begin
  select * into v_s from public.staff_settlement where id = p_settlement_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'SETTLEMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_settlement_actor_ok(v_s.exit_id);
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_s.status <> 'approved' or v_s.superseded_at is not null then
    raise exception 'SETTLEMENT_NOT_PAYABLE' using errcode = '55000';
  end if;
  update public.staff_settlement set status = 'paid', paid_by = (select auth.uid()), paid_at = clock_timestamp() where id = p_settlement_id;
  update public.staff_loan l set status = 'closed', total_repaid_paisa = l.principal_paisa
   where l.loan_type <> 'security_deposit'
     and l.id in (select loan_id from public.staff_settlement_line where settlement_id = p_settlement_id and loan_id is not null);
  update public.staff_loan l set status = 'closed', refunded_at = clock_timestamp()
   where l.loan_type = 'security_deposit'
     and l.id in (select loan_id from public.staff_settlement_line where settlement_id = p_settlement_id and loan_id is not null);
end;
$$;
revoke execute on function public.mark_settlement_paid(uuid) from public, anon;
grant execute on function public.mark_settlement_paid(uuid) to authenticated;
