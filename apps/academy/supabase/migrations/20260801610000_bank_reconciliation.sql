-- FR-K20: bank reconciliation and exception queue.
--
-- Exact matches post as bank_challan payments. Everything else becomes a
-- typed exception a human resolves — with one deliberate rule from the FR's
-- Notes: a line SHORT of the challan balance (a parent paying the pre-due
-- amount after the due date) is an amount_mismatch that an accountant
-- confirms into a PARTIAL payment, leaving the late fee outstanding. It is
-- not a failure. A line for an already-paid challan is possible_duplicate and
-- never posts automatically: double-credit is the error that matters.

alter table public.fee_payment
  add column if not exists bank_account_id uuid references public.campus_bank_account(id) on delete set null;

create unique index if not exists fee_payment_bank_ref_uq on public.fee_payment (bank_account_id, reference_no)
  where mode = 'bank_challan' and bank_account_id is not null;

create table public.bank_recon_exception (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  import_id       uuid not null references public.bank_statement_import(id) on delete cascade,
  line_id         uuid not null unique references public.bank_statement_line(id) on delete cascade,
  reason          text not null check (reason in ('unmatched', 'amount_mismatch', 'possible_duplicate', 'cancelled_challan', 'check_digit_fail')),
  challan_id      uuid references public.fee_challan(id) on delete set null,
  expected_paisa  bigint,
  received_paisa  bigint not null,
  resolved_by     uuid references auth.users(id),
  resolution_note text,
  resolved_at     timestamptz,
  payment_id      uuid references public.fee_payment(id) on delete set null,
  created_at      timestamptz not null default now()
);
create index idx_bank_exception_scope on public.bank_recon_exception (tenant_id, campus_id, resolved_at);
create index idx_bank_exception_import on public.bank_recon_exception (import_id) where resolved_at is null;

alter table public.bank_recon_exception enable row level security;
create policy bank_recon_exception_finance_read on public.bank_recon_exception
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal')
    and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids()))
  );

create view public.v_bank_recon_summary with (security_invoker = true) as
select i.id as import_id, i.tenant_id, i.campus_id, i.bank_account_id, i.status, i.row_count, i.parsed_count, i.failed_count,
       (select count(*) from public.bank_statement_line l where l.import_id = i.id and l.status = 'matched') as matched_count,
       (select count(*) from public.bank_recon_exception e where e.import_id = i.id and e.resolved_at is null) as unresolved_count,
       (select count(*) from public.bank_recon_exception e where e.import_id = i.id) as exception_count
  from public.bank_statement_import i;

-- One place that turns a confirmed external payment into a fee_payment: acts
-- as a system accountant for this transaction only, then restores the claims.
create or replace function app.fn_post_system_payment(
  p_tenant_id uuid, p_enrolment_id uuid, p_amount bigint, p_mode public.fee_payment_mode,
  p_reference text, p_value_date date, p_bank_account_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev text := current_setting('request.jwt.claims', true);
  v_id   uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('tenant_id', p_tenant_id, 'app_role', 'accountant')::text, true);
  v_id := public.record_payment(p_enrolment_id, p_amount, p_mode, p_reference, p_value_date);
  if p_bank_account_id is not null then
    update public.fee_payment set bank_account_id = p_bank_account_id where id = v_id;
  end if;
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  return v_id;
exception when others then
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  raise;
end;
$$;
revoke execute on function app.fn_post_system_payment(uuid, uuid, bigint, public.fee_payment_mode, text, date, uuid) from public, anon, authenticated;

create or replace function app.fn_post_online_payment(p_tenant_id uuid, p_enrolment_id uuid, p_amount bigint, p_reference text)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select app.fn_post_system_payment(p_tenant_id, p_enrolment_id, p_amount, 'online'::public.fee_payment_mode, p_reference, current_date, null);
$$;
revoke execute on function app.fn_post_online_payment(uuid, uuid, bigint, text) from public, anon, authenticated;

create or replace function app.fn_bank_line_exception(p_line public.bank_statement_line, p_reason text, p_challan_id uuid, p_expected bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.bank_recon_exception (tenant_id, campus_id, import_id, line_id, reason, challan_id, expected_paisa, received_paisa)
  values (p_line.tenant_id, p_line.campus_id, p_line.import_id, p_line.id, p_reason, p_challan_id, p_expected, p_line.amount_paisa)
  on conflict (line_id) do nothing;
  update public.bank_statement_line set status = 'exception' where id = p_line.id;
end;
$$;
revoke execute on function app.fn_bank_line_exception(public.bank_statement_line, text, uuid, bigint) from public, anon, authenticated;

create or replace function public.reconcile_bank_import(p_import_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_import   public.bank_statement_import%rowtype;
  v_line     public.bank_statement_line%rowtype;
  v_challan  record;
  v_balance  bigint;
  v_matched  int := 0;
  v_excepted int := 0;
begin
  if app.auth_role() not in ('accountant', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_import from public.bank_statement_import where id = p_import_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'IMPORT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_import.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_import.status not in ('parsed', 'reconciled') then
    raise exception 'IMPORT_NOT_READY' using errcode = '55000';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('bank-recon:' || p_import_id::text, 0));

  for v_line in
    select * from public.bank_statement_line where import_id = p_import_id and status = 'parsed' order by line_no
  loop
    if public.challan_check_digit(left(v_line.challan_ref, 11))::text <> right(v_line.challan_ref, 1) then
      perform app.fn_bank_line_exception(v_line, 'check_digit_fail', null, null);
      v_excepted := v_excepted + 1;
      continue;
    end if;

    select c.id, c.status, c.enrolment_id, c.tenant_id into v_challan
      from public.fee_challan c
     where c.tenant_id = v_import.tenant_id and c.campus_id = v_import.campus_id
       and c.challan_digits = v_line.challan_ref and c.deleted_at is null
     order by (select s.is_current from public.academic_session s where s.id = c.session_id) desc, c.created_at desc
     limit 1;

    if v_challan.id is null then
      perform app.fn_bank_line_exception(v_line, 'unmatched', null, null);
      v_excepted := v_excepted + 1;
      continue;
    end if;
    if v_challan.status = 'cancelled' then
      perform app.fn_bank_line_exception(v_line, 'cancelled_challan', v_challan.id, null);
      v_excepted := v_excepted + 1;
      continue;
    end if;

    v_balance := app.fn_challan_balance(v_challan.id);
    if v_challan.status = 'paid' or v_balance is null or v_balance <= 0
       or exists (select 1 from public.fee_payment where bank_account_id = v_import.bank_account_id and reference_no = v_line.bank_ref and mode = 'bank_challan') then
      perform app.fn_bank_line_exception(v_line, 'possible_duplicate', v_challan.id, v_balance);
      v_excepted := v_excepted + 1;
      continue;
    end if;
    if v_line.amount_paisa <> v_balance then
      perform app.fn_bank_line_exception(v_line, 'amount_mismatch', v_challan.id, v_balance);
      v_excepted := v_excepted + 1;
      continue;
    end if;

    begin
      perform app.fn_post_system_payment(v_import.tenant_id, v_challan.enrolment_id, v_line.amount_paisa, 'bank_challan'::public.fee_payment_mode, v_line.bank_ref, v_line.txn_date, v_import.bank_account_id);
      update public.bank_statement_line set status = 'matched' where id = v_line.id;
      v_matched := v_matched + 1;
    exception when unique_violation then
      perform app.fn_bank_line_exception(v_line, 'possible_duplicate', v_challan.id, v_balance);
      v_excepted := v_excepted + 1;
    end;
  end loop;

  update public.bank_statement_import set status = 'reconciled' where id = p_import_id and status = 'parsed';
  return jsonb_build_object('matched', v_matched, 'exceptions', v_excepted);
end;
$$;

revoke execute on function public.reconcile_bank_import(uuid) from public, anon;
grant execute on function public.reconcile_bank_import(uuid) to authenticated;

create or replace function public.resolve_bank_exception(
  p_exception_id uuid, p_action text, p_note text, p_challan_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ex       public.bank_recon_exception%rowtype;
  v_line     public.bank_statement_line%rowtype;
  v_import   public.bank_statement_import%rowtype;
  v_challan  record;
  v_payment  uuid;
begin
  if app.auth_role() not in ('accountant', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_action not in ('post', 'dismiss') then
    raise exception 'ACTION_INVALID' using errcode = '22023';
  end if;
  if p_note is null or length(btrim(p_note)) < 5 then
    raise exception 'RESOLUTION_NOTE_REQUIRED' using errcode = '22023';
  end if;

  select * into v_ex from public.bank_recon_exception where id = p_exception_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'EXCEPTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_ex.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_ex.resolved_at is not null then
    raise exception 'ALREADY_RESOLVED' using errcode = '55000';
  end if;

  select * into v_line from public.bank_statement_line where id = v_ex.line_id;
  select * into v_import from public.bank_statement_import where id = v_ex.import_id;

  if p_action = 'dismiss' then
    update public.bank_recon_exception
       set resolved_by = (select auth.uid()), resolution_note = p_note, resolved_at = now()
     where id = p_exception_id;
    return jsonb_build_object('status', 'dismissed');
  end if;

  if v_ex.reason = 'cancelled_challan' then
    raise exception 'CANCELLED_CHALLAN_CANNOT_BE_POSTED' using errcode = '55000';
  end if;

  select c.id, c.enrolment_id, c.status into v_challan
    from public.fee_challan c
   where c.id = coalesce(p_challan_id, v_ex.challan_id) and c.tenant_id = v_ex.tenant_id and c.campus_id = v_ex.campus_id and c.deleted_at is null;
  if v_challan.id is null or v_challan.status = 'cancelled' then
    raise exception 'CHALLAN_REQUIRED' using errcode = '22023';
  end if;

  v_payment := app.fn_post_system_payment(v_ex.tenant_id, v_challan.enrolment_id, v_line.amount_paisa, 'bank_challan'::public.fee_payment_mode,
                                          v_line.bank_ref, v_line.txn_date, v_import.bank_account_id);
  update public.bank_recon_exception
     set resolved_by = (select auth.uid()), resolution_note = p_note, resolved_at = now(), payment_id = v_payment, challan_id = v_challan.id
   where id = p_exception_id;
  update public.bank_statement_line set status = 'matched' where id = v_ex.line_id;

  return jsonb_build_object('status', 'posted', 'payment_id', v_payment);
exception when unique_violation then
  raise exception 'PAYMENT_ALREADY_POSTED_FOR_THIS_BANK_REFERENCE' using errcode = '23505';
end;
$$;

revoke execute on function public.resolve_bank_exception(uuid, text, text, uuid) from public, anon;
grant execute on function public.resolve_bank_exception(uuid, text, text, uuid) to authenticated;

create or replace function public.close_bank_import(p_import_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_import public.bank_statement_import%rowtype;
  v_open   int;
begin
  if app.auth_role() not in ('accountant', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_import from public.bank_statement_import where id = p_import_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'IMPORT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_import.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_import.status <> 'reconciled' then
    raise exception 'IMPORT_NOT_RECONCILED' using errcode = '55000';
  end if;

  select count(*) into v_open from public.bank_recon_exception where import_id = p_import_id and resolved_at is null;
  if v_open > 0 then
    raise exception 'UNRESOLVED_EXCEPTIONS' using errcode = '55000', detail = v_open::text || ' exceptions still unresolved';
  end if;

  update public.bank_statement_import set status = 'closed' where id = p_import_id;
end;
$$;

revoke execute on function public.close_bank_import(uuid) from public, anon;
grant execute on function public.close_bank_import(uuid) to authenticated;
