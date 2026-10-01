-- FR-R01: item master and an immutable stock ledger per campus store.
--
-- "On-hand quantity always has an audit trail behind it." There is no running
-- balance column anywhere: on-hand is SUM(qty) over inv_stock_movement, and the
-- movement rows are append-only (a trigger refuses UPDATE and DELETE for every
-- role). The classic bug this avoids is a mutable balance that two concurrent
-- sales both read before either writes. Writers instead take a row lock on
-- inv_stock_lock (one row per store+item) BEFORE reading the sum, so a second
-- sale of the last shirt waits for the first and then sees the true balance.
--
-- Size is a first-class column on inv_item: one shirt design is a dozen SKUs
-- and schools reorder by size, so it is not free text appended to the name.
--
-- Corrections are new rows. A stock take that counts 55 against a system 57 is
-- posted with post_stock_variance(), which writes a -2 'adjustment' row with a
-- reason code; the original rows are never touched.
--
-- Every campus has its own store(s). The same uniform item at two campuses has
-- an independent on-hand per store, and movements can only be posted to a store
-- of a campus the caller works at.

create type public.inv_item_category as enum ('uniform', 'textbook', 'stationery', 'consumable');
create type public.inv_movement_type as enum ('receipt', 'sale', 'issue', 'return', 'adjustment', 'writeoff');

create table public.inv_item (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  item_code     text not null check (item_code = btrim(item_code) and char_length(item_code) between 1 and 40),
  name          text not null check (char_length(btrim(name)) between 1 and 200),
  category      public.inv_item_category not null,
  uom           text not null default 'pcs' check (char_length(btrim(uom)) between 1 and 20),
  size          text check (size is null or char_length(btrim(size)) between 1 and 20),
  class_id      uuid references public.class_level(id),
  subject_id    uuid references public.subject(id),
  reorder_level numeric not null default 0 check (reorder_level >= 0),
  sale_price    bigint not null default 0 check (sale_price >= 0),
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);
create unique index uq_item_code on public.inv_item (tenant_id, item_code);
create index idx_inv_item_tenant on public.inv_item (tenant_id, category);
create index idx_inv_item_class on public.inv_item (class_id);
create index idx_inv_item_subject on public.inv_item (subject_id);

create table public.inv_store (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  name       text not null check (char_length(btrim(name)) between 1 and 100),
  created_at timestamptz not null default now(),
  constraint uq_inv_store_campus_name unique (campus_id, name)
);
create index idx_inv_store_tenant on public.inv_store (tenant_id);

create table public.inv_stock_lock (
  store_id uuid not null references public.inv_store(id) on delete cascade,
  item_id  uuid not null references public.inv_item(id) on delete cascade,
  primary key (store_id, item_id)
);
create index idx_inv_stock_lock_item on public.inv_stock_lock (item_id);

create table public.inv_stock_movement (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  store_id      uuid not null references public.inv_store(id),
  item_id       uuid not null references public.inv_item(id),
  movement_type public.inv_movement_type not null,
  qty           numeric not null check (qty <> 0),
  unit_cost     bigint check (unit_cost is null or unit_cost >= 0),
  reason_code   text check (reason_code is null or reason_code in ('SHRINKAGE', 'DAMAGE', 'EXPIRED', 'FOUND', 'COUNT_ERROR', 'OTHER')),
  ref_table     text,
  ref_id        uuid,
  moved_at      timestamptz not null default clock_timestamp(),
  moved_by      uuid references public.app_user(user_id),
  constraint chk_inv_movement_sign check (
    case movement_type
      when 'receipt' then qty > 0
      when 'return' then qty > 0
      when 'sale' then qty < 0
      when 'issue' then qty < 0
      when 'writeoff' then qty < 0
      else true
    end),
  constraint chk_inv_movement_reason check (movement_type not in ('adjustment', 'writeoff') or reason_code is not null)
);
create index idx_inv_movement_store_item on public.inv_stock_movement (store_id, item_id, moved_at);
create index idx_inv_movement_item on public.inv_stock_movement (item_id);
create index idx_inv_movement_ref on public.inv_stock_movement (ref_table, ref_id);
create index idx_inv_movement_tenant_campus on public.inv_stock_movement (tenant_id, campus_id);

create table public.inv_reorder_alert (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  store_id      uuid not null references public.inv_store(id) on delete cascade,
  item_id       uuid not null references public.inv_item(id) on delete cascade,
  on_hand       numeric not null,
  reorder_level numeric not null,
  raised_at     timestamptz not null default clock_timestamp(),
  resolved_at   timestamptz
);
create unique index uq_inv_reorder_open on public.inv_reorder_alert (store_id, item_id) where resolved_at is null;
create index idx_inv_reorder_tenant on public.inv_reorder_alert (tenant_id, campus_id);
create index idx_inv_reorder_item on public.inv_reorder_alert (item_id);

create trigger inv_item_audit after insert or update or delete on public.inv_item
  for each row execute function app.tg_audit_row();
create trigger inv_store_audit after insert or update or delete on public.inv_store
  for each row execute function app.tg_audit_row();

create or replace function app.tg_inv_movement_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'STOCK_MOVEMENT_IMMUTABLE'
    using errcode = '42501',
          hint = 'The stock ledger is append-only. Post an adjustment movement to correct a quantity.';
end;
$$;
create trigger trg_inv_movement_immutable before update or delete on public.inv_stock_movement
  for each row execute function app.tg_inv_movement_immutable();

alter table public.inv_item enable row level security;
alter table public.inv_store enable row level security;
alter table public.inv_stock_lock enable row level security;
alter table public.inv_stock_movement enable row level security;
alter table public.inv_reorder_alert enable row level security;

revoke insert, update, delete, truncate on public.inv_item, public.inv_store, public.inv_stock_lock, public.inv_stock_movement, public.inv_reorder_alert from anon, authenticated;
revoke all on public.inv_stock_lock from anon, authenticated;

create policy inv_item_tenant_read on public.inv_item for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'accountant', 'librarian', 'principal', 'vice_principal', 'admissions_officer'));

create policy inv_campus_scope on public.inv_store for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'accountant', 'librarian', 'principal', 'vice_principal', 'admissions_officer')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

create policy inv_movement_campus_scope on public.inv_stock_movement for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'accountant', 'librarian', 'principal', 'vice_principal', 'admissions_officer')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

create policy inv_reorder_alert_campus_scope on public.inv_reorder_alert for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'accountant', 'librarian', 'principal', 'vice_principal')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

create or replace view public.v_stock_on_hand
with (security_invoker = true) as
select m.tenant_id,
       m.campus_id,
       m.store_id,
       m.item_id,
       i.item_code,
       i.name as item_name,
       i.category,
       i.size,
       i.reorder_level,
       sum(m.qty) as on_hand,
       count(*)::int as movement_count,
       sum(m.qty) <= i.reorder_level as at_or_below_reorder
  from public.inv_stock_movement m
  join public.inv_item i on i.id = m.item_id
 group by m.tenant_id, m.campus_id, m.store_id, m.item_id, i.item_code, i.name, i.category, i.size, i.reorder_level;
revoke all on public.v_stock_on_hand from public, anon;
grant select on public.v_stock_on_hand to authenticated;

-- ── item and store maintenance ─────────────────────────────────────────

create or replace function public.create_inv_item(
  p_item_code text, p_name text, p_category public.inv_item_category, p_uom text default 'pcs', p_size text default null,
  p_class_id uuid default null, p_subject_id uuid default null, p_reorder_level numeric default 0, p_sale_price bigint default 0
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_id     uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'librarian') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if btrim(coalesce(p_item_code, '')) = '' or btrim(coalesce(p_name, '')) = '' then
    raise exception 'ITEM_CODE_AND_NAME_REQUIRED' using errcode = '23514';
  end if;
  if coalesce(p_reorder_level, 0) < 0 or coalesce(p_sale_price, 0) < 0 then
    raise exception 'VALUE_MUST_BE_NONNEGATIVE' using errcode = '23514';
  end if;
  if p_class_id is not null and not exists (select 1 from public.class_level where id = p_class_id and tenant_id = v_tenant) then
    raise exception 'CLASS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_subject_id is not null and not exists (select 1 from public.subject where id = p_subject_id and tenant_id = v_tenant) then
    raise exception 'SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into public.inv_item (tenant_id, item_code, name, category, uom, size, class_id, subject_id, reorder_level, sale_price)
  values (v_tenant, btrim(p_item_code), btrim(p_name), p_category, coalesce(nullif(btrim(p_uom), ''), 'pcs'), nullif(btrim(p_size), ''),
          p_class_id, p_subject_id, coalesce(p_reorder_level, 0), coalesce(p_sale_price, 0))
  returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'ITEM_CODE_EXISTS' using errcode = '23505';
end;
$$;
revoke execute on function public.create_inv_item(text, text, public.inv_item_category, text, text, uuid, uuid, numeric, bigint) from public, anon;
grant execute on function public.create_inv_item(text, text, public.inv_item_category, text, text, uuid, uuid, numeric, bigint) to authenticated;

create or replace function public.update_inv_item(p_item_id uuid, p_name text, p_reorder_level numeric, p_sale_price bigint, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'librarian') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if btrim(coalesce(p_name, '')) = '' or coalesce(p_reorder_level, 0) < 0 or coalesce(p_sale_price, 0) < 0 then
    raise exception 'VALUE_MUST_BE_NONNEGATIVE' using errcode = '23514';
  end if;
  update public.inv_item
     set name = btrim(p_name), reorder_level = coalesce(p_reorder_level, 0), sale_price = coalesce(p_sale_price, 0), active = coalesce(p_active, active)
   where id = p_item_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ITEM_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.update_inv_item(uuid, text, numeric, bigint, boolean) from public, anon;
grant execute on function public.update_inv_item(uuid, text, numeric, bigint, boolean) to authenticated;

create or replace function public.create_inv_store(p_campus_id uuid, p_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_id     uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'librarian') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (p_campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if btrim(coalesce(p_name, '')) = '' then
    raise exception 'STORE_NAME_REQUIRED' using errcode = '23514';
  end if;
  insert into public.inv_store (tenant_id, campus_id, name) values (v_tenant, p_campus_id, btrim(p_name)) returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'STORE_EXISTS' using errcode = '23505';
end;
$$;
revoke execute on function public.create_inv_store(uuid, text) from public, anon;
grant execute on function public.create_inv_store(uuid, text) to authenticated;

-- ── the one writer of the stock ledger ─────────────────────────────────
-- app.fn_post_stock_movement does no role check (callers such as create_sale
-- and post_goods_receipt have already authorised the business action); it does
-- verify tenant and campus scope of the store and takes the lock.

create or replace function app.fn_post_stock_movement(
  p_store_id uuid, p_item_id uuid, p_type public.inv_movement_type, p_qty numeric,
  p_unit_cost bigint default null, p_reason_code text default null, p_ref_table text default null, p_ref_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant  uuid := app.auth_tenant_id();
  v_store   public.inv_store%rowtype;
  v_item    public.inv_item%rowtype;
  v_on_hand numeric;
  v_id      uuid;
begin
  select * into v_store from public.inv_store where id = p_store_id and tenant_id = v_tenant;
  if not found then
    raise exception 'STORE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_store.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_item from public.inv_item where id = p_item_id and tenant_id = v_tenant;
  if not found then
    raise exception 'ITEM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_qty is null or p_qty = 0 then
    raise exception 'QTY_MUST_BE_NONZERO' using errcode = '23514';
  end if;

  -- Serialise every writer of this store+item BEFORE reading the balance.
  insert into public.inv_stock_lock (store_id, item_id) values (p_store_id, p_item_id) on conflict do nothing;
  perform 1 from public.inv_stock_lock where store_id = p_store_id and item_id = p_item_id for update;

  if p_qty < 0 then
    select coalesce(sum(qty), 0) into v_on_hand from public.inv_stock_movement where store_id = p_store_id and item_id = p_item_id;
    if v_on_hand + p_qty < 0 then
      raise exception 'INSUFFICIENT_STOCK'
        using errcode = '23514', detail = format('on_hand=%s requested=%s item=%s', v_on_hand, -p_qty, v_item.item_code);
    end if;
  end if;

  insert into public.inv_stock_movement (tenant_id, campus_id, store_id, item_id, movement_type, qty, unit_cost, reason_code, ref_table, ref_id, moved_by)
  values (v_store.tenant_id, v_store.campus_id, p_store_id, p_item_id, p_type, p_qty, p_unit_cost, p_reason_code, p_ref_table, p_ref_id, (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function app.fn_post_stock_movement(uuid, uuid, public.inv_movement_type, numeric, bigint, text, text, uuid) from public, anon, authenticated;

create or replace function public.post_stock_movement(
  p_store_id uuid, p_item_id uuid, p_type public.inv_movement_type, p_qty numeric,
  p_unit_cost bigint default null, p_reason_code text default null, p_ref_table text default null, p_ref_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'librarian') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  -- Callers state magnitudes for receipt/return and for the outgoing types;
  -- the sign is derived from the type so a sale can never be posted positive.
  return app.fn_post_stock_movement(
    p_store_id, p_item_id, p_type,
    case when p_type in ('sale', 'issue', 'writeoff') then -abs(p_qty) when p_type in ('receipt', 'return') then abs(p_qty) else p_qty end,
    p_unit_cost, p_reason_code, p_ref_table, p_ref_id);
end;
$$;
revoke execute on function public.post_stock_movement(uuid, uuid, public.inv_movement_type, numeric, bigint, text, text, uuid) from public, anon;
grant execute on function public.post_stock_movement(uuid, uuid, public.inv_movement_type, numeric, bigint, text, text, uuid) to authenticated;

-- Physical stock take: posts the difference between the counted quantity and
-- the system quantity as an adjustment row. Nothing existing is modified.
create or replace function public.post_stock_variance(p_store_id uuid, p_item_id uuid, p_counted numeric, p_reason_code text)
returns numeric
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_on_hand numeric;
  v_delta   numeric;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'librarian') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_counted is null or p_counted < 0 then
    raise exception 'COUNT_MUST_BE_NONNEGATIVE' using errcode = '23514';
  end if;
  if p_reason_code is null or p_reason_code not in ('SHRINKAGE', 'DAMAGE', 'EXPIRED', 'FOUND', 'COUNT_ERROR', 'OTHER') then
    raise exception 'REASON_CODE_INVALID' using errcode = '22023';
  end if;
  if not exists (select 1 from public.inv_store where id = p_store_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'STORE_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Lock first so the delta is computed against the balance no concurrent sale can change.
  insert into public.inv_stock_lock (store_id, item_id) values (p_store_id, p_item_id) on conflict do nothing;
  perform 1 from public.inv_stock_lock where store_id = p_store_id and item_id = p_item_id for update;
  select coalesce(sum(qty), 0) into v_on_hand from public.inv_stock_movement where store_id = p_store_id and item_id = p_item_id;
  v_delta := p_counted - v_on_hand;
  if v_delta = 0 then
    return 0;
  end if;
  perform app.fn_post_stock_movement(p_store_id, p_item_id, 'adjustment', v_delta, null, p_reason_code, 'stock_take', null);
  return v_delta;
end;
$$;
revoke execute on function public.post_stock_variance(uuid, uuid, numeric, text) from public, anon;
grant execute on function public.post_stock_variance(uuid, uuid, numeric, text) to authenticated;

-- ── weekly reorder alert (cron) ────────────────────────────────────────
-- Raises one open alert per store+item that is at or below its reorder level
-- and resolves alerts whose stock has been replenished. Runs as the table
-- owner from pg_cron; never callable by an end user.

create or replace function public.inv_reorder_alert_run()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_raised int;
begin
  update public.inv_reorder_alert a
     set resolved_at = clock_timestamp()
   where a.resolved_at is null
     and not exists (
       select 1 from public.v_stock_on_hand v
        where v.store_id = a.store_id and v.item_id = a.item_id and v.on_hand <= v.reorder_level);

  with low as (
    select m.tenant_id, m.campus_id, m.store_id, m.item_id, sum(m.qty) as on_hand, i.reorder_level
      from public.inv_stock_movement m
      join public.inv_item i on i.id = m.item_id and i.active and i.reorder_level > 0
     group by m.tenant_id, m.campus_id, m.store_id, m.item_id, i.reorder_level
    having sum(m.qty) <= i.reorder_level
  ), ins as (
    insert into public.inv_reorder_alert (tenant_id, campus_id, store_id, item_id, on_hand, reorder_level)
    select tenant_id, campus_id, store_id, item_id, on_hand, reorder_level from low
    on conflict (store_id, item_id) where resolved_at is null do nothing
    returning 1
  )
  select count(*)::int into v_raised from ins;
  return v_raised;
end;
$$;
revoke execute on function public.inv_reorder_alert_run() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('inv_reorder_alert', '0 3 * * 1', 'select public.inv_reorder_alert_run();');
  end if;
exception
  when others then null;
end;
$$;
