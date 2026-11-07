-- General ledger, part 2: automatic posting and financial statements.
--
-- Cash basis: fee income is recognised when a fee is paid, not when a challan
-- is issued. Each money movement posts one voucher, tagged with its source
-- (source_kind, source_id) so it can never post twice:
--
--   fee payment      Dr Cash/Bank            Cr fee head's income account (fee_head.gl_code, else 4000)
--                                            Cr 2200 for any amount not allocated to a challan
--   expense paid     Dr head's account (expense_head.gl_code, else 5900)   Cr Bank if a reference was given, else Cash
--   payroll locked   Dr 5000 Salaries        Cr 2100 net, 2400 tax and other deductions, 1300 loan recoveries
--   payroll paid     Dr 2100                 Cr 1010 Bank
--   shop cash sale   Dr 1000                 Cr 4300 (a credit note posts the mirror image)
--   petty cash out   Dr head's account       Cr 1000;  petty cash top-up: Dr 1000, Cr 1010
--
-- Nothing posts for a school that has not opened Accounts, and a posting whose
-- accounts are missing from the chart is skipped rather than blocking the fee
-- counter. post_ledger_backfill() posts anything not yet posted (history, or
-- skipped rows after the chart is fixed); it is safe to run any number of times.
--
-- Not posted: fee payments in 'adjustment' mode (no money moves), shop sales
-- charged to the fee ledger (they post when that fee is paid), and cost of
-- goods sold (sales do not store a cost price yet).

alter table public.journal_entry
  add column source_kind text check (source_kind in ('fee_payment', 'expense_voucher', 'payroll_accrual', 'payroll_payment', 'inv_sale', 'petty_cash')),
  add column source_id uuid,
  add constraint chk_journal_entry_source check ((source_kind is null) = (source_id is null));
create unique index uq_journal_entry_source on public.journal_entry (tenant_id, source_kind, source_id) where source_kind is not null;

-- Online payments land through the gateway webhook with no signed-in user.
alter table public.journal_entry alter column created_by drop not null;

alter table public.expense_head add column gl_code text check (gl_code is null or gl_code ~ '^[0-9]{3,8}$');

-- ── posting core ──────────────────────────────────────────────────────────
-- p_lines: [{"code": "1000", "debit": paisa, "credit": paisa, "memo": text}, ...]
-- Returns the new entry id, or null when nothing was posted.
create or replace function app.fn_gl_post_system(p_tenant_id uuid, p_date date, p_narration text, p_kind text, p_source_id uuid, p_lines jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id    uuid;
  v_lines jsonb;
  v_dr    bigint;
  v_cr    bigint;
begin
  if not exists (select 1 from public.gl_account where tenant_id = p_tenant_id) then
    return null;
  end if;
  if exists (select 1 from public.journal_entry where tenant_id = p_tenant_id and source_kind = p_kind and source_id = p_source_id) then
    return null;
  end if;

  select jsonb_agg(jsonb_build_object('account_id', a.id, 'debit', coalesce((l ->> 'debit')::bigint, 0), 'credit', coalesce((l ->> 'credit')::bigint, 0), 'memo', l ->> 'memo'))
    into v_lines
    from jsonb_array_elements(p_lines) l
    left join public.gl_account a on a.tenant_id = p_tenant_id and a.code = l ->> 'code' and a.is_active
   where coalesce((l ->> 'debit')::bigint, 0) > 0 or coalesce((l ->> 'credit')::bigint, 0) > 0;
  if v_lines is null or exists (select 1 from jsonb_array_elements(v_lines) l where l ->> 'account_id' is null) then
    return null;
  end if;
  select sum((l ->> 'debit')::bigint), sum((l ->> 'credit')::bigint) into v_dr, v_cr from jsonb_array_elements(v_lines) l;
  if v_dr <> v_cr then
    raise exception 'NOT_BALANCED' using errcode = '22023', detail = format('%s %s: debits %s, credits %s', p_kind, p_source_id, v_dr, v_cr);
  end if;

  insert into public.journal_entry (tenant_id, entry_no, entry_date, narration, source_kind, source_id)
  values (p_tenant_id, app.fn_next_journal_no(p_tenant_id, p_date), p_date, left(p_narration, 500), p_kind, p_source_id)
  returning id into v_id;
  insert into public.journal_line (tenant_id, entry_id, account_id, debit, credit, memo)
  select p_tenant_id, v_id, (l ->> 'account_id')::uuid, (l ->> 'debit')::bigint, (l ->> 'credit')::bigint, nullif(btrim(l ->> 'memo'), '')
    from jsonb_array_elements(v_lines) l;
  return v_id;
end;
$$;

-- The account to use: the mapped code when the chart has it, else the default.
create or replace function app.fn_gl_code(p_tenant_id uuid, p_code text, p_default text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case when exists (select 1 from public.gl_account where tenant_id = p_tenant_id and code = btrim(p_code) and is_active)
              then btrim(p_code) else p_default end;
$$;

-- ── one function per source ───────────────────────────────────────────────

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
    from (select app.fn_gl_code(p.tenant_id, h.gl_code, '4000') as code, string_agg(distinct h.name_en, ', ') as name, sum(fa.amount_paisa) as amount
            from public.fee_payment_allocation fa
            join public.fee_head h on h.id = fa.fee_head_id
           where fa.payment_id = p_id
           group by 1) x;
  return app.fn_gl_post_system(p.tenant_id, p.value_date,
    'Fee received' || coalesce(' · ' || p.reference_no, ''), 'fee_payment', p.id, v_lines);
end;
$$;

create or replace function app.fn_gl_post_expense_voucher(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.expense_voucher%rowtype;
  v_code text;
begin
  select * into v from public.expense_voucher where id = p_id;
  if not found or v.status <> 'paid' then
    return null;
  end if;
  select app.fn_gl_code(v.tenant_id, h.gl_code, '5900') into v_code from public.expense_head h where h.id = v.head_id;
  return app.fn_gl_post_system(v.tenant_id, (v.paid_at at time zone 'Asia/Karachi')::date,
    'Expense paid to ' || v.payee_name, 'expense_voucher', v.id,
    jsonb_build_array(
      jsonb_build_object('code', v_code, 'debit', v.amount_paisa, 'memo', v.narrative),
      jsonb_build_object('code', case when nullif(btrim(v.paid_reference), '') is null then '1000' else '1010' end, 'credit', v.amount_paisa)));
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
  v_net bigint; v_tax bigint; v_loan bigint;
  v_month text;
begin
  select * into r from public.payroll_run where id = p_id;
  if not found or r.status not in ('locked', 'paid') then
    return;
  end if;
  select coalesce(sum(net_paisa), 0), coalesce(sum(tax_withholding_paisa + other_deductions_paisa), 0), coalesce(sum(loan_recovery_paisa), 0)
    into v_net, v_tax, v_loan
    from public.payroll_run_line where payroll_run_id = p_id;
  v_month := to_char(r.period_month, 'Mon YYYY');
  -- Debit is built from the credits so the voucher balances whatever the
  -- line arithmetic; attendance deductions are pay never earned, not a payable.
  perform app.fn_gl_post_system(r.tenant_id, (coalesce(r.locked_at, now()) at time zone 'Asia/Karachi')::date,
    'Salaries for ' || v_month, 'payroll_accrual', r.id,
    jsonb_build_array(
      jsonb_build_object('code', '5000', 'debit', v_net + v_tax + v_loan),
      jsonb_build_object('code', '2100', 'credit', v_net, 'memo', 'Net pay'),
      jsonb_build_object('code', '2400', 'credit', v_tax, 'memo', 'Tax and deductions'),
      jsonb_build_object('code', '1300', 'credit', v_loan, 'memo', 'Loan recoveries')));
  if r.status = 'paid' then
    perform app.fn_gl_post_system(r.tenant_id, (now() at time zone 'Asia/Karachi')::date,
      'Salaries paid for ' || v_month, 'payroll_payment', r.id,
      jsonb_build_array(jsonb_build_object('code', '2100', 'debit', v_net), jsonb_build_object('code', '1010', 'credit', v_net)));
  end if;
end;
$$;

create or replace function app.fn_gl_post_inv_sale(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.inv_sale%rowtype;
  v_return boolean;
begin
  select * into s from public.inv_sale where id = p_id;
  if not found or s.settlement <> 'cash' then
    return null;
  end if;
  v_return := s.doc_type = 'credit_note';
  return app.fn_gl_post_system(s.tenant_id, (s.sold_at at time zone 'Asia/Karachi')::date,
    case when v_return then 'Shop refund ' else 'Shop sale ' end || s.serial || ' · ' || s.student_name, 'inv_sale', s.id,
    jsonb_build_array(
      jsonb_build_object('code', '1000', 'debit', case when v_return then 0 else s.total end, 'credit', case when v_return then s.total else 0 end),
      jsonb_build_object('code', '4300', 'debit', case when v_return then s.total else 0 end, 'credit', case when v_return then 0 else s.total end)));
end;
$$;

create or replace function app.fn_gl_post_petty_cash(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.petty_cash_txn%rowtype;
  v_code text;
begin
  select * into t from public.petty_cash_txn where id = p_id;
  if not found then
    return null;
  end if;
  if t.direction = 'in' then
    return app.fn_gl_post_system(t.tenant_id, (t.created_at at time zone 'Asia/Karachi')::date, 'Petty cash top-up', 'petty_cash', t.id,
      jsonb_build_array(jsonb_build_object('code', '1000', 'debit', t.amount_paisa), jsonb_build_object('code', '1010', 'credit', t.amount_paisa)));
  end if;
  select app.fn_gl_code(t.tenant_id, h.gl_code, '5900') into v_code from public.expense_head h where h.id = t.expense_head_id;
  return app.fn_gl_post_system(t.tenant_id, (t.created_at at time zone 'Asia/Karachi')::date,
    'Petty cash' || coalesce(' · ' || t.narrative, ''), 'petty_cash', t.id,
    jsonb_build_array(jsonb_build_object('code', v_code, 'debit', t.amount_paisa), jsonb_build_object('code', '1000', 'credit', t.amount_paisa)));
end;
$$;

revoke execute on function app.fn_gl_post_system(uuid, date, text, text, uuid, jsonb) from public, anon, authenticated;
revoke execute on function app.fn_gl_code(uuid, text, text) from public, anon, authenticated;
revoke execute on function app.fn_gl_post_fee_payment(uuid) from public, anon, authenticated;
revoke execute on function app.fn_gl_post_expense_voucher(uuid) from public, anon, authenticated;
revoke execute on function app.fn_gl_post_payroll(uuid) from public, anon, authenticated;
revoke execute on function app.fn_gl_post_inv_sale(uuid) from public, anon, authenticated;
revoke execute on function app.fn_gl_post_petty_cash(uuid) from public, anon, authenticated;

-- ── triggers ──────────────────────────────────────────────────────────────

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
  end case;
  return null;
end;
$$;
revoke execute on function app.tg_gl_post() from public, anon, authenticated;

-- Allocations are inserted after the payment row in the same transaction, so
-- the fee posting waits until commit to see them.
create constraint trigger fee_payment_gl_post after insert on public.fee_payment
  deferrable initially deferred for each row execute function app.tg_gl_post();
create trigger expense_voucher_gl_post after insert or update of status on public.expense_voucher
  for each row when (new.status = 'paid') execute function app.tg_gl_post();
create trigger payroll_run_gl_post after insert or update of status on public.payroll_run
  for each row when (new.status in ('locked', 'paid')) execute function app.tg_gl_post();
create trigger inv_sale_gl_post after insert on public.inv_sale
  for each row execute function app.tg_gl_post();
create trigger petty_cash_txn_gl_post after insert on public.petty_cash_txn
  for each row execute function app.tg_gl_post();

-- ── backfill ──────────────────────────────────────────────────────────────

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
  select count(*) into v_after from public.journal_entry where tenant_id = v_tenant and source_kind is not null;
  return v_after - v_before;
end;
$$;
revoke execute on function public.post_ledger_backfill() from public, anon;
grant execute on function public.post_ledger_backfill() to authenticated;

-- ── statements ────────────────────────────────────────────────────────────
-- Invoker functions: RLS limits them to ledger readers, like trial_balance.

create or replace function public.income_statement(p_from date, p_to date)
returns table (account_id uuid, code text, name text, type public.gl_account_type, amount bigint)
language sql
stable
set search_path = ''
as $$
  select a.id, a.code, a.name, a.type,
         (case when a.type = 'income' then sum(l.credit - l.debit) else sum(l.debit - l.credit) end)::bigint
    from public.gl_account a
    join public.journal_line l on l.account_id = a.id
    join public.journal_entry e on e.id = l.entry_id and e.entry_date between p_from and p_to
   where a.type in ('income', 'expense')
   group by a.id, a.code, a.name, a.type
  having sum(l.debit - l.credit) <> 0
   order by a.code;
$$;
revoke execute on function public.income_statement(date, date) from public, anon;
grant execute on function public.income_statement(date, date) to authenticated;

-- Assets, liabilities and equity as of a date. Until periods are closed into
-- retained earnings, all income less expenses to date shows as one equity
-- line, which is what makes the two sides agree.
create or replace function public.balance_sheet(p_as_of date)
returns table (account_id uuid, code text, name text, type public.gl_account_type, amount bigint)
language sql
stable
set search_path = ''
as $$
  with bal as (
    select a.id, a.code, a.name, a.type, sum(l.debit - l.credit) as dr
      from public.gl_account a
      join public.journal_line l on l.account_id = a.id
      join public.journal_entry e on e.id = l.entry_id and e.entry_date <= p_as_of
     group by a.id, a.code, a.name, a.type
  )
  select id, code, name, type, (case when type = 'asset' then dr else -dr end)::bigint
    from bal where type in ('asset', 'liability', 'equity') and dr <> 0
  union all
  select null, null, 'Surplus to date (income less expenses)', 'equity'::public.gl_account_type, (-sum(dr))::bigint
    from bal where type in ('income', 'expense')
  having coalesce(sum(dr), 0) <> 0
  order by 4, 2 nulls last;
$$;
revoke execute on function public.balance_sheet(date) from public, anon;
grant execute on function public.balance_sheet(date) to authenticated;

-- ── posting accounts per fee and expense head ─────────────────────────────

create or replace function public.set_head_gl_code(p_kind text, p_head_id uuid, p_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_code   text := nullif(btrim(coalesce(p_code, '')), '');
  v_type   public.gl_account_type;
begin
  perform app.fn_assert_accountant();
  if v_code is not null then
    select type into v_type from public.gl_account where tenant_id = v_tenant and code = v_code and is_active;
    if v_type is null or v_type <> (case p_kind when 'fee' then 'income'::public.gl_account_type else 'expense'::public.gl_account_type end) then
      raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002', hint = 'Fee heads post to an income account and expense heads to an expense account.';
    end if;
  end if;
  if p_kind = 'fee' then
    update public.fee_head set gl_code = v_code where id = p_head_id and tenant_id = v_tenant;
  elsif p_kind = 'expense' then
    update public.expense_head set gl_code = v_code where id = p_head_id and tenant_id = v_tenant;
  else
    raise exception 'KIND_INVALID' using errcode = '22023';
  end if;
  if not found then
    raise exception 'HEAD_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.set_head_gl_code(text, uuid, text) from public, anon;
grant execute on function public.set_head_gl_code(text, uuid, text) to authenticated;
