-- Fee commitments (a parent's promise to pay by a date) and bad debts.
--
-- A commitment is a register entry the counter staff follow up on; it moves
-- no money. A bad debt is a write_off credit on the fee ledger, so the
-- student's balance, the defaulter list and every report already account
-- for it. The register row keeps the reason and who decided it.

create type public.fee_commitment_status as enum ('open', 'kept', 'broken', 'cancelled');

create table public.fee_commitment (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  enrolment_id   uuid not null references public.enrolment(id) on delete cascade,
  promised_date  date not null,
  amount_paisa   bigint not null check (amount_paisa > 0),
  note           text check (note is null or length(note) <= 300),
  status         public.fee_commitment_status not null default 'open',
  created_by     uuid default auth.uid() references auth.users(id),
  created_at     timestamptz not null default now()
);
create index idx_fee_commitment_tenant_date on public.fee_commitment (tenant_id, promised_date) where status = 'open';
create index idx_fee_commitment_enrolment on public.fee_commitment (enrolment_id);

create table public.fee_bad_debt (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  enrolment_id    uuid not null references public.enrolment(id) on delete cascade,
  amount_paisa    bigint not null check (amount_paisa > 0),
  reason          text not null check (length(btrim(reason)) between 3 and 300),
  fee_ledger_id   uuid not null references public.fee_ledger(id),
  written_off_on  date not null default current_date,
  created_by      uuid default auth.uid() references auth.users(id),
  created_at      timestamptz not null default now()
);
create index idx_fee_bad_debt_tenant on public.fee_bad_debt (tenant_id, written_off_on desc);
create index idx_fee_bad_debt_enrolment on public.fee_bad_debt (enrolment_id);

create trigger fee_commitment_audit after insert or update or delete on public.fee_commitment
  for each row execute function app.tg_audit_row();
create trigger fee_bad_debt_audit after insert or update or delete on public.fee_bad_debt
  for each row execute function app.tg_audit_row();

create or replace function app.fn_fee_desk_role()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('super_admin', 'owner', 'principal', 'accountant', 'admissions_officer', 'receptionist');
$$;

alter table public.fee_commitment enable row level security;
alter table public.fee_bad_debt enable row level security;
create policy fee_commitment_read on public.fee_commitment for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_fee_desk_role());
create policy fee_bad_debt_read on public.fee_bad_debt for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'principal', 'accountant'));
select app.fn_block_portal_roles('public.fee_commitment');
select app.fn_block_portal_roles('public.fee_bad_debt');

create or replace function public.add_fee_commitment(
  p_enrolment_id uuid, p_promised_date date, p_amount_paisa bigint, p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enrolment public.enrolment%rowtype;
  v_id        uuid;
begin
  if not app.fn_fee_desk_role() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_amount_paisa is null or p_amount_paisa <= 0 then
    raise exception 'AMOUNT_MUST_BE_POSITIVE' using errcode = '23514';
  end if;
  if p_promised_date is null or p_promised_date < app.fn_karachi_today() then
    raise exception 'DATE_IN_PAST' using errcode = '22023';
  end if;

  select * into v_enrolment from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.fee_commitment (tenant_id, campus_id, enrolment_id, promised_date, amount_paisa, note)
  values (v_enrolment.tenant_id, v_enrolment.campus_id, p_enrolment_id, p_promised_date, p_amount_paisa, nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.add_fee_commitment(uuid, date, bigint, text) from public, anon;
grant execute on function public.add_fee_commitment(uuid, date, bigint, text) to authenticated;

create or replace function public.set_fee_commitment_status(p_id uuid, p_status public.fee_commitment_status)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app.fn_fee_desk_role() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.fee_commitment set status = p_status
   where id = p_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'COMMITMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.set_fee_commitment_status(uuid, public.fee_commitment_status) from public, anon;
grant execute on function public.set_fee_commitment_status(uuid, public.fee_commitment_status) to authenticated;

-- Never more than the student currently owes: a write-off cannot turn a
-- debt into credit.
create or replace function public.write_off_bad_debt(p_enrolment_id uuid, p_amount_paisa bigint, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enrolment public.enrolment%rowtype;
  v_balance   bigint;
  v_ledger_id uuid;
  v_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_amount_paisa is null or p_amount_paisa <= 0 then
    raise exception 'AMOUNT_MUST_BE_POSITIVE' using errcode = '23514';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;

  select * into v_enrolment from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select coalesce(sum(case when direction = 'debit' then amount_paisa else -amount_paisa end), 0)
    into v_balance from public.fee_ledger where enrolment_id = p_enrolment_id;
  if p_amount_paisa > v_balance then
    raise exception 'MORE_THAN_OWED' using errcode = '23514';
  end if;

  v_id := gen_random_uuid();
  insert into public.fee_ledger (
    tenant_id, campus_id, enrolment_id, session_id, entry_type, amount_paisa, direction,
    value_date, source_type, source_id, created_by
  ) values (
    v_enrolment.tenant_id, v_enrolment.campus_id, p_enrolment_id, v_enrolment.session_id, 'write_off', p_amount_paisa, 'credit',
    app.fn_karachi_today(), 'bad_debt', v_id, auth.uid()
  )
  returning id into v_ledger_id;

  insert into public.fee_bad_debt (id, tenant_id, campus_id, enrolment_id, amount_paisa, reason, fee_ledger_id, written_off_on)
  values (v_id, v_enrolment.tenant_id, v_enrolment.campus_id, p_enrolment_id, p_amount_paisa, btrim(p_reason), v_ledger_id, app.fn_karachi_today());

  update public.fee_commitment set status = 'cancelled'
   where enrolment_id = p_enrolment_id and status = 'open';
  return v_id;
end;
$$;
revoke execute on function public.write_off_bad_debt(uuid, bigint, text) from public, anon;
grant execute on function public.write_off_bad_debt(uuid, bigint, text) to authenticated;
