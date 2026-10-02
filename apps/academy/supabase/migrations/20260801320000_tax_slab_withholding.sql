-- ═══════════════════════════════════════════════════════════════════════
-- Migration: 20260801320000_tax_slab_withholding.sql
-- FR-L05: Income tax slab withholding engine
--
-- Provides versioned progressive tax slabs (conforming to Pakistan FBR salaried
-- tax structures), annual tax computation, and monthly withholding estimation.
-- ═══════════════════════════════════════════════════════════════════════

create table public.tax_slab_version (
  id             uuid primary key default gen_random_uuid(),
  tax_year       text not null unique,
  effective_from date not null,
  published_by   uuid references auth.users(id),
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);

create table public.tax_slab (
  id                 uuid primary key default gen_random_uuid(),
  version_id         uuid not null references public.tax_slab_version(id) on delete cascade,
  lower_bound_paisa  bigint not null check (lower_bound_paisa >= 0),
  upper_bound_paisa  bigint check (upper_bound_paisa is null or upper_bound_paisa > lower_bound_paisa),
  fixed_amount_paisa bigint not null default 0 check (fixed_amount_paisa >= 0),
  rate_pct           numeric(5, 2) not null default 0 check (rate_pct >= 0 and rate_pct <= 100),
  rebate_pct         numeric(5, 2) not null default 0 check (rebate_pct >= 0 and rebate_pct <= 100),
  sort_order         int not null default 1
);

create index idx_tax_slab_version on public.tax_slab (version_id, sort_order);

-- Audit triggers
create trigger tax_slab_version_audit after insert or update or delete on public.tax_slab_version
  for each row execute function app.tg_audit_row();

create trigger tax_slab_audit after insert or update or delete on public.tax_slab
  for each row execute function app.tg_audit_row();

-- RLS
alter table public.tax_slab_version enable row level security;
alter table public.tax_slab enable row level security;

create policy tax_slab_version_read on public.tax_slab_version
  for select to authenticated
  using (true);

create policy tax_slab_read on public.tax_slab
  for select to authenticated
  using (true);

create policy tax_slab_version_write on public.tax_slab_version
  for all to authenticated
  using (app.auth_role() in ('super_admin', 'owner'))
  with check (app.auth_role() in ('super_admin', 'owner'));

create policy tax_slab_write on public.tax_slab
  for all to authenticated
  using (app.auth_role() in ('super_admin', 'owner'))
  with check (app.auth_role() in ('super_admin', 'owner'));

-- Function to compute annual income tax in paisa
create or replace function public.fn_annual_tax_paisa(
  p_annual_taxable_paisa bigint,
  p_tax_year             text default null
)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_version_id uuid;
  v_slab       record;
  v_taxable    bigint := coalesce(p_annual_taxable_paisa, 0);
  v_excess     bigint := 0;
  v_variable   bigint := 0;
  v_gross_tax  bigint := 0;
  v_final_tax  bigint := 0;
begin
  if v_taxable <= 0 then
    return 0;
  end if;

  if p_tax_year is not null then
    select id into v_version_id
    from public.tax_slab_version
    where tax_year = p_tax_year;
  else
    select id into v_version_id
    from public.tax_slab_version
    where is_active = true
    order by effective_from desc
    limit 1;
  end if;

  if v_version_id is null then
    return 0;
  end if;

  -- Locate matching slab
  select *
  into v_slab
  from public.tax_slab
  where version_id = v_version_id
    and v_taxable > lower_bound_paisa
    and (upper_bound_paisa is null or v_taxable <= upper_bound_paisa)
  order by sort_order
  limit 1;

  if v_slab.id is null then
    return 0;
  end if;

  v_excess := v_taxable - v_slab.lower_bound_paisa;
  if v_slab.rate_pct > 0 then
    v_variable := round((v_excess::numeric * v_slab.rate_pct) / 100.0)::bigint;
  else
    v_variable := 0;
  end if;

  v_gross_tax := v_slab.fixed_amount_paisa + v_variable;

  if v_slab.rebate_pct > 0 then
    v_final_tax := round(v_gross_tax::numeric * (1.0 - (v_slab.rebate_pct / 100.0)))::bigint;
  else
    v_final_tax := v_gross_tax;
  end if;

  return greatest(0, v_final_tax);
end;
$$;

revoke execute on function public.fn_annual_tax_paisa(bigint, text) from public, anon;
grant  execute on function public.fn_annual_tax_paisa(bigint, text) to authenticated;

-- Function to compute monthly withholding tax from monthly taxable earnings
create or replace function public.fn_monthly_withholding_paisa(
  p_staff_id              uuid,
  p_monthly_taxable_paisa bigint,
  p_tax_year              text default null
)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_annual_taxable bigint;
  v_annual_tax     bigint;
begin
  if coalesce(p_monthly_taxable_paisa, 0) <= 0 then
    return 0;
  end if;

  -- Annualise monthly taxable income
  v_annual_taxable := p_monthly_taxable_paisa * 12;
  v_annual_tax     := public.fn_annual_tax_paisa(v_annual_taxable, p_tax_year);

  return round(v_annual_tax::numeric / 12.0)::bigint;
end;
$$;

revoke execute on function public.fn_monthly_withholding_paisa(uuid, bigint, text) from public, anon;
grant  execute on function public.fn_monthly_withholding_paisa(uuid, bigint, text) to authenticated;

-- Seed Pakistan FBR TY 2026-27 salaried slabs
do $$
declare
  v_v_id uuid;
begin
  insert into public.tax_slab_version (tax_year, effective_from, is_active)
  values ('2026-2027', '2026-07-01', true)
  on conflict (tax_year) do update set is_active = true
  returning id into v_v_id;

  if v_v_id is null then
    select id into v_v_id from public.tax_slab_version where tax_year = '2026-2027';
  end if;

  delete from public.tax_slab where version_id = v_v_id;

  -- Slab 1: 0 to 600,000 PKR (0 to 60,000,000 paisa) => 0%
  insert into public.tax_slab (version_id, lower_bound_paisa, upper_bound_paisa, fixed_amount_paisa, rate_pct, sort_order)
  values (v_v_id, 0, 60000000, 0, 0, 1);

  -- Slab 2: 600,001 to 1,200,000 PKR (60,000,000 to 120,000,000 paisa) => 5%
  insert into public.tax_slab (version_id, lower_bound_paisa, upper_bound_paisa, fixed_amount_paisa, rate_pct, sort_order)
  values (v_v_id, 60000000, 120000000, 0, 5.0, 2);

  -- Slab 3: 1,200,001 to 2,200,000 PKR (120,000,000 to 220,000,000 paisa) => 30,000 PKR + 15%
  insert into public.tax_slab (version_id, lower_bound_paisa, upper_bound_paisa, fixed_amount_paisa, rate_pct, sort_order)
  values (v_v_id, 120000000, 220000000, 3000000, 15.0, 3);

  -- Slab 4: 2,200,001 to 3,200,000 PKR (220,000,000 to 320,000,000 paisa) => 180,000 PKR + 25%
  insert into public.tax_slab (version_id, lower_bound_paisa, upper_bound_paisa, fixed_amount_paisa, rate_pct, sort_order)
  values (v_v_id, 220000000, 320000000, 18000000, 25.0, 4);

  -- Slab 5: 3,200,001 to 4,100,000 PKR (320,000,000 to 410,000,000 paisa) => 430,000 PKR + 30%
  insert into public.tax_slab (version_id, lower_bound_paisa, upper_bound_paisa, fixed_amount_paisa, rate_pct, sort_order)
  values (v_v_id, 320000000, 410000000, 43000000, 30.0, 5);

  -- Slab 6: Above 4,100,000 PKR (> 410,000,000 paisa) => 700,000 PKR + 35%
  insert into public.tax_slab (version_id, lower_bound_paisa, upper_bound_paisa, fixed_amount_paisa, rate_pct, sort_order)
  values (v_v_id, 410000000, null, 70000000, 35.0, 6);
end $$;
