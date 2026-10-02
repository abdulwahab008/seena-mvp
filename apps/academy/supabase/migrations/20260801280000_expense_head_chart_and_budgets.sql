-- ═══════════════════════════════════════════════════════════════════════
-- Migration: 20260801280000_expense_head_chart_and_budgets.sql
-- FR-L10: Expense head chart with budgets
--
-- Extends the flat expense_head table into a hierarchical Chart of
-- Accounts (up to 5 levels deep), adds per-campus head scoping, and
-- introduces a monthly expense_budget table with an automated
-- budget-vs-actual view.
-- ═══════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
-- 1. Extend expense_head with hierarchy columns
-- ───────────────────────────────────────────────────────────────────────
-- All existing rows keep their defaults: parent_id = NULL (root),
-- level = 1, is_leaf = true — so no existing voucher or approval chain
-- is disrupted.

alter table public.expense_head
  add column if not exists parent_id uuid
    references public.expense_head(id) on delete restrict,
  add column if not exists level smallint not null default 1
    check (level >= 1 and level <= 5),
  add column if not exists is_leaf boolean not null default true;

-- Index to speed up children lookups inside a tenant's tree.
create index if not exists idx_expense_head_parent
  on public.expense_head (tenant_id, parent_id)
  where parent_id is not null;

-- ───────────────────────────────────────────────────────────────────────
-- 2. Cycle-prevention & is_leaf auto-maintenance trigger
-- ───────────────────────────────────────────────────────────────────────

-- Returns true when a head has no active children.
create or replace function public.fn_expense_head_is_leaf(p_head_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (
    select 1 from public.expense_head
    where parent_id = p_head_id
  );
$$;

revoke execute on function public.fn_expense_head_is_leaf(uuid) from public, anon;
grant  execute on function public.fn_expense_head_is_leaf(uuid) to authenticated;

-- Trigger function that:
--  1. Prevents a head from becoming its own ancestor (cycle guard).
--  2. Derives level = parent.level + 1 on insert/update.
--  3. Flips parent's is_leaf = false when a child is added,
--     or back to true when the last child is removed.
create or replace function public.fn_tg_maintain_expense_head_tree()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_parent_level smallint;
  v_ancestor_id  uuid;
begin
  -- ── AFTER DELETE: restore parent's is_leaf if it has no more children ──
  if TG_OP = 'DELETE' then
    if OLD.parent_id is not null then
      update public.expense_head
      set    is_leaf = public.fn_expense_head_is_leaf(OLD.parent_id)
      where  id = OLD.parent_id;
    end if;
    return OLD;
  end if;

  -- ── INSERT / UPDATE ────────────────────────────────────────────────────
  if NEW.parent_id is null then
    -- Root head
    NEW.level  := 1;
    NEW.is_leaf := true; -- will be corrected when children are added
  else
    -- Validate parent belongs to the same tenant
    select level into v_parent_level
    from public.expense_head
    where id = NEW.parent_id and tenant_id = NEW.tenant_id;

    if not found then
      raise exception 'EXPENSE_HEAD_PARENT_NOT_FOUND'
        using errcode = 'P0001';
    end if;

    if v_parent_level >= 5 then
      raise exception 'EXPENSE_HEAD_MAX_DEPTH_EXCEEDED'
        using errcode = 'P0001';
    end if;

    -- Cycle detection: walk up from the proposed parent.
    v_ancestor_id := NEW.parent_id;
    loop
      exit when v_ancestor_id is null;
      if v_ancestor_id = NEW.id then
        raise exception 'EXPENSE_HEAD_CYCLE_DETECTED'
          using errcode = 'P0001';
      end if;
      select parent_id into v_ancestor_id
      from public.expense_head
      where id = v_ancestor_id;
    end loop;

    NEW.level  := v_parent_level + 1;
    NEW.is_leaf := true; -- new head starts as a leaf

    -- Mark the parent as a non-leaf
    update public.expense_head
    set    is_leaf = false
    where  id = NEW.parent_id;
  end if;

  return NEW;
end;
$$;

-- BEFORE trigger so we can mutate NEW before it hits the table.
drop trigger if exists trg_maintain_expense_head_tree on public.expense_head;
create trigger trg_maintain_expense_head_tree
  before insert or update of parent_id on public.expense_head
  for each row execute function public.fn_tg_maintain_expense_head_tree();

-- AFTER DELETE trigger for the parent cleanup path.
drop trigger if exists trg_maintain_expense_head_tree_del on public.expense_head;
create trigger trg_maintain_expense_head_tree_del
  after delete on public.expense_head
  for each row execute function public.fn_tg_maintain_expense_head_tree();

-- ───────────────────────────────────────────────────────────────────────
-- 3. Guard: vouchers may only be charged to leaf heads
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_tg_voucher_leaf_head_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_is_leaf boolean;
begin
  select is_leaf into v_is_leaf
  from public.expense_head
  where id = NEW.head_id;

  if v_is_leaf is false then
    raise exception 'EXPENSE_HEAD_NOT_LEAF'
      using errcode = 'P0001',
            detail  = 'Only leaf-level expense heads can have vouchers charged to them. '
                      'Choose a sub-head under this category.';
  end if;
  return NEW;
end;
$$;

-- Apply guard to expense_voucher (created in 20260731940000).
-- Only add if the trigger doesn't already exist.
do $$
begin
  if not exists (
    select 1 from pg_trigger
    where tgname = 'trg_voucher_leaf_head_guard'
      and tgrelid = 'public.expense_voucher'::regclass
  ) then
    execute $t$
      create trigger trg_voucher_leaf_head_guard
        before insert or update of head_id on public.expense_voucher
        for each row execute function public.fn_tg_voucher_leaf_head_guard()
    $t$;
  end if;
end;
$$;

-- ───────────────────────────────────────────────────────────────────────
-- 4. expense_head_campus — per-campus availability scoping
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.expense_head_campus (
  head_id   uuid not null references public.expense_head(id) on delete cascade,
  campus_id uuid not null references public.campus(id) on delete cascade,
  primary key (head_id, campus_id)
);

create index if not exists idx_expense_head_campus_campus
  on public.expense_head_campus (campus_id);

-- When a new head is created without explicit campus scoping it is
-- available on all campuses (head not present in this table).
-- A head listed here is *restricted* to listed campuses only.
-- The UI provides a "Restrict to campuses" multi-select.

alter table public.expense_head_campus enable row level security;

create policy expense_head_campus_tenant_read on public.expense_head_campus
  for select to authenticated
  using (
    exists (
      select 1 from public.expense_head eh
      where eh.id = head_id
        and eh.tenant_id = app.auth_tenant_id()
    )
  );

create policy expense_head_campus_write on public.expense_head_campus
  for all to authenticated
  using (
    app.auth_role() in ('super_admin', 'owner', 'principal', 'accountant')
    and exists (
      select 1 from public.expense_head eh
      where eh.id = head_id
        and eh.tenant_id = app.auth_tenant_id()
    )
  )
  with check (
    app.auth_role() in ('super_admin', 'owner', 'principal', 'accountant')
    and exists (
      select 1 from public.expense_head eh
      where eh.id = head_id
        and eh.tenant_id = app.auth_tenant_id()
    )
  );

-- ───────────────────────────────────────────────────────────────────────
-- 5. expense_budget — monthly budget allocations
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.expense_budget (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  session_id    uuid not null references public.academic_session(id) on delete cascade,
  head_id       uuid not null references public.expense_head(id) on delete cascade,
  -- Normalised to 1st of the month in the campus timezone.
  budget_month  date not null,
  amount_paisa  bigint not null check (amount_paisa >= 0),
  created_by    uuid references public.app_user(user_id),
  updated_by    uuid references public.app_user(user_id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  -- One row per (campus, session, head, month) — upsert safe.
  unique (campus_id, session_id, head_id, budget_month)
);

create index if not exists idx_expense_budget_lookup
  on public.expense_budget (campus_id, session_id, budget_month);

create index if not exists idx_expense_budget_head
  on public.expense_budget (head_id, budget_month);

alter table public.expense_budget enable row level security;

create policy expense_budget_read on public.expense_budget
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and campus_id = any(app.auth_campus_ids())
  );

create policy expense_budget_write on public.expense_budget
  for all to authenticated
  using (
    app.auth_role() in ('super_admin', 'owner', 'principal', 'accountant')
    and tenant_id = app.auth_tenant_id()
    and campus_id = any(app.auth_campus_ids())
  )
  with check (
    app.auth_role() in ('super_admin', 'owner', 'principal', 'accountant')
    and tenant_id = app.auth_tenant_id()
    and campus_id = any(app.auth_campus_ids())
  );

-- Audit trail
create trigger expense_budget_audit
  after insert or update or delete on public.expense_budget
  for each row execute function app.tg_audit_row();

-- ───────────────────────────────────────────────────────────────────────
-- 6. RPC: set_expense_budget — upsert a monthly budget
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.set_expense_budget(
  p_head_id      uuid,
  p_campus_id    uuid,
  p_session_id   uuid,
  p_budget_month date,
  p_amount_paisa bigint
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid;
begin
  -- Role guard
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- Campus membership
  if not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'CAMPUS_ACCESS_DENIED' using errcode = '42501';
  end if;

  -- Validate head belongs to tenant
  if not exists (
    select 1 from public.expense_head
    where id = p_head_id and tenant_id = v_tenant_id
  ) then
    raise exception 'EXPENSE_HEAD_NOT_FOUND' using errcode = 'P0001';
  end if;

  -- Validate amount
  if p_amount_paisa < 0 then
    raise exception 'BUDGET_AMOUNT_NEGATIVE' using errcode = '23514';
  end if;

  -- Normalise budget_month to the 1st of the month
  insert into public.expense_budget (
    tenant_id, campus_id, session_id, head_id,
    budget_month, amount_paisa, created_by, updated_by
  )
  values (
    v_tenant_id, p_campus_id, p_session_id, p_head_id,
    date_trunc('month', p_budget_month)::date,
    p_amount_paisa,
    auth.uid(), auth.uid()
  )
  on conflict (campus_id, session_id, head_id, budget_month)
  do update set
    amount_paisa = excluded.amount_paisa,
    updated_by   = auth.uid(),
    updated_at   = now()
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.set_expense_budget(uuid, uuid, uuid, date, bigint)
  from public, anon;
grant  execute on function public.set_expense_budget(uuid, uuid, uuid, date, bigint)
  to authenticated;

-- ───────────────────────────────────────────────────────────────────────
-- 7. RPC: update_expense_head — edit hierarchy & attributes
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.update_expense_head(
  p_id               uuid,
  p_name_en          text default null,
  p_name_ur          text default null,
  p_requires_approval boolean default null,
  p_is_active        boolean default null,
  p_parent_id        uuid default null,  -- pass explicit NULL via wrapper to unset
  p_set_parent       boolean default false  -- true = update parent_id
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.expense_head
    where id = p_id and tenant_id = v_tenant_id
  ) then
    raise exception 'EXPENSE_HEAD_NOT_FOUND' using errcode = 'P0001';
  end if;

  update public.expense_head
  set
    name_en             = coalesce(p_name_en, name_en),
    name_ur             = coalesce(p_name_ur, name_ur),
    requires_approval   = coalesce(p_requires_approval, requires_approval),
    is_active           = coalesce(p_is_active, is_active),
    parent_id           = case when p_set_parent then p_parent_id else parent_id end
  where id = p_id and tenant_id = v_tenant_id;
end;
$$;

revoke execute on function public.update_expense_head(uuid,text,text,boolean,boolean,uuid,boolean)
  from public, anon;
grant  execute on function public.update_expense_head(uuid,text,text,boolean,boolean,uuid,boolean)
  to authenticated;

-- ───────────────────────────────────────────────────────────────────────
-- 8. View: v_expense_budget_vs_actual
--    Budget vs. paid/approved expense vouchers for a month & campus.
-- ───────────────────────────────────────────────────────────────────────
create or replace view public.v_expense_budget_vs_actual
with (security_invoker = true)
as
select
  eb.id              as budget_id,
  eb.tenant_id,
  eb.campus_id,
  eb.session_id,
  eb.head_id,
  eh.code            as head_code,
  eh.name_en         as head_name_en,
  eh.name_ur         as head_name_ur,
  eh.level,
  eh.is_leaf,
  eh.parent_id,
  eb.budget_month,
  eb.amount_paisa    as budget_paisa,
  coalesce(act.actual_paisa, 0) as actual_paisa,
  eb.amount_paisa - coalesce(act.actual_paisa, 0) as remaining_paisa,
  case
    when coalesce(act.actual_paisa, 0) > eb.amount_paisa then true
    else false
  end                as is_overspent
from public.expense_budget eb
join public.expense_head eh on eh.id = eb.head_id
left join (
  select
    ev.head_id,
    ev.campus_id,
    date_trunc('month', ev.created_at)::date as voucher_month,
    sum(ev.amount_paisa) as actual_paisa
  from public.expense_voucher ev
  where ev.status in ('approved', 'paid')
  group by ev.head_id, ev.campus_id, date_trunc('month', ev.created_at)::date
) act on act.head_id = eb.head_id
      and act.campus_id = eb.campus_id
      and act.voucher_month = eb.budget_month;

-- ───────────────────────────────────────────────────────────────────────
-- 9. RPC: get_expense_chart — full tree with optional budget overlay
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.get_expense_chart(
  p_campus_id  uuid default null,
  p_session_id uuid default null,
  p_month      date default null
)
returns table (
  id                  uuid,
  tenant_id           uuid,
  code                text,
  name_en             text,
  name_ur             text,
  parent_id           uuid,
  level               smallint,
  is_leaf             boolean,
  requires_approval   boolean,
  is_active           boolean,
  budget_paisa        bigint,
  actual_paisa        bigint,
  remaining_paisa     bigint,
  is_overspent        boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    eh.id,
    eh.tenant_id,
    eh.code,
    eh.name_en,
    eh.name_ur,
    eh.parent_id,
    eh.level,
    eh.is_leaf,
    eh.requires_approval,
    eh.is_active,
    bva.budget_paisa,
    bva.actual_paisa,
    bva.remaining_paisa,
    bva.is_overspent
  from public.expense_head eh
  left join public.v_expense_budget_vs_actual bva
    on  bva.head_id    = eh.id
    and bva.campus_id  = coalesce(p_campus_id, bva.campus_id)
    and bva.session_id = coalesce(p_session_id, bva.session_id)
    and bva.budget_month = date_trunc('month', coalesce(p_month, current_date))::date
  where eh.tenant_id = app.auth_tenant_id()
  order by eh.level, eh.code;
$$;

revoke execute on function public.get_expense_chart(uuid, uuid, date) from public, anon;
grant  execute on function public.get_expense_chart(uuid, uuid, date) to authenticated;
