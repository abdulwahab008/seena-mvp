-- FR-K01: fee head master data — the first piece of Module K (Fees &
-- Billing), and the foundation every later fee FR (structure, plan,
-- ledger, challans) references by fee_head_id.
--
-- Accounting-specific care taken here, since it recurs through the whole
-- module: is_refundable is a first-class column, not something inferred
-- later — a security deposit must be structurally distinguishable from
-- real revenue everywhere it's ever posted, because "grep the report
-- filter" is how schools end up booking deposits as income and then
-- can't fund the refund years later. code uniqueness is case-insensitive
-- (lower(code)) per the AC's own TUITION/exam example — a naive
-- case-sensitive unique index would let both exist.
--
-- Scope: seeding is a deliberate, callable action (seed_default_fee_heads),
-- not woven into provision_tenant like class levels were — the AC's own
-- wording is "when the Accountant runs the seed action", not "when the
-- tenant is provisioned".

create type public.fee_frequency as enum ('monthly', 'quarterly', 'annual', 'one_time');

create table public.fee_head (
  id                        uuid primary key default gen_random_uuid(),
  tenant_id                 uuid not null references public.tenant(id) on delete cascade,
  code                      text not null,
  name_en                   text not null,
  name_ur                   text not null,
  is_refundable             boolean not null default false,
  carry_forward_on_arrears  boolean not null default true,
  gl_code                   text,
  default_frequency         public.fee_frequency not null default 'monthly',
  is_active                 boolean not null default true,
  created_by                uuid references public.app_user(user_id),
  created_at                timestamptz not null default now()
);

create unique index fee_head_tenant_code_uq on public.fee_head (tenant_id, lower(code));
create index idx_fee_head_tenant_active on public.fee_head (tenant_id, is_active);

create trigger fee_head_audit after insert or update or delete on public.fee_head
  for each row execute function app.tg_audit_row();

create or replace function public.seed_default_fee_heads(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_tenant_id <> app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.fee_head (tenant_id, code, name_en, name_ur, is_refundable, default_frequency, created_by) values
    (p_tenant_id, 'TUITION',          'Tuition Fee',      'فیس تعلیم',        false, 'monthly',  auth.uid()),
    (p_tenant_id, 'ADMISSION',        'Admission Fee',    'داخلہ فیس',        false, 'one_time', auth.uid()),
    (p_tenant_id, 'EXAM',             'Examination Fee',  'امتحانی فیس',      false, 'quarterly', auth.uid()),
    (p_tenant_id, 'TRANSPORT',        'Transport Fee',    'ٹرانسپورٹ فیس',    false, 'monthly',  auth.uid()),
    (p_tenant_id, 'LAB',              'Laboratory Fee',   'لیبارٹری فیس',     false, 'quarterly', auth.uid()),
    (p_tenant_id, 'SPORTS',           'Sports Fee',       'کھیل فیس',         false, 'annual',   auth.uid()),
    (p_tenant_id, 'SECURITY_DEPOSIT', 'Security Deposit', 'ضمانتی رقم',       true,  'one_time', auth.uid()),
    (p_tenant_id, 'ANNUAL',           'Annual Fund',      'سالانہ فنڈ',       false, 'annual',   auth.uid());
end;
$$;

revoke execute on function public.seed_default_fee_heads(uuid) from public, anon;
grant execute on function public.seed_default_fee_heads(uuid) to authenticated;

create or replace function public.create_fee_head(
  p_code text, p_name_en text, p_name_ur text,
  p_is_refundable boolean default false,
  p_carry_forward_on_arrears boolean default true,
  p_gl_code text default null,
  p_default_frequency public.fee_frequency default 'monthly'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.fee_head (tenant_id, code, name_en, name_ur, is_refundable, carry_forward_on_arrears, gl_code, default_frequency, created_by)
  values (app.auth_tenant_id(), p_code, p_name_en, p_name_ur, p_is_refundable, p_carry_forward_on_arrears, p_gl_code, p_default_frequency, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_fee_head(text, text, text, boolean, boolean, text, public.fee_frequency) from public, anon;
grant execute on function public.create_fee_head(text, text, text, boolean, boolean, text, public.fee_frequency) to authenticated;

create or replace function public.set_fee_head_active(p_id uuid, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.fee_head set is_active = p_is_active where id = p_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'FEE_HEAD_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function public.set_fee_head_active(uuid, boolean) from public, anon;
grant execute on function public.set_fee_head_active(uuid, boolean) to authenticated;

alter table public.fee_head enable row level security;

create policy fee_head_tenant_read on public.fee_head
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());
