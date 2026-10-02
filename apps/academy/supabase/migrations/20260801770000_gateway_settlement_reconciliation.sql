-- FR-K23: gateway settlement reconciliation.
--
-- The student is credited the FULL face value when the webhook posts the
-- payment (FR-K21). The settlement file only tells us what the gateway
-- actually paid out: the difference is the gateway's commission, a school
-- expense. It is recorded in gateway_commission, deliberately NOT in
-- fee_ledger: every balance and receivable figure sums fee_ledger, so a
-- commission row there would leave each online payer permanently short by
-- the commission and manufacture arrears.
--
-- A file is imported once per gateway (sha256). Rows that cannot be parsed
-- are kept (raw line), rows with no posted payment become unmatched
-- exceptions, rows whose gross differs from the posted payment or that were
-- already settled become exceptions. "Settled" is a matched settlement line
-- pointing at the payment, so zero-commission settlements count too.
--
-- The unsettled watchdog is a live view rather than a scheduled job: the
-- report is always current, nothing can fall behind, and the threshold (default
-- 3 days) is read at query time.

create table public.gateway_settlement_import (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  gateway         text not null check (gateway in ('jazzcash', 'easypaisa', 'onelink')),
  file_name       text,
  storage_path    text,
  file_sha256     text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  settlement_date date,
  row_count       int not null default 0,
  matched_count   int not null default 0,
  exception_count int not null default 0,
  status          text not null default 'uploaded' check (status in ('uploaded', 'parsed', 'reconciled')),
  uploaded_by     uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  constraint gateway_import_sha_uq unique (tenant_id, gateway, file_sha256)
);
create index idx_gateway_import_scope on public.gateway_settlement_import (tenant_id, created_at desc);

create table public.gateway_settlement_line (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  import_id       uuid not null references public.gateway_settlement_import(id) on delete cascade,
  line_no         int not null,
  gateway_txn_id  text,
  settlement_date date,
  gross_paisa     bigint,
  commission_paisa bigint,
  net_paisa       bigint,
  raw_line        text not null,
  status          text not null default 'parsed' check (status in ('parsed', 'parse_error', 'matched', 'unmatched', 'exception')),
  error_text      text,
  payment_id      uuid references public.fee_payment(id) on delete set null,
  created_at      timestamptz not null default now(),
  constraint uq_gateway_line_no unique (import_id, line_no),
  constraint gateway_line_parsed_has_fields check (
    status = 'parse_error' or (
      gateway_txn_id is not null and settlement_date is not null and gross_paisa > 0 and commission_paisa >= 0 and net_paisa >= 0
      and gross_paisa = commission_paisa + net_paisa
    )
  )
);
create index idx_gateway_line_scope on public.gateway_settlement_line (tenant_id, status);
create index idx_gateway_line_import on public.gateway_settlement_line (import_id);
create unique index uq_gateway_line_settled_payment on public.gateway_settlement_line (payment_id) where status = 'matched';

create table public.gateway_commission (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  payment_id       uuid not null references public.fee_payment(id) on delete cascade,
  enrolment_id     uuid not null references public.enrolment(id) on delete cascade,
  settlement_line_id uuid not null references public.gateway_settlement_line(id) on delete cascade,
  gateway          text not null,
  gateway_txn_id   text not null,
  amount_paisa     bigint not null check (amount_paisa > 0),
  settlement_date  date not null,
  created_at       timestamptz not null default now(),
  constraint uq_gateway_commission_payment unique (payment_id)
);
create index idx_gateway_commission_scope on public.gateway_commission (tenant_id, campus_id, settlement_date);

create table public.gateway_settlement_policy (
  tenant_id            uuid primary key references public.tenant(id) on delete cascade,
  unsettled_after_days int not null default 3 check (unsettled_after_days between 1 and 30)
);

create index idx_fee_payment_online_value on public.fee_payment (tenant_id, value_date) where mode = 'online';

create trigger gateway_settlement_import_audit after insert or update or delete on public.gateway_settlement_import
  for each row execute function app.tg_audit_row();
create trigger gateway_commission_audit after insert or update or delete on public.gateway_commission
  for each row execute function app.tg_audit_row();

alter table public.gateway_settlement_import enable row level security;
alter table public.gateway_settlement_line enable row level security;
alter table public.gateway_commission enable row level security;
alter table public.gateway_settlement_policy enable row level security;

create policy gateway_import_finance_read on public.gateway_settlement_import for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal'));
create policy gateway_line_finance_read on public.gateway_settlement_line for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal'));
create policy gateway_commission_finance_read on public.gateway_commission for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids())));
create policy gateway_policy_read on public.gateway_settlement_policy for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create or replace function public.set_unsettled_after_days(p_days int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_days is null or p_days not between 1 and 30 then
    raise exception 'DAYS_OUT_OF_RANGE' using errcode = '22023';
  end if;
  insert into public.gateway_settlement_policy (tenant_id, unsettled_after_days) values (app.auth_tenant_id(), p_days)
  on conflict (tenant_id) do update set unsettled_after_days = excluded.unsettled_after_days;
end;
$$;
revoke execute on function public.set_unsettled_after_days(int) from public, anon;
grant execute on function public.set_unsettled_after_days(int) to authenticated;

create or replace function public.start_gateway_settlement_import(p_gateway text, p_file_sha256 text, p_file_name text, p_storage_path text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_prior     record;
  v_id        uuid;
begin
  if app.auth_role() not in ('accountant', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select i.created_at, coalesce(u.full_name, 'unknown') as who into v_prior
    from public.gateway_settlement_import i
    left join public.app_user u on u.user_id = i.uploaded_by
   where i.tenant_id = v_tenant_id and i.gateway = p_gateway and i.file_sha256 = p_file_sha256;
  if found then
    raise exception 'duplicate file (sha256 match, imported % by %)', to_char(v_prior.created_at, 'DD-MM-YYYY'), v_prior.who using errcode = '23505';
  end if;
  insert into public.gateway_settlement_import (tenant_id, gateway, file_name, storage_path, file_sha256, uploaded_by)
  values (v_tenant_id, p_gateway, p_file_name, p_storage_path, p_file_sha256, (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.start_gateway_settlement_import(text, text, text, text) from public, anon;
grant execute on function public.start_gateway_settlement_import(text, text, text, text) to authenticated;

create or replace function public.add_gateway_settlement_lines(p_import_id uuid, p_lines jsonb, p_complete boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_import public.gateway_settlement_import%rowtype;
  v_ok     int;
  v_bad    int;
begin
  if app.auth_role() not in ('accountant', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) > 1000 then
    raise exception 'LINES_MUST_BE_AN_ARRAY_OF_AT_MOST_1000' using errcode = '22023';
  end if;
  select * into v_import from public.gateway_settlement_import where id = p_import_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'IMPORT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_import.status <> 'uploaded' then
    raise exception 'IMPORT_ALREADY_PARSED' using errcode = '55000';
  end if;

  insert into public.gateway_settlement_line (tenant_id, import_id, line_no, gateway_txn_id, settlement_date, gross_paisa, commission_paisa, net_paisa, raw_line, status, error_text)
  select v_import.tenant_id, p_import_id, l.line_no, l.gateway_txn_id, l.settlement_date, l.gross_paisa, l.commission_paisa, l.net_paisa, l.raw_line,
         case when l.error is null then 'parsed' else 'parse_error' end, l.error
    from jsonb_to_recordset(p_lines) as l(line_no int, gateway_txn_id text, settlement_date date, gross_paisa bigint, commission_paisa bigint, net_paisa bigint, raw_line text, error text);

  select count(*) filter (where status = 'parsed'), count(*) filter (where status = 'parse_error') into v_ok, v_bad
    from public.gateway_settlement_line where import_id = p_import_id;
  update public.gateway_settlement_import
     set row_count = v_ok + v_bad, exception_count = v_bad,
         settlement_date = (select max(settlement_date) from public.gateway_settlement_line where import_id = p_import_id),
         status = case when p_complete then 'parsed' else status end
   where id = p_import_id;
  return jsonb_build_object('row_count', v_ok + v_bad, 'parsed', v_ok, 'failed', v_bad);
end;
$$;
revoke execute on function public.add_gateway_settlement_lines(uuid, jsonb, boolean) from public, anon;
grant execute on function public.add_gateway_settlement_lines(uuid, jsonb, boolean) to authenticated;

create or replace function public.reconcile_gateway_settlement(p_import_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_import  public.gateway_settlement_import%rowtype;
  v_line    public.gateway_settlement_line%rowtype;
  v_pay     public.fee_payment%rowtype;
  v_matched int := 0;
  v_unmatched int := 0;
  v_exceptions int := 0;
  v_commission bigint := 0;
begin
  if app.auth_role() not in ('accountant', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_import from public.gateway_settlement_import where id = p_import_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'IMPORT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_import.status = 'uploaded' then
    raise exception 'IMPORT_NOT_PARSED' using errcode = '55000';
  end if;

  for v_line in select * from public.gateway_settlement_line where import_id = p_import_id and status = 'parsed' order by line_no loop
    select p.* into v_pay
      from public.fee_payment p
     where p.tenant_id = v_import.tenant_id and p.mode = 'online' and p.reference_no = v_line.gateway_txn_id
       and not exists (select 1 from public.payment_webhook_event e
                        where e.tenant_id = p.tenant_id and e.gateway_txn_id = p.reference_no and e.status = 'processed' and e.gateway <> v_import.gateway);
    if not found then
      update public.gateway_settlement_line set status = 'unmatched', error_text = 'No posted online payment has this transaction id' where id = v_line.id;
      v_unmatched := v_unmatched + 1;
    elsif exists (select 1 from public.gateway_settlement_line l where l.payment_id = v_pay.id and l.status = 'matched') then
      update public.gateway_settlement_line set status = 'exception', error_text = 'This payment was already settled in an earlier file' where id = v_line.id;
      v_exceptions := v_exceptions + 1;
    elsif v_line.gross_paisa <> v_pay.amount_paisa then
      update public.gateway_settlement_line
         set status = 'exception', error_text = format('Settled gross %s differs from the posted payment %s', v_line.gross_paisa, v_pay.amount_paisa)
       where id = v_line.id;
      v_exceptions := v_exceptions + 1;
    else
      update public.gateway_settlement_line set status = 'matched', payment_id = v_pay.id where id = v_line.id;
      if v_line.commission_paisa > 0 then
        insert into public.gateway_commission (tenant_id, campus_id, payment_id, enrolment_id, settlement_line_id, gateway, gateway_txn_id, amount_paisa, settlement_date)
        values (v_import.tenant_id, v_pay.campus_id, v_pay.id, v_pay.enrolment_id, v_line.id, v_import.gateway, v_line.gateway_txn_id, v_line.commission_paisa, v_line.settlement_date);
        v_commission := v_commission + v_line.commission_paisa;
      end if;
      v_matched := v_matched + 1;
    end if;
  end loop;

  update public.gateway_settlement_import
     set status = 'reconciled',
         matched_count = (select count(*) from public.gateway_settlement_line where import_id = p_import_id and status = 'matched'),
         exception_count = (select count(*) from public.gateway_settlement_line where import_id = p_import_id and status in ('parse_error', 'unmatched', 'exception'))
   where id = p_import_id;
  return jsonb_build_object('matched', v_matched, 'unmatched', v_unmatched, 'exceptions', v_exceptions, 'commission_paisa', v_commission);
end;
$$;
revoke execute on function public.reconcile_gateway_settlement(uuid) from public, anon;
grant execute on function public.reconcile_gateway_settlement(uuid) to authenticated;

create view public.v_unsettled_online_payments with (security_invoker = true) as
select p.id as payment_id, p.tenant_id, p.campus_id, p.enrolment_id, p.amount_paisa, p.reference_no as gateway_txn_id, p.value_date,
       (app.fn_karachi_today() - p.value_date) as age_days
  from public.fee_payment p
  left join public.gateway_settlement_policy pol on pol.tenant_id = p.tenant_id
 where p.mode = 'online' and p.reference_no is not null
   and (app.fn_karachi_today() - p.value_date) > coalesce(pol.unsettled_after_days, 3)
   and not exists (select 1 from public.gateway_settlement_line l where l.payment_id = p.id and l.status = 'matched');

grant select on public.v_unsettled_online_payments to authenticated;
