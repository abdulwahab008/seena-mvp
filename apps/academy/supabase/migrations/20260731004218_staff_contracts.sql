-- FR-D04: versioned employment contract records.
--
-- Scope note: FR-D13 (substitute teacher assignment) was considered for
-- this batch and set aside entirely — it is built on timetable_slot
-- (Module F, Timetable), which doesn't exist at all yet. Unlike prior
-- scope cuts (a deferred sub-check, a deferred UI), there is no partial
-- version of "suggest a substitute for an absent teacher's period" without
-- a real timetable to substitute for.
--
-- RLS note: the FR's own two descriptions of staff_contract's read access
-- disagree — its Notes say "a campus Principal may manage contracts but
-- must not see the Owner's salary decisions" (implying Principal has
-- contract access), while its terser Supabase Objects line says
-- owner+hr_manager only. The Notes' stated rationale is the more specific,
-- deliberate one, so contract_hr_owner_only here includes Principal for
-- staff_contract; staff_contract_pay (owner+hr_manager only, no Principal)
-- is what actually implements the "must not see salary" restriction.

create type public.contract_type as enum ('permanent', 'contract', 'probation', 'visiting', 'part_time');

create table public.staff_contract (
  id                          uuid primary key default gen_random_uuid(),
  tenant_id                   uuid not null references public.tenant(id) on delete cascade,
  staff_id                    uuid not null references public.staff(id) on delete cascade,
  contract_type               public.contract_type not null,
  start_date                  date not null,
  end_date                    date,
  contracted_periods_per_week smallint,
  notice_period_days          smallint,
  supersedes_id               uuid references public.staff_contract(id),
  probation_confirmed_at      timestamptz,
  created_at                  timestamptz not null default now(),
  created_by                  uuid references public.app_user(user_id),
  -- The only reliable defence against two simultaneously "current"
  -- contracts — an application-level check loses to two HR tabs saving at
  -- once.
  constraint ex_staff_contract_no_overlap
    exclude using gist (staff_id with =, daterange(start_date, coalesce(end_date, 'infinity'::date)) with &&)
);

create index idx_staff_contract_staff on public.staff_contract (staff_id);

create trigger staff_contract_audit after insert or update or delete on public.staff_contract
  for each row execute function app.tg_audit_row();

-- Salary lives on its own table, never a column on staff_contract, purely
-- so a different (narrower) RLS policy can gate it — this is a column-
-- level restriction achieved through table separation, not row-level.
create table public.staff_contract_pay (
  contract_id  uuid primary key references public.staff_contract(id) on delete cascade,
  gross_salary numeric(12, 2) not null,
  allowances   jsonb not null default '{}'::jsonb
);

create or replace function public.create_staff_contract(
  p_staff_id                    uuid,
  p_contract_type               public.contract_type,
  p_start_date                  date,
  p_contracted_periods_per_week smallint default null,
  p_notice_period_days          smallint default null,
  p_gross_salary                numeric default null,
  p_allowances                  jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_prev_id   uuid;
  v_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id into v_tenant_id from public.staff where id = p_staff_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Superseded, never edited: close whichever open-ended contract
  -- currently covers this date the day before the new one starts — zero
  -- gap, zero overlap, full history preserved for settlement disputes.
  select id into v_prev_id from public.staff_contract
   where staff_id = p_staff_id and end_date is null and start_date < p_start_date;
  if v_prev_id is not null then
    update public.staff_contract set end_date = p_start_date - 1 where id = v_prev_id;
  end if;

  insert into public.staff_contract (
    tenant_id, staff_id, contract_type, start_date, contracted_periods_per_week, notice_period_days, supersedes_id, created_by
  ) values (
    v_tenant_id, p_staff_id, p_contract_type, p_start_date, p_contracted_periods_per_week, p_notice_period_days, v_prev_id, auth.uid()
  )
  returning id into v_id;

  if p_gross_salary is not null then
    insert into public.staff_contract_pay (contract_id, gross_salary, allowances) values (v_id, p_gross_salary, p_allowances);
  end if;

  return v_id;
end;
$$;

revoke execute on function public.create_staff_contract(
  uuid, public.contract_type, date, smallint, smallint, numeric, jsonb
) from public, anon;
grant execute on function public.create_staff_contract(
  uuid, public.contract_type, date, smallint, smallint, numeric, jsonb
) to authenticated;

create or replace function public.confirm_probation(p_contract_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id into v_tenant_id from public.staff_contract where id = p_contract_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'CONTRACT_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.staff_contract set probation_confirmed_at = now() where id = p_contract_id;
end;
$$;

revoke execute on function public.confirm_probation(uuid) from public, anon;
grant execute on function public.confirm_probation(uuid) to authenticated;

create or replace function public.current_contract(p_staff_id uuid, p_on date default current_date)
returns public.staff_contract
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.staff_contract
   where staff_id = p_staff_id and start_date <= p_on and (end_date is null or end_date >= p_on)
   limit 1;
$$;

revoke execute on function public.current_contract(uuid, date) from public, anon;
grant execute on function public.current_contract(uuid, date) to authenticated;

-- Not wired to a schedule (no pg_cron locally, same as every other
-- "daily job" in this schema) — a plain worklist query, safe to grant
-- broadly since it only reads.
create or replace function public.fn_flag_probation_lapsed()
returns setof public.staff_contract
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.staff_contract
   where tenant_id = app.auth_tenant_id()
     and contract_type = 'probation'
     and end_date < current_date
     and probation_confirmed_at is null;
$$;

revoke execute on function public.fn_flag_probation_lapsed() from public, anon;
grant execute on function public.fn_flag_probation_lapsed() to authenticated;

alter table public.staff_contract enable row level security;
alter table public.staff_contract_pay enable row level security;

create policy contract_hr_owner_only on public.staff_contract
  for select to authenticated
  using (app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'principal') and tenant_id = app.auth_tenant_id());

create policy contract_pay_owner_only on public.staff_contract_pay
  for select to authenticated
  using (
    app.auth_role() in ('super_admin', 'owner', 'hr_manager')
    and contract_id in (select id from public.staff_contract where tenant_id = app.auth_tenant_id())
  );
