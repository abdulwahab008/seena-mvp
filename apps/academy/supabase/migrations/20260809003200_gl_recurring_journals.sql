-- General ledger, part 5: recurring journal vouchers.
--
-- A template (rent every month, insurance every year) holds the lines of a
-- voucher and the date it is next due. post_due_recurring_journals() posts
-- every run that has fallen due, catching up missed ones, through
-- post_journal_entry() so each run passes the same balance, account and
-- period-lock checks as a voucher typed by hand. There is no scheduler: the
-- accountant presses "Post due now".
--
-- Runs are counted from anchor_date (the first due date) rather than from the
-- last run, so a template due on the 31st posts on the last day of short
-- months and returns to the 31st afterwards instead of drifting to the 28th.

create table public.gl_recurring_journal (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  name        text not null check (length(btrim(name)) between 1 and 150),
  narration   text not null check (length(btrim(narration)) between 1 and 500),
  frequency   text not null check (frequency in ('monthly', 'quarterly', 'yearly')),
  anchor_date date not null,
  next_run    date not null,
  is_active   boolean not null default true,
  created_by  uuid default auth.uid() references auth.users(id),
  created_at  timestamptz not null default now()
);
create index idx_gl_recurring_journal_tenant on public.gl_recurring_journal (tenant_id, next_run);

create table public.gl_recurring_journal_line (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  template_id    uuid not null references public.gl_recurring_journal(id) on delete cascade,
  account_id     uuid not null references public.gl_account(id),
  cost_center_id uuid references public.gl_cost_center(id),
  debit          bigint not null default 0 check (debit >= 0),
  credit         bigint not null default 0 check (credit >= 0),
  memo           text check (memo is null or length(memo) <= 200),
  constraint chk_gl_recurring_line_one_side check ((debit > 0) <> (credit > 0))
);
create index idx_gl_recurring_journal_line_template on public.gl_recurring_journal_line (template_id);
create index idx_gl_recurring_journal_line_tenant on public.gl_recurring_journal_line (tenant_id);

create table public.gl_recurring_journal_run (
  template_id uuid not null references public.gl_recurring_journal(id) on delete cascade,
  run_date    date not null,
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  entry_id    uuid not null references public.journal_entry(id),
  created_at  timestamptz not null default now(),
  primary key (template_id, run_date)
);
create index idx_gl_recurring_journal_run_tenant on public.gl_recurring_journal_run (tenant_id);
create index idx_gl_recurring_journal_run_entry on public.gl_recurring_journal_run (entry_id);

alter table public.gl_recurring_journal enable row level security;
alter table public.gl_recurring_journal_line enable row level security;
alter table public.gl_recurring_journal_run enable row level security;
create policy gl_recurring_journal_read on public.gl_recurring_journal for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_ledger_reader());
create policy gl_recurring_journal_line_read on public.gl_recurring_journal_line for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_ledger_reader());
create policy gl_recurring_journal_run_read on public.gl_recurring_journal_run for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_ledger_reader());
select app.fn_block_portal_roles('public.gl_recurring_journal');
select app.fn_block_portal_roles('public.gl_recurring_journal_line');
select app.fn_block_portal_roles('public.gl_recurring_journal_run');
create trigger gl_recurring_journal_audit after insert or update or delete on public.gl_recurring_journal
  for each row execute function app.tg_audit_row();

create or replace function app.fn_recurring_next_run(p_anchor date, p_frequency text, p_after date)
returns date
language sql
immutable
set search_path = ''
as $$
  with s as (
    select case p_frequency when 'monthly' then 1 when 'quarterly' then 3 else 12 end as step,
           (extract(year from p_after)::int - extract(year from p_anchor)::int) * 12
             + extract(month from p_after)::int - extract(month from p_anchor)::int as months
  )
  select (p_anchor + make_interval(months => step * (greatest(months, 0) / step + 1)))::date from s;
$$;
revoke execute on function app.fn_recurring_next_run(date, text, date) from public, anon, authenticated;

-- p_lines: [{"account_id": uuid, "cost_center_id": uuid|null, "debit": paisa, "credit": paisa, "memo": text}, ...]
-- Saving replaces the lines. Changing the next due date restarts the schedule
-- from that date.
create or replace function public.save_recurring_journal(
  p_name text, p_narration text, p_frequency text, p_next_run date, p_lines jsonb,
  p_is_active boolean default true, p_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_id     uuid;
  v_dr     bigint;
  v_cr     bigint;
begin
  perform app.fn_assert_accountant();
  if p_frequency is null or p_frequency not in ('monthly', 'quarterly', 'yearly') then
    raise exception 'FREQUENCY_INVALID' using errcode = '22023';
  end if;
  if p_next_run is null then
    raise exception 'DATE_INVALID' using errcode = '22023';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'LINES_REQUIRED' using errcode = '22023', hint = 'A voucher needs at least two lines.';
  end if;
  if exists (select 1 from jsonb_array_elements(p_lines) l
              where not exists (select 1 from public.gl_account a
                                 where a.id = (l ->> 'account_id')::uuid and a.tenant_id = v_tenant and a.is_active)) then
    raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if exists (select 1 from jsonb_array_elements(p_lines) l
              where nullif(l ->> 'cost_center_id', '') is not null
                and not exists (select 1 from public.gl_cost_center c
                                 where c.id = (l ->> 'cost_center_id')::uuid and c.tenant_id = v_tenant and c.is_active)) then
    raise exception 'COST_CENTER_NOT_FOUND' using errcode = 'P0002';
  end if;
  select coalesce(sum(coalesce((l ->> 'debit')::bigint, 0)), 0), coalesce(sum(coalesce((l ->> 'credit')::bigint, 0)), 0)
    into v_dr, v_cr from jsonb_array_elements(p_lines) l;
  if v_dr <> v_cr or v_dr = 0 then
    raise exception 'NOT_BALANCED' using errcode = '22023', detail = format('debits %s, credits %s', v_dr, v_cr);
  end if;

  if p_id is null then
    insert into public.gl_recurring_journal (tenant_id, name, narration, frequency, anchor_date, next_run, is_active)
    values (v_tenant, btrim(p_name), btrim(p_narration), p_frequency, p_next_run, p_next_run, coalesce(p_is_active, true))
    returning id into v_id;
  else
    update public.gl_recurring_journal
       set name = btrim(p_name), narration = btrim(p_narration), frequency = p_frequency,
           anchor_date = case when next_run = p_next_run and frequency = p_frequency then anchor_date else p_next_run end,
           next_run = p_next_run, is_active = coalesce(p_is_active, true)
     where id = p_id and tenant_id = v_tenant
    returning id into v_id;
    if v_id is null then
      raise exception 'TEMPLATE_NOT_FOUND' using errcode = 'P0002';
    end if;
    delete from public.gl_recurring_journal_line where template_id = v_id;
  end if;

  insert into public.gl_recurring_journal_line (tenant_id, template_id, account_id, cost_center_id, debit, credit, memo)
  select v_tenant, v_id, (l ->> 'account_id')::uuid, nullif(l ->> 'cost_center_id', '')::uuid,
         coalesce((l ->> 'debit')::bigint, 0), coalesce((l ->> 'credit')::bigint, 0), nullif(btrim(l ->> 'memo'), '')
    from jsonb_array_elements(p_lines) l;
  return v_id;
end;
$$;
revoke execute on function public.save_recurring_journal(text, text, text, date, jsonb, boolean, uuid) from public, anon;
grant execute on function public.save_recurring_journal(text, text, text, date, jsonb, boolean, uuid) to authenticated;

create or replace function public.set_recurring_journal_active(p_id uuid, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.fn_assert_accountant();
  update public.gl_recurring_journal set is_active = coalesce(p_is_active, false)
   where id = p_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'TEMPLATE_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.set_recurring_journal_active(uuid, boolean) from public, anon;
grant execute on function public.set_recurring_journal_active(uuid, boolean) to authenticated;

-- Posts every active template's runs due up to today and returns how many
-- vouchers were posted. Any refusal (an account since deactivated, a run
-- dated in a closed year) rolls the whole call back, so nothing posts half.
create or replace function public.post_due_recurring_journals()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_posted int := 0;
  v_entry  uuid;
  v_lines  jsonb;
  t        public.gl_recurring_journal%rowtype;
begin
  perform app.fn_assert_accountant();
  for t in select * from public.gl_recurring_journal
            where tenant_id = v_tenant and is_active and next_run <= current_date
            order by next_run, created_at
              for update loop
    select jsonb_agg(jsonb_build_object('account_id', account_id, 'cost_center_id', cost_center_id,
                                        'debit', debit, 'credit', credit, 'memo', memo))
      into v_lines
      from public.gl_recurring_journal_line where template_id = t.id;
    while t.next_run <= current_date loop
      v_entry := public.post_journal_entry(t.next_run, t.narration, coalesce(v_lines, '[]'::jsonb));
      insert into public.gl_recurring_journal_run (template_id, run_date, tenant_id, entry_id)
      values (t.id, t.next_run, v_tenant, v_entry);
      v_posted := v_posted + 1;
      t.next_run := app.fn_recurring_next_run(t.anchor_date, t.frequency, t.next_run);
    end loop;
    update public.gl_recurring_journal set next_run = t.next_run where id = t.id;
  end loop;
  return v_posted;
end;
$$;
revoke execute on function public.post_due_recurring_journals() from public, anon;
grant execute on function public.post_due_recurring_journals() to authenticated;
