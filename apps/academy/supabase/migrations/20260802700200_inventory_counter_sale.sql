-- FR-R02: counter sale of stock to students.
--
-- A sale is recorded against the student with a serial receipt and settles
-- either in cash (it is on the cash-book view) or to the fee ledger under the
-- UNIFORM_BOOKS head (it lands on the student's next challan). Never lost
-- between the two: a charge-to-fee sale creates no cash-book row, and a cash
-- sale creates no ledger row.
--
-- Serials (UNI-2026-00218) are gapless, so they come from a locked counter ROW
-- per (tenant, campus, financial year) incremented inside the same transaction
-- as the sale, not from a Postgres sequence: a sequence skips numbers on
-- rollback, and a missing receipt number reads to an auditor as cash theft. If
-- the sale aborts (insufficient stock, any error) the increment rolls back with
-- it and the next sale is handed the same number. Two terminals raising a
-- receipt in the same second serialise on the counter row.
--
-- The receipt row is never edited. A return inside the tenant's window
-- (default 7 days) is a NEW credit-note document (UCN series, same gapless
-- counter) that references the original, writes a +qty return movement and,
-- for a charge-to-fee sale, a credit on the fee ledger.
--
-- Charge-to-fee sales are attached to the student's next challan by a trigger
-- on fee_challan (fee_challan_line under UNIFORM_BOOKS, challan totals raised
-- by the amount); the ledger debit was already posted at sale time, so the
-- ledger is not double-charged. generate_challans itself is untouched.
--
-- Books already bundled in an admission package: inv_student_entitlement holds
-- what the package covered. A line for an item with remaining entitlement is
-- refused (ALREADY_COVERED_BY_PACKAGE) unless it is explicitly issued FROM the
-- package, which is stock-out at zero price; get_sale_context() hands the sale
-- screen the entitlement so the clerk sees it before ringing anything up.

create type public.inv_sale_settlement as enum ('cash', 'fee_ledger');
create type public.inv_sale_doc_type as enum ('sale', 'credit_note');

create table public.inv_setting (
  tenant_id          uuid primary key references public.tenant(id) on delete cascade,
  return_window_days int not null default 7 check (return_window_days between 0 and 90)
);

create table public.inv_receipt_counter (
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  financial_year int not null check (financial_year between 1900 and 2999),
  last_serial    bigint not null default 0 check (last_serial >= 0),
  primary key (tenant_id, campus_id, financial_year)
);
create index idx_inv_receipt_counter_campus on public.inv_receipt_counter (campus_id);

create table public.inv_sale (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  store_id       uuid not null references public.inv_store(id),
  doc_type       public.inv_sale_doc_type not null default 'sale',
  serial         text not null,
  financial_year int not null,
  student_id     uuid not null references public.student(id),
  enrolment_id   uuid references public.enrolment(id),
  student_gr     text not null,
  student_name   text not null,
  class_name     text,
  sold_at        timestamptz not null default clock_timestamp(),
  sold_by        uuid references public.app_user(user_id),
  settlement     public.inv_sale_settlement not null,
  total          bigint not null check (total >= 0),
  credit_note_of uuid references public.inv_sale(id),
  constraint chk_inv_sale_credit_note check ((doc_type = 'credit_note') = (credit_note_of is not null))
);
create unique index uq_sale_serial on public.inv_sale (tenant_id, campus_id, financial_year, serial);
create index idx_inv_sale_student on public.inv_sale (student_id, sold_at desc);
create index idx_inv_sale_campus_date on public.inv_sale (campus_id, sold_at);
create index idx_inv_sale_credit_of on public.inv_sale (credit_note_of);
create index idx_inv_sale_store on public.inv_sale (store_id);
create index idx_inv_sale_enrolment on public.inv_sale (enrolment_id);

create table public.inv_sale_line (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  sale_id      uuid not null references public.inv_sale(id) on delete cascade,
  item_id      uuid not null references public.inv_item(id),
  qty          numeric not null check (qty > 0),
  unit_price   bigint not null check (unit_price >= 0),
  amount       bigint not null check (amount >= 0),
  from_package boolean not null default false
);
create index idx_inv_sale_line_sale on public.inv_sale_line (sale_id);
create index idx_inv_sale_line_item on public.inv_sale_line (item_id);

create table public.inv_sale_challan_link (
  sale_id           uuid primary key references public.inv_sale(id) on delete cascade,
  challan_id        uuid not null references public.fee_challan(id) on delete cascade,
  challan_line_id   uuid references public.fee_challan_line(id) on delete set null,
  amount_paisa      bigint not null check (amount_paisa > 0),
  attached_at       timestamptz not null default clock_timestamp()
);
create index idx_inv_sale_challan_link_challan on public.inv_sale_challan_link (challan_id);

create table public.inv_student_entitlement (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  student_id uuid not null references public.student(id) on delete cascade,
  item_id    uuid not null references public.inv_item(id),
  qty        numeric not null check (qty > 0),
  source     text not null default 'admission_package',
  granted_by uuid references public.app_user(user_id),
  granted_at timestamptz not null default now(),
  constraint uq_inv_entitlement unique (student_id, item_id, source)
);
create index idx_inv_entitlement_item on public.inv_student_entitlement (item_id);
create index idx_inv_entitlement_tenant on public.inv_student_entitlement (tenant_id);

create trigger inv_student_entitlement_audit after insert or update or delete on public.inv_student_entitlement
  for each row execute function app.tg_audit_row();
create trigger inv_sale_audit after insert on public.inv_sale
  for each row execute function app.tg_audit_row();

create or replace function app.tg_inv_sale_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'SALE_RECEIPT_IMMUTABLE'
    using errcode = '42501', hint = 'A receipt is never edited. Issue a credit note for a return.';
end;
$$;
create trigger trg_inv_sale_immutable before update or delete on public.inv_sale
  for each row execute function app.tg_inv_sale_immutable();
create trigger trg_inv_sale_line_immutable before update or delete on public.inv_sale_line
  for each row execute function app.tg_inv_sale_immutable();

alter table public.inv_setting enable row level security;
alter table public.inv_receipt_counter enable row level security;
alter table public.inv_sale enable row level security;
alter table public.inv_sale_line enable row level security;
alter table public.inv_sale_challan_link enable row level security;
alter table public.inv_student_entitlement enable row level security;
revoke insert, update, delete, truncate on public.inv_setting, public.inv_receipt_counter, public.inv_sale, public.inv_sale_line,
  public.inv_sale_challan_link, public.inv_student_entitlement from anon, authenticated;
revoke all on public.inv_receipt_counter from anon, authenticated;

create policy inv_setting_read on public.inv_setting for select to authenticated using (tenant_id = app.auth_tenant_id());

create policy inv_sale_campus_scope on public.inv_sale for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'accountant', 'admissions_officer', 'principal', 'vice_principal')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy inv_sale_parent_read on public.inv_sale for select to authenticated
  using (tenant_id = app.auth_tenant_id() and student_id = any (app.auth_guardian_student_ids()));

create policy inv_sale_line_read on public.inv_sale_line for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.inv_sale s where s.id = sale_id));

create policy inv_sale_challan_link_read on public.inv_sale_challan_link for select to authenticated
  using (exists (select 1 from public.inv_sale s where s.id = sale_id));

create policy inv_entitlement_read on public.inv_student_entitlement for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('owner', 'super_admin', 'accountant', 'admissions_officer', 'principal', 'vice_principal')
              or student_id = any (app.auth_guardian_student_ids())));

-- Cash sales and cash refunds as the cash book sees them. Charge-to-fee sales
-- are deliberately absent: that money is on the next challan, not in the till.
create or replace view public.v_inv_cash_book_entry
with (security_invoker = true) as
select s.tenant_id, s.campus_id, (s.sold_at at time zone 'Asia/Karachi')::date as book_date, s.id as sale_id, s.serial,
       s.doc_type,
       case when s.doc_type = 'sale' then s.total else -s.total end as amount_paisa
  from public.inv_sale s
 where s.settlement = 'cash';
revoke all on public.v_inv_cash_book_entry from public, anon;
grant select on public.v_inv_cash_book_entry to authenticated;

-- ── helpers ────────────────────────────────────────────────────────────

-- Pakistan's financial year runs July to June and is labelled by the year it starts in.
create or replace function app.fn_financial_year(p_date date)
returns int
language sql
immutable
set search_path = ''
as $$
  select (case when extract(month from p_date) >= 7 then extract(year from p_date) else extract(year from p_date) - 1 end)::int;
$$;
revoke execute on function app.fn_financial_year(date) from public, anon, authenticated;

-- Gapless: locks the counter row for (tenant, campus, financial year) and bumps it in the caller's transaction.
create or replace function app.fn_next_inv_serial(p_tenant_id uuid, p_campus_id uuid, p_fy int, p_prefix text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_next bigint;
begin
  insert into public.inv_receipt_counter (tenant_id, campus_id, financial_year) values (p_tenant_id, p_campus_id, p_fy)
  on conflict do nothing;
  update public.inv_receipt_counter set last_serial = last_serial + 1
   where tenant_id = p_tenant_id and campus_id = p_campus_id and financial_year = p_fy
  returning last_serial into v_next;
  return p_prefix || '-' || p_fy::text || '-' || lpad(v_next::text, 5, '0');
end;
$$;
revoke execute on function app.fn_next_inv_serial(uuid, uuid, int, text) from public, anon, authenticated;

create or replace function app.fn_uniform_books_head(p_tenant_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.fee_head where tenant_id = p_tenant_id and lower(code) = 'uniform_books';
  if v_id is null then
    insert into public.fee_head (tenant_id, code, name_en, name_ur, default_frequency)
    values (p_tenant_id, 'UNIFORM_BOOKS', 'Uniform and Books', 'یونیفارم اور کتابیں', 'one_time')
    on conflict do nothing;
    select id into v_id from public.fee_head where tenant_id = p_tenant_id and lower(code) = 'uniform_books';
  end if;
  return v_id;
end;
$$;
revoke execute on function app.fn_uniform_books_head(uuid) from public, anon, authenticated;

create or replace function app.fn_package_remaining(p_student_id uuid, p_item_id uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select sum(e.qty) from public.inv_student_entitlement e where e.student_id = p_student_id and e.item_id = p_item_id), 0)
       - coalesce((select sum(case when s.doc_type = 'sale' then l.qty else -l.qty end)
                     from public.inv_sale_line l join public.inv_sale s on s.id = l.sale_id
                    where s.student_id = p_student_id and l.item_id = p_item_id and l.from_package), 0);
$$;
revoke execute on function app.fn_package_remaining(uuid, uuid) from public, anon, authenticated;

create or replace function public.set_inv_return_window(p_days int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_days is null or p_days not between 0 and 90 then
    raise exception 'RETURN_WINDOW_INVALID' using errcode = '22023';
  end if;
  insert into public.inv_setting (tenant_id, return_window_days) values (app.auth_tenant_id(), p_days)
  on conflict (tenant_id) do update set return_window_days = excluded.return_window_days;
end;
$$;
revoke execute on function public.set_inv_return_window(int) from public, anon;
grant execute on function public.set_inv_return_window(int) to authenticated;

create or replace function public.grant_student_entitlement(p_student_id uuid, p_item_id uuid, p_qty numeric, p_source text default 'admission_package')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_campus uuid;
  v_id     uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select campus_id into v_campus from public.student where id = p_student_id and tenant_id = v_tenant;
  if v_campus is null then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_campus = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.inv_item where id = p_item_id and tenant_id = v_tenant) then
    raise exception 'ITEM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'QTY_MUST_BE_POSITIVE' using errcode = '23514';
  end if;
  insert into public.inv_student_entitlement (tenant_id, student_id, item_id, qty, source, granted_by)
  values (v_tenant, p_student_id, p_item_id, p_qty, coalesce(nullif(btrim(p_source), ''), 'admission_package'), (select auth.uid()))
  on conflict (student_id, item_id, source) do update set qty = excluded.qty
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.grant_student_entitlement(uuid, uuid, numeric, text) from public, anon;
grant execute on function public.grant_student_entitlement(uuid, uuid, numeric, text) to authenticated;

-- What the admission package already covered, for the sale screen.
create or replace function public.get_sale_context(p_student_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_campus uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select campus_id into v_campus from public.student where id = p_student_id and tenant_id = v_tenant;
  if v_campus is null then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_campus = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'student_id', p_student_id,
    'package', coalesce((
      select jsonb_agg(jsonb_build_object(
               'item_id', e.item_id, 'item_code', i.item_code, 'name', i.name, 'source', e.source,
               'entitled', e.qty, 'remaining', app.fn_package_remaining(p_student_id, e.item_id)) order by i.item_code)
        from public.inv_student_entitlement e join public.inv_item i on i.id = e.item_id
       where e.student_id = p_student_id), '[]'::jsonb));
end;
$$;
revoke execute on function public.get_sale_context(uuid) from public, anon;
grant execute on function public.get_sale_context(uuid) to authenticated;

-- ── the sale ───────────────────────────────────────────────────────────
-- p_lines: [{"item_id": uuid, "qty": 2, "unit_price": optional paisa, "from_package": optional bool}]

create or replace function public.create_sale(p_student_id uuid, p_lines jsonb, p_settlement text, p_store_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant   uuid := app.auth_tenant_id();
  v_stu      record;
  v_store    public.inv_store%rowtype;
  v_enrol    record;
  v_settle   public.inv_sale_settlement;
  v_fy       int;
  v_serial   text;
  v_sale_id  uuid;
  v_total    bigint := 0;
  v_line     jsonb;
  v_item     public.inv_item%rowtype;
  v_qty      numeric;
  v_price    bigint;
  v_pkg      boolean;
  v_remaining numeric;
  v_amount   bigint;
  v_resolved jsonb := '[]'::jsonb;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_settlement not in ('cash', 'fee_ledger') then
    raise exception 'SETTLEMENT_INVALID' using errcode = '22023';
  end if;
  v_settle := p_settlement::public.inv_sale_settlement;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'LINES_REQUIRED' using errcode = '23514';
  end if;

  select s.id, s.campus_id, s.gr_number, s.name_en, s.deleted_at into v_stu
    from public.student s where s.id = p_student_id and s.tenant_id = v_tenant;
  if not found or v_stu.deleted_at is not null then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_stu.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_store_id is null then
    select * into v_store from public.inv_store where tenant_id = v_tenant and campus_id = v_stu.campus_id order by created_at limit 1;
  else
    select * into v_store from public.inv_store where id = p_store_id and tenant_id = v_tenant;
  end if;
  if not found then
    raise exception 'STORE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_store.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select e.id, cl.name_en || ' ' || sec.name as class_name into v_enrol
    from public.enrolment e
    join public.class_level cl on cl.id = e.class_level_id
    join public.class_section sec on sec.id = e.section_id
   where e.student_id = p_student_id and e.status = 'active'
   order by e.joined_on desc limit 1;
  if v_settle = 'fee_ledger' and v_enrol.id is null then
    raise exception 'NO_ACTIVE_ENROLMENT' using errcode = '55000';
  end if;

  -- Pass 1: resolve every line (item, price, package rules) and total the receipt.
  for v_line in select * from jsonb_array_elements(p_lines) loop
    select * into v_item from public.inv_item
     where id = (v_line ->> 'item_id')::uuid and tenant_id = v_tenant and active;
    if not found then
      raise exception 'ITEM_NOT_FOUND' using errcode = 'P0002';
    end if;
    v_qty := (v_line ->> 'qty')::numeric;
    if v_qty is null or v_qty <= 0 then
      raise exception 'QTY_MUST_BE_POSITIVE' using errcode = '23514';
    end if;
    v_pkg := coalesce((v_line ->> 'from_package')::boolean, false);
    v_remaining := app.fn_package_remaining(p_student_id, v_item.id)
                   - coalesce((select sum((r ->> 'qty')::numeric) from jsonb_array_elements(v_resolved) r
                                where (r ->> 'item_id')::uuid = v_item.id and (r ->> 'from_package')::boolean), 0);

    if v_pkg then
      if v_remaining < v_qty then
        raise exception 'PACKAGE_ENTITLEMENT_EXCEEDED' using errcode = '23514', detail = format('item=%s remaining=%s requested=%s', v_item.item_code, v_remaining, v_qty);
      end if;
      v_price := 0;
    else
      if v_remaining > 0 then
        raise exception 'ALREADY_COVERED_BY_PACKAGE' using errcode = '23514',
          detail = format('item=%s remaining=%s', v_item.item_code, v_remaining),
          hint = 'The admission package already covers this item; issue it from the package instead of selling it again.';
      end if;
      v_price := coalesce((v_line ->> 'unit_price')::bigint, v_item.sale_price);
      if v_price < 0 then
        raise exception 'PRICE_MUST_BE_NONNEGATIVE' using errcode = '23514';
      end if;
    end if;
    v_amount := round(v_price * v_qty)::bigint;
    v_resolved := v_resolved || jsonb_build_object('item_id', v_item.id, 'qty', v_qty, 'unit_price', v_price, 'amount', v_amount, 'from_package', v_pkg);
    v_total := v_total + v_amount;
  end loop;

  -- Pass 2: the receipt (gapless serial), its lines and the stock movements, all in this transaction.
  v_fy := app.fn_financial_year(app.fn_karachi_today());
  v_serial := app.fn_next_inv_serial(v_tenant, v_store.campus_id, v_fy, 'UNI');

  insert into public.inv_sale (tenant_id, campus_id, store_id, doc_type, serial, financial_year, student_id, enrolment_id, student_gr, student_name,
                               class_name, sold_by, settlement, total)
  values (v_tenant, v_store.campus_id, v_store.id, 'sale', v_serial, v_fy, p_student_id, v_enrol.id, v_stu.gr_number, v_stu.name_en,
          v_enrol.class_name, (select auth.uid()), v_settle, v_total)
  returning id into v_sale_id;

  for v_line in select * from jsonb_array_elements(v_resolved) loop
    insert into public.inv_sale_line (tenant_id, sale_id, item_id, qty, unit_price, amount, from_package)
    values (v_tenant, v_sale_id, (v_line ->> 'item_id')::uuid, (v_line ->> 'qty')::numeric, (v_line ->> 'unit_price')::bigint,
            (v_line ->> 'amount')::bigint, (v_line ->> 'from_package')::boolean);
    perform app.fn_post_stock_movement(v_store.id, (v_line ->> 'item_id')::uuid,
                                       case when (v_line ->> 'from_package')::boolean then 'issue' else 'sale' end::public.inv_movement_type,
                                       -(v_line ->> 'qty')::numeric, null, null, 'inv_sale', v_sale_id);
  end loop;

  if v_settle = 'fee_ledger' and v_total > 0 then
    insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction,
                                   value_date, source_type, source_id, created_by)
    select v_tenant, e.campus_id, e.id, e.session_id, 'charge', app.fn_uniform_books_head(v_tenant), v_total, 'debit',
           app.fn_karachi_today(), 'inv_sale', v_sale_id, (select auth.uid())
      from public.enrolment e where e.id = v_enrol.id;
  end if;

  return public.get_sale_receipt(v_sale_id);
end;
$$;
revoke execute on function public.create_sale(uuid, jsonb, text, uuid) from public, anon;
grant execute on function public.create_sale(uuid, jsonb, text, uuid) to authenticated;

-- ── the receipt, as printed ────────────────────────────────────────────

create or replace function public.get_sale_receipt(p_sale_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_s public.inv_sale%rowtype;
begin
  select * into v_s from public.inv_sale where id = p_sale_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SALE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not (
       (app.auth_role() in ('owner', 'super_admin', 'accountant', 'admissions_officer', 'principal', 'vice_principal')
        and (app.auth_role() in ('owner', 'super_admin') or v_s.campus_id = any (app.auth_campus_ids())))
       or v_s.student_id = any (app.auth_guardian_student_ids())) then
    raise exception 'SALE_NOT_FOUND' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'sale_id', v_s.id, 'serial', v_s.serial, 'doc_type', v_s.doc_type, 'sold_at', v_s.sold_at, 'settlement', v_s.settlement,
    'total_paisa', v_s.total, 'credit_note_of', v_s.credit_note_of,
    'student', jsonb_build_object('gr_number', v_s.student_gr, 'name', v_s.student_name, 'class', v_s.class_name),
    'lines', coalesce((select jsonb_agg(jsonb_build_object(
                'item_id', l.item_id, 'item_code', i.item_code, 'name', i.name, 'size', i.size, 'qty', l.qty,
                'unit_price_paisa', l.unit_price, 'amount_paisa', l.amount, 'from_package', l.from_package) order by i.item_code)
              from public.inv_sale_line l join public.inv_item i on i.id = l.item_id where l.sale_id = v_s.id), '[]'::jsonb));
end;
$$;
revoke execute on function public.get_sale_receipt(uuid) from public, anon;
grant execute on function public.get_sale_receipt(uuid) to authenticated;

-- ── returns: a credit note, never an edit ──────────────────────────────
-- p_lines: [{"item_id": uuid, "qty": 1}]

create or replace function public.return_sale_items(p_sale_id uuid, p_lines jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant   uuid := app.auth_tenant_id();
  v_s        public.inv_sale%rowtype;
  v_window   int;
  v_line     jsonb;
  v_item_id  uuid;
  v_qty      numeric;
  v_sold     record;
  v_returned numeric;
  v_amount   bigint;
  v_total    bigint := 0;
  v_resolved jsonb := '[]'::jsonb;
  v_serial   text;
  v_cn_id    uuid;
  v_fy       int;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_s from public.inv_sale where id = p_sale_id and tenant_id = v_tenant and doc_type = 'sale';
  if not found then
    raise exception 'SALE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_s.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'LINES_REQUIRED' using errcode = '23514';
  end if;

  -- Serialise returns of the same sale so two clerks cannot return the same shirt twice.
  perform 1 from public.inv_sale where id = p_sale_id for update;

  select coalesce((select return_window_days from public.inv_setting where tenant_id = v_tenant), 7) into v_window;
  if app.fn_karachi_today() - (v_s.sold_at at time zone 'Asia/Karachi')::date > v_window then
    raise exception 'RETURN_WINDOW_EXPIRED' using errcode = '55000', detail = format('window_days=%s sold_on=%s', v_window, (v_s.sold_at at time zone 'Asia/Karachi')::date);
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_item_id := (v_line ->> 'item_id')::uuid;
    v_qty := (v_line ->> 'qty')::numeric;
    if v_qty is null or v_qty <= 0 then
      raise exception 'QTY_MUST_BE_POSITIVE' using errcode = '23514';
    end if;
    select coalesce(sum(l.qty), 0) as qty, max(l.unit_price) as unit_price, bool_or(l.from_package) as from_package into v_sold
      from public.inv_sale_line l where l.sale_id = p_sale_id and l.item_id = v_item_id;
    if v_sold.qty = 0 then
      raise exception 'ITEM_NOT_ON_SALE' using errcode = '23514';
    end if;
    select coalesce(sum(l.qty), 0) into v_returned
      from public.inv_sale_line l join public.inv_sale c on c.id = l.sale_id
     where c.credit_note_of = p_sale_id and l.item_id = v_item_id;
    v_returned := v_returned + coalesce((select sum((r ->> 'qty')::numeric) from jsonb_array_elements(v_resolved) r where (r ->> 'item_id')::uuid = v_item_id), 0);
    if v_returned + v_qty > v_sold.qty then
      raise exception 'RETURN_EXCEEDS_SOLD' using errcode = '23514', detail = format('sold=%s already_returned=%s requested=%s', v_sold.qty, v_returned, v_qty);
    end if;
    v_amount := round(v_sold.unit_price * v_qty)::bigint;
    v_resolved := v_resolved || jsonb_build_object('item_id', v_item_id, 'qty', v_qty, 'unit_price', v_sold.unit_price, 'amount', v_amount, 'from_package', v_sold.from_package);
    v_total := v_total + v_amount;
  end loop;

  v_fy := app.fn_financial_year(app.fn_karachi_today());
  v_serial := app.fn_next_inv_serial(v_tenant, v_s.campus_id, v_fy, 'UCN');
  insert into public.inv_sale (tenant_id, campus_id, store_id, doc_type, serial, financial_year, student_id, enrolment_id, student_gr, student_name,
                               class_name, sold_by, settlement, total, credit_note_of)
  values (v_tenant, v_s.campus_id, v_s.store_id, 'credit_note', v_serial, v_fy, v_s.student_id, v_s.enrolment_id, v_s.student_gr, v_s.student_name,
          v_s.class_name, (select auth.uid()), v_s.settlement, v_total, p_sale_id)
  returning id into v_cn_id;

  for v_line in select * from jsonb_array_elements(v_resolved) loop
    insert into public.inv_sale_line (tenant_id, sale_id, item_id, qty, unit_price, amount, from_package)
    values (v_tenant, v_cn_id, (v_line ->> 'item_id')::uuid, (v_line ->> 'qty')::numeric, (v_line ->> 'unit_price')::bigint,
            (v_line ->> 'amount')::bigint, (v_line ->> 'from_package')::boolean);
    perform app.fn_post_stock_movement(v_s.store_id, (v_line ->> 'item_id')::uuid, 'return', (v_line ->> 'qty')::numeric, null, null, 'inv_sale', v_cn_id);
  end loop;

  if v_s.settlement = 'fee_ledger' and v_total > 0 then
    insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction,
                                   value_date, source_type, source_id, reason, created_by)
    select v_tenant, e.campus_id, e.id, e.session_id, 'adjustment', app.fn_uniform_books_head(v_tenant), v_total, 'credit',
           app.fn_karachi_today(), 'inv_sale', v_cn_id, 'Return against ' || v_s.serial, (select auth.uid())
      from public.enrolment e where e.id = v_s.enrolment_id;
  end if;

  return public.get_sale_receipt(v_cn_id);
end;
$$;
revoke execute on function public.return_sale_items(uuid, jsonb) from public, anon;
grant execute on function public.return_sale_items(uuid, jsonb) to authenticated;

-- ── a charge-to-fee sale rides on the student's next challan ───────────
-- Runs when a challan row is created. The sale's ledger debit already exists,
-- so only the challan line and the challan totals change. What is owed is the
-- sale total less any credit notes already raised against it.

create or replace function app.tg_attach_sales_to_challan()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sale   record;
  v_line   uuid;
  v_head   uuid;
  v_sum    bigint := 0;
begin
  for v_sale in
    select s.id, s.total - coalesce((select sum(c.total) from public.inv_sale c where c.credit_note_of = s.id), 0) as due
      from public.inv_sale s
     where s.enrolment_id = new.enrolment_id and s.tenant_id = new.tenant_id
       and s.doc_type = 'sale' and s.settlement = 'fee_ledger'
       and not exists (select 1 from public.inv_sale_challan_link k where k.sale_id = s.id)
     order by s.sold_at
  loop
    if v_sale.due <= 0 then
      continue;
    end if;
    v_head := app.fn_uniform_books_head(new.tenant_id);
    insert into public.fee_challan_line (challan_id, fee_head_id, amount_paisa, concession_paisa, net_paisa, line_type)
    values (new.id, v_head, v_sale.due, 0, v_sale.due, 'charge')
    returning id into v_line;
    insert into public.inv_sale_challan_link (sale_id, challan_id, challan_line_id, amount_paisa) values (v_sale.id, new.id, v_line, v_sale.due);
    v_sum := v_sum + v_sale.due;
  end loop;
  if v_sum > 0 then
    update public.fee_challan set gross_paisa = gross_paisa + v_sum, net_paisa = net_paisa + v_sum where id = new.id;
  end if;
  return null;
end;
$$;
revoke execute on function app.tg_attach_sales_to_challan() from public, anon, authenticated;
create trigger trg_attach_sales_to_challan after insert on public.fee_challan
  for each row execute function app.tg_attach_sales_to_challan();
