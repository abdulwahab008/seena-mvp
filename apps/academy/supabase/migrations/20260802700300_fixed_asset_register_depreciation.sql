-- FR-R03: fixed asset register with monthly depreciation.
--
-- A tagged register of capitalised assets that depreciates itself monthly.
-- All money is bigint paisa.
--
-- Rounding is the trap, so the straight-line instalment is never "cost / life"
-- repeated: each period posts remaining depreciable base / remaining months
-- (cost - salvage - accumulated, over life - periods posted), and the last
-- period (one month left) posts the whole remainder. A PKR 120,000 projector
-- over 60 months posts 2,000.00 sixty times and lands on net book value of
-- exactly zero; an asset that does not divide evenly still ends with no residual
-- paisa. Because the instalment is derived from the CURRENT cost and what is
-- already posted, a capital improvement (FR-R05) that raises capitalised_cost
-- re-bases the remaining periods automatically.
--
-- Reducing balance is annual-anchored: the year's depreciation is rate % of the
-- written-down value at the START of that 12-period block, spread over its 12
-- months (the twelfth absorbs the rounding), so period 1 posts on the opening
-- WDV and period 13 on the reduced WDV. Depreciation never takes the asset
-- below its salvage value.
--
-- run_monthly_depreciation(period) is idempotent: (asset_id, period) is unique,
-- a second run posts nothing and reports ALREADY_POSTED. The run also catches an
-- asset up through any earlier missed months so the series stays consecutive.
-- Disposal posts depreciation through the month of disposal (it stops at that
-- period), books proceeds against net book value as a gain or loss, and marks
-- the asset disposed (or written_off).
--
-- A bus is both a fleet record (Transport's transport_vehicle) and a fixed asset.
-- asset.vehicle_id points at that one fleet record, uniquely, so the fleet is one
-- record seen from two modules instead of two registers that drift apart. The
-- foreign key is added when transport_vehicle exists; this migration does not
-- create or alter Transport's table.

create type public.asset_category as enum ('furniture', 'it', 'lab', 'vehicle', 'building', 'other');
create type public.asset_method as enum ('SL', 'RB');
create type public.asset_status as enum ('active', 'in_repair', 'disposed', 'written_off');

create table public.asset (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  campus_id           uuid not null references public.campus(id) on delete cascade,
  tag_no              text not null check (tag_no = btrim(tag_no) and char_length(tag_no) between 1 and 40),
  name                text not null check (char_length(btrim(name)) between 1 and 200),
  category            public.asset_category not null,
  purchased_on        date not null,
  capitalised_cost    bigint not null check (capitalised_cost > 0),
  useful_life_months  int not null check (useful_life_months between 1 and 1200),
  salvage_value       bigint not null default 0 check (salvage_value >= 0),
  method              public.asset_method not null default 'SL',
  rate                numeric check (rate is null or (rate > 0 and rate <= 100)),
  status              public.asset_status not null default 'active',
  vehicle_id          uuid,
  created_at          timestamptz not null default now(),
  constraint chk_asset_salvage check (salvage_value <= capitalised_cost),
  constraint chk_asset_rb_rate check (method <> 'RB' or rate is not null)
);
create unique index uq_asset_tag on public.asset (tenant_id, tag_no);
create unique index uq_asset_vehicle on public.asset (vehicle_id) where vehicle_id is not null;
create index idx_asset_campus on public.asset (campus_id, status);
create index idx_asset_tenant on public.asset (tenant_id);

create table public.asset_depreciation_entry (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  campus_id   uuid not null references public.campus(id) on delete cascade,
  asset_id    uuid not null references public.asset(id) on delete cascade,
  period      date not null check (period = date_trunc('month', period)::date),
  amount      bigint not null check (amount >= 0),
  opening_wdv bigint not null,
  closing_wdv bigint not null,
  posted_at   timestamptz not null default clock_timestamp(),
  constraint chk_dep_wdv check (closing_wdv = opening_wdv - amount)
);
create unique index uq_dep_period on public.asset_depreciation_entry (asset_id, period);
create index idx_dep_tenant_period on public.asset_depreciation_entry (tenant_id, campus_id, period);

create table public.asset_disposal (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  asset_id         uuid not null unique references public.asset(id) on delete cascade,
  disposed_on      date not null,
  proceeds         bigint not null check (proceeds >= 0),
  nbv_at_disposal  bigint not null,
  gain_loss        bigint not null,
  written_off      boolean not null default false,
  disposed_by      uuid references public.app_user(user_id),
  created_at       timestamptz not null default now()
);
create index idx_asset_disposal_tenant on public.asset_disposal (tenant_id, campus_id);

create trigger asset_audit after insert or update or delete on public.asset
  for each row execute function app.tg_audit_row();
create trigger asset_disposal_audit after insert or update or delete on public.asset_disposal
  for each row execute function app.tg_audit_row();

create or replace function app.tg_dep_entry_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'DEPRECIATION_ENTRY_IMMUTABLE' using errcode = '42501', hint = 'A posted depreciation entry is never edited or removed.';
end;
$$;
create trigger trg_dep_entry_immutable before update or delete on public.asset_depreciation_entry
  for each row execute function app.tg_dep_entry_immutable();

alter table public.asset enable row level security;
alter table public.asset_depreciation_entry enable row level security;
alter table public.asset_disposal enable row level security;
revoke insert, update, delete, truncate on public.asset, public.asset_depreciation_entry, public.asset_disposal from anon, authenticated;

create policy asset_campus_scope on public.asset for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal', 'vice_principal', 'transport_manager', 'hr_manager')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy asset_dep_campus_scope on public.asset_depreciation_entry for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal', 'vice_principal')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy asset_disposal_campus_scope on public.asset_disposal for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal', 'vice_principal')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

create or replace view public.v_asset_register
with (security_invoker = true) as
select a.id as asset_id, a.tenant_id, a.campus_id, a.tag_no, a.name, a.category, a.purchased_on, a.capitalised_cost,
       a.useful_life_months, a.salvage_value, a.method, a.rate, a.status, a.vehicle_id,
       coalesce(d.accumulated, 0)::bigint as accumulated_depreciation,
       (a.capitalised_cost - coalesce(d.accumulated, 0))::bigint as net_book_value,
       d.periods_posted
  from public.asset a
  left join lateral (
    select sum(e.amount) as accumulated, count(*)::int as periods_posted from public.asset_depreciation_entry e where e.asset_id = a.id
  ) d on true;
revoke all on public.v_asset_register from public, anon;
grant select on public.v_asset_register to authenticated;

do $$
begin
  if to_regclass('public.transport_vehicle') is not null then
    alter table public.asset add constraint asset_vehicle_id_fkey foreign key (vehicle_id) references public.transport_vehicle(id);
  end if;
end;
$$;

-- ── register an asset ──────────────────────────────────────────────────

create or replace function public.create_asset(
  p_campus_id uuid, p_tag_no text, p_name text, p_category public.asset_category, p_purchased_on date,
  p_capitalised_cost bigint, p_useful_life_months int, p_salvage_value bigint default 0,
  p_method public.asset_method default 'SL', p_rate numeric default null, p_vehicle_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_id     uuid;
  v_ok     boolean;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (p_campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_capitalised_cost is null or p_capitalised_cost <= 0 then
    raise exception 'COST_MUST_BE_POSITIVE' using errcode = '23514';
  end if;
  if coalesce(p_salvage_value, 0) < 0 or coalesce(p_salvage_value, 0) > p_capitalised_cost then
    raise exception 'SALVAGE_INVALID' using errcode = '23514';
  end if;
  if p_useful_life_months is null or p_useful_life_months not between 1 and 1200 then
    raise exception 'LIFE_INVALID' using errcode = '23514';
  end if;
  if p_method = 'RB' and (p_rate is null or p_rate <= 0 or p_rate > 100) then
    raise exception 'RATE_REQUIRED' using errcode = '23514';
  end if;
  if p_vehicle_id is not null then
    if p_category <> 'vehicle' then
      raise exception 'VEHICLE_LINK_NEEDS_VEHICLE_CATEGORY' using errcode = '23514';
    end if;
    if to_regclass('public.transport_vehicle') is null then
      raise exception 'VEHICLE_NOT_FOUND' using errcode = 'P0002';
    end if;
    execute 'select exists (select 1 from public.transport_vehicle where id = $1 and tenant_id = $2)' into v_ok using p_vehicle_id, v_tenant;
    if not v_ok then
      raise exception 'VEHICLE_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;
  insert into public.asset (tenant_id, campus_id, tag_no, name, category, purchased_on, capitalised_cost, useful_life_months, salvage_value, method, rate, vehicle_id)
  values (v_tenant, p_campus_id, btrim(p_tag_no), btrim(p_name), p_category, p_purchased_on, p_capitalised_cost, p_useful_life_months,
          coalesce(p_salvage_value, 0), p_method, case when p_method = 'RB' then p_rate end, p_vehicle_id)
  returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'ASSET_TAG_EXISTS' using errcode = '23505';
end;
$$;
revoke execute on function public.create_asset(uuid, text, text, public.asset_category, date, bigint, int, bigint, public.asset_method, numeric, uuid) from public, anon;
grant execute on function public.create_asset(uuid, text, text, public.asset_category, date, bigint, int, bigint, public.asset_method, numeric, uuid) to authenticated;

-- ── the depreciation arithmetic ────────────────────────────────────────
-- Amount for the NEXT period of an asset given what is already posted.

create or replace function app.fn_asset_next_amount(p_asset_id uuid)
returns table (amount bigint, opening_wdv bigint)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_a       public.asset%rowtype;
  v_n       int;
  v_accum   bigint;
  v_wdv     bigint;
  v_floor   bigint;
  v_base    bigint;
  v_block   bigint;
  v_year_open bigint;
  v_annual  bigint;
  v_month_in_year int;
  v_amt     bigint;
begin
  select * into v_a from public.asset where id = p_asset_id;
  select count(*), coalesce(sum(e.amount), 0) into v_n, v_accum from public.asset_depreciation_entry e where e.asset_id = p_asset_id;
  v_wdv := v_a.capitalised_cost - v_accum;
  v_floor := v_a.salvage_value;
  v_base := v_wdv - v_floor;
  if v_base <= 0 then
    return query select 0::bigint, v_wdv;
    return;
  end if;

  if v_a.method = 'SL' then
    if v_a.useful_life_months - v_n <= 1 then
      v_amt := v_base;
    else
      v_amt := round(v_base::numeric / (v_a.useful_life_months - v_n))::bigint;
    end if;
  else
    -- opening WDV of the 12-period block this period falls in
    select coalesce(sum(b.amount), 0) into v_block
      from (select e.amount, row_number() over (order by e.period) as rn from public.asset_depreciation_entry e where e.asset_id = p_asset_id) b
     where b.rn <= 12 * (v_n / 12);
    v_year_open := v_a.capitalised_cost - v_block;
    v_annual := round(v_year_open::numeric * v_a.rate / 100)::bigint;
    v_month_in_year := (v_n % 12) + 1;
    if v_month_in_year = 12 then
      v_amt := v_annual - 11 * (v_annual / 12);
    else
      v_amt := v_annual / 12;
    end if;
  end if;
  v_amt := least(v_amt, v_base);
  return query select v_amt, v_wdv;
end;
$$;
revoke execute on function app.fn_asset_next_amount(uuid) from public, anon, authenticated;

-- Posts every missing monthly entry for one asset up to and including p_period. Returns the count posted.
create or replace function app.fn_asset_post_through(p_asset_id uuid, p_period date)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a      public.asset%rowtype;
  v_last   date;
  v_next   date;
  v_amt    bigint;
  v_open   bigint;
  v_posted int := 0;
begin
  select * into v_a from public.asset where id = p_asset_id for update;
  if not found or v_a.status in ('disposed', 'written_off') then
    return 0;
  end if;
  select max(period) into v_last from public.asset_depreciation_entry where asset_id = p_asset_id;
  v_next := coalesce((v_last + interval '1 month')::date, date_trunc('month', v_a.purchased_on)::date);
  while v_next <= p_period loop
    select n.amount, n.opening_wdv into v_amt, v_open from app.fn_asset_next_amount(p_asset_id) n;
    exit when v_amt = 0 and v_open - v_a.salvage_value <= 0;
    insert into public.asset_depreciation_entry (tenant_id, campus_id, asset_id, period, amount, opening_wdv, closing_wdv)
    values (v_a.tenant_id, v_a.campus_id, p_asset_id, v_next, v_amt, v_open, v_open - v_amt)
    on conflict (asset_id, period) do nothing;
    if found then
      v_posted := v_posted + 1;
    end if;
    v_next := (v_next + interval '1 month')::date;
  end loop;
  return v_posted;
end;
$$;
revoke execute on function app.fn_asset_post_through(uuid, date) from public, anon, authenticated;

create or replace function app.fn_run_depreciation(p_tenant_id uuid, p_campus_ids uuid[], p_period date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_period  date := date_trunc('month', p_period)::date;
  v_asset   record;
  v_posted  int := 0;
  v_assets  int := 0;
  v_already boolean := false;
begin
  for v_asset in
    select a.id from public.asset a
     where a.tenant_id = p_tenant_id and a.status in ('active', 'in_repair')
       and date_trunc('month', a.purchased_on)::date <= v_period
       and (p_campus_ids is null or a.campus_id = any (p_campus_ids))
     order by a.tag_no
  loop
    v_assets := v_assets + 1;
    v_posted := v_posted + app.fn_asset_post_through(v_asset.id, v_period);
  end loop;
  if v_posted = 0 and exists (
       select 1 from public.asset_depreciation_entry e join public.asset a on a.id = e.asset_id
        where a.tenant_id = p_tenant_id and e.period = v_period and (p_campus_ids is null or a.campus_id = any (p_campus_ids))) then
    v_already := true;
  end if;
  return jsonb_build_object('period', v_period, 'posted', v_posted, 'assets', v_assets,
                            'status', case when v_already then 'ALREADY_POSTED' when v_posted = 0 then 'NOTHING_TO_POST' else 'POSTED' end);
end;
$$;
revoke execute on function app.fn_run_depreciation(uuid, uuid[], date) from public, anon, authenticated;

create or replace function public.run_monthly_depreciation(p_period date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_period is null then
    raise exception 'PERIOD_REQUIRED' using errcode = '23514';
  end if;
  return app.fn_run_depreciation(app.auth_tenant_id(),
           case when app.auth_role() in ('owner', 'super_admin') then null else app.auth_campus_ids() end, p_period);
end;
$$;
revoke execute on function public.run_monthly_depreciation(date) from public, anon;
grant execute on function public.run_monthly_depreciation(date) to authenticated;

-- Cron entry point: every tenant, for the month that just closed.
create or replace function public.asset_depreciation_cron()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant record;
  v_total  int := 0;
  v_res    jsonb;
begin
  for v_tenant in select distinct tenant_id from public.asset where status in ('active', 'in_repair') loop
    v_res := app.fn_run_depreciation(v_tenant.tenant_id, null, (date_trunc('month', now() at time zone 'Asia/Karachi') - interval '1 month')::date);
    v_total := v_total + (v_res ->> 'posted')::int;
  end loop;
  return v_total;
end;
$$;
revoke execute on function public.asset_depreciation_cron() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('asset_depreciation_run', '30 20 2 * *', 'select public.asset_depreciation_cron();');
  end if;
exception
  when others then null;
end;
$$;

-- ── disposal ───────────────────────────────────────────────────────────

create or replace function public.dispose_asset(p_asset_id uuid, p_disposed_on date, p_proceeds bigint default 0, p_write_off boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a      public.asset%rowtype;
  v_month  date := date_trunc('month', p_disposed_on)::date;
  v_last   date;
  v_nbv    bigint;
  v_gain   bigint;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_a from public.asset where id = p_asset_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'ASSET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_a.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_a.status in ('disposed', 'written_off') then
    raise exception 'ASSET_ALREADY_DISPOSED' using errcode = '55000';
  end if;
  if p_disposed_on is null or p_disposed_on < v_a.purchased_on then
    raise exception 'DISPOSAL_DATE_INVALID' using errcode = '23514';
  end if;
  if coalesce(p_proceeds, 0) < 0 or (p_write_off and coalesce(p_proceeds, 0) <> 0) then
    raise exception 'PROCEEDS_INVALID' using errcode = '23514';
  end if;
  select max(period) into v_last from public.asset_depreciation_entry where asset_id = p_asset_id;
  if v_last is not null and v_last > v_month then
    raise exception 'DISPOSAL_BEFORE_POSTED_PERIOD' using errcode = '55000', detail = format('last_posted=%s', v_last);
  end if;

  -- Depreciation stops at the period of disposal: bring the series up to and including that month.
  perform app.fn_asset_post_through(p_asset_id, v_month);
  select v_a.capitalised_cost - coalesce(sum(e.amount), 0) into v_nbv from public.asset_depreciation_entry e where e.asset_id = p_asset_id;
  v_gain := coalesce(p_proceeds, 0) - v_nbv;

  insert into public.asset_disposal (tenant_id, campus_id, asset_id, disposed_on, proceeds, nbv_at_disposal, gain_loss, written_off, disposed_by)
  values (v_a.tenant_id, v_a.campus_id, p_asset_id, p_disposed_on, coalesce(p_proceeds, 0), v_nbv, v_gain, p_write_off, (select auth.uid()));
  update public.asset set status = case when p_write_off then 'written_off'::public.asset_status else 'disposed'::public.asset_status end where id = p_asset_id;

  return jsonb_build_object('asset_id', p_asset_id, 'disposed_on', p_disposed_on, 'nbv_at_disposal', v_nbv, 'proceeds', coalesce(p_proceeds, 0), 'gain_loss', v_gain);
end;
$$;
revoke execute on function public.dispose_asset(uuid, date, bigint, boolean) from public, anon;
grant execute on function public.dispose_asset(uuid, date, bigint, boolean) to authenticated;
