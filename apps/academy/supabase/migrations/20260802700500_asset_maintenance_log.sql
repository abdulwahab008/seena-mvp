-- FR-R05: asset maintenance and repair log.
--
-- One maintenance table serves the bus and the generator. A repair logged with
-- downtime makes the asset unavailable for those dates: assert_asset_available
-- (called by issue_asset_custody, and by assert_vehicle_available for fleet
-- assignment) refuses an asset whose downtime covers the date, with
-- VEHICLE_IN_REPAIR for a vehicle-linked asset and ASSET_IN_REPAIR otherwise.
-- A trigger keeps asset.status in step (in_repair while a repair is open and
-- today falls in its downtime, active again after).
--
-- Transport's assignment code only has to call assert_vehicle_available(vehicle,
-- date); because asset.vehicle_id is the single link to the fleet record, a bus
-- cannot be available in one module and in the workshop in the other.
--
-- A repair flagged as a capital improvement, above the tenant's capitalisation
-- threshold (asset_setting, default PKR 50,000), is added to the asset's
-- capitalised cost. Depreciation derives each instalment from the current cost
-- and what is already posted (FR-R03), so the remaining periods are re-based on
-- the new cost from the next period without rewriting any posted entry. A
-- repair below the threshold cannot be flagged capital: it is an expense.
--
-- asset_service_due_reminder_run (pg_cron, daily 02:00 UTC) queues an in-app
-- reminder for the campus Principal(s) and the repair's responsible user when a
-- next-service date is 14 days or less away. Stubbed: delivery over SMS or
-- WhatsApp; the reminder rows are the queue a gateway adapter would read.

create table public.procurement_vendor (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  name       text not null check (char_length(btrim(name)) between 1 and 200),
  phone      text,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index uq_procurement_vendor_name on public.procurement_vendor (tenant_id, lower(name));
create index idx_procurement_vendor_tenant on public.procurement_vendor (tenant_id);
create trigger procurement_vendor_audit after insert or update or delete on public.procurement_vendor
  for each row execute function app.tg_audit_row();
alter table public.procurement_vendor enable row level security;
revoke insert, update, delete, truncate on public.procurement_vendor from anon, authenticated;
create policy procurement_vendor_read on public.procurement_vendor for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal', 'vice_principal', 'transport_manager', 'librarian'));

create or replace function public.create_procurement_vendor(p_name text, p_phone text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal', 'transport_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if btrim(coalesce(p_name, '')) = '' then
    raise exception 'VENDOR_NAME_REQUIRED' using errcode = '23514';
  end if;
  insert into public.procurement_vendor (tenant_id, name, phone) values (app.auth_tenant_id(), btrim(p_name), nullif(btrim(p_phone), '')) returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'VENDOR_EXISTS' using errcode = '23505';
end;
$$;
revoke execute on function public.create_procurement_vendor(text, text) from public, anon;
grant execute on function public.create_procurement_vendor(text, text) to authenticated;

create table public.asset_setting (
  tenant_id               uuid primary key references public.tenant(id) on delete cascade,
  capitalisation_threshold bigint not null default 5000000 check (capitalisation_threshold >= 0)
);
alter table public.asset_setting enable row level security;
revoke insert, update, delete, truncate on public.asset_setting from anon, authenticated;
create policy asset_setting_read on public.asset_setting for select to authenticated using (tenant_id = app.auth_tenant_id());

create or replace function public.set_capitalisation_threshold(p_threshold_paisa bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_threshold_paisa is null or p_threshold_paisa < 0 then
    raise exception 'THRESHOLD_INVALID' using errcode = '23514';
  end if;
  insert into public.asset_setting (tenant_id, capitalisation_threshold) values (app.auth_tenant_id(), p_threshold_paisa)
  on conflict (tenant_id) do update set capitalisation_threshold = excluded.capitalisation_threshold;
end;
$$;
revoke execute on function public.set_capitalisation_threshold(bigint) from public, anon;
grant execute on function public.set_capitalisation_threshold(bigint) to authenticated;

create table public.asset_maintenance (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  campus_id           uuid not null references public.campus(id) on delete cascade,
  asset_id            uuid not null references public.asset(id) on delete cascade,
  reported_on         date not null,
  fault               text not null check (char_length(btrim(fault)) between 1 and 1000),
  vendor_id           uuid references public.procurement_vendor(id),
  cost                bigint not null default 0 check (cost >= 0),
  is_capitalised      boolean not null default false,
  downtime_from       date,
  downtime_to         date,
  next_service_due    date,
  responsible_user_id uuid references public.app_user(user_id),
  closed_by           uuid references public.app_user(user_id),
  closed_at           timestamptz,
  created_by          uuid references public.app_user(user_id),
  created_at          timestamptz not null default now(),
  constraint chk_maint_downtime check (downtime_to is null or (downtime_from is not null and downtime_to >= downtime_from)),
  constraint chk_maint_capital check (not is_capitalised or cost > 0),
  constraint chk_maint_closed check ((closed_at is null) = (closed_by is null))
);
create index idx_asset_maintenance_asset on public.asset_maintenance (asset_id, reported_on);
create index idx_asset_maintenance_scope on public.asset_maintenance (tenant_id, campus_id);
create index idx_asset_maintenance_due on public.asset_maintenance (next_service_due) where next_service_due is not null;
create index idx_asset_maintenance_vendor on public.asset_maintenance (vendor_id);
create index idx_asset_maintenance_responsible on public.asset_maintenance (responsible_user_id);
create trigger asset_maintenance_audit after insert or update or delete on public.asset_maintenance
  for each row execute function app.tg_audit_row();

alter table public.asset_maintenance enable row level security;
revoke insert, update, delete, truncate on public.asset_maintenance from anon, authenticated;
create policy asset_maintenance_campus_scope on public.asset_maintenance for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal', 'vice_principal', 'transport_manager')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

create table public.asset_service_reminder (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant(id) on delete cascade,
  campus_id          uuid not null references public.campus(id) on delete cascade,
  asset_id           uuid not null references public.asset(id) on delete cascade,
  maintenance_id     uuid not null references public.asset_maintenance(id) on delete cascade,
  recipient_user_id  uuid not null references public.app_user(user_id) on delete cascade,
  recipient_role     text not null,
  due_on             date not null,
  lead_days          int not null,
  created_at         timestamptz not null default clock_timestamp(),
  read_at            timestamptz,
  constraint uq_service_reminder unique (maintenance_id, recipient_user_id)
);
create index idx_service_reminder_recipient on public.asset_service_reminder (recipient_user_id, created_at desc);
create index idx_service_reminder_asset on public.asset_service_reminder (asset_id);
create index idx_service_reminder_tenant on public.asset_service_reminder (tenant_id, campus_id);
alter table public.asset_service_reminder enable row level security;
revoke insert, update, delete, truncate on public.asset_service_reminder from anon, authenticated;
create policy asset_service_reminder_scope on public.asset_service_reminder for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (recipient_user_id = (select auth.uid()) or app.auth_role() in ('owner', 'super_admin')));

-- ── availability ───────────────────────────────────────────────────────

create or replace function app.fn_asset_in_repair_on(p_asset_id uuid, p_on date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.asset_maintenance m
     where m.asset_id = p_asset_id and m.downtime_from is not null and m.downtime_from <= p_on
       and p_on <= coalesce(
             -- a repair closed early frees the asset from the day it was closed
             case when m.closed_at is not null then least(coalesce(m.downtime_to, (m.closed_at at time zone 'Asia/Karachi')::date - 1), (m.closed_at at time zone 'Asia/Karachi')::date - 1)
                  else m.downtime_to end,
             'infinity'::date));
$$;
revoke execute on function app.fn_asset_in_repair_on(uuid, date) from public, anon, authenticated;

create or replace function public.assert_asset_available(p_asset_id uuid, p_on date default current_date)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_a public.asset%rowtype;
begin
  select * into v_a from public.asset where id = p_asset_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ASSET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_a.status in ('disposed', 'written_off') then
    raise exception 'ASSET_NOT_AVAILABLE' using errcode = '55000', detail = format('status=%s', v_a.status);
  end if;
  if app.fn_asset_in_repair_on(p_asset_id, coalesce(p_on, current_date)) then
    if v_a.vehicle_id is not null then
      raise exception 'VEHICLE_IN_REPAIR' using errcode = '55000', detail = format('asset=%s on=%s', v_a.tag_no, p_on);
    end if;
    raise exception 'ASSET_IN_REPAIR' using errcode = '55000', detail = format('asset=%s on=%s', v_a.tag_no, p_on);
  end if;
end;
$$;
revoke execute on function public.assert_asset_available(uuid, date) from public, anon;
grant execute on function public.assert_asset_available(uuid, date) to authenticated;

-- For Transport: refuse to assign a fleet vehicle to a trip on a date it is in the workshop.
create or replace function public.assert_vehicle_available(p_vehicle_id uuid, p_on date)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_asset uuid;
begin
  select id into v_asset from public.asset where vehicle_id = p_vehicle_id and tenant_id = app.auth_tenant_id();
  if v_asset is null then
    return;
  end if;
  perform public.assert_asset_available(v_asset, p_on);
end;
$$;
revoke execute on function public.assert_vehicle_available(uuid, date) from public, anon;
grant execute on function public.assert_vehicle_available(uuid, date) to authenticated;

-- ── status sync ────────────────────────────────────────────────────────

create or replace function app.fn_refresh_asset_status(p_asset_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.asset_status;
  v_repair boolean;
begin
  select status into v_status from public.asset where id = p_asset_id;
  if v_status is null or v_status in ('disposed', 'written_off') then
    return;
  end if;
  v_repair := app.fn_asset_in_repair_on(p_asset_id, app.fn_karachi_today());
  if v_repair and v_status = 'active' then
    update public.asset set status = 'in_repair' where id = p_asset_id;
  elsif not v_repair and v_status = 'in_repair' then
    update public.asset set status = 'active' where id = p_asset_id;
  end if;
end;
$$;
revoke execute on function app.fn_refresh_asset_status(uuid) from public, anon, authenticated;

create or replace function app.tg_asset_status_on_maintenance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.fn_refresh_asset_status(new.asset_id);
  return null;
end;
$$;
revoke execute on function app.tg_asset_status_on_maintenance() from public, anon, authenticated;
create trigger trg_asset_status_on_maintenance after insert or update on public.asset_maintenance
  for each row execute function app.tg_asset_status_on_maintenance();

-- ── logging a repair ───────────────────────────────────────────────────

create or replace function public.log_asset_maintenance(
  p_asset_id uuid, p_fault text, p_reported_on date default null, p_vendor_id uuid default null, p_cost bigint default 0,
  p_is_capitalised boolean default false, p_downtime_from date default null, p_downtime_to date default null,
  p_next_service_due date default null, p_responsible_user_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant    uuid := app.auth_tenant_id();
  v_a         public.asset%rowtype;
  v_threshold bigint;
  v_id        uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal', 'transport_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_a from public.asset where id = p_asset_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'ASSET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_a.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() = 'transport_manager' and v_a.category <> 'vehicle' then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_a.status in ('disposed', 'written_off') then
    raise exception 'ASSET_NOT_AVAILABLE' using errcode = '55000';
  end if;
  if btrim(coalesce(p_fault, '')) = '' then
    raise exception 'FAULT_REQUIRED' using errcode = '23514';
  end if;
  if coalesce(p_cost, 0) < 0 then
    raise exception 'COST_MUST_BE_NONNEGATIVE' using errcode = '23514';
  end if;
  if p_downtime_to is not null and (p_downtime_from is null or p_downtime_to < p_downtime_from) then
    raise exception 'DOWNTIME_INVALID' using errcode = '23514';
  end if;
  if p_vendor_id is not null and not exists (select 1 from public.procurement_vendor where id = p_vendor_id and tenant_id = v_tenant) then
    raise exception 'VENDOR_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_responsible_user_id is not null and not exists (select 1 from public.app_user where user_id = p_responsible_user_id and tenant_id = v_tenant) then
    raise exception 'USER_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_is_capitalised then
    select coalesce((select capitalisation_threshold from public.asset_setting where tenant_id = v_tenant), 5000000) into v_threshold;
    if coalesce(p_cost, 0) <= v_threshold then
      raise exception 'BELOW_CAPITALISATION_THRESHOLD' using errcode = '23514',
        detail = format('cost=%s threshold=%s', coalesce(p_cost, 0), v_threshold),
        hint = 'Only repairs above the capitalisation threshold can be added to the asset''s cost; book this one as an expense.';
    end if;
    update public.asset set capitalised_cost = capitalised_cost + p_cost where id = p_asset_id;
  end if;

  insert into public.asset_maintenance (tenant_id, campus_id, asset_id, reported_on, fault, vendor_id, cost, is_capitalised,
                                        downtime_from, downtime_to, next_service_due, responsible_user_id, created_by)
  values (v_tenant, v_a.campus_id, p_asset_id, coalesce(p_reported_on, app.fn_karachi_today()), btrim(p_fault), p_vendor_id, coalesce(p_cost, 0), coalesce(p_is_capitalised, false),
          p_downtime_from, p_downtime_to, p_next_service_due, p_responsible_user_id, (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.log_asset_maintenance(uuid, text, date, uuid, bigint, boolean, date, date, date, uuid) from public, anon;
grant execute on function public.log_asset_maintenance(uuid, text, date, uuid, bigint, boolean, date, date, date, uuid) to authenticated;

create or replace function public.close_asset_maintenance(p_maintenance_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m public.asset_maintenance%rowtype;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal', 'transport_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_m from public.asset_maintenance where id = p_maintenance_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'MAINTENANCE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_m.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_m.closed_at is not null then
    raise exception 'MAINTENANCE_ALREADY_CLOSED' using errcode = '55000';
  end if;
  update public.asset_maintenance set closed_at = clock_timestamp(), closed_by = (select auth.uid()) where id = p_maintenance_id;
end;
$$;
revoke execute on function public.close_asset_maintenance(uuid) from public, anon;
grant execute on function public.close_asset_maintenance(uuid) to authenticated;

-- ── the asset ledger: cost, maintenance and NBV together ───────────────

create or replace view public.v_asset_ledger
with (security_invoker = true) as
select r.asset_id, r.tenant_id, r.campus_id, r.tag_no, r.name, r.category, r.status, r.vehicle_id,
       r.capitalised_cost, r.accumulated_depreciation, r.net_book_value,
       coalesce(m.lifetime_maintenance, 0)::bigint as lifetime_maintenance,
       coalesce(m.capital_improvements, 0)::bigint as capital_improvements,
       m.next_service_due
  from public.v_asset_register r
  left join lateral (
    select sum(x.cost) filter (where not x.is_capitalised) as lifetime_maintenance,
           sum(x.cost) filter (where x.is_capitalised) as capital_improvements,
           min(x.next_service_due) filter (where x.next_service_due >= current_date) as next_service_due
      from public.asset_maintenance x where x.asset_id = r.asset_id
  ) m on true;
revoke all on public.v_asset_ledger from public, anon;
grant select on public.v_asset_ledger to authenticated;

-- ── daily service-due reminder (cron) ──────────────────────────────────

create or replace function public.asset_service_due_reminder_run(p_today date default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := coalesce(p_today, app.fn_karachi_today());
  v_count int := 0;
  v_n     int;
begin
  -- the latest service date per asset, only while it is due within 14 days
  with due as (
    select distinct on (m.asset_id) m.id, m.tenant_id, m.campus_id, m.asset_id, m.next_service_due, m.responsible_user_id
      from public.asset_maintenance m join public.asset a on a.id = m.asset_id
     where m.next_service_due is not null and a.status in ('active', 'in_repair')
     order by m.asset_id, m.next_service_due desc, m.created_at desc
  ), recipients as (
    select d.*, u.user_id as recipient, 'principal'::text as role_label
      from due d join public.user_campus uc on uc.campus_id = d.campus_id and uc.is_active
      join public.app_user u on u.user_id = uc.user_id and u.app_role = 'principal'
     where d.next_service_due - v_today between 0 and 14
    union
    select d.*, d.responsible_user_id, 'maintenance_owner'
      from due d where d.responsible_user_id is not null and d.next_service_due - v_today between 0 and 14
  ), ins as (
    insert into public.asset_service_reminder (tenant_id, campus_id, asset_id, maintenance_id, recipient_user_id, recipient_role, due_on, lead_days)
    select r.tenant_id, r.campus_id, r.asset_id, r.id, r.recipient, r.role_label, r.next_service_due, 14 from recipients r
    on conflict (maintenance_id, recipient_user_id) do nothing
    returning 1
  )
  select count(*)::int into v_n from ins;
  v_count := v_n;
  return v_count;
end;
$$;
revoke execute on function public.asset_service_due_reminder_run(date) from public, anon, authenticated;

-- Keep asset.status honest as downtime windows start and end.
create or replace function public.asset_status_refresh_run()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a record;
  v_n int := 0;
begin
  for v_a in select distinct asset_id from public.asset_maintenance loop
    perform app.fn_refresh_asset_status(v_a.asset_id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.asset_status_refresh_run() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('asset_service_due_reminder', '0 2 * * *', 'select public.asset_status_refresh_run(); select public.asset_service_due_reminder_run();');
  end if;
exception
  when others then null;
end;
$$;
