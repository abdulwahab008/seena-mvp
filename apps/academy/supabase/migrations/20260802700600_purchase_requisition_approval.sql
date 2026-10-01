-- FR-R06: purchase requisition with approval thresholds, PO and goods receipt.
--
-- Spending approval is enforced by the system rather than by memory. Tiers live
-- in purchase_threshold ("Principal up to PKR 50,000, Director above"): a
-- requisition needs approval from every tier whose cap is below the amount, up
-- to and including the first tier that covers it. PKR 35,000 needs the Principal
-- only and never appears in the Director's queue; PKR 250,000 needs the Principal
-- THEN the Director, and a Director approving first is refused with OUT_OF_ORDER.
--
-- The resolved chain is SNAPSHOT onto the requisition at submission
-- (approval_chain). Thresholds change every budget year, and a live lookup would
-- re-route a requisition that is already half approved. The only thing that
-- re-resolves a chain is an edit: editing a pending requisition after any
-- approval voids ALL approvals (kept, with voided_at, for the audit trail),
-- restarts the chain at level 1 on the current thresholds and bumps the version.
-- The change is on the audit log via the row audit triggers on the requisition
-- and its lines.
--
-- Short delivery is the normal case in Pakistan, so goods receipts are partial
-- by design: post_goods_receipt posts the RECEIVED quantity (not the ordered
-- one) into the store through the FR-R01 stock ledger, the PO stays
-- partially_fulfilled and the shortfall is visible on v_purchase_order_line
-- until a later receipt makes it up. Receiving more than was ordered is refused.
-- Lines without an inventory item (services, one-off purchases) are receipted
-- but post no stock.

create type public.purchase_req_status as enum ('draft', 'pending', 'approved', 'rejected', 'converted');
create type public.purchase_order_status as enum ('open', 'partially_fulfilled', 'fulfilled', 'cancelled');
create type public.purchase_decision as enum ('approve', 'reject');

create table public.purchase_threshold (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid references public.campus(id) on delete cascade,
  level          int not null check (level between 1 and 6),
  upto_amount    bigint check (upto_amount is null or upto_amount > 0),
  approver_role  text not null check (approver_role in ('principal', 'vice_principal', 'accountant', 'hr_manager', 'owner')),
  effective_from date not null default current_date,
  created_by     uuid references public.app_user(user_id),
  created_at     timestamptz not null default now()
);
create unique index uq_purchase_threshold_level on public.purchase_threshold
  (tenant_id, coalesce(campus_id, '00000000-0000-0000-0000-000000000000'::uuid), effective_from, level);
create index idx_purchase_threshold_campus on public.purchase_threshold (campus_id);

create table public.purchase_counter (
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  kind           text not null check (kind in ('REQ', 'PO', 'GRN')),
  financial_year int not null,
  last_no        bigint not null default 0,
  primary key (tenant_id, campus_id, kind, financial_year)
);
create index idx_purchase_counter_campus on public.purchase_counter (campus_id);

create table public.purchase_requisition (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  req_no         text not null,
  department_id  uuid references public.department(id),
  raised_by      uuid not null references public.app_user(user_id),
  raised_at      timestamptz not null default clock_timestamp(),
  justification  text not null check (char_length(btrim(justification)) between 1 and 2000),
  est_total      bigint not null default 0 check (est_total >= 0),
  approval_chain jsonb not null default '[]'::jsonb check (jsonb_typeof(approval_chain) = 'array'),
  current_level  int not null default 1 check (current_level >= 1),
  version        int not null default 1,
  status         public.purchase_req_status not null default 'draft',
  submitted_at   timestamptz,
  decided_at     timestamptz,
  constraint uq_purchase_req_no unique (tenant_id, req_no)
);
create index idx_purchase_req_scope on public.purchase_requisition (tenant_id, campus_id, status);
create index idx_purchase_req_raised_by on public.purchase_requisition (raised_by);
create index idx_purchase_req_department on public.purchase_requisition (department_id);

create table public.purchase_requisition_line (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  req_id        uuid not null references public.purchase_requisition(id) on delete cascade,
  item_id       uuid references public.inv_item(id),
  description   text not null check (char_length(btrim(description)) between 1 and 300),
  qty           numeric not null check (qty > 0),
  est_unit_cost bigint not null check (est_unit_cost >= 0)
);
create index idx_purchase_req_line_req on public.purchase_requisition_line (req_id);
create index idx_purchase_req_line_item on public.purchase_requisition_line (item_id);

create table public.purchase_approval (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  req_id        uuid not null references public.purchase_requisition(id) on delete cascade,
  level         int not null,
  approver_role text not null,
  approved_by   uuid not null references public.app_user(user_id),
  decided_at    timestamptz not null default clock_timestamp(),
  decision      public.purchase_decision not null,
  remarks       text check (remarks is null or char_length(remarks) <= 500),
  req_version   int not null,
  voided_at     timestamptz,
  void_reason   text
);
create unique index uq_purchase_approval_active on public.purchase_approval (req_id, level) where voided_at is null;
create index idx_purchase_approval_req on public.purchase_approval (req_id);
create index idx_purchase_approval_user on public.purchase_approval (approved_by);

create table public.purchase_order (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  campus_id   uuid not null references public.campus(id) on delete cascade,
  req_id      uuid not null unique references public.purchase_requisition(id),
  vendor_id   uuid not null references public.procurement_vendor(id),
  po_no       text not null,
  ordered_at  timestamptz not null default clock_timestamp(),
  status      public.purchase_order_status not null default 'open',
  created_by  uuid references public.app_user(user_id),
  constraint uq_purchase_po_no unique (tenant_id, po_no)
);
create index idx_purchase_order_scope on public.purchase_order (tenant_id, campus_id, status);
create index idx_purchase_order_vendor on public.purchase_order (vendor_id);

create table public.purchase_order_line (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  po_id       uuid not null references public.purchase_order(id) on delete cascade,
  item_id     uuid references public.inv_item(id),
  description text not null,
  qty_ordered numeric not null check (qty_ordered > 0),
  unit_cost   bigint not null check (unit_cost >= 0)
);
create index idx_purchase_order_line_po on public.purchase_order_line (po_id);
create index idx_purchase_order_line_item on public.purchase_order_line (item_id);

create table public.goods_receipt (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  campus_id   uuid not null references public.campus(id) on delete cascade,
  po_id       uuid not null references public.purchase_order(id),
  store_id    uuid not null references public.inv_store(id),
  grn_no      text not null,
  received_at timestamptz not null default clock_timestamp(),
  received_by uuid references public.app_user(user_id),
  constraint uq_goods_receipt_no unique (tenant_id, grn_no)
);
create index idx_goods_receipt_po on public.goods_receipt (po_id);
create index idx_goods_receipt_store on public.goods_receipt (store_id);

create table public.goods_receipt_line (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  grn_id        uuid not null references public.goods_receipt(id) on delete cascade,
  po_line_id    uuid not null references public.purchase_order_line(id),
  item_id       uuid references public.inv_item(id),
  qty_ordered   numeric not null,
  qty_received  numeric not null check (qty_received > 0),
  unit_cost     bigint not null check (unit_cost >= 0)
);
create index idx_goods_receipt_line_grn on public.goods_receipt_line (grn_id);
create index idx_goods_receipt_line_po_line on public.goods_receipt_line (po_line_id);
create index idx_goods_receipt_line_item on public.goods_receipt_line (item_id);

create trigger purchase_requisition_audit after insert or update or delete on public.purchase_requisition
  for each row execute function app.tg_audit_row();
create trigger purchase_requisition_line_audit after insert or update or delete on public.purchase_requisition_line
  for each row execute function app.tg_audit_row();
create trigger purchase_approval_audit after insert or update or delete on public.purchase_approval
  for each row execute function app.tg_audit_row();
create trigger purchase_threshold_audit after insert or update or delete on public.purchase_threshold
  for each row execute function app.tg_audit_row();
create trigger purchase_order_audit after insert or update or delete on public.purchase_order
  for each row execute function app.tg_audit_row();
create trigger goods_receipt_audit after insert or update or delete on public.goods_receipt
  for each row execute function app.tg_audit_row();

alter table public.purchase_threshold enable row level security;
alter table public.purchase_counter enable row level security;
alter table public.purchase_requisition enable row level security;
alter table public.purchase_requisition_line enable row level security;
alter table public.purchase_approval enable row level security;
alter table public.purchase_order enable row level security;
alter table public.purchase_order_line enable row level security;
alter table public.goods_receipt enable row level security;
alter table public.goods_receipt_line enable row level security;
revoke insert, update, delete, truncate on public.purchase_threshold, public.purchase_requisition, public.purchase_requisition_line,
  public.purchase_approval, public.purchase_order, public.purchase_order_line, public.goods_receipt, public.goods_receipt_line from anon, authenticated;
revoke all on public.purchase_counter from anon, authenticated;

create policy purchase_threshold_read on public.purchase_threshold for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'accountant', 'hr_manager'));

-- A requester sees their own requisitions and their department's; approvers and finance see the campus.
create policy purchase_req_department_scope on public.purchase_requisition for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (raised_by = (select auth.uid())
              or (department_id is not null and department_id in (select s.department_id from public.staff s where s.user_id = (select auth.uid())))
              or app.auth_role() in ('owner', 'super_admin')
              or (app.auth_role() in ('principal', 'vice_principal', 'accountant', 'hr_manager') and campus_id = any (app.auth_campus_ids()))));

create policy purchase_req_line_read on public.purchase_requisition_line for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.purchase_requisition r where r.id = req_id));

create policy purchase_approval_role_scope on public.purchase_approval for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.purchase_requisition r where r.id = req_id));

create policy purchase_order_scope on public.purchase_order for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'accountant', 'librarian')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy purchase_order_line_read on public.purchase_order_line for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.purchase_order o where o.id = po_id));
create policy goods_receipt_scope on public.goods_receipt for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'accountant', 'librarian')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy goods_receipt_line_read on public.goods_receipt_line for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.goods_receipt g where g.id = grn_id));

-- ── numbering ──────────────────────────────────────────────────────────

create or replace function app.fn_next_purchase_no(p_tenant_id uuid, p_campus_id uuid, p_kind text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fy   int := app.fn_financial_year(app.fn_karachi_today());
  v_next bigint;
begin
  insert into public.purchase_counter (tenant_id, campus_id, kind, financial_year) values (p_tenant_id, p_campus_id, p_kind, v_fy)
  on conflict do nothing;
  update public.purchase_counter set last_no = last_no + 1
   where tenant_id = p_tenant_id and campus_id = p_campus_id and kind = p_kind and financial_year = v_fy
  returning last_no into v_next;
  return p_kind || '-' || v_fy::text || '-' || lpad(v_next::text, 5, '0');
end;
$$;
revoke execute on function app.fn_next_purchase_no(uuid, uuid, text) from public, anon, authenticated;

-- ── thresholds and chain resolution ────────────────────────────────────

-- p_tiers: [{"upto_amount": 5000000, "approver_role": "principal"}, {"upto_amount": null, "approver_role": "owner"}]
create or replace function public.save_purchase_thresholds(p_tiers jsonb, p_campus_id uuid default null, p_effective_from date default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_tier   jsonb;
  v_level  int := 0;
  v_prev   bigint := 0;
  v_upto   bigint;
  v_n      int;
begin
  if app.auth_role() not in ('owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_campus_id is not null and not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_tiers is null or jsonb_typeof(p_tiers) <> 'array' or jsonb_array_length(p_tiers) = 0 then
    raise exception 'TIERS_REQUIRED' using errcode = '23514';
  end if;
  v_n := jsonb_array_length(p_tiers);
  delete from public.purchase_threshold
   where tenant_id = v_tenant and campus_id is not distinct from p_campus_id and effective_from = coalesce(p_effective_from, app.fn_karachi_today());
  for v_tier in select * from jsonb_array_elements(p_tiers) loop
    v_level := v_level + 1;
    v_upto := nullif(v_tier ->> 'upto_amount', '')::bigint;
    if v_upto is null and v_level < v_n then
      raise exception 'TIERS_INVALID' using errcode = '23514', hint = 'Only the last tier may have no upper limit.';
    end if;
    if v_upto is not null and v_upto <= v_prev then
      raise exception 'TIERS_INVALID' using errcode = '23514', hint = 'Each tier''s limit must be above the one before.';
    end if;
    insert into public.purchase_threshold (tenant_id, campus_id, level, upto_amount, approver_role, effective_from, created_by)
    values (v_tenant, p_campus_id, v_level, v_upto, v_tier ->> 'approver_role', coalesce(p_effective_from, app.fn_karachi_today()), (select auth.uid()));
    v_prev := coalesce(v_upto, v_prev);
  end loop;
  return v_level;
end;
$$;
revoke execute on function public.save_purchase_thresholds(jsonb, uuid, date) from public, anon;
grant execute on function public.save_purchase_thresholds(jsonb, uuid, date) to authenticated;

create or replace function app.fn_resolve_chain(p_tenant_id uuid, p_amount bigint, p_campus_id uuid, p_on date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_scope uuid;
  v_eff   date;
  v_tier  record;
  v_chain jsonb := '[]'::jsonb;
begin
  if exists (select 1 from public.purchase_threshold where tenant_id = p_tenant_id and campus_id = p_campus_id and effective_from <= p_on) then
    v_scope := p_campus_id;
  end if;
  select max(effective_from) into v_eff from public.purchase_threshold
   where tenant_id = p_tenant_id and campus_id is not distinct from v_scope and effective_from <= p_on;
  if v_eff is null then
    raise exception 'THRESHOLDS_NOT_CONFIGURED' using errcode = '55000', hint = 'The Owner must set the approval thresholds first.';
  end if;
  for v_tier in
    select level, upto_amount, approver_role from public.purchase_threshold
     where tenant_id = p_tenant_id and campus_id is not distinct from v_scope and effective_from = v_eff order by level
  loop
    v_chain := v_chain || jsonb_build_object('level', v_tier.level, 'approver_role', v_tier.approver_role);
    exit when v_tier.upto_amount is null or v_tier.upto_amount >= p_amount;
  end loop;
  -- the chain is renumbered 1..n so "level" is the position in this requisition's chain
  return (select coalesce(jsonb_agg(jsonb_build_object('level', rn, 'approver_role', e ->> 'approver_role') order by rn), '[]'::jsonb)
            from (select e, row_number() over () as rn from jsonb_array_elements(v_chain) e) x);
end;
$$;
revoke execute on function app.fn_resolve_chain(uuid, bigint, uuid, date) from public, anon, authenticated;

create or replace function public.resolve_approval_chain(p_amount bigint, p_campus_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal', 'accountant', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  return app.fn_resolve_chain(app.auth_tenant_id(), p_amount, p_campus_id, app.fn_karachi_today());
end;
$$;
revoke execute on function public.resolve_approval_chain(bigint, uuid) from public, anon;
grant execute on function public.resolve_approval_chain(bigint, uuid) to authenticated;

-- ── edits void approvals ───────────────────────────────────────────────

create or replace function app.fn_requisition_edited(p_req_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r      public.purchase_requisition%rowtype;
  v_total  bigint;
  v_voided int := 0;
begin
  select * into v_r from public.purchase_requisition where id = p_req_id;
  if not found then
    return;
  end if;
  if v_r.status in ('approved', 'rejected', 'converted') then
    raise exception 'REQUISITION_LOCKED' using errcode = '55000', hint = 'A decided requisition cannot be edited. Raise a new one.';
  end if;
  select coalesce(sum(round(qty * est_unit_cost)), 0)::bigint into v_total from public.purchase_requisition_line where req_id = p_req_id;
  if v_r.status = 'draft' then
    update public.purchase_requisition set est_total = v_total where id = p_req_id and est_total is distinct from v_total;
    return;
  end if;
  -- pending: any approval is voided, the chain restarts at level 1 on the current thresholds
  update public.purchase_approval set voided_at = clock_timestamp(), void_reason = 'REQUISITION_EDITED'
   where req_id = p_req_id and voided_at is null;
  get diagnostics v_voided = row_count;
  update public.purchase_requisition
     set est_total = v_total,
         approval_chain = app.fn_resolve_chain(v_r.tenant_id, v_total, v_r.campus_id, app.fn_karachi_today()),
         current_level = 1,
         version = version + case when v_voided > 0 then 1 else 0 end
   where id = p_req_id;
end;
$$;
revoke execute on function app.fn_requisition_edited(uuid) from public, anon, authenticated;

create or replace function app.tg_void_approvals_on_edit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.fn_requisition_edited(coalesce(new.req_id, old.req_id));
  return null;
end;
$$;
revoke execute on function app.tg_void_approvals_on_edit() from public, anon, authenticated;
create trigger trg_void_approvals_on_edit after insert or update or delete on public.purchase_requisition_line
  for each row execute function app.tg_void_approvals_on_edit();

create or replace function app.tg_void_approvals_on_header_edit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.fn_requisition_edited(new.id);
  return null;
end;
$$;
revoke execute on function app.tg_void_approvals_on_header_edit() from public, anon, authenticated;
create trigger trg_void_approvals_on_header_edit after update of justification, department_id on public.purchase_requisition
  for each row execute function app.tg_void_approvals_on_header_edit();

-- ── raising, editing, submitting ───────────────────────────────────────

create or replace function app.fn_requisition_set_lines(p_req_id uuid, p_tenant uuid, p_lines jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_line jsonb;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'LINES_REQUIRED' using errcode = '23514';
  end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    if (v_line ->> 'item_id') is not null and not exists (select 1 from public.inv_item where id = (v_line ->> 'item_id')::uuid and tenant_id = p_tenant) then
      raise exception 'ITEM_NOT_FOUND' using errcode = 'P0002';
    end if;
    if coalesce((v_line ->> 'qty')::numeric, 0) <= 0 or coalesce((v_line ->> 'est_unit_cost')::bigint, -1) < 0 then
      raise exception 'LINE_INVALID' using errcode = '23514';
    end if;
  end loop;
  delete from public.purchase_requisition_line where req_id = p_req_id;
  insert into public.purchase_requisition_line (tenant_id, req_id, item_id, description, qty, est_unit_cost)
  select p_tenant, p_req_id, nullif(l ->> 'item_id', '')::uuid, btrim(l ->> 'description'), (l ->> 'qty')::numeric, (l ->> 'est_unit_cost')::bigint
    from jsonb_array_elements(p_lines) l;
end;
$$;
revoke execute on function app.fn_requisition_set_lines(uuid, uuid, jsonb) from public, anon, authenticated;

-- p_lines: [{"item_id": uuid|null, "description": "Chairs", "qty": 100, "est_unit_cost": 350000}]
create or replace function public.create_requisition(p_campus_id uuid, p_justification text, p_lines jsonb, p_department_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_id     uuid;
begin
  if app.auth_role() in ('parent', 'student') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (p_campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_department_id is not null and not exists (select 1 from public.department where id = p_department_id and tenant_id = v_tenant) then
    raise exception 'DEPARTMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if btrim(coalesce(p_justification, '')) = '' then
    raise exception 'JUSTIFICATION_REQUIRED' using errcode = '23514';
  end if;
  insert into public.purchase_requisition (tenant_id, campus_id, req_no, department_id, raised_by, justification)
  values (v_tenant, p_campus_id, app.fn_next_purchase_no(v_tenant, p_campus_id, 'REQ'), p_department_id, (select auth.uid()), btrim(p_justification))
  returning id into v_id;
  perform app.fn_requisition_set_lines(v_id, v_tenant, p_lines);
  return v_id;
end;
$$;
revoke execute on function public.create_requisition(uuid, text, jsonb, uuid) from public, anon;
grant execute on function public.create_requisition(uuid, text, jsonb, uuid) to authenticated;

create or replace function public.update_requisition(p_req_id uuid, p_justification text, p_lines jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r public.purchase_requisition%rowtype;
begin
  select * into v_r from public.purchase_requisition where id = p_req_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'REQUISITION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_r.raised_by <> (select auth.uid()) and app.auth_role() not in ('owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_r.status in ('approved', 'rejected', 'converted') then
    raise exception 'REQUISITION_LOCKED' using errcode = '55000';
  end if;
  if btrim(coalesce(p_justification, '')) = '' then
    raise exception 'JUSTIFICATION_REQUIRED' using errcode = '23514';
  end if;
  perform app.fn_requisition_set_lines(p_req_id, v_r.tenant_id, p_lines);
  update public.purchase_requisition set justification = btrim(p_justification) where id = p_req_id;
end;
$$;
revoke execute on function public.update_requisition(uuid, text, jsonb) from public, anon;
grant execute on function public.update_requisition(uuid, text, jsonb) to authenticated;

create or replace function public.submit_requisition(p_req_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r     public.purchase_requisition%rowtype;
  v_chain jsonb;
begin
  select * into v_r from public.purchase_requisition where id = p_req_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'REQUISITION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_r.raised_by <> (select auth.uid()) and app.auth_role() not in ('owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_r.status <> 'draft' then
    raise exception 'REQUISITION_NOT_DRAFT' using errcode = '55000';
  end if;
  if v_r.est_total <= 0 then
    raise exception 'AMOUNT_MUST_BE_POSITIVE' using errcode = '23514';
  end if;
  -- the chain is resolved ONCE, here, and snapshot onto the requisition
  v_chain := app.fn_resolve_chain(v_r.tenant_id, v_r.est_total, v_r.campus_id, app.fn_karachi_today());
  update public.purchase_requisition
     set status = 'pending', approval_chain = v_chain, current_level = 1, submitted_at = clock_timestamp()
   where id = p_req_id;
  return v_chain;
end;
$$;
revoke execute on function public.submit_requisition(uuid) from public, anon;
grant execute on function public.submit_requisition(uuid) to authenticated;

-- ── deciding ───────────────────────────────────────────────────────────

create or replace function app.fn_requisition_actor_check(p_r public.purchase_requisition)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role  text := app.auth_role();
  v_need  text;
  v_later boolean;
begin
  if p_r.status <> 'pending' then
    raise exception 'REQUISITION_NOT_PENDING' using errcode = '55000';
  end if;
  if v_role not in ('owner', 'super_admin') and not (p_r.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  v_need := p_r.approval_chain -> (p_r.current_level - 1) ->> 'approver_role';
  -- super_admin acts as the owner tier
  if v_role = v_need or (v_role = 'super_admin' and v_need = 'owner') then
    return;
  end if;
  select exists (
    select 1 from jsonb_array_elements(p_r.approval_chain) e
     where (e ->> 'level')::int > p_r.current_level and (e ->> 'approver_role' = v_role or (v_role = 'super_admin' and e ->> 'approver_role' = 'owner'))
  ) into v_later;
  if v_later then
    raise exception 'OUT_OF_ORDER' using errcode = '55000', detail = format('awaiting=%s', v_need);
  end if;
  raise exception 'FORBIDDEN' using errcode = '42501';
end;
$$;
revoke execute on function app.fn_requisition_actor_check(public.purchase_requisition) from public, anon, authenticated;

create or replace function public.approve_requisition(p_req_id uuid, p_remarks text default null)
returns public.purchase_req_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r      public.purchase_requisition%rowtype;
  v_levels int;
  v_status public.purchase_req_status;
begin
  select * into v_r from public.purchase_requisition where id = p_req_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'REQUISITION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_requisition_actor_check(v_r);
  v_levels := jsonb_array_length(v_r.approval_chain);
  insert into public.purchase_approval (tenant_id, req_id, level, approver_role, approved_by, decision, remarks, req_version)
  values (v_r.tenant_id, p_req_id, v_r.current_level, v_r.approval_chain -> (v_r.current_level - 1) ->> 'approver_role', (select auth.uid()), 'approve', nullif(btrim(p_remarks), ''), v_r.version);
  if v_r.current_level >= v_levels then
    v_status := 'approved';
    update public.purchase_requisition set status = 'approved', decided_at = clock_timestamp() where id = p_req_id;
  else
    v_status := 'pending';
    update public.purchase_requisition set current_level = current_level + 1 where id = p_req_id;
  end if;
  return v_status;
end;
$$;
revoke execute on function public.approve_requisition(uuid, text) from public, anon;
grant execute on function public.approve_requisition(uuid, text) to authenticated;

create or replace function public.reject_requisition(p_req_id uuid, p_remarks text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r public.purchase_requisition%rowtype;
begin
  if btrim(coalesce(p_remarks, '')) = '' then
    raise exception 'REMARKS_REQUIRED' using errcode = '23514';
  end if;
  select * into v_r from public.purchase_requisition where id = p_req_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'REQUISITION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_requisition_actor_check(v_r);
  insert into public.purchase_approval (tenant_id, req_id, level, approver_role, approved_by, decision, remarks, req_version)
  values (v_r.tenant_id, p_req_id, v_r.current_level, v_r.approval_chain -> (v_r.current_level - 1) ->> 'approver_role', (select auth.uid()), 'reject', btrim(p_remarks), v_r.version);
  update public.purchase_requisition set status = 'rejected', decided_at = clock_timestamp() where id = p_req_id;
end;
$$;
revoke execute on function public.reject_requisition(uuid, text) from public, anon;
grant execute on function public.reject_requisition(uuid, text) to authenticated;

-- What is waiting for the signed-in approver, and only that.
create or replace view public.v_requisition_approval_queue
with (security_invoker = true) as
select r.id as req_id, r.tenant_id, r.campus_id, r.req_no, r.est_total, r.justification, r.raised_by, r.submitted_at,
       r.current_level, r.approval_chain -> (r.current_level - 1) ->> 'approver_role' as awaiting_role
  from public.purchase_requisition r
 where r.status = 'pending'
   and ((r.approval_chain -> (r.current_level - 1) ->> 'approver_role') = app.auth_role()
        or (app.auth_role() = 'super_admin' and (r.approval_chain -> (r.current_level - 1) ->> 'approver_role') = 'owner'));
revoke all on public.v_requisition_approval_queue from public, anon;
grant select on public.v_requisition_approval_queue to authenticated;

-- ── purchase order and goods receipt ───────────────────────────────────

create or replace function public.convert_to_purchase_order(p_req_id uuid, p_vendor_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r  public.purchase_requisition%rowtype;
  v_id uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_r from public.purchase_requisition where id = p_req_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'REQUISITION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_r.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_r.status <> 'approved' then
    raise exception 'REQUISITION_NOT_APPROVED' using errcode = '55000';
  end if;
  if not exists (select 1 from public.procurement_vendor where id = p_vendor_id and tenant_id = v_r.tenant_id and active) then
    raise exception 'VENDOR_NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into public.purchase_order (tenant_id, campus_id, req_id, vendor_id, po_no, created_by)
  values (v_r.tenant_id, v_r.campus_id, p_req_id, p_vendor_id, app.fn_next_purchase_no(v_r.tenant_id, v_r.campus_id, 'PO'), (select auth.uid()))
  returning id into v_id;
  insert into public.purchase_order_line (tenant_id, po_id, item_id, description, qty_ordered, unit_cost)
  select v_r.tenant_id, v_id, l.item_id, l.description, l.qty, l.est_unit_cost from public.purchase_requisition_line l where l.req_id = p_req_id;
  -- the lines of a converted requisition are frozen
  update public.purchase_requisition set status = 'converted' where id = p_req_id;
  return v_id;
end;
$$;
revoke execute on function public.convert_to_purchase_order(uuid, uuid) from public, anon;
grant execute on function public.convert_to_purchase_order(uuid, uuid) to authenticated;

create or replace view public.v_purchase_order_line
with (security_invoker = true) as
select l.id as po_line_id, l.po_id, l.tenant_id, l.item_id, l.description, l.qty_ordered, l.unit_cost,
       coalesce(sum(g.qty_received), 0) as qty_received,
       l.qty_ordered - coalesce(sum(g.qty_received), 0) as shortfall
  from public.purchase_order_line l
  left join public.goods_receipt_line g on g.po_line_id = l.id
 group by l.id;
revoke all on public.v_purchase_order_line from public, anon;
grant select on public.v_purchase_order_line to authenticated;

-- p_lines: [{"po_line_id": uuid, "qty_received": 92}]
create or replace function public.post_goods_receipt(p_po_id uuid, p_store_id uuid, p_lines jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_po       public.purchase_order%rowtype;
  v_store    public.inv_store%rowtype;
  v_grn      uuid;
  v_line     jsonb;
  v_pol      public.purchase_order_line%rowtype;
  v_qty      numeric;
  v_prev     numeric;
  v_open     int;
  v_status   public.purchase_order_status;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'librarian') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_po from public.purchase_order where id = p_po_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'PURCHASE_ORDER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_po.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_po.status in ('fulfilled', 'cancelled') then
    raise exception 'PURCHASE_ORDER_CLOSED' using errcode = '55000';
  end if;
  select * into v_store from public.inv_store where id = p_store_id and tenant_id = v_po.tenant_id and campus_id = v_po.campus_id;
  if not found then
    raise exception 'STORE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'LINES_REQUIRED' using errcode = '23514';
  end if;

  insert into public.goods_receipt (tenant_id, campus_id, po_id, store_id, grn_no, received_by)
  values (v_po.tenant_id, v_po.campus_id, p_po_id, p_store_id, app.fn_next_purchase_no(v_po.tenant_id, v_po.campus_id, 'GRN'), (select auth.uid()))
  returning id into v_grn;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    select * into v_pol from public.purchase_order_line where id = (v_line ->> 'po_line_id')::uuid and po_id = p_po_id;
    if not found then
      raise exception 'PO_LINE_NOT_FOUND' using errcode = 'P0002';
    end if;
    v_qty := (v_line ->> 'qty_received')::numeric;
    if v_qty is null or v_qty <= 0 then
      raise exception 'QTY_MUST_BE_POSITIVE' using errcode = '23514';
    end if;
    select coalesce(sum(qty_received), 0) into v_prev from public.goods_receipt_line where po_line_id = v_pol.id;
    if v_prev + v_qty > v_pol.qty_ordered then
      raise exception 'RECEIPT_EXCEEDS_ORDER' using errcode = '23514', detail = format('ordered=%s already_received=%s now=%s', v_pol.qty_ordered, v_prev, v_qty);
    end if;
    insert into public.goods_receipt_line (tenant_id, grn_id, po_line_id, item_id, qty_ordered, qty_received, unit_cost)
    values (v_po.tenant_id, v_grn, v_pol.id, v_pol.item_id, v_pol.qty_ordered, v_qty, v_pol.unit_cost);
    -- the RECEIVED quantity goes into stock, not the ordered one
    if v_pol.item_id is not null then
      perform app.fn_post_stock_movement(p_store_id, v_pol.item_id, 'receipt', v_qty, v_pol.unit_cost, null, 'goods_receipt', v_grn);
    end if;
  end loop;

  select count(*) into v_open from public.purchase_order_line l
   where l.po_id = p_po_id and l.qty_ordered > (select coalesce(sum(g.qty_received), 0) from public.goods_receipt_line g where g.po_line_id = l.id);
  v_status := case when v_open = 0 then 'fulfilled' else 'partially_fulfilled' end;
  update public.purchase_order set status = v_status where id = p_po_id;
  return jsonb_build_object('grn_id', v_grn, 'po_status', v_status, 'open_lines', v_open);
end;
$$;
revoke execute on function public.post_goods_receipt(uuid, uuid, jsonb) from public, anon;
grant execute on function public.post_goods_receipt(uuid, uuid, jsonb) to authenticated;
