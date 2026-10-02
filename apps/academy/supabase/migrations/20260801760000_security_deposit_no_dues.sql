-- FR-K28: security deposit refund and no-dues clearance.
--
-- A deposit is a liability, never income: it lives in security_deposit and
-- posts NOTHING to fee_ledger or fee_payment when received, so no revenue,
-- billed, collected or receivable figure can ever count it (those figures
-- are built from ledger/payment rows). It touches the ledger only when it
-- leaves: an adjustment credit releasing it to the student's account and a
-- refund debit for the cash paid out, so a refund nets the account to zero.
--
-- One held deposit per enrolment (a top-up is a policy decision for later,
-- not something to guess at).
--
-- Library, hostel and inventory modules do not exist yet, so their checklist
-- items are signed off by the person who owns that domain, who also records
-- the amount outstanding. Fees is computed from the ledger and cannot be
-- ticked by hand. Dues owed to a domain can be netted against the deposit.
-- The Transfer Certificate is gated by a trigger on certificate_issue so the
-- existing issuance function keeps working untouched.

create table public.security_deposit (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  enrolment_id     uuid not null references public.enrolment(id) on delete cascade,
  amount_paisa     bigint not null check (amount_paisa > 0),
  received_on      date not null,
  mode             text not null check (mode in ('cash', 'cheque', 'transfer', 'bank_challan')),
  receipt_ref      text,
  status           text not null default 'held' check (status in ('held', 'refunded', 'forfeited', 'adjusted')),
  netted_paisa     bigint not null default 0 check (netted_paisa >= 0 and netted_paisa <= amount_paisa),
  refund_paisa     bigint check (refund_paisa >= 0),
  approved_by      uuid references auth.users(id),
  approved_at      timestamptz,
  disbursed_by     uuid references auth.users(id),
  disbursed_at     timestamptz,
  instrument_type  text check (instrument_type in ('cash', 'cheque', 'transfer')),
  instrument_ref   text,
  forfeit_reason   text,
  created_by       uuid references auth.users(id),
  created_at       timestamptz not null default now()
);
create unique index uq_security_deposit_held on public.security_deposit (enrolment_id) where status = 'held';
create index idx_security_deposit_scope on public.security_deposit (tenant_id, campus_id, status);
create index idx_security_deposit_enrolment on public.security_deposit (enrolment_id);

create table public.no_dues_clearance (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  enrolment_id      uuid not null references public.enrolment(id) on delete cascade,
  status            text not null default 'open' check (status in ('open', 'cleared', 'overridden', 'cancelled')),
  requested_by      uuid not null references auth.users(id),
  requested_at      timestamptz not null default now(),
  override_reason   text,
  override_by       uuid references auth.users(id),
  override_at       timestamptz,
  constraint no_dues_override_complete check (
    status <> 'overridden' or (override_by is not null and override_at is not null and length(btrim(override_reason)) >= 20)
  )
);
create unique index uq_no_dues_open on public.no_dues_clearance (enrolment_id) where status in ('open', 'cleared', 'overridden');
create index idx_no_dues_clearance_scope on public.no_dues_clearance (tenant_id, campus_id, status);

create table public.no_dues_item (
  id               uuid primary key default gen_random_uuid(),
  clearance_id     uuid not null references public.no_dues_clearance(id) on delete cascade,
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  domain           text not null check (domain in ('fees', 'library', 'transport', 'hostel', 'inventory')),
  outstanding_paisa bigint not null default 0 check (outstanding_paisa >= 0),
  netted_paisa     bigint not null default 0 check (netted_paisa >= 0 and netted_paisa <= outstanding_paisa),
  status           text not null default 'pending' check (status in ('pending', 'cleared', 'waived')),
  note             text,
  cleared_by       uuid references auth.users(id),
  cleared_at       timestamptz,
  constraint uq_no_dues_item_domain unique (clearance_id, domain)
);
create index idx_no_dues_item_scope on public.no_dues_item (tenant_id, campus_id, status);

create table public.no_dues_policy (
  tenant_id            uuid primary key references public.tenant(id) on delete cascade,
  tc_requires_clearance boolean not null default false
);

create trigger security_deposit_audit after insert or update or delete on public.security_deposit
  for each row execute function app.tg_audit_row();
create trigger no_dues_clearance_audit after insert or update or delete on public.no_dues_clearance
  for each row execute function app.tg_audit_row();
create trigger no_dues_item_audit after insert or update or delete on public.no_dues_item
  for each row execute function app.tg_audit_row();

alter table public.security_deposit enable row level security;
alter table public.no_dues_clearance enable row level security;
alter table public.no_dues_item enable row level security;
alter table public.no_dues_policy enable row level security;

create policy security_deposit_read on public.security_deposit for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids())));
create policy no_dues_clearance_read on public.no_dues_clearance for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal', 'vice_principal', 'admissions_officer', 'librarian', 'transport_manager')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids())));
create policy no_dues_item_read on public.no_dues_item for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal', 'vice_principal', 'admissions_officer', 'librarian', 'transport_manager')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids())));
create policy no_dues_policy_read on public.no_dues_policy for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create or replace function app.fn_no_dues_domain_roles(p_domain text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case p_domain
    when 'fees' then array['owner', 'super_admin', 'accountant', 'principal']
    when 'library' then array['owner', 'super_admin', 'librarian', 'principal']
    when 'transport' then array['owner', 'super_admin', 'transport_manager', 'principal']
    else array['owner', 'super_admin', 'principal', 'vice_principal']
  end;
$$;

create or replace function app.fn_enrolment_ledger_balance(p_enrolment_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(case when direction = 'debit' then amount_paisa else -amount_paisa end), 0)::bigint
    from public.fee_ledger fl
   where fl.enrolment_id = p_enrolment_id
     and not exists (select 1 from public.fee_challan c2 where c2.id = coalesce(fl.challan_id, case when fl.source_type = 'fee_challan' then fl.source_id end) and c2.deleted_at is not null);
$$;

create or replace function app.fn_no_dues_load_item(p_item_id uuid, p_roles text[] default null)
returns public.no_dues_item
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_i public.no_dues_item%rowtype;
  v_c public.no_dues_clearance%rowtype;
begin
  select * into v_i from public.no_dues_item where id = p_item_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'ITEM_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into v_c from public.no_dues_clearance where id = v_i.clearance_id for update;
  if v_c.status <> 'open' then
    raise exception 'CLEARANCE_NOT_OPEN' using errcode = '55000';
  end if;
  if not (app.auth_role() = any (coalesce(p_roles, app.fn_no_dues_domain_roles(v_i.domain)))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_i.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return v_i;
end;
$$;
revoke execute on function app.fn_no_dues_load_item(uuid, text[]) from public, anon, authenticated;

create or replace function app.fn_no_dues_close_if_done(p_clearance_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.no_dues_clearance c set status = 'cleared'
   where c.id = p_clearance_id and c.status = 'open'
     and not exists (select 1 from public.no_dues_item i where i.clearance_id = c.id and i.status = 'pending');
$$;
revoke execute on function app.fn_no_dues_close_if_done(uuid) from public, anon, authenticated;

create or replace function public.record_security_deposit(
  p_enrolment_id uuid, p_amount_paisa bigint, p_received_on date, p_mode text, p_receipt_ref text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e  public.enrolment%rowtype;
  v_id uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_amount_paisa is null or p_amount_paisa <= 0 then
    raise exception 'AMOUNT_MUST_BE_POSITIVE' using errcode = '23514';
  end if;
  select * into v_e from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id() and deleted_at is null;
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_e.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.security_deposit (tenant_id, campus_id, enrolment_id, amount_paisa, received_on, mode, receipt_ref, created_by)
  values (v_e.tenant_id, v_e.campus_id, p_enrolment_id, p_amount_paisa, coalesce(p_received_on, app.fn_karachi_today()), p_mode, nullif(btrim(p_receipt_ref), ''), (select auth.uid()))
  returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'DEPOSIT_ALREADY_HELD' using errcode = '23505';
end;
$$;
revoke execute on function public.record_security_deposit(uuid, bigint, date, text, text) from public, anon;
grant execute on function public.record_security_deposit(uuid, bigint, date, text, text) to authenticated;

create or replace function public.security_deposit_balance(p_enrolment_id uuid)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return coalesce((select sum(d.amount_paisa - d.netted_paisa) from public.security_deposit d
                    where d.enrolment_id = p_enrolment_id and d.tenant_id = app.auth_tenant_id() and d.status = 'held'), 0)::bigint;
end;
$$;
revoke execute on function public.security_deposit_balance(uuid) from public, anon;
grant execute on function public.security_deposit_balance(uuid) to authenticated;

create or replace function public.build_no_dues_checklist(p_enrolment_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e       public.enrolment%rowtype;
  v_c       public.no_dues_clearance%rowtype;
  v_balance bigint;
  v_dom     text;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_e from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id() and deleted_at is null;
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_e.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_c from public.no_dues_clearance where enrolment_id = p_enrolment_id and status in ('open', 'cleared', 'overridden');
  if not found then
    insert into public.no_dues_clearance (tenant_id, campus_id, enrolment_id, requested_by)
    values (v_e.tenant_id, v_e.campus_id, p_enrolment_id, (select auth.uid()))
    returning * into v_c;
    foreach v_dom in array array['fees', 'library', 'transport', 'hostel', 'inventory'] loop
      insert into public.no_dues_item (clearance_id, tenant_id, campus_id, domain) values (v_c.id, v_c.tenant_id, v_c.campus_id, v_dom);
    end loop;
  end if;

  if v_c.status = 'open' then
    v_balance := greatest(app.fn_enrolment_ledger_balance(p_enrolment_id), 0);
    update public.no_dues_item i
       set outstanding_paisa = v_balance,
           netted_paisa = least(i.netted_paisa, v_balance),
           status = case when v_balance = 0 and i.status = 'pending' then 'cleared' else i.status end,
           cleared_at = case when v_balance = 0 and i.status = 'pending' then now() else i.cleared_at end,
           cleared_by = case when v_balance = 0 and i.status = 'pending' then (select auth.uid()) else i.cleared_by end
     where i.clearance_id = v_c.id and i.domain = 'fees' and i.status in ('pending', 'cleared');
    update public.no_dues_item i
       set status = 'pending', cleared_at = null, cleared_by = null
     where i.clearance_id = v_c.id and i.domain = 'fees' and i.status = 'cleared' and i.outstanding_paisa > 0;
    perform app.fn_no_dues_close_if_done(v_c.id);
  end if;
  return v_c.id;
end;
$$;
revoke execute on function public.build_no_dues_checklist(uuid) from public, anon;
grant execute on function public.build_no_dues_checklist(uuid) to authenticated;

create or replace function public.set_no_dues_item_outstanding(p_item_id uuid, p_outstanding_paisa bigint, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_i public.no_dues_item%rowtype;
begin
  v_i := app.fn_no_dues_load_item(p_item_id);
  if v_i.domain = 'fees' then
    raise exception 'FEES_ITEM_IS_COMPUTED' using errcode = '55000', hint = 'Fees dues come from the ledger';
  end if;
  if p_outstanding_paisa is null or p_outstanding_paisa < 0 then
    raise exception 'AMOUNT_INVALID' using errcode = '23514';
  end if;
  update public.no_dues_item
     set outstanding_paisa = p_outstanding_paisa, netted_paisa = least(netted_paisa, p_outstanding_paisa),
         status = 'pending', cleared_by = null, cleared_at = null, note = nullif(btrim(p_note), '')
   where id = p_item_id;
end;
$$;
revoke execute on function public.set_no_dues_item_outstanding(uuid, bigint, text) from public, anon;
grant execute on function public.set_no_dues_item_outstanding(uuid, bigint, text) to authenticated;

create or replace function public.clear_no_dues_item(p_item_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_i       public.no_dues_item%rowtype;
  v_c       public.no_dues_clearance%rowtype;
  v_balance bigint;
begin
  v_i := app.fn_no_dues_load_item(p_item_id);
  select * into v_c from public.no_dues_clearance where id = v_i.clearance_id;
  if v_i.domain = 'fees' then
    v_balance := greatest(app.fn_enrolment_ledger_balance(v_c.enrolment_id), 0);
    update public.no_dues_item set outstanding_paisa = v_balance, netted_paisa = least(netted_paisa, v_balance) where id = p_item_id returning * into v_i;
  end if;
  if v_i.outstanding_paisa - v_i.netted_paisa > 0 then
    raise exception 'OUTSTANDING_AMOUNT_REMAINS' using errcode = '55000', detail = format('remaining_paisa=%s', v_i.outstanding_paisa - v_i.netted_paisa),
      hint = 'Collect it, net it against the deposit, or waive it with a reason';
  end if;
  update public.no_dues_item
     set status = 'cleared', cleared_by = (select auth.uid()), cleared_at = now(), note = coalesce(nullif(btrim(p_note), ''), note)
   where id = p_item_id;
  perform app.fn_no_dues_close_if_done(v_i.clearance_id);
end;
$$;
revoke execute on function public.clear_no_dues_item(uuid, text) from public, anon;
grant execute on function public.clear_no_dues_item(uuid, text) to authenticated;

create or replace function public.waive_no_dues_item(p_item_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_i public.no_dues_item%rowtype;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'REASON_MIN_LENGTH_20' using errcode = '23514';
  end if;
  v_i := app.fn_no_dues_load_item(p_item_id, array['owner', 'super_admin', 'principal']);
  update public.no_dues_item
     set status = 'waived', cleared_by = (select auth.uid()), cleared_at = now(), note = btrim(p_reason)
   where id = p_item_id;
  perform app.fn_no_dues_close_if_done(v_i.clearance_id);
end;
$$;
revoke execute on function public.waive_no_dues_item(uuid, text) from public, anon;
grant execute on function public.waive_no_dues_item(uuid, text) to authenticated;

create or replace function public.net_no_dues_item_against_deposit(p_item_id uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_i       public.no_dues_item%rowtype;
  v_c       public.no_dues_clearance%rowtype;
  v_d       public.security_deposit%rowtype;
  v_balance bigint;
  v_net     bigint;
begin
  v_i := app.fn_no_dues_load_item(p_item_id, array['owner', 'super_admin', 'accountant', 'principal']);
  select * into v_c from public.no_dues_clearance where id = v_i.clearance_id;
  select * into v_d from public.security_deposit where enrolment_id = v_c.enrolment_id and status = 'held' for update;
  if not found or v_d.approved_at is not null then
    raise exception 'NO_DEPOSIT_AVAILABLE' using errcode = '55000';
  end if;
  if v_i.domain = 'fees' then
    v_balance := greatest(app.fn_enrolment_ledger_balance(v_c.enrolment_id), 0);
    v_i.outstanding_paisa := v_balance;
  end if;
  v_net := least(v_i.outstanding_paisa - v_i.netted_paisa, v_d.amount_paisa - v_d.netted_paisa);
  if v_net <= 0 then
    raise exception 'NOTHING_TO_NET' using errcode = '55000';
  end if;
  update public.security_deposit set netted_paisa = netted_paisa + v_net where id = v_d.id;
  update public.no_dues_item
     set outstanding_paisa = v_i.outstanding_paisa, netted_paisa = v_i.netted_paisa + v_net,
         status = case when v_i.netted_paisa + v_net >= v_i.outstanding_paisa then 'cleared' else 'pending' end,
         cleared_by = case when v_i.netted_paisa + v_net >= v_i.outstanding_paisa then (select auth.uid()) else null end,
         cleared_at = case when v_i.netted_paisa + v_net >= v_i.outstanding_paisa then now() else null end
   where id = p_item_id;
  perform app.fn_no_dues_close_if_done(v_i.clearance_id);
  return v_net;
end;
$$;
revoke execute on function public.net_no_dues_item_against_deposit(uuid) from public, anon;
grant execute on function public.net_no_dues_item_against_deposit(uuid) to authenticated;

create or replace function public.override_no_dues_clearance(p_clearance_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_c public.no_dues_clearance%rowtype;
begin
  if app.auth_role() not in ('owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'REASON_MIN_LENGTH_20' using errcode = '23514';
  end if;
  select * into v_c from public.no_dues_clearance where id = p_clearance_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'CLEARANCE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_c.status <> 'open' then
    raise exception 'CLEARANCE_NOT_OPEN' using errcode = '55000';
  end if;
  update public.no_dues_clearance
     set status = 'overridden', override_reason = btrim(p_reason), override_by = (select auth.uid()), override_at = clock_timestamp()
   where id = p_clearance_id;
end;
$$;
revoke execute on function public.override_no_dues_clearance(uuid, text) from public, anon;
grant execute on function public.override_no_dues_clearance(uuid, text) to authenticated;

create or replace function public.approve_deposit_refund(p_enrolment_id uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_d public.security_deposit%rowtype;
  v_c public.no_dues_clearance%rowtype;
  v_uid uuid := (select auth.uid());
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_d from public.security_deposit where enrolment_id = p_enrolment_id and tenant_id = app.auth_tenant_id() and status = 'held' for update;
  if not found then
    raise exception 'NO_DEPOSIT_HELD' using errcode = 'P0002';
  end if;
  if app.auth_role() = 'principal' and not (v_d.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_c from public.no_dues_clearance where enrolment_id = p_enrolment_id and status in ('open', 'cleared', 'overridden');
  if not found or v_c.status <> 'cleared' then
    raise exception 'NO_DUES_NOT_CLEARED' using errcode = '55000', hint = 'Every checklist item must be cleared or waived first';
  end if;
  if v_uid = v_c.requested_by then
    raise exception 'CANNOT_APPROVE_OWN_REQUEST' using errcode = '42501';
  end if;
  update public.security_deposit
     set approved_by = v_uid, approved_at = now(), refund_paisa = amount_paisa - netted_paisa
   where id = v_d.id;
  return v_d.amount_paisa - v_d.netted_paisa;
end;
$$;
revoke execute on function public.approve_deposit_refund(uuid) from public, anon;
grant execute on function public.approve_deposit_refund(uuid) to authenticated;

create or replace function public.disburse_deposit_refund(p_enrolment_id uuid, p_instrument_type text, p_instrument_ref text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_d       public.security_deposit%rowtype;
  v_n_fees  bigint;
  v_n_other bigint;
  v_balance bigint;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_d from public.security_deposit where enrolment_id = p_enrolment_id and tenant_id = app.auth_tenant_id() and status = 'held' for update;
  if not found then
    raise exception 'NO_DEPOSIT_HELD' using errcode = 'P0002';
  end if;
  if v_d.approved_at is null then
    raise exception 'REFUND_NOT_APPROVED' using errcode = '55000';
  end if;
  if p_instrument_type not in ('cash', 'cheque', 'transfer') or (p_instrument_type <> 'cash' and length(btrim(coalesce(p_instrument_ref, ''))) = 0) then
    raise exception 'INSTRUMENT_REFERENCE_REQUIRED' using errcode = '22023';
  end if;

  select coalesce(sum(i.netted_paisa) filter (where i.domain = 'fees'), 0), coalesce(sum(i.netted_paisa) filter (where i.domain <> 'fees'), 0)
    into v_n_fees, v_n_other
    from public.no_dues_item i join public.no_dues_clearance c on c.id = i.clearance_id
   where c.enrolment_id = p_enrolment_id and c.status = 'cleared';
  if v_n_fees + v_n_other <> v_d.netted_paisa then
    raise exception 'NETTING_MISMATCH' using errcode = '55000';
  end if;
  if v_n_fees > greatest(app.fn_enrolment_ledger_balance(p_enrolment_id), 0) then
    raise exception 'LEDGER_MOVED_SINCE_APPROVAL' using errcode = '55000', hint = 'The fee dues changed after the clearance; rebuild the checklist';
  end if;

  -- fees netted settles dues on the ledger; other-domain netting leaves the account untouched, so only the rest is released to it
  if v_d.amount_paisa - v_n_other > 0 then
    perform public.post_ledger_entry(p_enrolment_id, 'adjustment', v_d.amount_paisa - v_n_other, 'credit', null, app.fn_karachi_today(), 'security_deposit', v_d.id);
  end if;
  if v_d.refund_paisa > 0 then
    perform public.post_ledger_entry(p_enrolment_id, 'refund', v_d.refund_paisa, 'debit', null, app.fn_karachi_today(), 'security_deposit', v_d.id);
  end if;

  update public.security_deposit
     set status = case when v_d.refund_paisa > 0 then 'refunded' else 'adjusted' end,
         disbursed_by = (select auth.uid()), disbursed_at = now(), instrument_type = p_instrument_type, instrument_ref = nullif(btrim(p_instrument_ref), '')
   where id = v_d.id;

  v_balance := app.fn_enrolment_ledger_balance(p_enrolment_id);
  return jsonb_build_object('status', case when v_d.refund_paisa > 0 then 'refunded' else 'adjusted' end, 'refund_paisa', v_d.refund_paisa, 'ledger_balance_paisa', v_balance);
end;
$$;
revoke execute on function public.disburse_deposit_refund(uuid, text, text) from public, anon;
grant execute on function public.disburse_deposit_refund(uuid, text, text) to authenticated;

create or replace function public.forfeit_security_deposit(p_enrolment_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'REASON_MIN_LENGTH_20' using errcode = '23514';
  end if;
  update public.security_deposit set status = 'forfeited', forfeit_reason = btrim(p_reason)
   where enrolment_id = p_enrolment_id and tenant_id = app.auth_tenant_id() and status = 'held' and approved_at is null;
  if not found then
    raise exception 'NO_DEPOSIT_HELD' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.forfeit_security_deposit(uuid, text) from public, anon;
grant execute on function public.forfeit_security_deposit(uuid, text) to authenticated;

create or replace function public.set_tc_requires_no_dues(p_required boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.no_dues_policy (tenant_id, tc_requires_clearance) values (app.auth_tenant_id(), p_required)
  on conflict (tenant_id) do update set tc_requires_clearance = excluded.tc_requires_clearance;
end;
$$;
revoke execute on function public.set_tc_requires_no_dues(boolean) from public, anon;
grant execute on function public.set_tc_requires_no_dues(boolean) to authenticated;

create or replace function app.tg_tc_issue_require_clearance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status   text;
  v_required boolean;
begin
  if new.certificate_type <> 'transfer' or new.original_issue_id is not null then
    return new;
  end if;
  select c.status into v_status from public.no_dues_clearance c where c.enrolment_id = new.enrolment_id and c.status in ('open', 'cleared', 'overridden');
  select coalesce((select p.tc_requires_clearance from public.no_dues_policy p where p.tenant_id = new.tenant_id), false) into v_required;
  if v_status = 'open' or (v_status is null and v_required) then
    raise exception 'NO_DUES_CLEARANCE_REQUIRED' using errcode = '55000',
      hint = 'Complete the no-dues clearance, or have the Owner override it with a recorded reason';
  end if;
  return new;
end;
$$;
create trigger tc_issue_bi_require_clearance before insert on public.certificate_issue
  for each row execute function app.tg_tc_issue_require_clearance();
