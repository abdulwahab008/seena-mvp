-- FR-D16: staff exit with a clearance checklist.
--
-- The staff row is NEVER deleted: marks, fee receipts, certificates and audit
-- entries reference it for good, so exit is a status flip (employment_status
-- 'exited') plus an access revocation.
--
--   * initiate_staff_exit() creates the exit, snapshots the contractual notice
--     (staff_contract.notice_period_days at the notice date), computes the
--     notice shortfall for a resignation (carried into the final settlement,
--     FR-D17) and copies the tenant's clearance templates into per-exit items.
--   * Only the department that owns an item may mark it cleared (library dues:
--     the Librarian; fee float: the Accountant ...). HR or the Owner may record
--     a WAIVER instead, with a reason of at least 10 characters.
--   * complete_staff_exit() refuses while any mandatory item is neither cleared
--     nor waived, naming the outstanding items, and refuses before the last
--     working date (except termination and death).
--   * Revocation is event-driven, not left to natural token expiry: completing
--     the exit sets the login to 'terminated' (which bumps app_user.claims_version,
--     so a cached token is rejected on its very next query with TOKEN_EPOCH_STALE)
--     and deletes the person's auth sessions (their refresh tokens go with them).
--     That is immediate, which satisfies "within 15 minutes". It happens inside
--     the same transaction as the status flip, so there is no window in which the
--     exit is complete but access remains; no separate Edge Function is needed.
--   * A daily job (04:00 PKT) opens a contract_expiry exit for every active staff
--     member whose fixed-term contract has lapsed with no successor.

create type public.staff_exit_type as enum ('resignation', 'termination', 'contract_expiry', 'retirement', 'death');
create type public.staff_exit_status as enum ('initiated', 'clearance', 'completed');

create table public.clearance_item_template (
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  item_code    text not null check (item_code ~ '^[a-z][a-z0-9_]{1,39}$'),
  item_name    text not null,
  owner_role   text not null,
  is_mandatory boolean not null default true,
  sort_order   smallint not null default 0,
  primary key (tenant_id, item_code)
);
create trigger clearance_item_template_audit after insert or update or delete on public.clearance_item_template
  for each row execute function app.tg_audit_row();
alter table public.clearance_item_template enable row level security;
create policy clearance_template_read on public.clearance_item_template for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'principal', 'accountant', 'librarian'));

create or replace function app.tg_seed_clearance_templates()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.clearance_item_template (tenant_id, item_code, item_name, owner_role, sort_order) values
    (new.id, 'library_dues', 'Library dues', 'librarian', 1),
    (new.id, 'fee_counter_float', 'Fee counter float and receipts', 'accountant', 2),
    (new.id, 'loans_advances', 'Staff loans and advances settled', 'accountant', 3),
    (new.id, 'it_assets', 'Laptop, keys and IT assets returned', 'hr_manager', 4),
    (new.id, 'id_card_uniform', 'ID card and uniform returned', 'hr_manager', 5),
    (new.id, 'academic_handover', 'Marks, registers and files handed over', 'principal', 6)
  on conflict do nothing;
  return new;
end;
$$;
create trigger tenant_seed_clearance_templates after insert on public.tenant
  for each row execute function app.tg_seed_clearance_templates();
insert into public.clearance_item_template (tenant_id, item_code, item_name, owner_role, sort_order)
select t.id, v.code, v.name, v.owner_role, v.sort_order
  from public.tenant t
 cross join (values
   ('library_dues', 'Library dues', 'librarian', 1), ('fee_counter_float', 'Fee counter float and receipts', 'accountant', 2),
   ('loans_advances', 'Staff loans and advances settled', 'accountant', 3), ('it_assets', 'Laptop, keys and IT assets returned', 'hr_manager', 4),
   ('id_card_uniform', 'ID card and uniform returned', 'hr_manager', 5), ('academic_handover', 'Marks, registers and files handed over', 'principal', 6)
 ) as v(code, name, owner_role, sort_order)
on conflict do nothing;

create table public.staff_exit (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenant(id) on delete cascade,
  campus_id             uuid not null references public.campus(id) on delete cascade,
  staff_id              uuid not null references public.staff(id),
  exit_type             public.staff_exit_type not null,
  notice_date           date,
  last_working_date     date not null,
  notice_period_days    smallint,
  notice_shortfall_days smallint not null default 0 check (notice_shortfall_days >= 0),
  status                public.staff_exit_status not null default 'initiated',
  reason                text,
  initiated_by          uuid references public.app_user(user_id),
  initiated_at          timestamptz not null default now(),
  completed_by          uuid references public.app_user(user_id),
  completed_at          timestamptz,
  constraint chk_exit_notice_before_lwd check (notice_date is null or last_working_date >= notice_date),
  constraint chk_exit_completed check ((status = 'completed') = (completed_at is not null))
);
create unique index uq_staff_exit_open on public.staff_exit (staff_id) where status <> 'completed';
create index idx_staff_exit_tenant_status on public.staff_exit (tenant_id, status);
create index idx_staff_exit_campus on public.staff_exit (campus_id);
create index idx_staff_exit_staff on public.staff_exit (staff_id);
create trigger staff_exit_audit after insert or update or delete on public.staff_exit
  for each row execute function app.tg_audit_row();

create table public.staff_clearance_item (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  exit_id       uuid not null references public.staff_exit(id) on delete cascade,
  item_code     text not null,
  item_name     text not null,
  owner_role    text not null,
  is_mandatory  boolean not null default true,
  sort_order    smallint not null default 0,
  cleared_by    uuid references public.app_user(user_id),
  cleared_at    timestamptz,
  waiver_reason text,
  waived_by     uuid references public.app_user(user_id),
  waived_at     timestamptz,
  constraint uq_clearance_item unique (exit_id, item_code),
  constraint chk_clearance_one_resolution check (not (cleared_at is not null and waived_at is not null)),
  constraint chk_waiver_reason_length check (waiver_reason is null or char_length(btrim(waiver_reason)) >= 10)
);
create index idx_clearance_item_exit on public.staff_clearance_item (exit_id);
create index idx_clearance_item_tenant on public.staff_clearance_item (tenant_id);
create trigger staff_clearance_item_audit after insert or update or delete on public.staff_clearance_item
  for each row execute function app.tg_audit_row();

alter table public.staff_exit enable row level security;
alter table public.staff_clearance_item enable row level security;
create policy exit_read on public.staff_exit for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'principal', 'vice_principal', 'accountant', 'librarian')
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
create policy clearance_item_read on public.staff_clearance_item for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.staff_exit e where e.id = exit_id));
-- All writes go through the SECURITY DEFINER functions below.
revoke insert, update, delete on public.staff_exit, public.staff_clearance_item from authenticated, anon;

-- ── creation ──────────────────────────────────────────────────────────────

create or replace function app.fn_create_staff_exit(
  p_staff_id uuid, p_exit_type public.staff_exit_type, p_notice_date date, p_last_working_date date, p_reason text, p_actor uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff     public.staff%rowtype;
  v_contract  public.staff_contract%rowtype;
  v_notice    smallint;
  v_shortfall smallint := 0;
  v_id        uuid;
begin
  select * into v_staff from public.staff where id = p_staff_id;
  if not found then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_staff.employment_status = 'exited' then
    raise exception 'ALREADY_EXITED' using errcode = '55000';
  end if;
  if p_last_working_date is null then
    raise exception 'LAST_WORKING_DATE_REQUIRED' using errcode = '22023';
  end if;
  if p_notice_date is not null and p_last_working_date < p_notice_date then
    raise exception 'LAST_WORKING_DATE_BEFORE_NOTICE' using errcode = '22023';
  end if;

  select * into v_contract from public.staff_contract
   where staff_id = p_staff_id and start_date <= coalesce(p_notice_date, p_last_working_date)
     and (end_date is null or end_date >= coalesce(p_notice_date, p_last_working_date))
   limit 1;
  v_notice := v_contract.notice_period_days;
  if p_exit_type = 'resignation' and p_notice_date is not null and v_notice is not null then
    v_shortfall := greatest(0, v_notice - (p_last_working_date - p_notice_date))::smallint;
  end if;

  insert into public.staff_exit (tenant_id, campus_id, staff_id, exit_type, notice_date, last_working_date, notice_period_days, notice_shortfall_days, reason, initiated_by)
  values (v_staff.tenant_id, v_staff.campus_id, p_staff_id, p_exit_type, p_notice_date, p_last_working_date, v_notice, v_shortfall, nullif(btrim(p_reason), ''), p_actor)
  returning id into v_id;

  insert into public.staff_clearance_item (tenant_id, exit_id, item_code, item_name, owner_role, is_mandatory, sort_order)
  select v_staff.tenant_id, v_id, t.item_code, t.item_name, t.owner_role, t.is_mandatory, t.sort_order
    from public.clearance_item_template t where t.tenant_id = v_staff.tenant_id;
  return v_id;
exception when unique_violation then
  raise exception 'EXIT_ALREADY_OPEN' using errcode = '23505';
end;
$$;
revoke execute on function app.fn_create_staff_exit(uuid, public.staff_exit_type, date, date, text, uuid) from public, anon, authenticated;

create or replace function public.initiate_staff_exit(
  p_staff_id uuid, p_exit_type public.staff_exit_type, p_notice_date date default null, p_last_working_date date default null, p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff public.staff%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_staff from public.staff where id = p_staff_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() = 'hr_manager' and not (v_staff.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return app.fn_create_staff_exit(p_staff_id, p_exit_type, p_notice_date, p_last_working_date, p_reason, (select auth.uid()));
end;
$$;
revoke execute on function public.initiate_staff_exit(uuid, public.staff_exit_type, date, date, text) from public, anon;
grant execute on function public.initiate_staff_exit(uuid, public.staff_exit_type, date, date, text) to authenticated;

-- ── clearing and waiving ──────────────────────────────────────────────────

create or replace function app.fn_exit_for_update(p_exit_id uuid)
returns public.staff_exit
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exit public.staff_exit%rowtype;
begin
  select * into v_exit from public.staff_exit where id = p_exit_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'EXIT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_exit.status = 'completed' then
    raise exception 'EXIT_ALREADY_COMPLETED' using errcode = '55000';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_exit.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return v_exit;
end;
$$;
revoke execute on function app.fn_exit_for_update(uuid) from public, anon, authenticated;

create or replace function public.clear_exit_item(p_exit_id uuid, p_item_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exit public.staff_exit%rowtype;
  v_item public.staff_clearance_item%rowtype;
begin
  v_exit := app.fn_exit_for_update(p_exit_id);
  select * into v_item from public.staff_clearance_item where exit_id = p_exit_id and item_code = p_item_code for update;
  if not found then
    raise exception 'ITEM_NOT_FOUND' using errcode = 'P0002';
  end if;
  -- Only the owning department signs an item off.
  if app.auth_role() <> v_item.owner_role then
    raise exception 'NOT_ITEM_OWNER' using errcode = '42501';
  end if;
  update public.staff_clearance_item
     set cleared_by = (select auth.uid()), cleared_at = clock_timestamp(), waiver_reason = null, waived_by = null, waived_at = null
   where id = v_item.id;
  update public.staff_exit set status = 'clearance' where id = p_exit_id and status = 'initiated';
end;
$$;
revoke execute on function public.clear_exit_item(uuid, text) from public, anon;
grant execute on function public.clear_exit_item(uuid, text) to authenticated;

create or replace function public.waive_exit_item(p_exit_id uuid, p_item_code text, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exit public.staff_exit%rowtype;
begin
  v_exit := app.fn_exit_for_update(p_exit_id);
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'WAIVER_REASON_TOO_SHORT' using errcode = '22023';
  end if;
  update public.staff_clearance_item
     set waiver_reason = btrim(p_reason), waived_by = (select auth.uid()), waived_at = clock_timestamp(), cleared_by = null, cleared_at = null
   where exit_id = p_exit_id and item_code = p_item_code;
  if not found then
    raise exception 'ITEM_NOT_FOUND' using errcode = 'P0002';
  end if;
  update public.staff_exit set status = 'clearance' where id = p_exit_id and status = 'initiated';
end;
$$;
revoke execute on function public.waive_exit_item(uuid, text, text) from public, anon;
grant execute on function public.waive_exit_item(uuid, text, text) to authenticated;

create or replace function public.get_outstanding_clearance_items(p_exit_id uuid)
returns table (item_code text, item_name text, owner_role text)
language sql
stable
security definer
set search_path = ''
as $$
  select i.item_code, i.item_name, i.owner_role
    from public.staff_clearance_item i
   where i.exit_id = p_exit_id and i.tenant_id = app.auth_tenant_id()
     and i.is_mandatory and i.cleared_at is null and i.waived_at is null
   order by i.sort_order, i.item_name;
$$;
revoke execute on function public.get_outstanding_clearance_items(uuid) from public, anon;
grant execute on function public.get_outstanding_clearance_items(uuid) to authenticated;

-- ── completion and revocation ─────────────────────────────────────────────

create or replace function public.complete_staff_exit(p_exit_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exit        public.staff_exit%rowtype;
  v_staff       public.staff%rowtype;
  v_outstanding text;
begin
  v_exit := app.fn_exit_for_update(p_exit_id);
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select string_agg(o.item_name, ', ' order by o.item_name) into v_outstanding from public.get_outstanding_clearance_items(p_exit_id) o;
  if v_outstanding is not null then
    raise exception 'CLEARANCE_OUTSTANDING: %', v_outstanding using errcode = '55000';
  end if;
  -- Access must not be cut before the person's last day (termination and death are immediate).
  if v_exit.exit_type not in ('termination', 'death') and v_exit.last_working_date > app.fn_karachi_today() then
    raise exception 'LAST_WORKING_DATE_NOT_REACHED' using errcode = '55000';
  end if;

  select * into v_staff from public.staff where id = v_exit.staff_id for update;
  update public.staff set employment_status = 'exited' where id = v_staff.id;
  update public.staff_exit set status = 'completed', completed_at = clock_timestamp(), completed_by = (select auth.uid()) where id = p_exit_id;
  perform app.fn_revoke_staff_access(v_staff.user_id);
end;
$$;
revoke execute on function public.complete_staff_exit(uuid) from public, anon;
grant execute on function public.complete_staff_exit(uuid) to authenticated;

-- Event-driven revocation. app_user.status -> 'terminated' bumps claims_version
-- (FR-A13), so a token minted before this instant is refused on its next query;
-- deleting the sessions stops any refresh. The staff row itself is untouched.
create or replace function app.fn_revoke_staff_access(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_user_id is null then
    return;
  end if;
  update public.app_user set status = 'terminated' where user_id = p_user_id and status <> 'terminated';
  delete from auth.sessions where user_id = p_user_id;
end;
$$;
revoke execute on function app.fn_revoke_staff_access(uuid) from public, anon, authenticated;

-- ── contract-expiry exits (daily 04:00 PKT) ───────────────────────────────

create or replace function public.initiate_contract_expiry_exits(p_today date default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := coalesce(p_today, app.fn_karachi_today());
  r record;
  v_n integer := 0;
begin
  for r in
    select s.id as staff_id, last_c.end_date
      from public.staff s
      join lateral (select c.end_date from public.staff_contract c where c.staff_id = s.id order by c.start_date desc limit 1) last_c on true
     where s.employment_status in ('active', 'on_leave', 'suspended')
       and last_c.end_date is not null and last_c.end_date < v_today
       and not exists (select 1 from public.staff_exit e where e.staff_id = s.id)
  loop
    perform app.fn_create_staff_exit(r.staff_id, 'contract_expiry', null, r.end_date, 'Fixed-term contract ended', null);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.initiate_contract_expiry_exits(date) from public, anon, authenticated;

-- 04:00 PKT = 23:00 UTC the day before.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('contract-expiry-exit', '0 23 * * *', 'select public.initiate_contract_expiry_exits();');
  end if;
exception
  when others then null;
end;
$$;
