-- General ledger, part 1: chart of accounts, journal vouchers, trial balance.
--
-- Double entry, in paisa like the rest of the money in this schema. A voucher
-- (journal_entry) has two or more lines, each a debit or a credit on one
-- account, and only posts when debits equal credits. Posted vouchers are
-- never edited or deleted: a mistake is undone by reverse_journal_entry(),
-- which posts the mirror image and links the two. Voucher numbers are gapless
-- per school (JV-2026-00001), from a locked counter row like the receipt
-- counters, because a missing voucher number is the first thing an auditor asks
-- about.
--
-- Automatic posting from fee receipts, payroll and expenses, and the balance
-- sheet and income statement, come in later migrations; this is the ledger
-- they will post into.

create type public.gl_account_type as enum ('asset', 'liability', 'equity', 'income', 'expense');

create table public.gl_account (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  code       text not null check (code ~ '^[0-9]{3,8}$'),
  name       text not null check (length(btrim(name)) between 1 and 150),
  type       public.gl_account_type not null,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index uq_gl_account_code on public.gl_account (tenant_id, code);

create table public.journal_counter (
  tenant_id uuid not null references public.tenant(id) on delete cascade,
  year      int not null,
  last_no   int not null default 0,
  primary key (tenant_id, year)
);

create table public.journal_entry (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  entry_no    text not null,
  entry_date  date not null,
  narration   text not null check (length(btrim(narration)) between 1 and 500),
  reversal_of uuid references public.journal_entry(id),
  reversed_by uuid references public.journal_entry(id),
  created_by  uuid not null default auth.uid() references auth.users(id),
  created_at  timestamptz not null default now()
);
create unique index uq_journal_entry_no on public.journal_entry (tenant_id, entry_no);
create index idx_journal_entry_date on public.journal_entry (tenant_id, entry_date desc);

create table public.journal_line (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  entry_id   uuid not null references public.journal_entry(id) on delete cascade,
  account_id uuid not null references public.gl_account(id),
  debit      bigint not null default 0 check (debit >= 0),
  credit     bigint not null default 0 check (credit >= 0),
  memo       text check (memo is null or length(memo) <= 200),
  constraint chk_journal_line_one_side check ((debit > 0) <> (credit > 0))
);
create index idx_journal_line_entry on public.journal_line (entry_id);
create index idx_journal_line_account on public.journal_line (account_id);
create index idx_journal_line_tenant on public.journal_line (tenant_id);

alter table public.gl_account enable row level security;
alter table public.journal_counter enable row level security;
alter table public.journal_entry enable row level security;
alter table public.journal_line enable row level security;

create or replace function app.fn_ledger_reader()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('super_admin', 'owner', 'principal', 'accountant');
$$;

create policy gl_account_read on public.gl_account for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_ledger_reader());
create policy journal_entry_read on public.journal_entry for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_ledger_reader());
create policy journal_line_read on public.journal_line for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_ledger_reader());
create policy journal_counter_none on public.journal_counter for select to authenticated using (false);

select app.fn_block_portal_roles('public.gl_account');
select app.fn_block_portal_roles('public.journal_counter');
select app.fn_block_portal_roles('public.journal_entry');
select app.fn_block_portal_roles('public.journal_line');

-- Posted vouchers are permanent. The only update allowed is stamping
-- reversed_by on the original when its reversal posts.
create or replace function app.tg_journal_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if pg_trigger_depth() > 1 then
      return old;
    end if;
    raise exception 'JOURNAL_IMMUTABLE' using errcode = '42501';
  end if;
  if tg_table_name = 'journal_entry' then
    if old.reversed_by is null and new.reversed_by is not null
       and (new.entry_no, new.entry_date, new.narration, new.reversal_of) is not distinct from (old.entry_no, old.entry_date, old.narration, old.reversal_of) then
      return new;
    end if;
  end if;
  raise exception 'JOURNAL_IMMUTABLE' using errcode = '42501';
end;
$$;
create trigger journal_entry_immutable before update or delete on public.journal_entry
  for each row execute function app.tg_journal_immutable();
create trigger journal_line_immutable before update or delete on public.journal_line
  for each row execute function app.tg_journal_immutable();

-- ── chart of accounts ─────────────────────────────────────────────────────

create or replace function app.fn_assert_accountant()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is null or app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function app.fn_assert_accountant() from public, anon, authenticated;

-- A standard chart for a Pakistani private school, created the first time
-- accounts are opened. Codes leave room for a school's own accounts.
create or replace function public.ensure_chart_of_accounts()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  perform app.fn_assert_accountant();
  if exists (select 1 from public.gl_account where tenant_id = app.auth_tenant_id()) then
    return 0;
  end if;
  insert into public.gl_account (tenant_id, code, name, type)
  select app.auth_tenant_id(), c.code, c.name, c.type::public.gl_account_type
    from (values
      ('1000', 'Cash in hand', 'asset'), ('1010', 'Bank', 'asset'), ('1100', 'Fees receivable', 'asset'),
      ('1200', 'Stock (uniforms, books)', 'asset'), ('1300', 'Advances to staff', 'asset'), ('1500', 'Furniture and equipment', 'asset'),
      ('2000', 'Accounts payable', 'liability'), ('2100', 'Salaries payable', 'liability'), ('2200', 'Fees received in advance', 'liability'),
      ('2300', 'Security deposits held', 'liability'), ('2400', 'Tax and EOBI payable', 'liability'),
      ('3000', 'Owner''s capital', 'equity'), ('3100', 'Retained earnings', 'equity'),
      ('4000', 'Tuition fee income', 'income'), ('4100', 'Admission fee income', 'income'), ('4200', 'Transport fee income', 'income'),
      ('4300', 'Sales of uniforms and books', 'income'), ('4900', 'Other income', 'income'),
      ('5000', 'Salaries', 'expense'), ('5100', 'Utilities', 'expense'), ('5200', 'Rent', 'expense'),
      ('5300', 'Stationery and supplies', 'expense'), ('5400', 'Repairs and maintenance', 'expense'),
      ('5500', 'Transport running costs', 'expense'), ('5600', 'Cost of goods sold', 'expense'), ('5900', 'Other expenses', 'expense')
    ) as c(code, name, type);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.ensure_chart_of_accounts() from public, anon;
grant execute on function public.ensure_chart_of_accounts() to authenticated;

create or replace function public.save_gl_account(p_code text, p_name text, p_type public.gl_account_type, p_is_active boolean default true, p_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.fn_assert_accountant();
  if p_id is null then
    insert into public.gl_account (tenant_id, code, name, type, is_active)
    values (app.auth_tenant_id(), btrim(p_code), btrim(p_name), p_type, coalesce(p_is_active, true))
    returning id into v_id;
  else
    -- An account with postings keeps its type: changing asset to expense
    -- would silently move history from the balance sheet to the P&L.
    if exists (select 1 from public.journal_line where account_id = p_id)
       and exists (select 1 from public.gl_account where id = p_id and type <> p_type) then
      raise exception 'ACCOUNT_TYPE_LOCKED' using errcode = '22023';
    end if;
    update public.gl_account set code = btrim(p_code), name = btrim(p_name), type = p_type, is_active = coalesce(p_is_active, true)
     where id = p_id and tenant_id = app.auth_tenant_id()
    returning id into v_id;
    if v_id is null then
      raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
end;
$$;
revoke execute on function public.save_gl_account(text, text, public.gl_account_type, boolean, uuid) from public, anon;
grant execute on function public.save_gl_account(text, text, public.gl_account_type, boolean, uuid) to authenticated;

-- ── vouchers ──────────────────────────────────────────────────────────────

create or replace function app.fn_next_journal_no(p_tenant_id uuid, p_date date)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_year int := extract(year from p_date)::int;
  v_no   int;
begin
  insert into public.journal_counter (tenant_id, year) values (p_tenant_id, v_year) on conflict do nothing;
  update public.journal_counter set last_no = last_no + 1 where tenant_id = p_tenant_id and year = v_year returning last_no into v_no;
  return 'JV-' || v_year || '-' || lpad(v_no::text, 5, '0');
end;
$$;
revoke execute on function app.fn_next_journal_no(uuid, date) from public, anon, authenticated;

-- p_lines: [{"account_id": uuid, "debit": paisa, "credit": paisa, "memo": text}, ...]
create or replace function public.post_journal_entry(p_entry_date date, p_narration text, p_lines jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid;
  v_dr        bigint;
  v_cr        bigint;
begin
  perform app.fn_assert_accountant();
  if p_entry_date is null or p_entry_date > current_date then
    raise exception 'DATE_INVALID' using errcode = '22023', hint = 'A voucher cannot be dated in the future.';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'LINES_REQUIRED' using errcode = '22023', hint = 'A voucher needs at least two lines.';
  end if;
  if exists (select 1 from jsonb_array_elements(p_lines) l
              where not exists (select 1 from public.gl_account a
                                 where a.id = (l ->> 'account_id')::uuid and a.tenant_id = v_tenant_id and a.is_active)) then
    raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002';
  end if;
  select coalesce(sum(coalesce((l ->> 'debit')::bigint, 0)), 0), coalesce(sum(coalesce((l ->> 'credit')::bigint, 0)), 0)
    into v_dr, v_cr from jsonb_array_elements(p_lines) l;
  if v_dr <> v_cr or v_dr = 0 then
    raise exception 'NOT_BALANCED' using errcode = '22023', detail = format('debits %s, credits %s', v_dr, v_cr);
  end if;

  insert into public.journal_entry (tenant_id, entry_no, entry_date, narration)
  values (v_tenant_id, app.fn_next_journal_no(v_tenant_id, p_entry_date), p_entry_date, btrim(p_narration))
  returning id into v_id;
  insert into public.journal_line (tenant_id, entry_id, account_id, debit, credit, memo)
  select v_tenant_id, v_id, (l ->> 'account_id')::uuid, coalesce((l ->> 'debit')::bigint, 0), coalesce((l ->> 'credit')::bigint, 0), nullif(btrim(l ->> 'memo'), '')
    from jsonb_array_elements(p_lines) l;
  return v_id;
end;
$$;
revoke execute on function public.post_journal_entry(date, text, jsonb) from public, anon;
grant execute on function public.post_journal_entry(date, text, jsonb) to authenticated;

create or replace function public.reverse_journal_entry(p_entry_id uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_orig public.journal_entry%rowtype;
  v_id   uuid;
begin
  perform app.fn_assert_accountant();
  select * into v_orig from public.journal_entry where id = p_entry_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'ENTRY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_orig.reversed_by is not null or v_orig.reversal_of is not null then
    raise exception 'CANNOT_REVERSE' using errcode = '22023', hint = 'This voucher is already a reversal or has been reversed.';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;

  insert into public.journal_entry (tenant_id, entry_no, entry_date, narration, reversal_of)
  values (v_orig.tenant_id, app.fn_next_journal_no(v_orig.tenant_id, current_date), current_date,
          left('Reversal of ' || v_orig.entry_no || ': ' || btrim(p_reason), 500), v_orig.id)
  returning id into v_id;
  insert into public.journal_line (tenant_id, entry_id, account_id, debit, credit, memo)
  select tenant_id, v_id, account_id, credit, debit, memo from public.journal_line where entry_id = v_orig.id;
  update public.journal_entry set reversed_by = v_id where id = v_orig.id;
  return v_id;
end;
$$;
revoke execute on function public.reverse_journal_entry(uuid, text) from public, anon;
grant execute on function public.reverse_journal_entry(uuid, text) to authenticated;

-- ── trial balance ─────────────────────────────────────────────────────────
-- Every account's total debits and credits up to a date, and its balance on
-- its natural side. Invoker: RLS limits it to ledger readers.
create or replace function public.trial_balance(p_as_of date)
returns table (account_id uuid, code text, name text, type public.gl_account_type, debit bigint, credit bigint, balance bigint)
language sql
stable
set search_path = ''
as $$
  select a.id, a.code, a.name, a.type,
         coalesce(sum(l.debit), 0)::bigint, coalesce(sum(l.credit), 0)::bigint,
         (case when a.type in ('asset', 'expense') then coalesce(sum(l.debit - l.credit), 0)
               else coalesce(sum(l.credit - l.debit), 0) end)::bigint
    from public.gl_account a
    left join public.journal_line l on l.account_id = a.id
     and exists (select 1 from public.journal_entry e where e.id = l.entry_id and e.entry_date <= p_as_of)
   group by a.id, a.code, a.name, a.type
  having coalesce(sum(l.debit), 0) <> 0 or coalesce(sum(l.credit), 0) <> 0
   order by a.code;
$$;
revoke execute on function public.trial_balance(date) from public, anon;
grant execute on function public.trial_balance(date) to authenticated;
