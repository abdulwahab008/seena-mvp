-- General ledger, part 4: cost centres.
--
-- A cost centre (a campus wing, the transport fleet, the hostel) is an
-- optional tag on a voucher line, so the same account can be reported per
-- centre. Untagged lines stay valid and report as "unallocated". A centre
-- in use is deactivated, never deleted, because posted lines point at it.

create table public.gl_cost_center (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  code       text not null check (code ~ '^[A-Z0-9-]{1,12}$'),
  name       text not null check (length(btrim(name)) between 1 and 150),
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index uq_gl_cost_center_code on public.gl_cost_center (tenant_id, code);

alter table public.gl_cost_center enable row level security;
create policy gl_cost_center_read on public.gl_cost_center for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_ledger_reader());
select app.fn_block_portal_roles('public.gl_cost_center');
create trigger gl_cost_center_audit after insert or update or delete on public.gl_cost_center
  for each row execute function app.tg_audit_row();

alter table public.journal_line add column cost_center_id uuid references public.gl_cost_center(id);
create index idx_journal_line_cost_center on public.journal_line (cost_center_id) where cost_center_id is not null;

create or replace function public.save_gl_cost_center(p_code text, p_name text, p_is_active boolean default true, p_id uuid default null)
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
    insert into public.gl_cost_center (tenant_id, code, name, is_active)
    values (app.auth_tenant_id(), upper(btrim(p_code)), btrim(p_name), coalesce(p_is_active, true))
    returning id into v_id;
  else
    update public.gl_cost_center set code = upper(btrim(p_code)), name = btrim(p_name), is_active = coalesce(p_is_active, true)
     where id = p_id and tenant_id = app.auth_tenant_id()
    returning id into v_id;
    if v_id is null then
      raise exception 'COST_CENTER_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
end;
$$;
revoke execute on function public.save_gl_cost_center(text, text, boolean, uuid) from public, anon;
grant execute on function public.save_gl_cost_center(text, text, boolean, uuid) to authenticated;

-- Same as part 1, plus an optional "cost_center_id" on each line, which must
-- be an active centre of the same school.
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
  if exists (select 1 from jsonb_array_elements(p_lines) l
              where nullif(l ->> 'cost_center_id', '') is not null
                and not exists (select 1 from public.gl_cost_center c
                                 where c.id = (l ->> 'cost_center_id')::uuid and c.tenant_id = v_tenant_id and c.is_active)) then
    raise exception 'COST_CENTER_NOT_FOUND' using errcode = 'P0002';
  end if;
  select coalesce(sum(coalesce((l ->> 'debit')::bigint, 0)), 0), coalesce(sum(coalesce((l ->> 'credit')::bigint, 0)), 0)
    into v_dr, v_cr from jsonb_array_elements(p_lines) l;
  if v_dr <> v_cr or v_dr = 0 then
    raise exception 'NOT_BALANCED' using errcode = '22023', detail = format('debits %s, credits %s', v_dr, v_cr);
  end if;

  insert into public.journal_entry (tenant_id, entry_no, entry_date, narration)
  values (v_tenant_id, app.fn_next_journal_no(v_tenant_id, p_entry_date), p_entry_date, btrim(p_narration))
  returning id into v_id;
  insert into public.journal_line (tenant_id, entry_id, account_id, debit, credit, memo, cost_center_id)
  select v_tenant_id, v_id, (l ->> 'account_id')::uuid, coalesce((l ->> 'debit')::bigint, 0), coalesce((l ->> 'credit')::bigint, 0),
         nullif(btrim(l ->> 'memo'), ''), nullif(l ->> 'cost_center_id', '')::uuid
    from jsonb_array_elements(p_lines) l;
  return v_id;
end;
$$;

-- Same as part 1; the mirror lines keep their cost centre so a reversal
-- cancels out in the cost-centre report too.
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
  insert into public.journal_line (tenant_id, entry_id, account_id, debit, credit, memo, cost_center_id)
  select tenant_id, v_id, account_id, credit, debit, memo, cost_center_id from public.journal_line where entry_id = v_orig.id;
  update public.journal_entry set reversed_by = v_id where id = v_orig.id;
  return v_id;
end;
$$;

-- Income and expenses per cost centre for a period, one row per centre and
-- account; lines with no centre come back with a null cost_center_id.
-- Invoker: RLS limits it to ledger readers, like trial_balance.
create or replace function public.cost_center_report(p_from date, p_to date)
returns table (cost_center_id uuid, cost_center_code text, cost_center_name text, account_id uuid, code text, name text,
               type public.gl_account_type, amount bigint)
language sql
stable
set search_path = ''
as $$
  select c.id, c.code, c.name, a.id, a.code, a.name, a.type,
         (case when a.type = 'income' then sum(l.credit - l.debit) else sum(l.debit - l.credit) end)::bigint
    from public.journal_line l
    join public.journal_entry e on e.id = l.entry_id and e.entry_date between p_from and p_to
                               and e.source_kind is distinct from 'year_close'
    join public.gl_account a on a.id = l.account_id and a.type in ('income', 'expense')
    left join public.gl_cost_center c on c.id = l.cost_center_id
   group by c.id, c.code, c.name, a.id, a.code, a.name, a.type
  having sum(l.debit - l.credit) <> 0
   order by c.code nulls last, a.code;
$$;
revoke execute on function public.cost_center_report(date, date) from public, anon;
grant execute on function public.cost_center_report(date, date) to authenticated;
