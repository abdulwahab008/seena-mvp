-- FR-D01 (staff master profile) and FR-D09 (configurable leave types),
-- the first Module D (Staff & HR) work this schema has. Shipped together
-- because D09's own AC assumes staff.gender and staff.contract_type exist
-- for eligibility filtering, and D01 (this same migration) is what
-- defines the staff table — no reason to ship it missing those columns
-- when D09 needs them immediately.
--
-- Scope cuts:
--   * D01's teachable-subject matrix (FR-D03) and its timetable triggers
--     are a separate FR — timetable_slot (Module F) doesn't exist yet.
--   * D09's DOCUMENT_REQUIRED-on-application check is a leave APPLICATION
--     concern (FR-D11, doesn't exist) — doc_required_after_days is stored
--     correctly on leave_type, just not enforced anywhere yet.
--   * staff_id in FR-E08/E09 (already shipped) still references
--     app_user(user_id) directly, not this new staff table — reconciling
--     the two is a real, separate migration for whenever something
--     actually needs to allocate/section-teach a staff member who has no
--     app_user login (a support employee, a newly hired teacher whose
--     account isn't set up yet). Not touching shipped, tested code for a
--     refactor nothing is asking for yet.

create table public.designation (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant(id) on delete cascade,
  code      text not null,
  name_en   text not null,
  name_ur   text,
  unique (tenant_id, code)
);

create table public.department (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant(id) on delete cascade,
  code      text not null,
  name_en   text not null,
  name_ur   text,
  unique (tenant_id, code)
);

create type public.id_document_type as enum ('cnic', 'passport');
create type public.employment_status as enum ('active', 'on_leave', 'suspended', 'exited');

create table public.staff (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  user_id           uuid references auth.users(id), -- nullable: HR can enter a staff record before any login exists
  employee_code     text not null,
  id_document_type  public.id_document_type not null default 'cnic',
  cnic              text,
  passport_no       text,
  gender            public.gender not null,
  contract_type     text not null default 'permanent',
  dob               date,
  doj               date not null default current_date,
  designation_id    uuid references public.designation(id),
  department_id     uuid references public.department(id),
  employment_status public.employment_status not null default 'active',
  full_name         text not null,
  full_name_ur      text,
  created_at        timestamptz not null default now(),
  constraint chk_staff_cnic_format check (cnic is null or cnic ~ '^[0-9]{5}-[0-9]{7}-[0-9]$'),
  constraint chk_staff_id_document check (
    (id_document_type = 'cnic' and cnic is not null and passport_no is null)
    or (id_document_type = 'passport' and passport_no is not null)
  )
);

-- Partial on active: a rehire (exited, then a new row for the return) or
-- the same person legitimately working at two schools in the same group
-- must not collide with their own prior/other record.
create unique index uq_staff_tenant_employee_code on public.staff (tenant_id, employee_code);
create unique index uq_staff_active_cnic on public.staff (tenant_id, cnic) where employment_status = 'active' and cnic is not null;
create index idx_staff_campus_status on public.staff (campus_id, employment_status);

create trigger staff_audit after insert or update or delete on public.staff
  for each row execute function app.tg_audit_row();

create table public.staff_campus (
  staff_id  uuid not null references public.staff(id) on delete cascade,
  campus_id uuid not null references public.campus(id) on delete cascade,
  primary key (staff_id, campus_id)
);

-- Gapless and never-reused: settlement, gratuity and provident-fund history
-- reference employee_code for the life of the school, so a counter row
-- locked FOR UPDATE, not max()+1, which races under concurrent HR entry.
create table public.employee_code_counter (
  campus_id  uuid primary key references public.campus(id) on delete cascade,
  next_value bigint not null default 1
);

create or replace function app.tg_seed_employee_code_counter()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.employee_code_counter (campus_id) values (new.id) on conflict (campus_id) do nothing;
  return new;
end;
$$;

create trigger campus_seed_employee_code_counter after insert on public.campus
  for each row execute function app.tg_seed_employee_code_counter();

create or replace function app.fn_next_employee_code(p_campus_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_next        bigint;
  v_campus_code text;
begin
  select next_value into v_next from public.employee_code_counter where campus_id = p_campus_id for update;
  if not found then
    raise exception 'EMPLOYEE_CODE_COUNTER_NOT_CONFIGURED' using errcode = 'P0002';
  end if;

  select code into v_campus_code from public.campus where id = p_campus_id;
  update public.employee_code_counter set next_value = next_value + 1 where campus_id = p_campus_id;

  return 'SA-' || v_campus_code || '-' || lpad(v_next::text, 4, '0');
end;
$$;

revoke execute on function app.fn_next_employee_code(uuid) from public, anon, authenticated;

create or replace function public.create_staff(
  p_campus_id        uuid,
  p_full_name        text,
  p_gender           public.gender,
  p_id_document_type public.id_document_type default 'cnic',
  p_cnic             text default null,
  p_passport_no      text default null,
  p_full_name_ur     text default null,
  p_contract_type    text default 'permanent',
  p_dob              date default null,
  p_doj              date default current_date,
  p_designation_id   uuid default null,
  p_department_id    uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_normalized_cnic  text;
  v_existing_code    text;
  v_employee_code    text;
  v_id               uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_id_document_type = 'cnic' then
    if p_cnic is null then
      raise exception 'CNIC_REQUIRED' using errcode = '23514';
    end if;
    v_normalized_cnic := app.fn_normalize_pk_id(p_cnic);

    select employee_code into v_existing_code
      from public.staff
     where tenant_id = app.auth_tenant_id() and cnic = v_normalized_cnic and employment_status = 'active'
     limit 1;
    if found then
      raise exception 'CNIC_CONFLICT' using errcode = '23505', detail = format('conflicting_employee_code=%s', v_existing_code);
    end if;
  elsif p_passport_no is null then
    raise exception 'PASSPORT_REQUIRED' using errcode = '23514';
  end if;

  v_employee_code := app.fn_next_employee_code(p_campus_id);

  insert into public.staff (
    tenant_id, campus_id, employee_code, id_document_type, cnic, passport_no, gender, contract_type,
    dob, doj, designation_id, department_id, full_name, full_name_ur
  ) values (
    app.auth_tenant_id(), p_campus_id, v_employee_code, p_id_document_type, v_normalized_cnic, p_passport_no, p_gender, p_contract_type,
    p_dob, p_doj, p_designation_id, p_department_id, p_full_name, p_full_name_ur
  )
  returning id into v_id;

  insert into public.staff_campus (staff_id, campus_id) values (v_id, p_campus_id);

  return v_id;
end;
$$;

revoke execute on function public.create_staff(
  uuid, text, public.gender, public.id_document_type, text, text, text, text, date, date, uuid, uuid
) from public, anon;
grant execute on function public.create_staff(
  uuid, text, public.gender, public.id_document_type, text, text, text, text, date, date, uuid, uuid
) to authenticated;

create or replace function public.attach_staff_campus(p_staff_id uuid, p_campus_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id into v_tenant_id from public.staff where id = p_staff_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.staff_campus (staff_id, campus_id) values (p_staff_id, p_campus_id) on conflict do nothing;
end;
$$;

revoke execute on function public.attach_staff_campus(uuid, uuid) from public, anon;
grant execute on function public.attach_staff_campus(uuid, uuid) to authenticated;

alter table public.staff enable row level security;
alter table public.staff_campus enable row level security;
alter table public.designation enable row level security;
alter table public.department enable row level security;

-- Combines the FR's "staff_campus_scope" and "staff_self_read" into one
-- policy — multiple permissive policies OR together in Postgres RLS
-- anyway, so a single policy expressing both is equivalent and simpler.
create policy staff_campus_scope on public.staff
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
      or exists (select 1 from public.staff_campus sc where sc.staff_id = staff.id and sc.campus_id = any(app.auth_campus_ids()))
      or user_id = auth.uid()
    )
  );

-- Scoped through campus, never through staff — a policy here that queried
-- public.staff would recurse into staff's own policy, which queries this
-- table right back (Postgres detects this as infinite RLS recursion and
-- errors on every read of either table).
create policy staff_campus_read on public.staff_campus
  for select to authenticated
  using (
    campus_id in (
      select id from public.campus
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or id = any(app.auth_campus_ids()))
    )
  );

create policy designation_tenant_read on public.designation
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create policy department_tenant_read on public.department
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

-- ── D09: leave_type ──────────────────────────────────────────────────

create type public.leave_accrual_method as enum ('annual_grant', 'monthly_accrual', 'none');

create table public.leave_type (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               uuid not null references public.tenant(id) on delete cascade,
  code                    text not null,
  name_en                 text not null,
  name_ur                 text,
  entitlement_days        numeric(5, 2) not null,
  accrual_method          public.leave_accrual_method not null default 'annual_grant',
  is_paid                 boolean not null default true,
  is_encashable           boolean not null default false,
  carry_forward_cap_days  numeric(5, 2),
  doc_required_after_days smallint,
  eligible_genders        text[] not null default array['male', 'female', 'other'],
  eligible_contract_types text[] not null default array['permanent', 'contract', 'probation'],
  effective_from          date not null default current_date,
  is_active               boolean not null default true,
  unique (tenant_id, code, effective_from)
);

create index idx_leave_type_tenant_active on public.leave_type (tenant_id, is_active);

create trigger leave_type_audit after insert or update or delete on public.leave_type
  for each row execute function app.tg_audit_row();

create or replace function public.create_leave_type(
  p_code                    text,
  p_name_en                 text,
  p_entitlement_days        numeric,
  p_name_ur                 text default null,
  p_accrual_method          public.leave_accrual_method default 'annual_grant',
  p_is_paid                 boolean default true,
  p_is_encashable           boolean default false,
  p_carry_forward_cap_days  numeric default null,
  p_doc_required_after_days smallint default null,
  p_eligible_genders        text[] default array['male', 'female', 'other'],
  p_eligible_contract_types text[] default array['permanent', 'contract', 'probation'],
  p_effective_from          date default current_date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- A changed entitlement is a NEW row at a new effective_from, never an
  -- UPDATE — existing balances stay computed against the version that was
  -- in effect when they accrued, and the new value only applies forward.
  insert into public.leave_type (
    tenant_id, code, name_en, name_ur, entitlement_days, accrual_method, is_paid, is_encashable,
    carry_forward_cap_days, doc_required_after_days, eligible_genders, eligible_contract_types, effective_from
  ) values (
    app.auth_tenant_id(), p_code, p_name_en, p_name_ur, p_entitlement_days, p_accrual_method, p_is_paid, p_is_encashable,
    p_carry_forward_cap_days, p_doc_required_after_days, p_eligible_genders, p_eligible_contract_types, p_effective_from
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_leave_type(
  text, text, numeric, text, public.leave_accrual_method, boolean, boolean, numeric, smallint, text[], text[], date
) from public, anon;
grant execute on function public.create_leave_type(
  text, text, numeric, text, public.leave_accrual_method, boolean, boolean, numeric, smallint, text[], text[], date
) to authenticated;

-- One row per code: whichever version's effective_from is the latest one
-- not in the future, filtered to this staff member's gender and contract
-- type.
create or replace function public.eligible_leave_types(p_staff_id uuid)
returns setof public.leave_type
language sql
stable
security definer
set search_path = ''
as $$
  select lt.*
    from public.leave_type lt
    join public.staff s on s.id = p_staff_id
   where lt.tenant_id = s.tenant_id
     and lt.is_active
     and lt.eligible_genders @> array[s.gender::text]
     and lt.eligible_contract_types @> array[s.contract_type]
     and lt.effective_from = (
       select max(lt2.effective_from) from public.leave_type lt2
        where lt2.tenant_id = lt.tenant_id and lt2.code = lt.code and lt2.effective_from <= current_date
     );
$$;

revoke execute on function public.eligible_leave_types(uuid) from public, anon;
grant execute on function public.eligible_leave_types(uuid) to authenticated;

alter table public.leave_type enable row level security;

create policy leave_type_tenant_scope on public.leave_type
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());
