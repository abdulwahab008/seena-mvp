-- FR-K19: bank statement upload and parsing.
--
-- Parsing is app-side (lib/bank/parse-statement.ts) because every bank sends
-- a different layout; the database owns what must not vary: one file is
-- imported once per account (sha256), every row is kept even when it cannot
-- be parsed (raw line preserved), and only finance roles in the right campus
-- can see any of it. Reconciliation (FR-K20) consumes bank_statement_line.

create table public.bank_mapping_profile (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  name             text not null check (length(btrim(name)) > 0),
  format           text not null default 'csv' check (format in ('csv', 'xlsx', 'mt940')),
  column_map       jsonb not null,
  date_format      text not null default 'DD/MM/YYYY' check (date_format in ('DD/MM/YYYY', 'DD-MM-YYYY', 'YYYY-MM-DD', 'DD-Mon-YYYY')),
  amount_sign_rule text not null default 'credit_positive' check (amount_sign_rule in ('credit_positive', 'separate_columns', 'absolute')),
  created_by       uuid references auth.users(id),
  created_at       timestamptz not null default now(),
  constraint uq_bank_profile_name unique (tenant_id, name),
  constraint bank_profile_map_shape check (
    column_map ? 'txn_date' and column_map ? 'challan_ref' and column_map ? 'bank_ref'
    and (
      (amount_sign_rule = 'separate_columns' and column_map ? 'debit' and column_map ? 'credit')
      or (amount_sign_rule <> 'separate_columns' and column_map ? 'amount')
    )
  )
);

alter table public.campus_bank_account
  add column if not exists mapping_profile_id uuid references public.bank_mapping_profile(id) on delete set null;

create table public.bank_statement_import (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  bank_account_id uuid not null references public.campus_bank_account(id) on delete cascade,
  file_name       text,
  storage_path    text,
  file_sha256     text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  row_count       int not null default 0,
  parsed_count    int not null default 0,
  failed_count    int not null default 0,
  status          text not null default 'uploaded' check (status in ('uploaded', 'parsed', 'reconciled', 'closed')),
  uploaded_by     uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  constraint bank_import_sha_uq unique (bank_account_id, file_sha256)
);
create index idx_bank_import_scope on public.bank_statement_import (tenant_id, campus_id, created_at desc);

create table public.bank_statement_line (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  import_id    uuid not null references public.bank_statement_import(id) on delete cascade,
  line_no      int not null,
  txn_date     date,
  challan_ref  text,
  amount_paisa bigint,
  bank_ref     text,
  raw_line     text not null,
  status       text not null default 'parsed' check (status in ('parsed', 'parse_error', 'matched', 'exception')),
  error_text   text,
  created_at   timestamptz not null default now(),
  constraint uq_bank_line_no unique (import_id, line_no),
  constraint bank_line_parsed_has_fields check (status = 'parse_error' or (txn_date is not null and amount_paisa is not null and bank_ref is not null))
);
create index idx_bank_line_scope on public.bank_statement_line (tenant_id, campus_id, status);

create trigger bank_statement_import_audit after insert or update or delete on public.bank_statement_import
  for each row execute function app.tg_audit_row();

alter table public.bank_mapping_profile enable row level security;
alter table public.bank_statement_import enable row level security;
alter table public.bank_statement_line enable row level security;

create policy bank_profile_finance_read on public.bank_mapping_profile
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal'));

create policy bank_import_finance_read on public.bank_statement_import
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal')
    and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids()))
  );

create policy bank_line_finance_read on public.bank_statement_line
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal')
    and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids()))
  );

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bank-statements', 'bank-statements', false, 5242880, array['text/csv', 'text/plain', 'application/vnd.ms-excel'])
on conflict (id) do update set file_size_limit = 5242880, allowed_mime_types = array['text/csv', 'text/plain', 'application/vnd.ms-excel'];

-- ── profiles ──────────────────────────────────────────────────────────────

create or replace function public.create_bank_mapping_profile(
  p_name text, p_format text, p_column_map jsonb, p_date_format text, p_amount_sign_rule text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('accountant', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.bank_mapping_profile (tenant_id, name, format, column_map, date_format, amount_sign_rule, created_by)
  values (app.auth_tenant_id(), btrim(p_name), p_format, p_column_map, p_date_format, p_amount_sign_rule, (select auth.uid()))
  returning id into v_id;
  return v_id;
exception when check_violation then
  raise exception 'INVALID_MAPPING_PROFILE' using errcode = '22023';
end;
$$;

revoke execute on function public.create_bank_mapping_profile(text, text, jsonb, text, text) from public, anon;
grant execute on function public.create_bank_mapping_profile(text, text, jsonb, text, text) to authenticated;

create or replace function public.assign_bank_mapping_profile(p_bank_account_id uuid, p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  if app.auth_role() not in ('accountant', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.bank_mapping_profile where id = p_profile_id and tenant_id = v_tenant_id) then
    raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0002';
  end if;
  update public.campus_bank_account a set mapping_profile_id = p_profile_id
   from public.campus c
   where a.id = p_bank_account_id and c.id = a.campus_id and c.tenant_id = v_tenant_id;
  if not found then
    raise exception 'BANK_ACCOUNT_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function public.assign_bank_mapping_profile(uuid, uuid) from public, anon;
grant execute on function public.assign_bank_mapping_profile(uuid, uuid) to authenticated;

-- ── imports ───────────────────────────────────────────────────────────────

create or replace function public.start_bank_statement_import(
  p_bank_account_id uuid, p_file_sha256 text, p_file_name text, p_storage_path text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_campus_id uuid;
  v_prior     record;
  v_id        uuid;
begin
  if app.auth_role() not in ('accountant', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select a.campus_id into v_campus_id
    from public.campus_bank_account a join public.campus c on c.id = a.campus_id
   where a.id = p_bank_account_id and c.tenant_id = v_tenant_id;
  if v_campus_id is null then
    raise exception 'BANK_ACCOUNT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select i.created_at, coalesce(u.full_name, 'unknown') as who into v_prior
    from public.bank_statement_import i
    left join public.app_user u on u.user_id = i.uploaded_by
   where i.bank_account_id = p_bank_account_id and i.file_sha256 = p_file_sha256;
  if found then
    raise exception 'duplicate file (sha256 match, imported % by %)', to_char(v_prior.created_at, 'DD-MM-YYYY'), v_prior.who
      using errcode = '23505';
  end if;

  insert into public.bank_statement_import (tenant_id, campus_id, bank_account_id, file_name, storage_path, file_sha256, uploaded_by)
  values (v_tenant_id, v_campus_id, p_bank_account_id, p_file_name, p_storage_path, p_file_sha256, (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;

revoke execute on function public.start_bank_statement_import(uuid, text, text, text) from public, anon;
grant execute on function public.start_bank_statement_import(uuid, text, text, text) to authenticated;

create or replace function public.add_bank_statement_lines(p_import_id uuid, p_lines jsonb, p_complete boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_import public.bank_statement_import%rowtype;
  v_parsed int;
  v_failed int;
begin
  if app.auth_role() not in ('accountant', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) > 1000 then
    raise exception 'LINES_MUST_BE_AN_ARRAY_OF_AT_MOST_1000' using errcode = '22023';
  end if;

  select * into v_import from public.bank_statement_import where id = p_import_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'IMPORT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_import.status <> 'uploaded' then
    raise exception 'IMPORT_ALREADY_PARSED' using errcode = '55000';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_import.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.bank_statement_line (tenant_id, campus_id, import_id, line_no, txn_date, challan_ref, amount_paisa, bank_ref, raw_line, status, error_text)
  select v_import.tenant_id, v_import.campus_id, p_import_id, l.line_no, l.txn_date, l.challan_ref, l.amount_paisa, l.bank_ref, l.raw_line,
         case when l.error is null then 'parsed' else 'parse_error' end, l.error
    from jsonb_to_recordset(p_lines) as l(line_no int, txn_date date, challan_ref text, amount_paisa bigint, bank_ref text, raw_line text, error text);

  select count(*) filter (where status = 'parsed'), count(*) filter (where status = 'parse_error')
    into v_parsed, v_failed from public.bank_statement_line where import_id = p_import_id;

  update public.bank_statement_import
     set row_count = v_parsed + v_failed, parsed_count = v_parsed, failed_count = v_failed,
         status = case when p_complete then 'parsed' else status end
   where id = p_import_id;

  return jsonb_build_object('row_count', v_parsed + v_failed, 'parsed', v_parsed, 'failed', v_failed);
end;
$$;

revoke execute on function public.add_bank_statement_lines(uuid, jsonb, boolean) from public, anon;
grant execute on function public.add_bank_statement_lines(uuid, jsonb, boolean) to authenticated;
