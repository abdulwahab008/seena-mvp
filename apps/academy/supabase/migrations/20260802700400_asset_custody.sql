-- FR-R04: asset issue to department / room / staff custody.
--
-- Custody is a temporal history, not a current_custodian column on the asset:
-- the auditor's question is always "who had it in May". Each stint is a row
-- (issued_on .. returned_on); the partial unique index uq_open_custody allows
-- at most one open row per asset, so issuing a held asset to a second custodian
-- without a return is refused with ASSET_IN_CUSTODY. asset_custody_asof(date)
-- answers the historical question for the whole register (security invoker, so
-- RLS applies).
--
-- Acknowledgement closes the paper loop. By OTP the custodian proves receipt
-- with a six-digit code that is stored only as a hash; the plaintext sits in
-- the dispatch queue asset_custody_otp_dispatch for the SMS worker (service
-- role only; no gateway call is made here, same adapter-less pattern as the
-- other outbound queues). Signature and paper acknowledgements are recorded by
-- an issuer with a reference. Once acknowledged, the row can no longer be
-- edited; the only permitted change is the one-way return stamp.
--
-- Clearance: assert_staff_asset_clearance(staff) raises ASSET_CLEARANCE_BLOCKED
-- listing every asset still in the person's open custody by tag and name. It is
-- wired into the HR exit by a trigger on staff.employment_status ('exited'),
-- so a resignation cannot be completed while a laptop is outstanding.

create type public.asset_custodian_type as enum ('department', 'room', 'staff');
create type public.asset_ack_method as enum ('otp', 'signature', 'paper');

create table public.asset_custody (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  campus_id           uuid not null references public.campus(id) on delete cascade,
  asset_id            uuid not null references public.asset(id) on delete cascade,
  custodian_type      public.asset_custodian_type not null,
  department_id       uuid references public.department(id),
  room_id             uuid references public.room(id),
  staff_id            uuid references public.staff(id),
  issued_on           date not null,
  issued_by           uuid references public.app_user(user_id),
  acknowledged_at     timestamptz,
  ack_method          public.asset_ack_method,
  ack_reference       text,
  returned_on         date,
  condition_on_return text check (condition_on_return is null or condition_on_return in ('good', 'fair', 'damaged', 'lost')),
  remarks             text check (remarks is null or char_length(remarks) <= 500),
  created_at          timestamptz not null default now(),
  constraint chk_custody_target check (
    (custodian_type = 'department' and department_id is not null and room_id is null and staff_id is null)
    or (custodian_type = 'room' and room_id is not null and department_id is null and staff_id is null)
    or (custodian_type = 'staff' and staff_id is not null and department_id is null and room_id is null)),
  constraint chk_custody_dates check (returned_on is null or returned_on >= issued_on),
  constraint chk_custody_ack check ((acknowledged_at is null) = (ack_method is null)),
  constraint chk_custody_return_condition check ((returned_on is null) = (condition_on_return is null))
);
create unique index uq_open_custody on public.asset_custody (asset_id) where returned_on is null;
create index idx_custody_asset_history on public.asset_custody (asset_id, issued_on);
create index idx_custody_staff_open on public.asset_custody (staff_id) where returned_on is null and staff_id is not null;
create index idx_custody_tenant_campus on public.asset_custody (tenant_id, campus_id);
create index idx_custody_department on public.asset_custody (department_id);
create index idx_custody_room on public.asset_custody (room_id);

create table public.asset_custody_otp (
  custody_id uuid primary key references public.asset_custody(id) on delete cascade,
  code_hash  text not null,
  expires_at timestamptz not null,
  attempts   int not null default 0
);

create table public.asset_custody_otp_dispatch (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  custody_id uuid not null references public.asset_custody(id) on delete cascade,
  staff_id   uuid references public.staff(id),
  code       text not null,
  created_at timestamptz not null default clock_timestamp(),
  sent_at    timestamptz
);
create index idx_custody_otp_dispatch_custody on public.asset_custody_otp_dispatch (custody_id);
create index idx_custody_otp_dispatch_tenant on public.asset_custody_otp_dispatch (tenant_id);

create trigger asset_custody_audit after insert or update or delete on public.asset_custody
  for each row execute function app.tg_audit_row();

-- Acknowledged rows are frozen; the only later change is the one-time return stamp. Rows are never deleted.
create or replace function app.tg_asset_custody_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'CUSTODY_HISTORY_IMMUTABLE' using errcode = '42501', hint = 'Custody history is never deleted.';
  end if;
  if old.returned_on is not null then
    raise exception 'CUSTODY_HISTORY_IMMUTABLE' using errcode = '42501', hint = 'A closed custody row cannot change.';
  end if;
  if old.acknowledged_at is not null then
    if new.returned_on is not null
       and new.id = old.id and new.tenant_id = old.tenant_id and new.campus_id = old.campus_id and new.asset_id = old.asset_id
       and new.custodian_type = old.custodian_type
       and new.department_id is not distinct from old.department_id and new.room_id is not distinct from old.room_id
       and new.staff_id is not distinct from old.staff_id and new.issued_on = old.issued_on
       and new.acknowledged_at is not distinct from old.acknowledged_at and new.ack_method is not distinct from old.ack_method
       and new.ack_reference is not distinct from old.ack_reference then
      return new;
    end if;
    raise exception 'CUSTODY_ACKNOWLEDGED_IMMUTABLE' using errcode = '42501', hint = 'An acknowledged custody row cannot be edited.';
  end if;
  return new;
end;
$$;
create trigger trg_asset_custody_guard before update or delete on public.asset_custody
  for each row execute function app.tg_asset_custody_guard();

alter table public.asset_custody enable row level security;
alter table public.asset_custody_otp enable row level security;
alter table public.asset_custody_otp_dispatch enable row level security;
revoke insert, update, delete, truncate on public.asset_custody from anon, authenticated;
revoke all on public.asset_custody_otp, public.asset_custody_otp_dispatch from anon, authenticated;

create policy asset_custody_campus_scope on public.asset_custody for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and ((app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal', 'vice_principal', 'hr_manager')
               and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())))
              or staff_id in (select s.id from public.staff s where s.user_id = (select auth.uid()))));

-- Minimal availability rule; FR-R05 extends it with repair downtime.
create or replace function public.assert_asset_available(p_asset_id uuid, p_on date default current_date)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_status public.asset_status;
begin
  select status into v_status from public.asset where id = p_asset_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ASSET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_status in ('disposed', 'written_off') then
    raise exception 'ASSET_NOT_AVAILABLE' using errcode = '55000', detail = format('status=%s', v_status);
  end if;
end;
$$;
revoke execute on function public.assert_asset_available(uuid, date) from public, anon;
grant execute on function public.assert_asset_available(uuid, date) to authenticated;

create or replace function public.issue_asset_custody(
  p_asset_id uuid, p_custodian_type public.asset_custodian_type, p_department_id uuid default null, p_room_id uuid default null,
  p_staff_id uuid default null, p_issued_on date default null, p_remarks text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_a      public.asset%rowtype;
  v_on     date := coalesce(p_issued_on, app.fn_karachi_today());
  v_id     uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_a from public.asset where id = p_asset_id and tenant_id = v_tenant;
  if not found then
    raise exception 'ASSET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_a.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  perform public.assert_asset_available(p_asset_id, v_on);

  if p_custodian_type = 'department' and not exists (select 1 from public.department where id = p_department_id and tenant_id = v_tenant) then
    raise exception 'CUSTODIAN_NOT_FOUND' using errcode = 'P0002';
  elsif p_custodian_type = 'room' and not exists (select 1 from public.room where id = p_room_id and tenant_id = v_tenant and campus_id = v_a.campus_id) then
    raise exception 'CUSTODIAN_NOT_FOUND' using errcode = 'P0002';
  elsif p_custodian_type = 'staff' and not exists (select 1 from public.staff where id = p_staff_id and tenant_id = v_tenant and employment_status <> 'exited') then
    raise exception 'CUSTODIAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.asset_custody (tenant_id, campus_id, asset_id, custodian_type, department_id, room_id, staff_id, issued_on, issued_by, remarks)
  values (v_tenant, v_a.campus_id, p_asset_id, p_custodian_type,
          case when p_custodian_type = 'department' then p_department_id end,
          case when p_custodian_type = 'room' then p_room_id end,
          case when p_custodian_type = 'staff' then p_staff_id end,
          v_on, (select auth.uid()), nullif(btrim(p_remarks), ''))
  returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'ASSET_IN_CUSTODY' using errcode = '23505', hint = 'Return the asset before issuing it to someone else.';
end;
$$;
revoke execute on function public.issue_asset_custody(uuid, public.asset_custodian_type, uuid, uuid, uuid, date, text) from public, anon;
grant execute on function public.issue_asset_custody(uuid, public.asset_custodian_type, uuid, uuid, uuid, date, text) to authenticated;

create or replace function public.return_asset_custody(p_custody_id uuid, p_condition text, p_returned_on date default null, p_remarks text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_c public.asset_custody%rowtype;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_condition is null or p_condition not in ('good', 'fair', 'damaged', 'lost') then
    raise exception 'CONDITION_INVALID' using errcode = '22023';
  end if;
  select * into v_c from public.asset_custody where id = p_custody_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'CUSTODY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_c.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_c.returned_on is not null then
    raise exception 'ALREADY_RETURNED' using errcode = '55000';
  end if;
  if coalesce(p_returned_on, app.fn_karachi_today()) < v_c.issued_on then
    raise exception 'RETURN_BEFORE_ISSUE' using errcode = '23514';
  end if;
  update public.asset_custody
     set returned_on = coalesce(p_returned_on, app.fn_karachi_today()), condition_on_return = p_condition,
         remarks = coalesce(nullif(btrim(p_remarks), ''), remarks)
   where id = p_custody_id;
end;
$$;
revoke execute on function public.return_asset_custody(uuid, text, date, text) from public, anon;
grant execute on function public.return_asset_custody(uuid, text, date, text) to authenticated;

-- ── acknowledgement ────────────────────────────────────────────────────

create or replace function public.request_custody_ack_otp(p_custody_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_c    public.asset_custody%rowtype;
  v_code text := lpad((floor(random() * 1000000))::int::text, 6, '0');
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_c from public.asset_custody where id = p_custody_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CUSTODY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_c.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_c.acknowledged_at is not null or v_c.returned_on is not null then
    raise exception 'CUSTODY_NOT_ACKNOWLEDGEABLE' using errcode = '55000';
  end if;
  insert into public.asset_custody_otp (custody_id, code_hash, expires_at)
  values (p_custody_id, encode(extensions.digest(v_code || p_custody_id::text, 'sha256'), 'hex'), clock_timestamp() + interval '15 minutes')
  on conflict (custody_id) do update set code_hash = excluded.code_hash, expires_at = excluded.expires_at, attempts = 0;
  insert into public.asset_custody_otp_dispatch (tenant_id, custody_id, staff_id, code) values (v_c.tenant_id, p_custody_id, v_c.staff_id, v_code);
end;
$$;
revoke execute on function public.request_custody_ack_otp(uuid) from public, anon;
grant execute on function public.request_custody_ack_otp(uuid) to authenticated;

create or replace function public.acknowledge_asset_custody(p_custody_id uuid, p_method public.asset_ack_method, p_otp text default null, p_reference text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_c   public.asset_custody%rowtype;
  v_otp public.asset_custody_otp%rowtype;
begin
  select * into v_c from public.asset_custody where id = p_custody_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'CUSTODY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_c.acknowledged_at is not null or v_c.returned_on is not null then
    raise exception 'CUSTODY_NOT_ACKNOWLEDGEABLE' using errcode = '55000';
  end if;

  if p_method = 'otp' then
    -- the custodian (or the issuer sitting with them) enters the code that was sent
    if not (app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal', 'hr_manager')
            or v_c.staff_id in (select s.id from public.staff s where s.user_id = (select auth.uid()))) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    select * into v_otp from public.asset_custody_otp where custody_id = p_custody_id for update;
    if not found or v_otp.expires_at < clock_timestamp() then
      raise exception 'OTP_EXPIRED' using errcode = '55000';
    end if;
    if v_otp.attempts >= 5 then
      raise exception 'OTP_LOCKED' using errcode = '55000';
    end if;
    if p_otp is null or encode(extensions.digest(p_otp || p_custody_id::text, 'sha256'), 'hex') <> v_otp.code_hash then
      update public.asset_custody_otp set attempts = attempts + 1 where custody_id = p_custody_id;
      raise exception 'OTP_INVALID' using errcode = '28000';
    end if;
    delete from public.asset_custody_otp where custody_id = p_custody_id;
  else
    if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal', 'hr_manager') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if btrim(coalesce(p_reference, '')) = '' then
      raise exception 'REFERENCE_REQUIRED' using errcode = '23514', hint = 'Record the signed form or paper register reference.';
    end if;
  end if;

  update public.asset_custody
     set acknowledged_at = clock_timestamp(), ack_method = p_method, ack_reference = nullif(btrim(p_reference), '')
   where id = p_custody_id;
end;
$$;
revoke execute on function public.acknowledge_asset_custody(uuid, public.asset_ack_method, text, text) from public, anon;
grant execute on function public.acknowledge_asset_custody(uuid, public.asset_ack_method, text, text) to authenticated;

-- ── who held it on a date ──────────────────────────────────────────────
-- Security invoker: the caller's RLS on asset_custody applies.

create or replace function public.v_asset_custody_asof(p_date date)
returns table (
  asset_id uuid, tag_no text, asset_name text, custody_id uuid, custodian_type public.asset_custodian_type,
  custodian_name text, issued_on date, returned_on date
)
language sql
stable
set search_path = ''
as $$
  select c.asset_id, a.tag_no, a.name, c.id, c.custodian_type,
         coalesce(d.name_en, r.name, s.full_name) as custodian_name, c.issued_on, c.returned_on
    from public.asset_custody c
    join public.asset a on a.id = c.asset_id
    left join public.department d on d.id = c.department_id
    left join public.room r on r.id = c.room_id
    left join public.staff s on s.id = c.staff_id
   where c.issued_on <= p_date and (c.returned_on is null or c.returned_on > p_date);
$$;
revoke execute on function public.v_asset_custody_asof(date) from public, anon;
grant execute on function public.v_asset_custody_asof(date) to authenticated;

-- ── HR exit clearance ──────────────────────────────────────────────────

create or replace function app.fn_staff_open_assets(p_staff_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('custody_id', c.id, 'asset_id', a.id, 'tag_no', a.tag_no, 'name', a.name) order by a.tag_no), '[]'::jsonb)
    from public.asset_custody c join public.asset a on a.id = c.asset_id
   where c.staff_id = p_staff_id and c.returned_on is null;
$$;
revoke execute on function app.fn_staff_open_assets(uuid) from public, anon, authenticated;

create or replace function public.assert_staff_asset_clearance(p_staff_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_assets jsonb;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'hr_manager', 'accountant', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.staff where id = p_staff_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_assets := app.fn_staff_open_assets(p_staff_id);
  if jsonb_array_length(v_assets) > 0 then
    raise exception 'ASSET_CLEARANCE_BLOCKED' using errcode = '55000',
      detail = (select string_agg(x ->> 'tag_no' || ' ' || (x ->> 'name'), '; ') from jsonb_array_elements(v_assets) x),
      hint = 'Return the listed assets before the exit can be cleared.';
  end if;
end;
$$;
revoke execute on function public.assert_staff_asset_clearance(uuid) from public, anon;
grant execute on function public.assert_staff_asset_clearance(uuid) to authenticated;

-- The same check, as a report for the HR exit checklist screen.
create or replace function public.staff_asset_clearance(p_staff_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_assets jsonb;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'hr_manager', 'accountant', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.staff where id = p_staff_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_assets := app.fn_staff_open_assets(p_staff_id);
  return jsonb_build_object('staff_id', p_staff_id, 'cleared', jsonb_array_length(v_assets) = 0, 'assets', v_assets);
end;
$$;
revoke execute on function public.staff_asset_clearance(uuid) from public, anon;
grant execute on function public.staff_asset_clearance(uuid) to authenticated;

-- Completing an exit (employment_status -> 'exited') is blocked while assets are outstanding.
create or replace function app.tg_staff_exit_asset_clearance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_assets jsonb;
begin
  v_assets := app.fn_staff_open_assets(new.id);
  if jsonb_array_length(v_assets) > 0 then
    raise exception 'ASSET_CLEARANCE_BLOCKED' using errcode = '55000',
      detail = (select string_agg(x ->> 'tag_no' || ' ' || (x ->> 'name'), '; ') from jsonb_array_elements(v_assets) x),
      hint = 'Return the listed assets before the exit can be cleared.';
  end if;
  return new;
end;
$$;
revoke execute on function app.tg_staff_exit_asset_clearance() from public, anon, authenticated;
create trigger trg_staff_exit_asset_clearance before update of employment_status on public.staff
  for each row when (new.employment_status = 'exited' and old.employment_status is distinct from 'exited')
  execute function app.tg_staff_exit_asset_clearance();
