-- Pay scales (BPS-style grades): a basic-pay band with a yearly increment.
-- A salary structure may name the scale it sits on; its basic must then fall
-- inside the band.

create table public.pay_scale (
  id                     uuid primary key default gen_random_uuid(),
  tenant_id              uuid not null references public.tenant(id) on delete cascade,
  code                   text not null check (length(btrim(code)) between 1 and 20),
  name                   text not null check (length(btrim(name)) between 1 and 100),
  min_basic_paisa        bigint not null check (min_basic_paisa >= 0),
  max_basic_paisa        bigint not null,
  annual_increment_paisa bigint not null default 0 check (annual_increment_paisa >= 0),
  created_at             timestamptz not null default now(),
  constraint chk_pay_scale_band check (max_basic_paisa >= min_basic_paisa),
  constraint uq_pay_scale_code unique (tenant_id, code)
);

alter table public.pay_scale enable row level security;
create policy pay_scale_read on public.pay_scale for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager', 'accountant'));
select app.fn_block_portal_roles('public.pay_scale');

create trigger pay_scale_audit after insert or update or delete on public.pay_scale
  for each row execute function app.tg_audit_row();

create or replace function public.save_pay_scale(
  p_id uuid,
  p_code text,
  p_name text,
  p_min_basic_paisa bigint,
  p_max_basic_paisa bigint,
  p_annual_increment_paisa bigint
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id uuid;
begin
  if v_tenant_id is null or app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_min_basic_paisa is null or p_max_basic_paisa is null or p_min_basic_paisa < 0 or p_max_basic_paisa < p_min_basic_paisa
     or coalesce(p_annual_increment_paisa, 0) < 0 then
    raise exception 'BAND_INVALID' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.pay_scale (tenant_id, code, name, min_basic_paisa, max_basic_paisa, annual_increment_paisa)
    values (v_tenant_id, upper(btrim(p_code)), btrim(p_name), p_min_basic_paisa, p_max_basic_paisa, coalesce(p_annual_increment_paisa, 0))
    returning id into v_id;
  else
    update public.pay_scale
       set code = upper(btrim(p_code)), name = btrim(p_name), min_basic_paisa = p_min_basic_paisa,
           max_basic_paisa = p_max_basic_paisa, annual_increment_paisa = coalesce(p_annual_increment_paisa, 0)
     where id = p_id and tenant_id = v_tenant_id
    returning id into v_id;
    if v_id is null then
      raise exception 'PAY_SCALE_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
end;
$$;
revoke execute on function public.save_pay_scale(uuid, text, text, bigint, bigint, bigint) from public, anon;
grant execute on function public.save_pay_scale(uuid, text, text, bigint, bigint, bigint) to authenticated;

alter table public.employee_salary_structure add column pay_scale_id uuid references public.pay_scale(id);
create index idx_salary_structure_pay_scale on public.employee_salary_structure (pay_scale_id) where pay_scale_id is not null;

-- Salary structures are written straight through RLS, not an RPC, so the band
-- is checked here. Definer: the scale must be readable whatever the writer's role.
create or replace function app.tg_salary_structure_pay_scale()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_scale public.pay_scale%rowtype;
begin
  if new.pay_scale_id is null then
    return new;
  end if;
  select * into v_scale from public.pay_scale where id = new.pay_scale_id and tenant_id = new.tenant_id;
  if not found then
    raise exception 'PAY_SCALE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if new.basic_paisa < v_scale.min_basic_paisa or new.basic_paisa > v_scale.max_basic_paisa then
    raise exception 'BASIC_OUTSIDE_PAY_SCALE' using errcode = '22023';
  end if;
  return new;
end;
$$;

create trigger trg_salary_structure_pay_scale before insert or update of pay_scale_id, basic_paisa on public.employee_salary_structure
  for each row execute function app.tg_salary_structure_pay_scale();
