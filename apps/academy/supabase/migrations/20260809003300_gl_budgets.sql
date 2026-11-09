-- General ledger, part 6: budgets and budget vs actual.
--
-- A budget is an amount per income or expense account per month, on the
-- account's natural side. Financial years run July to June, as on the
-- Accounts page; a year is named by the calendar year it starts in. Actuals
-- come from posted vouchers, leaving out year-end closing vouchers like the
-- income statement does.

create table public.gl_budget (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  account_id   uuid not null references public.gl_account(id),
  month        date not null check (extract(day from month) = 1),
  amount_paisa bigint not null check (amount_paisa > 0),
  updated_by   uuid default auth.uid() references auth.users(id),
  updated_at   timestamptz not null default now()
);
create unique index uq_gl_budget_month on public.gl_budget (tenant_id, account_id, month);
create index idx_gl_budget_account on public.gl_budget (account_id);

alter table public.gl_budget enable row level security;
create policy gl_budget_read on public.gl_budget for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_ledger_reader());
select app.fn_block_portal_roles('public.gl_budget');
create trigger gl_budget_audit after insert or update or delete on public.gl_budget
  for each row execute function app.tg_audit_row();

-- p_amounts: twelve amounts in paisa, July first. A zero clears that month.
create or replace function public.save_account_budget(p_account_id uuid, p_fy_start_year int, p_amounts bigint[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_start  date;
begin
  perform app.fn_assert_accountant();
  if not exists (select 1 from public.gl_account where id = p_account_id and tenant_id = v_tenant and type in ('income', 'expense')) then
    raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002', hint = 'Budgets are for income and expense accounts.';
  end if;
  if p_fy_start_year is null or p_fy_start_year not between 2000 and 2100 then
    raise exception 'YEAR_INVALID' using errcode = '22023';
  end if;
  if p_amounts is null or cardinality(p_amounts) <> 12 or exists (select 1 from unnest(p_amounts) a where a is null or a < 0) then
    raise exception 'AMOUNTS_INVALID' using errcode = '22023', hint = 'Give twelve amounts, July to June, none negative.';
  end if;
  v_start := make_date(p_fy_start_year, 7, 1);

  delete from public.gl_budget b
   using unnest(p_amounts) with ordinality as a(amount, i)
   where b.tenant_id = v_tenant and b.account_id = p_account_id
     and b.month = (v_start + make_interval(months => (a.i - 1)::int))::date and a.amount = 0;
  insert into public.gl_budget (tenant_id, account_id, month, amount_paisa)
  select v_tenant, p_account_id, (v_start + make_interval(months => (a.i - 1)::int))::date, a.amount
    from unnest(p_amounts) with ordinality as a(amount, i)
   where a.amount > 0
  on conflict (tenant_id, account_id, month) do update
    set amount_paisa = excluded.amount_paisa, updated_by = auth.uid(), updated_at = now()
    where public.gl_budget.amount_paisa is distinct from excluded.amount_paisa;
end;
$$;
revoke execute on function public.save_account_budget(uuid, int, bigint[]) from public, anon;
grant execute on function public.save_account_budget(uuid, int, bigint[]) to authenticated;

-- One row per account and month of the year that has a budget or a posting.
-- Invoker: RLS limits it to ledger readers, like trial_balance.
create or replace function public.budget_vs_actual(p_fy_start_year int)
returns table (account_id uuid, code text, name text, type public.gl_account_type, month date, budget bigint, actual bigint)
language sql
stable
set search_path = ''
as $$
  with actual as (
    select l.account_id, date_trunc('month', e.entry_date)::date as month,
           sum(case when a.type = 'income' then l.credit - l.debit else l.debit - l.credit end) as amount
      from public.journal_line l
      join public.journal_entry e on e.id = l.entry_id
                                 and e.entry_date between make_date(p_fy_start_year, 7, 1) and make_date(p_fy_start_year + 1, 6, 30)
                                 and e.source_kind is distinct from 'year_close'
      join public.gl_account a on a.id = l.account_id and a.type in ('income', 'expense')
     group by 1, 2
  ),
  budget as (
    select b.account_id, b.month, b.amount_paisa as amount
      from public.gl_budget b
     where b.month between make_date(p_fy_start_year, 7, 1) and make_date(p_fy_start_year + 1, 6, 1)
  )
  select a.id, a.code, a.name, a.type, k.month, coalesce(b.amount, 0)::bigint, coalesce(x.amount, 0)::bigint
    from (select account_id, month from budget union select account_id, month from actual) k
    join public.gl_account a on a.id = k.account_id
    left join budget b on b.account_id = k.account_id and b.month = k.month
    left join actual x on x.account_id = k.account_id and x.month = k.month
   order by a.type, a.code, k.month;
$$;
revoke execute on function public.budget_vs_actual(int) from public, anon;
grant execute on function public.budget_vs_actual(int) to authenticated;
