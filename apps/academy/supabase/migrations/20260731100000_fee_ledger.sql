-- FR-K14 (append-only fee ledger) and FR-K15 (correction by reversal
-- entry only), shipped together: an "immutable" ledger with no correction
-- path at all isn't a usable feature — reversal IS the correction
-- mechanism an append-only ledger requires, not an optional add-on.
--
-- This is the accounting core the whole fee module posts to. Every other
-- FR in this module (challans, payments, concessions applied) writes
-- ENTRIES here; none of them ever computes "the balance" by caching a
-- number anywhere. student_balance() sums the ledger itself — deriving
-- balance from entries, never a stored column, is what removes the whole
-- class of drift bugs where a cached number and the entries disagree.
--
-- fee_ledger_no_mutate is a plain BEFORE UPDATE OR DELETE trigger that
-- unconditionally raises — no role check, no exception carved out for
-- service_role. "We just never write an UPDATE in the app" is not a
-- control; a trigger that fires regardless of caller is. The only way to
-- correct a posted entry is reverse_ledger_entry(): a new, opposite-
-- direction entry referencing the original via reversal_of_id, posted at
-- TODAY's value_date — never the original entry's date, or a signed-off
-- daily collection report for a past date would silently change.
--
-- Reversal is Owner-only, deliberately narrower than posting
-- (Accountant/Owner/Super Admin) — reversing a payment is a materially
-- more sensitive action than recording one.
--
-- Scope cuts:
--   * challan_id has no FK — fee_challan (FR-K09) doesn't exist yet. A
--     plain nullable uuid column now, bound once K09 ships.
--   * "a denied reversal attempt writes its own audit row" (from the AC)
--     is not implemented — the transaction that raises FORBIDDEN rolls
--     back everything in it, so logging a denial that survives the abort
--     needs an autonomous sub-transaction plpgsql doesn't have natively.
--     The denial itself is fully enforced; only the extra audit trail for
--     denied (not just successful) actions is deferred.
--   * post_ledger_entry() is a generic, callable entry point so this
--     batch is independently testable — K09/K16 will call the same
--     insert shape once they exist, not reinvent it.

create type public.fee_ledger_entry_type as enum (
  'charge', 'concession', 'late_fee', 'payment', 'refund', 'adjustment', 'write_off', 'reversal'
);
create type public.fee_ledger_direction as enum ('debit', 'credit');

create table public.fee_ledger (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  enrolment_id   uuid not null references public.enrolment(id) on delete cascade,
  session_id     uuid not null references public.academic_session(id) on delete cascade,
  challan_id     uuid,
  entry_type     public.fee_ledger_entry_type not null,
  fee_head_id    uuid references public.fee_head(id),
  amount_paisa   bigint not null check (amount_paisa > 0),
  direction      public.fee_ledger_direction not null,
  posted_at      timestamptz not null default now(),
  value_date     date not null default current_date,
  source_type    text,
  source_id      uuid,
  reason         text,
  created_by     uuid references public.app_user(user_id),
  reversal_of_id uuid references public.fee_ledger(id),
  constraint ck_reversal_reason_len check (reversal_of_id is null or length(btrim(reason)) >= 15)
);

create index idx_fee_ledger_enrol_posted on public.fee_ledger (enrolment_id, posted_at);
create index idx_fee_ledger_challan on public.fee_ledger (challan_id);
create unique index fee_ledger_reversal_uq on public.fee_ledger (reversal_of_id) where reversal_of_id is not null;

-- No role exception, no "unless service_role" carve-out — this must hold
-- against every caller, including the elevated keys Edge Functions and
-- background workers connect with.
create or replace function app.tg_fee_ledger_no_mutate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'FEE_LEDGER_IMMUTABLE' using errcode = '42501';
end;
$$;

create trigger fee_ledger_no_mutate before update or delete on public.fee_ledger
  for each row execute function app.tg_fee_ledger_no_mutate();

-- debit increases what a student owes (charge, late_fee); credit
-- decreases it (concession, payment, refund, write_off). adjustment can
-- go either way, at the caller's discretion.
create or replace function public.student_balance(p_enrolment_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(case when direction = 'debit' then amount_paisa else -amount_paisa end), 0)::bigint
    from public.fee_ledger
   where enrolment_id = p_enrolment_id and tenant_id = app.auth_tenant_id();
$$;

revoke execute on function public.student_balance(uuid) from public, anon;
grant execute on function public.student_balance(uuid) to authenticated;

create or replace function public.post_ledger_entry(
  p_enrolment_id uuid, p_entry_type public.fee_ledger_entry_type, p_amount_paisa bigint, p_direction public.fee_ledger_direction,
  p_fee_head_id uuid default null, p_value_date date default current_date, p_source_type text default null, p_source_id uuid default null
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
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_amount_paisa <= 0 then
    raise exception 'AMOUNT_MUST_BE_POSITIVE' using errcode = '23514';
  end if;

  select * into v_enrolment from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.fee_ledger (
    tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction,
    value_date, source_type, source_id, created_by
  ) values (
    v_enrolment.tenant_id, v_enrolment.campus_id, p_enrolment_id, v_enrolment.session_id, p_entry_type, p_fee_head_id, p_amount_paisa, p_direction,
    p_value_date, p_source_type, p_source_id, auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.post_ledger_entry(
  uuid, public.fee_ledger_entry_type, bigint, public.fee_ledger_direction, uuid, date, text, uuid
) from public, anon;
grant execute on function public.post_ledger_entry(
  uuid, public.fee_ledger_entry_type, bigint, public.fee_ledger_direction, uuid, date, text, uuid
) to authenticated;

create or replace function public.reverse_ledger_entry(p_ledger_id uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry         public.fee_ledger%rowtype;
  v_new_direction public.fee_ledger_direction;
  v_id            uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 15 then
    raise exception 'REASON_TOO_SHORT' using errcode = '23514';
  end if;

  select * into v_entry from public.fee_ledger where id = p_ledger_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'LEDGER_ENTRY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_entry.reversal_of_id is not null then
    raise exception 'CANNOT_REVERSE_A_REVERSAL' using errcode = '55000';
  end if;

  v_new_direction := case v_entry.direction when 'debit' then 'credit'::public.fee_ledger_direction else 'debit'::public.fee_ledger_direction end;

  insert into public.fee_ledger (
    tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction,
    value_date, source_type, source_id, reason, created_by, reversal_of_id
  ) values (
    v_entry.tenant_id, v_entry.campus_id, v_entry.enrolment_id, v_entry.session_id, 'reversal', v_entry.fee_head_id, v_entry.amount_paisa, v_new_direction,
    current_date, 'reversal', p_ledger_id, p_reason, auth.uid(), p_ledger_id
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.reverse_ledger_entry(uuid, text) from public, anon;
grant execute on function public.reverse_ledger_entry(uuid, text) to authenticated;

alter table public.fee_ledger enable row level security;

create policy fee_ledger_select_campus_scope on public.fee_ledger
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
