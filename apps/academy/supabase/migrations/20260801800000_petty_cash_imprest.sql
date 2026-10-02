-- FR-L12: petty cash imprest and reconciliation.
--
-- A campus holds a fixed float. Spending draws it down; the only way back up
-- is a replenishment that was counted first, explained if the count and the
-- system disagree, and signed off by the Principal. The top-up is always
-- float minus the SYSTEM balance, so the books return to exactly the float;
-- a shortfall found in the count stays on the record with its explanation
-- rather than being quietly absorbed.
--
-- Every posting takes FOR UPDATE on the account row, so two simultaneous
-- payments serialise instead of both reading the same balance. While a
-- replenishment is waiting for sign-off the tin is frozen (the count must
-- stay true), and a change of custodian is refused until everything spent
-- has been reconciled, so the incoming custodian cannot inherit an
-- uncounted shortfall. Money is bigint paisa, like the rest of the schema.

create table public.petty_cash_account (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenant(id) on delete cascade,
  campus_id             uuid not null references public.campus(id) on delete cascade,
  float_paisa           bigint not null check (float_paisa > 0),
  txn_cap_paisa         bigint not null check (txn_cap_paisa > 0),
  custodian_user_id     uuid not null references public.app_user(user_id),
  current_balance_paisa bigint not null check (current_balance_paisa >= 0),
  created_at            timestamptz not null default now(),
  constraint petty_cash_cap_within_float check (txn_cap_paisa <= float_paisa),
  constraint uq_petty_cash_campus unique (campus_id)
);
create index idx_petty_cash_account_scope on public.petty_cash_account (tenant_id, campus_id);
create index idx_petty_cash_account_custodian on public.petty_cash_account (custodian_user_id);

create table public.petty_cash_reconciliation (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  account_id           uuid not null references public.petty_cash_account(id) on delete cascade,
  system_balance_paisa bigint not null,
  counted_paisa        bigint not null check (counted_paisa >= 0),
  variance_paisa       bigint not null,
  explanation          text,
  status               text not null default 'pending' check (status in ('pending', 'rejected', 'closed')),
  topup_paisa          bigint check (topup_paisa >= 0),
  requested_by         uuid not null references auth.users(id),
  requested_at         timestamptz not null default now(),
  decided_by           uuid references auth.users(id),
  decided_at           timestamptz,
  decision_note        text,
  constraint petty_cash_variance_math check (variance_paisa = counted_paisa - system_balance_paisa),
  constraint petty_cash_variance_explained check (variance_paisa = 0 or length(btrim(coalesce(explanation, ''))) >= 20)
);
create unique index uq_petty_cash_pending on public.petty_cash_reconciliation (account_id) where status = 'pending';
create index idx_petty_cash_recon_scope on public.petty_cash_reconciliation (tenant_id, campus_id, status);
create index idx_petty_cash_recon_account on public.petty_cash_reconciliation (account_id, requested_at desc);

create table public.petty_cash_txn (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  account_id           uuid not null references public.petty_cash_account(id) on delete cascade,
  direction            text not null check (direction in ('in', 'out')),
  amount_paisa         bigint not null check (amount_paisa > 0),
  expense_head_id      uuid references public.expense_head(id),
  narrative            text,
  balance_after_paisa  bigint not null check (balance_after_paisa >= 0),
  reconciliation_id    uuid references public.petty_cash_reconciliation(id),
  created_by           uuid references auth.users(id),
  created_at           timestamptz not null default clock_timestamp(),
  constraint petty_cash_out_has_head check (direction = 'in' or expense_head_id is not null)
);
create index idx_petty_cash_txn_account on public.petty_cash_txn (account_id, created_at);
create index idx_petty_cash_txn_scope on public.petty_cash_txn (tenant_id, campus_id);
create index idx_petty_cash_txn_head on public.petty_cash_txn (expense_head_id);

create or replace function app.tg_petty_cash_txn_no_mutate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'PETTY_CASH_TXN_IMMUTABLE' using errcode = '42501';
end;
$$;
create trigger petty_cash_txn_no_mutate before update or delete on public.petty_cash_txn
  for each row execute function app.tg_petty_cash_txn_no_mutate();

create trigger petty_cash_account_audit after insert or update or delete on public.petty_cash_account
  for each row execute function app.tg_audit_row();
create trigger petty_cash_reconciliation_audit after insert or update or delete on public.petty_cash_reconciliation
  for each row execute function app.tg_audit_row();

alter table public.petty_cash_account enable row level security;
alter table public.petty_cash_reconciliation enable row level security;
alter table public.petty_cash_txn enable row level security;

create policy petty_cash_campus_read on public.petty_cash_account for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (custodian_user_id = (select auth.uid())
              or (app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal', 'vice_principal')
                  and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids())))));
create policy petty_cash_recon_read on public.petty_cash_reconciliation for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (requested_by = (select auth.uid())
              or (app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal', 'vice_principal')
                  and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids())))));
create policy petty_cash_txn_read on public.petty_cash_txn for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (created_by = (select auth.uid())
              or (app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal', 'vice_principal')
                  and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids())))));

create or replace function app.fn_petty_cash_lock(p_account_id uuid)
returns public.petty_cash_account
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a public.petty_cash_account%rowtype;
begin
  select * into v_a from public.petty_cash_account where id = p_account_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'PETTY_CASH_ACCOUNT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_a.campus_id = any(app.auth_campus_ids())) and v_a.custodian_user_id is distinct from (select auth.uid()) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return v_a;
end;
$$;
revoke execute on function app.fn_petty_cash_lock(uuid) from public, anon, authenticated;

create or replace function public.create_petty_cash_account(p_campus_id uuid, p_float_paisa bigint, p_txn_cap_paisa bigint, p_custodian_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.app_user where user_id = p_custodian_user_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CUSTODIAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into public.petty_cash_account (tenant_id, campus_id, float_paisa, txn_cap_paisa, custodian_user_id, current_balance_paisa)
  values (app.auth_tenant_id(), p_campus_id, p_float_paisa, p_txn_cap_paisa, p_custodian_user_id, p_float_paisa)
  returning id into v_id;
  insert into public.petty_cash_txn (tenant_id, campus_id, account_id, direction, amount_paisa, narrative, balance_after_paisa, created_by)
  values (app.auth_tenant_id(), p_campus_id, v_id, 'in', p_float_paisa, 'Opening float', p_float_paisa, (select auth.uid()));
  return v_id;
exception
  when unique_violation then
    raise exception 'PETTY_CASH_ACCOUNT_EXISTS' using errcode = '23505';
end;
$$;
revoke execute on function public.create_petty_cash_account(uuid, bigint, bigint, uuid) from public, anon;
grant execute on function public.create_petty_cash_account(uuid, bigint, bigint, uuid) to authenticated;

create or replace function public.set_petty_cash_limits(p_account_id uuid, p_float_paisa bigint, p_txn_cap_paisa bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a public.petty_cash_account%rowtype;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  v_a := app.fn_petty_cash_lock(p_account_id);
  update public.petty_cash_account set float_paisa = p_float_paisa, txn_cap_paisa = p_txn_cap_paisa where id = p_account_id;
end;
$$;
revoke execute on function public.set_petty_cash_limits(uuid, bigint, bigint) from public, anon;
grant execute on function public.set_petty_cash_limits(uuid, bigint, bigint) to authenticated;

create or replace function public.post_petty_cash(p_account_id uuid, p_amount_paisa bigint, p_head_id uuid, p_narrative text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a       public.petty_cash_account%rowtype;
  v_uid     uuid := (select auth.uid());
  v_balance bigint;
  v_txn     uuid;
begin
  v_a := app.fn_petty_cash_lock(p_account_id);
  if not (v_a.custodian_user_id = v_uid or app.auth_role() in ('accountant', 'owner', 'super_admin')) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_amount_paisa is null or p_amount_paisa <= 0 then
    raise exception 'AMOUNT_MUST_BE_POSITIVE' using errcode = '23514';
  end if;
  if not exists (select 1 from public.expense_head where id = p_head_id and tenant_id = v_a.tenant_id and is_active) then
    raise exception 'EXPENSE_HEAD_NOT_FOUND' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.petty_cash_reconciliation where account_id = p_account_id and status = 'pending') then
    raise exception 'RECONCILIATION_PENDING' using errcode = '55000', hint = 'The tin is frozen while a count awaits sign-off';
  end if;
  if p_amount_paisa > v_a.txn_cap_paisa then
    raise exception 'petty_cash_txn_cap_exceeded' using errcode = '23514', hint = 'Raise a full expense voucher instead';
  end if;
  if p_amount_paisa > v_a.current_balance_paisa then
    raise exception 'insufficient_petty_cash' using errcode = '23514', detail = format('balance_paisa=%s', v_a.current_balance_paisa);
  end if;

  v_balance := v_a.current_balance_paisa - p_amount_paisa;
  insert into public.petty_cash_txn (tenant_id, campus_id, account_id, direction, amount_paisa, expense_head_id, narrative, balance_after_paisa, created_by)
  values (v_a.tenant_id, v_a.campus_id, p_account_id, 'out', p_amount_paisa, p_head_id, nullif(btrim(p_narrative), ''), v_balance, v_uid)
  returning id into v_txn;
  update public.petty_cash_account set current_balance_paisa = v_balance where id = p_account_id;
  return jsonb_build_object('txn_id', v_txn, 'balance_after_paisa', v_balance);
end;
$$;
revoke execute on function public.post_petty_cash(uuid, bigint, uuid, text) from public, anon;
grant execute on function public.post_petty_cash(uuid, bigint, uuid, text) to authenticated;

create or replace function public.request_petty_cash_replenishment(p_account_id uuid, p_counted_paisa bigint, p_explanation text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a   public.petty_cash_account%rowtype;
  v_uid uuid := (select auth.uid());
  v_id  uuid;
  v_var bigint;
begin
  v_a := app.fn_petty_cash_lock(p_account_id);
  if not (v_a.custodian_user_id = v_uid or app.auth_role() in ('accountant', 'owner', 'super_admin')) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_counted_paisa is null or p_counted_paisa < 0 then
    raise exception 'COUNT_INVALID' using errcode = '23514';
  end if;
  v_var := p_counted_paisa - v_a.current_balance_paisa;
  if v_var <> 0 and length(btrim(coalesce(p_explanation, ''))) < 20 then
    raise exception 'EXPLANATION_REQUIRED' using errcode = '23514', detail = format('variance_paisa=%s', v_var), hint = 'Explain the difference in at least 20 characters';
  end if;
  insert into public.petty_cash_reconciliation (tenant_id, campus_id, account_id, system_balance_paisa, counted_paisa, variance_paisa, explanation, requested_by)
  values (v_a.tenant_id, v_a.campus_id, p_account_id, v_a.current_balance_paisa, p_counted_paisa, v_var, nullif(btrim(p_explanation), ''), v_uid)
  returning id into v_id;
  return jsonb_build_object('reconciliation_id', v_id, 'variance_paisa', v_var, 'topup_paisa', v_a.float_paisa - v_a.current_balance_paisa);
exception when unique_violation then
  raise exception 'RECONCILIATION_ALREADY_PENDING' using errcode = '23505';
end;
$$;
revoke execute on function public.request_petty_cash_replenishment(uuid, bigint, text) from public, anon;
grant execute on function public.request_petty_cash_replenishment(uuid, bigint, text) to authenticated;

create or replace function public.decide_petty_cash_replenishment(p_reconciliation_id uuid, p_approve boolean, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r     public.petty_cash_reconciliation%rowtype;
  v_a     public.petty_cash_account%rowtype;
  v_uid   uuid := (select auth.uid());
  v_topup bigint;
begin
  if app.auth_role() not in ('principal', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_r from public.petty_cash_reconciliation where id = p_reconciliation_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'RECONCILIATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_a := app.fn_petty_cash_lock(v_r.account_id);
  select * into v_r from public.petty_cash_reconciliation where id = p_reconciliation_id for update;
  if v_r.status <> 'pending' then
    raise exception 'RECONCILIATION_NOT_PENDING' using errcode = '55000';
  end if;
  if v_uid = v_r.requested_by then
    raise exception 'CANNOT_APPROVE_OWN_COUNT' using errcode = '42501';
  end if;

  if not p_approve then
    update public.petty_cash_reconciliation set status = 'rejected', decided_by = v_uid, decided_at = clock_timestamp(), decision_note = nullif(btrim(p_note), '') where id = p_reconciliation_id;
    return jsonb_build_object('status', 'rejected');
  end if;

  if v_a.current_balance_paisa <> v_r.system_balance_paisa then
    raise exception 'COUNT_STALE' using errcode = '55000', hint = 'The balance moved after the count; count again';
  end if;
  v_topup := greatest(v_a.float_paisa - v_a.current_balance_paisa, 0);
  if v_topup > 0 then
    insert into public.petty_cash_txn (tenant_id, campus_id, account_id, direction, amount_paisa, narrative, balance_after_paisa, reconciliation_id, created_by)
    values (v_a.tenant_id, v_a.campus_id, v_a.id, 'in', v_topup, 'Replenishment to float', v_a.float_paisa, p_reconciliation_id, v_uid);
    update public.petty_cash_account set current_balance_paisa = v_a.float_paisa where id = v_a.id;
  end if;
  update public.petty_cash_reconciliation
     set status = 'closed', topup_paisa = v_topup, decided_by = v_uid, decided_at = clock_timestamp(), decision_note = nullif(btrim(p_note), '')
   where id = p_reconciliation_id;
  return jsonb_build_object('status', 'closed', 'topup_paisa', v_topup, 'balance_paisa', greatest(v_a.float_paisa, v_a.current_balance_paisa));
end;
$$;
revoke execute on function public.decide_petty_cash_replenishment(uuid, boolean, text) from public, anon;
grant execute on function public.decide_petty_cash_replenishment(uuid, boolean, text) to authenticated;

create or replace function public.change_petty_cash_custodian(p_account_id uuid, p_new_custodian_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a     public.petty_cash_account%rowtype;
  v_close timestamptz;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  v_a := app.fn_petty_cash_lock(p_account_id);
  if not exists (select 1 from public.app_user where user_id = p_new_custodian_user_id and tenant_id = v_a.tenant_id) then
    raise exception 'CUSTODIAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.petty_cash_reconciliation where account_id = p_account_id and status = 'pending') then
    raise exception 'RECONCILIATION_PENDING' using errcode = '55000';
  end if;
  select max(decided_at) into v_close from public.petty_cash_reconciliation where account_id = p_account_id and status = 'closed';
  if exists (select 1 from public.petty_cash_txn where account_id = p_account_id and direction = 'out' and created_at > coalesce(v_close, '-infinity'::timestamptz)) then
    raise exception 'RECONCILIATION_REQUIRED_BEFORE_HANDOVER' using errcode = '55000', hint = 'Count and replenish the tin before it changes hands';
  end if;
  update public.petty_cash_account set custodian_user_id = p_new_custodian_user_id where id = p_account_id;
end;
$$;
revoke execute on function public.change_petty_cash_custodian(uuid, uuid) from public, anon;
grant execute on function public.change_petty_cash_custodian(uuid, uuid) to authenticated;

create or replace function public.petty_cash_ledger_balance(p_account_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(case when direction = 'in' then amount_paisa else -amount_paisa end), 0)::bigint
    from public.petty_cash_txn where account_id = p_account_id;
$$;
revoke execute on function public.petty_cash_ledger_balance(uuid) from public, anon;
grant execute on function public.petty_cash_ledger_balance(uuid) to authenticated;
