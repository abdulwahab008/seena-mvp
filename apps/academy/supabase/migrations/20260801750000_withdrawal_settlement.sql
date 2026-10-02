-- FR-K27: withdrawal refund and pro-rata adjustment.
--
-- On withdrawal, charges for periods the student will not attend are reversed
-- by a ledger 'adjustment' credit (pro-rata for the leaving month by the
-- campus's basis), what the family still owes is NETTED against it, and only a
-- remaining credit becomes a refund. Which heads are unearned on withdrawal is
-- decided by fee_head.withdrawal_treatment, not by a rule per case: admission
-- and annual fees stay non-refundable because their head says so.
--
-- Sequencing is the trap the Notes name: a refund released before the last
-- challan is closed strands dues nobody netted. So the settlement computes
-- from the LEDGER at proposal time, needs the Principal's approval (and the
-- Owner's above the threshold), and disburse re-checks nothing moved.

alter table public.fee_head
  add column if not exists withdrawal_treatment text check (withdrawal_treatment in ('none', 'prorate'));

create or replace function app.fn_head_prorates(p_fee_head_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(h.withdrawal_treatment, case when h.default_frequency = 'monthly' then 'prorate' else 'none' end) = 'prorate'
    from public.fee_head h where h.id = p_fee_head_id;
$$;
revoke execute on function app.fn_head_prorates(uuid) from public, anon, authenticated;

create or replace function public.set_fee_head_withdrawal_treatment(p_fee_head_id uuid, p_treatment text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_treatment not in ('none', 'prorate') then
    raise exception 'TREATMENT_INVALID' using errcode = '22023';
  end if;
  update public.fee_head set withdrawal_treatment = p_treatment where id = p_fee_head_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'FEE_HEAD_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.set_fee_head_withdrawal_treatment(uuid, text) from public, anon;
grant execute on function public.set_fee_head_withdrawal_treatment(uuid, text) to authenticated;

create table public.fee_settlement_policy (
  tenant_id            uuid primary key references public.tenant(id) on delete cascade,
  owner_threshold_paisa bigint not null default 2500000 check (owner_threshold_paisa >= 0)
);
alter table public.fee_settlement_policy enable row level security;
create policy fee_settlement_policy_read on public.fee_settlement_policy for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal'));

create or replace function public.set_settlement_owner_threshold(p_paisa bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.fee_settlement_policy (tenant_id, owner_threshold_paisa) values (app.auth_tenant_id(), p_paisa)
  on conflict (tenant_id) do update set owner_threshold_paisa = excluded.owner_threshold_paisa;
end;
$$;
revoke execute on function public.set_settlement_owner_threshold(bigint) from public, anon;
grant execute on function public.set_settlement_owner_threshold(bigint) to authenticated;

create table public.fee_settlement (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               uuid not null references public.tenant(id) on delete cascade,
  campus_id               uuid not null references public.campus(id) on delete cascade,
  enrolment_id            uuid not null references public.enrolment(id) on delete cascade,
  leaving_date            date not null,
  basis                   text not null check (basis in ('full_month', 'half_month', 'daily')),
  ledger_balance_paisa    bigint not null,
  credit_adjustment_paisa bigint not null check (credit_adjustment_paisa >= 0),
  net_refund_paisa        bigint not null check (net_refund_paisa >= 0),
  remaining_dues_paisa    bigint not null check (remaining_dues_paisa >= 0),
  requires_owner          boolean not null,
  status                  text not null default 'pending' check (status in ('pending', 'approved', 'disbursed', 'rejected')),
  proposed_by             uuid not null references auth.users(id),
  proposal_note           text,
  disbursed_by            uuid references auth.users(id),
  disbursed_at            timestamptz,
  instrument_type         text check (instrument_type in ('cash', 'cheque', 'transfer')),
  instrument_ref          text,
  created_at              timestamptz not null default now()
);
create unique index uq_fee_settlement_open on public.fee_settlement (enrolment_id) where status in ('pending', 'approved');
create index idx_fee_settlement_scope on public.fee_settlement (tenant_id, campus_id, status);

create table public.fee_settlement_approval (
  id            uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references public.fee_settlement(id) on delete cascade,
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  role          text not null check (role in ('principal', 'owner')),
  decision      text not null check (decision in ('approved', 'rejected')),
  decided_by    uuid not null references auth.users(id),
  note          text,
  decided_at    timestamptz not null default now(),
  constraint uq_settlement_role_approval unique (settlement_id, role)
);

create trigger fee_settlement_audit after insert or update or delete on public.fee_settlement
  for each row execute function app.tg_audit_row();

alter table public.fee_settlement enable row level security;
alter table public.fee_settlement_approval enable row level security;
create policy fee_settlement_approve_by_amount_threshold on public.fee_settlement for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids())));
create policy fee_settlement_approval_read on public.fee_settlement_approval for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal'));

create or replace function public.compute_withdrawal_settlement(p_enrolment_id uuid, p_leaving_date date, p_basis text default 'half_month')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_e       public.enrolment%rowtype;
  v_credit  bigint := 0;
  v_balance bigint;
  v_month   date := date_trunc('month', p_leaving_date)::date;
  v_dim     int := extract(day from (date_trunc('month', p_leaving_date) + interval '1 month - 1 day'))::int;
  v_lines   jsonb;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_basis not in ('full_month', 'half_month', 'daily') then
    raise exception 'BASIS_INVALID' using errcode = '22023';
  end if;
  select * into v_e from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id() and deleted_at is null;
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_e.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  with l as (
    select c.billing_period, c.challan_no, h.code as head_code, fcl.net_paisa,
           case
             when c.billing_period > v_month then 1.0
             when c.billing_period = v_month and p_basis = 'half_month' then (case when extract(day from p_leaving_date) <= 15 then 0.5 else 0 end)
             when c.billing_period = v_month and p_basis = 'daily' then (v_dim - extract(day from p_leaving_date))::numeric / v_dim
             else 0 end as factor
      from public.fee_challan c
      join public.fee_challan_line fcl on fcl.challan_id = c.id and fcl.line_type = 'charge'
      join public.fee_head h on h.id = fcl.fee_head_id
     where c.enrolment_id = p_enrolment_id and c.deleted_at is null and c.status <> 'cancelled'
       and c.billing_period >= v_month and app.fn_head_prorates(fcl.fee_head_id)
  )
  select coalesce(sum(round(net_paisa * factor)), 0)::bigint,
         coalesce(jsonb_agg(jsonb_build_object('challan_no', challan_no, 'billing_period', billing_period, 'head', head_code, 'net_paisa', net_paisa, 'factor', factor,
                                               'unearned_paisa', round(net_paisa * factor)::bigint) order by billing_period) filter (where factor > 0), '[]'::jsonb)
    into v_credit, v_lines from l;

  select coalesce(sum(case when direction = 'debit' then amount_paisa else -amount_paisa end), 0)::bigint into v_balance
    from public.fee_ledger fl
   where fl.enrolment_id = p_enrolment_id
     and not exists (select 1 from public.fee_challan c2 where c2.id = coalesce(fl.challan_id, case when fl.source_type = 'fee_challan' then fl.source_id end) and c2.deleted_at is not null);

  return jsonb_build_object(
    'ledger_balance_paisa', v_balance,
    'credit_adjustment_paisa', v_credit,
    'net_refund_paisa', greatest(v_credit - v_balance, 0),
    'remaining_dues_paisa', greatest(v_balance - v_credit, 0),
    'lines', v_lines
  );
end;
$$;
revoke execute on function public.compute_withdrawal_settlement(uuid, date, text) from public, anon;
grant execute on function public.compute_withdrawal_settlement(uuid, date, text) to authenticated;

create or replace function public.propose_fee_settlement(p_enrolment_id uuid, p_leaving_date date, p_basis text, p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_calc   jsonb;
  v_e      public.enrolment%rowtype;
  v_thr    bigint;
  v_id     uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  v_calc := public.compute_withdrawal_settlement(p_enrolment_id, p_leaving_date, p_basis);
  select * into v_e from public.enrolment where id = p_enrolment_id;
  select coalesce((select owner_threshold_paisa from public.fee_settlement_policy where tenant_id = v_e.tenant_id), 2500000) into v_thr;

  insert into public.fee_settlement (tenant_id, campus_id, enrolment_id, leaving_date, basis, ledger_balance_paisa, credit_adjustment_paisa, net_refund_paisa, remaining_dues_paisa, requires_owner, proposed_by, proposal_note)
  values (v_e.tenant_id, v_e.campus_id, p_enrolment_id, p_leaving_date, p_basis,
          (v_calc ->> 'ledger_balance_paisa')::bigint, (v_calc ->> 'credit_adjustment_paisa')::bigint, (v_calc ->> 'net_refund_paisa')::bigint, (v_calc ->> 'remaining_dues_paisa')::bigint,
          (v_calc ->> 'net_refund_paisa')::bigint > v_thr, (select auth.uid()), p_note)
  returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'SETTLEMENT_ALREADY_OPEN' using errcode = '23505';
end;
$$;
revoke execute on function public.propose_fee_settlement(uuid, date, text, text) from public, anon;
grant execute on function public.propose_fee_settlement(uuid, date, text, text) to authenticated;

create or replace function public.decide_fee_settlement(p_settlement_id uuid, p_approve boolean, p_note text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s      public.fee_settlement%rowtype;
  v_role   text;
  v_uid    uuid := (select auth.uid());
  v_need_p boolean;
  v_need_o boolean;
begin
  select * into v_s from public.fee_settlement where id = p_settlement_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'SETTLEMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_s.status <> 'pending' then
    raise exception 'SETTLEMENT_NOT_PENDING' using errcode = '55000';
  end if;
  v_role := case app.auth_role() when 'principal' then 'principal' when 'owner' then 'owner' else null end;
  if v_role is null then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_role = 'principal' and not (v_s.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_uid = v_s.proposed_by then
    raise exception 'CANNOT_APPROVE_OWN_PROPOSAL' using errcode = '42501';
  end if;
  if v_role = 'owner' and not v_s.requires_owner then
    raise exception 'OWNER_APPROVAL_NOT_REQUIRED' using errcode = '55000';
  end if;

  insert into public.fee_settlement_approval (settlement_id, tenant_id, role, decision, decided_by, note)
  values (p_settlement_id, v_s.tenant_id, v_role, case when p_approve then 'approved' else 'rejected' end, v_uid, p_note);

  if not p_approve then
    update public.fee_settlement set status = 'rejected' where id = p_settlement_id;
    return 'rejected';
  end if;

  select exists (select 1 from public.fee_settlement_approval where settlement_id = p_settlement_id and role = 'principal' and decision = 'approved') into v_need_p;
  select (not v_s.requires_owner) or exists (select 1 from public.fee_settlement_approval where settlement_id = p_settlement_id and role = 'owner' and decision = 'approved') into v_need_o;
  if v_need_p and v_need_o then
    update public.fee_settlement set status = 'approved' where id = p_settlement_id;
    return 'approved';
  end if;
  return 'pending';
exception when unique_violation then
  raise exception 'ALREADY_DECIDED' using errcode = '23505';
end;
$$;
revoke execute on function public.decide_fee_settlement(uuid, boolean, text) from public, anon;
grant execute on function public.decide_fee_settlement(uuid, boolean, text) to authenticated;

create or replace function public.disburse_fee_settlement(p_settlement_id uuid, p_instrument_type text, p_instrument_ref text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s       public.fee_settlement%rowtype;
  v_calc    jsonb;
  v_balance bigint;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_s from public.fee_settlement where id = p_settlement_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'SETTLEMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_s.status <> 'approved' then
    raise exception 'SETTLEMENT_NOT_APPROVED' using errcode = '55000';
  end if;
  if p_instrument_type not in ('cash', 'cheque', 'transfer') or (p_instrument_type <> 'cash' and length(btrim(coalesce(p_instrument_ref, ''))) = 0) then
    raise exception 'INSTRUMENT_REFERENCE_REQUIRED' using errcode = '22023';
  end if;

  -- nothing may have moved since the proposal: a payment or a new charge would make the numbers wrong
  v_calc := public.compute_withdrawal_settlement(v_s.enrolment_id, v_s.leaving_date, v_s.basis);
  if (v_calc ->> 'ledger_balance_paisa')::bigint <> v_s.ledger_balance_paisa or (v_calc ->> 'credit_adjustment_paisa')::bigint <> v_s.credit_adjustment_paisa then
    raise exception 'LEDGER_MOVED_SINCE_PROPOSAL' using errcode = '55000', hint = 'Withdraw this proposal and propose again';
  end if;

  if v_s.credit_adjustment_paisa > 0 then
    perform public.post_ledger_entry(v_s.enrolment_id, 'adjustment', v_s.credit_adjustment_paisa, 'credit', null, app.fn_karachi_today(), 'fee_settlement', p_settlement_id);
  end if;
  if v_s.net_refund_paisa > 0 then
    perform public.post_ledger_entry(v_s.enrolment_id, 'refund', v_s.net_refund_paisa, 'debit', null, app.fn_karachi_today(), 'fee_settlement', p_settlement_id);
  end if;

  update public.fee_settlement
     set status = 'disbursed', disbursed_by = (select auth.uid()), disbursed_at = now(), instrument_type = p_instrument_type, instrument_ref = nullif(btrim(p_instrument_ref), '')
   where id = p_settlement_id;

  select coalesce(sum(case when direction = 'debit' then amount_paisa else -amount_paisa end), 0)::bigint into v_balance from public.fee_ledger where enrolment_id = v_s.enrolment_id;
  return jsonb_build_object('status', 'disbursed', 'ledger_balance_paisa', v_balance);
end;
$$;
revoke execute on function public.disburse_fee_settlement(uuid, text, text) from public, anon;
grant execute on function public.disburse_fee_settlement(uuid, text, text) to authenticated;
