-- General ledger, part 3: opening balances and closing a financial year.
--
-- Opening balances: a school that starts on Seena mid-life already has cash,
-- bank, payables and so on. They post once, as one voucher; whatever does not
-- balance goes to Owner's capital (3000).
--
-- Year close: income and expense accounts are emptied into Retained earnings
-- (3100) by one closing voucher dated the year end, and every date up to the
-- year end is locked. A manual voucher dated in a locked period is refused; an
-- automatic posting for a locked date (a backdated fee receipt, say) lands on
-- the first open day instead, so the fee counter never stops.

alter table public.journal_entry drop constraint journal_entry_source_kind_check;
alter table public.journal_entry add constraint journal_entry_source_kind_check
  check (source_kind in ('fee_payment', 'expense_voucher', 'payroll_accrual', 'payroll_payment', 'inv_sale', 'petty_cash', 'opening', 'year_close'));

create table public.gl_setting (
  tenant_id      uuid primary key references public.tenant(id) on delete cascade,
  locked_through date,
  updated_at     timestamptz not null default now()
);
alter table public.gl_setting enable row level security;
create policy gl_setting_read on public.gl_setting for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_ledger_reader());
select app.fn_block_portal_roles('public.gl_setting');

create or replace function app.tg_journal_period_lock()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_locked date;
begin
  select locked_through into v_locked from public.gl_setting where tenant_id = new.tenant_id;
  if v_locked is null or new.entry_date > v_locked or new.source_kind = 'year_close' then
    return new;
  end if;
  if new.source_kind is null or new.source_kind = 'opening' then
    raise exception 'PERIOD_LOCKED' using errcode = '22023', detail = format('locked through %s', v_locked);
  end if;
  new.entry_date := v_locked + 1;
  return new;
end;
$$;
revoke execute on function app.tg_journal_period_lock() from public, anon, authenticated;
create trigger journal_entry_period_lock before insert on public.journal_entry
  for each row execute function app.tg_journal_period_lock();

-- Closing vouchers are bookkeeping, not the year's results: leave them out,
-- or every closed year would show nothing earned and nothing spent.
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
                               and e.source_kind is distinct from 'year_close'
   where a.type in ('income', 'expense')
   group by a.id, a.code, a.name, a.type
  having sum(l.debit - l.credit) <> 0
   order by a.code;
$$;

-- p_lines: [{"account_id": uuid, "amount": paisa}] on each account's natural
-- side (assets as debits, liabilities and equity as credits).
create or replace function public.post_opening_balances(p_date date, p_lines jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant  uuid := app.auth_tenant_id();
  v_capital uuid;
  v_lines   jsonb;
  v_net     bigint;
  v_id      uuid;
begin
  perform app.fn_assert_accountant();
  if exists (select 1 from public.journal_entry where tenant_id = v_tenant and source_kind = 'opening') then
    raise exception 'OPENING_ALREADY_POSTED' using errcode = '22023', hint = 'Correct opening balances with a journal voucher.';
  end if;
  if p_date is null or p_date > current_date then
    raise exception 'DATE_INVALID' using errcode = '22023';
  end if;
  select id into v_capital from public.gl_account where tenant_id = v_tenant and code = '3000' and is_active;
  if v_capital is null then
    raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002', hint = 'Opening balances settle against Owner''s capital (3000).';
  end if;
  if jsonb_typeof(p_lines) <> 'array'
     or exists (select 1 from jsonb_array_elements(p_lines) l
                 where coalesce((l ->> 'amount')::bigint, 0) < 0
                    or not exists (select 1 from public.gl_account a where a.id = (l ->> 'account_id')::uuid and a.tenant_id = v_tenant
                                      and a.is_active and a.type in ('asset', 'liability', 'equity'))) then
    raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002', hint = 'Opening balances are for asset, liability and equity accounts.';
  end if;

  select jsonb_agg(jsonb_build_object('account_id', a.id,
           'debit', case when a.type = 'asset' then (l ->> 'amount')::bigint else 0 end,
           'credit', case when a.type = 'asset' then 0 else (l ->> 'amount')::bigint end)),
         coalesce(sum(case when a.type = 'asset' then (l ->> 'amount')::bigint else -(l ->> 'amount')::bigint end), 0)
    into v_lines, v_net
    from jsonb_array_elements(p_lines) l
    join public.gl_account a on a.id = (l ->> 'account_id')::uuid
   where (l ->> 'amount')::bigint > 0;
  if v_lines is null then
    raise exception 'LINES_REQUIRED' using errcode = '22023';
  end if;
  if v_net <> 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id', v_capital,
      'debit', greatest(-v_net, 0), 'credit', greatest(v_net, 0)));
  end if;

  insert into public.journal_entry (tenant_id, entry_no, entry_date, narration, source_kind, source_id)
  values (v_tenant, app.fn_next_journal_no(v_tenant, p_date), p_date, 'Opening balances', 'opening', v_tenant)
  returning id into v_id;
  insert into public.journal_line (tenant_id, entry_id, account_id, debit, credit)
  select v_tenant, v_id, (l ->> 'account_id')::uuid, (l ->> 'debit')::bigint, (l ->> 'credit')::bigint
    from jsonb_array_elements(v_lines) l;
  return v_id;
end;
$$;
revoke execute on function public.post_opening_balances(date, jsonb) from public, anon;
grant execute on function public.post_opening_balances(date, jsonb) to authenticated;

create or replace function public.close_financial_year(p_year_end date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant   uuid := app.auth_tenant_id();
  v_locked   date;
  v_retained uuid;
  v_id       uuid;
  v_net      bigint;
begin
  perform app.fn_assert_accountant();
  if p_year_end is null or p_year_end >= current_date then
    raise exception 'DATE_INVALID' using errcode = '22023', hint = 'Close a year only after it has ended.';
  end if;
  select locked_through into v_locked from public.gl_setting where tenant_id = v_tenant for update;
  if v_locked is not null and p_year_end <= v_locked then
    raise exception 'PERIOD_LOCKED' using errcode = '22023', detail = format('locked through %s', v_locked);
  end if;
  select id into v_retained from public.gl_account where tenant_id = v_tenant and code = '3100' and is_active;
  if v_retained is null then
    raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002', hint = 'The surplus closes to Retained earnings (3100).';
  end if;

  create temp table _close on commit drop as
    select l.account_id, sum(l.debit - l.credit)::bigint as dr
      from public.journal_line l
      join public.journal_entry e on e.id = l.entry_id and e.entry_date <= p_year_end
      join public.gl_account a on a.id = l.account_id and a.type in ('income', 'expense')
     where l.tenant_id = v_tenant
     group by l.account_id
    having sum(l.debit - l.credit) <> 0;

  if exists (select 1 from _close) then
    select sum(dr) into v_net from _close;
    insert into public.journal_entry (tenant_id, entry_no, entry_date, narration, source_kind, source_id)
    values (v_tenant, app.fn_next_journal_no(v_tenant, p_year_end), p_year_end,
            'Year-end close to retained earnings, year ending ' || to_char(p_year_end, 'DD Mon YYYY'), 'year_close', gen_random_uuid())
    returning id into v_id;
    insert into public.journal_line (tenant_id, entry_id, account_id, debit, credit)
    select v_tenant, v_id, account_id, greatest(-dr, 0), greatest(dr, 0) from _close;
    -- dr is expenses less income: a surplus (negative) credits retained earnings.
    insert into public.journal_line (tenant_id, entry_id, account_id, debit, credit)
    select v_tenant, v_id, v_retained, greatest(v_net, 0), greatest(-v_net, 0) where v_net <> 0;
  end if;

  insert into public.gl_setting (tenant_id, locked_through) values (v_tenant, p_year_end)
  on conflict (tenant_id) do update set locked_through = excluded.locked_through, updated_at = now();
  return v_id;
end;
$$;
revoke execute on function public.close_financial_year(date) from public, anon;
grant execute on function public.close_financial_year(date) to authenticated;
