-- FR-P04: stop allocation drives the transport fee.
--
-- A student is allocated to a pickup stop (and a drop stop) on one route from a
-- date. The fee follows from the stop's fare slab; nothing is typed per student.
--
--  * ends_on is the LAST day of service. The overlap exclusion constraint works
--    on the half-open range [starts_on, ends_on + 1), so a move on 2026-10-16
--    (old ends 10-15, new starts 10-16) never overlaps and never leaves a gap.
--  * Seat capacity is the seat count of the vehicle assigned to the route on the
--    start date (not the route's nominal capacity). The route row is locked while
--    counting, so two clerks cannot both take the last seat. A full route raises
--    ROUTE_FULL (n/n); the student can then be queued on transport_waitlist.
--  * Charges post to fee_ledger (head code TRANSPORT) as debit charges tagged
--    source_type 'transport_allocation'. One line per allocation per month, made
--    idempotent by a unique index. Pro-rata is a tenant setting
--    (transport.prorate: 'prorata' | 'full_month', default full_month); pro-rata
--    prices the days of service in the month over the days in the month,
--    rounded to whole rupees. When a student has several allocations in a month
--    (a mid-month move), their charges never total more than the dearest slab.
--    Closing an allocation re-prices its last month with one correcting line.
--  * The monthly job runs on day 1 at 20:15 UTC, ahead of challan generation, so
--    a month's bus fee cannot slip onto the next challan. Charges are ledger
--    debits (they raise the student's balance and arrears); the challan
--    generator itself is plan-line driven and is not modified here.

create table public.transport_allocation (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  student_id     uuid not null references public.student(id),
  enrolment_id   uuid not null references public.enrolment(id),
  route_id       uuid not null references public.transport_route(id),
  pickup_stop_id uuid not null references public.transport_stop(id),
  drop_stop_id   uuid not null references public.transport_stop(id),
  fare_slab_id   uuid not null references public.transport_fare_slab(id),
  starts_on      date not null,
  ends_on        date,
  allocated_by   uuid references auth.users(id),
  created_at     timestamptz not null default now(),
  constraint chk_alloc_span check (ends_on is null or ends_on >= starts_on),
  constraint ex_transport_alloc_no_overlap exclude using gist (
    student_id with =, daterange(starts_on, coalesce(ends_on + 1, 'infinity'), '[)') with &&)
);
create index idx_alloc_route_dates on public.transport_allocation (route_id, starts_on, ends_on);
create index idx_alloc_scope on public.transport_allocation (tenant_id, campus_id);
create index idx_alloc_enrolment on public.transport_allocation (enrolment_id);
create index idx_alloc_pickup on public.transport_allocation (pickup_stop_id);
create index idx_alloc_drop on public.transport_allocation (drop_stop_id);
create index idx_alloc_slab on public.transport_allocation (fare_slab_id);

create table public.transport_waitlist (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant(id) on delete cascade,
  campus_id uuid not null references public.campus(id) on delete cascade,
  route_id  uuid not null references public.transport_route(id) on delete cascade,
  student_id uuid not null references public.student(id) on delete cascade,
  queued_at timestamptz not null default clock_timestamp(),
  queued_by uuid references auth.users(id),
  constraint uq_transport_waitlist unique (route_id, student_id)
);
create index idx_waitlist_scope on public.transport_waitlist (tenant_id, campus_id, route_id, queued_at);
create index idx_waitlist_student on public.transport_waitlist (student_id);

-- One first charge line per allocation per month.
create unique index fee_ledger_transport_month_uq on public.fee_ledger (source_id, value_date) where source_type = 'transport_allocation';

create trigger transport_allocation_audit after insert or update or delete on public.transport_allocation
  for each row execute function app.tg_audit_row();
create trigger transport_waitlist_audit after insert or update or delete on public.transport_waitlist
  for each row execute function app.tg_audit_row();

-- Routes a signed-in parent's or student's own allocations ride today.
create or replace function app.fn_parent_route_ids()
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct a.route_id), '{}'::uuid[])
    from public.transport_allocation a
   where a.tenant_id = app.auth_tenant_id()
     and (a.student_id = any (app.auth_guardian_student_ids()) or a.student_id = public.my_student_id())
     and (a.ends_on is null or a.ends_on >= app.fn_karachi_today());
$$;
revoke execute on function app.fn_parent_route_ids() from public, anon;
grant execute on function app.fn_parent_route_ids() to authenticated;

alter table public.transport_allocation enable row level security;
alter table public.transport_waitlist enable row level security;
create policy transport_allocation_campus_scope on public.transport_allocation for select to authenticated
  using (app.fn_campus_scope(tenant_id, campus_id) and app.auth_role() not in ('parent', 'student'));
create policy transport_allocation_parent_read on public.transport_allocation for select to authenticated
  using (tenant_id = app.auth_tenant_id() and (student_id = any (app.auth_guardian_student_ids()) or student_id = public.my_student_id()));
create policy transport_waitlist_campus_scope on public.transport_waitlist for select to authenticated
  using (app.fn_campus_scope(tenant_id, campus_id) and app.auth_role() not in ('parent', 'student'));
create policy transport_route_parent_read on public.transport_route for select to authenticated
  using (tenant_id = app.auth_tenant_id() and id = any (app.fn_parent_route_ids()));
create policy transport_stop_parent_read on public.transport_stop for select to authenticated
  using (tenant_id = app.auth_tenant_id() and route_id = any (app.fn_parent_route_ids()));

-- ── Pricing ─────────────────────────────────────────────────────────────────
create or replace function app.fn_transport_fee_head(p_tenant uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.fee_head where tenant_id = p_tenant and lower(code) = 'transport';
  if v_id is null then
    insert into public.fee_head (tenant_id, code, name_en, name_ur, default_frequency)
    values (p_tenant, 'TRANSPORT', 'Transport fee', 'ٹرانسپورٹ فیس', 'monthly')
    on conflict (tenant_id, lower(code)) do nothing;
    select id into v_id from public.fee_head where tenant_id = p_tenant and lower(code) = 'transport';
  end if;
  return v_id;
end;
$$;
revoke execute on function app.fn_transport_fee_head(uuid) from public, anon, authenticated;

-- What one allocation costs for one month, before the per-student cap.
create or replace function app.fn_prorate_transport(p_alloc public.transport_allocation, p_month date)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ms     date := date_trunc('month', p_month)::date;
  v_me     date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_from   date := greatest(p_alloc.starts_on, v_ms);
  v_to     date := least(coalesce(p_alloc.ends_on, v_me), v_me);
  v_amount bigint;
  v_policy text;
begin
  if v_to < v_from then
    return 0;
  end if;
  v_amount := app.fn_slab_amount(p_alloc.fare_slab_id, v_from);
  v_policy := coalesce(app.fn_transport_setting(p_alloc.tenant_id, 'transport.prorate', '"full_month"'::jsonb) #>> '{}', 'full_month');
  if v_policy = 'full_month' then
    return v_amount;
  end if;
  return (round((v_amount::numeric * (v_to - v_from + 1) / (v_me - v_ms + 1)) / 100) * 100)::bigint;
end;
$$;
revoke execute on function app.fn_prorate_transport(public.transport_allocation, date) from public, anon, authenticated;

create or replace function public.prorate_transport_fee(p_allocation_id uuid, p_month date)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_a public.transport_allocation%rowtype;
begin
  select * into v_a from public.transport_allocation where id = p_allocation_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ALLOCATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  return app.fn_prorate_transport(v_a, p_month);
end;
$$;
revoke execute on function public.prorate_transport_fee(uuid, date) from public, anon;
grant execute on function public.prorate_transport_fee(uuid, date) to authenticated;

-- Net amount already in the ledger for an allocation and month.
create or replace function app.fn_transport_posted(p_alloc_id uuid, p_month date)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(case when direction = 'debit' then amount_paisa else -amount_paisa end), 0)::bigint
    from public.fee_ledger
   where source_id = p_alloc_id and source_type in ('transport_allocation', 'transport_allocation_adj') and value_date = date_trunc('month', p_month)::date;
$$;
revoke execute on function app.fn_transport_posted(uuid, date) from public, anon, authenticated;

-- Brings the ledger for one allocation and month to the amount it should be.
-- Returns the number of ledger lines written (0 or 1).
create or replace function app.fn_transport_post_allocation(p_alloc_id uuid, p_month date)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a        public.transport_allocation%rowtype;
  v_ms       date := date_trunc('month', p_month)::date;
  v_me       date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_desired  bigint;
  v_existing bigint;
  v_others   bigint;
  v_cap      bigint;
  v_enrol    public.enrolment%rowtype;
  v_head     uuid;
begin
  select * into v_a from public.transport_allocation where id = p_alloc_id;
  if not found then
    return 0;
  end if;
  v_desired := app.fn_prorate_transport(v_a, v_ms);
  v_existing := app.fn_transport_posted(p_alloc_id, v_ms);
  if v_desired = 0 and v_existing = 0 then
    return 0;
  end if;
  -- Cap: all of the student's allocations in the month together never exceed the dearest slab.
  select coalesce(sum(app.fn_transport_posted(o.id, v_ms)), 0) into v_others
    from public.transport_allocation o
   where o.student_id = v_a.student_id and o.id <> v_a.id and o.starts_on <= v_me and coalesce(o.ends_on, v_me) >= v_ms;
  select max(app.fn_slab_amount(o.fare_slab_id, greatest(o.starts_on, v_ms))) into v_cap
    from public.transport_allocation o
   where o.student_id = v_a.student_id and o.starts_on <= v_me and coalesce(o.ends_on, v_me) >= v_ms;
  v_desired := least(v_desired, greatest(0, coalesce(v_cap, v_desired) - v_others));
  if v_desired = v_existing then
    return 0;
  end if;
  select * into v_enrol from public.enrolment where id = v_a.enrolment_id;
  v_head := app.fn_transport_fee_head(v_a.tenant_id);
  if v_existing = 0 then
    insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction, value_date, source_type, source_id, created_by)
    values (v_a.tenant_id, v_a.campus_id, v_a.enrolment_id, v_enrol.session_id, 'charge', v_head, v_desired, 'debit', v_ms, 'transport_allocation', v_a.id, (select au.user_id from public.app_user au where au.user_id = (select auth.uid())));
  else
    insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction, value_date, source_type, source_id, reason, created_by)
    values (v_a.tenant_id, v_a.campus_id, v_a.enrolment_id, v_enrol.session_id, 'adjustment', v_head, abs(v_desired - v_existing),
            case when v_desired > v_existing then 'debit'::public.fee_ledger_direction else 'credit'::public.fee_ledger_direction end,
            v_ms, 'transport_allocation_adj', v_a.id, 'Transport fee re-priced after a change of stop or end of service', (select au.user_id from public.app_user au where au.user_id = (select auth.uid())));
  end if;
  return 1;
end;
$$;
revoke execute on function app.fn_transport_post_allocation(uuid, date) from public, anon, authenticated;

-- Posts the month for every allocation that overlaps it. p_tenant null = every tenant.
create or replace function app.fn_post_transport_month(p_tenant uuid, p_month date)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ms date := date_trunc('month', p_month)::date;
  v_me date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  r    record;
  v_n  int := 0;
begin
  for r in
    select a.id from public.transport_allocation a
     where (p_tenant is null or a.tenant_id = p_tenant) and a.starts_on <= v_me and coalesce(a.ends_on, v_me) >= v_ms
     order by a.starts_on, a.created_at
  loop
    v_n := v_n + app.fn_transport_post_allocation(r.id, v_ms);
  end loop;
  return v_n;
end;
$$;
revoke execute on function app.fn_post_transport_month(uuid, date) from public, anon, authenticated;

create or replace function public.post_transport_charges(p_month date)
returns int
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal', 'transport_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return app.fn_post_transport_month(app.auth_tenant_id(), p_month);
end;
$$;
revoke execute on function public.post_transport_charges(date) from public, anon;
grant execute on function public.post_transport_charges(date) to authenticated;

create or replace function public.transport_fee_monthly_post(p_month date default null)
returns int
language sql
security definer
set search_path = ''
as $$
  select app.fn_post_transport_month(null, coalesce(p_month, app.fn_karachi_today()));
$$;
revoke execute on function public.transport_fee_monthly_post(date) from public, anon, authenticated;
grant execute on function public.transport_fee_monthly_post(date) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('transport_fee_monthly_post', '15 20 1 * *', 'select public.transport_fee_monthly_post();');
  end if;
exception
  when others then null;
end;
$$;

-- ── Allocation ──────────────────────────────────────────────────────────────
create or replace function app.fn_transport_allocator_check()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager', 'accountant', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function app.fn_transport_allocator_check() from public, anon, authenticated;

-- Core insert shared by allocate and move. Checks stops, seats and posts the start month.
create or replace function app.fn_transport_allocate(p_student_id uuid, p_pickup_stop uuid, p_drop_stop uuid, p_from date, p_ignore_student_seat boolean)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enrol   public.enrolment%rowtype;
  v_pick    public.transport_stop%rowtype;
  v_drop    public.transport_stop%rowtype;
  v_route   public.transport_route%rowtype;
  v_seats   int;
  v_taken   int;
  v_id      uuid;
begin
  select * into v_enrol from public.enrolment
   where student_id = p_student_id and tenant_id = app.auth_tenant_id() and status = 'active' and deleted_at is null
   order by joined_on desc limit 1;
  if not found then
    raise exception 'NO_ACTIVE_ENROLMENT' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_enrol.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_pick from public.transport_stop where id = p_pickup_stop and tenant_id = v_enrol.tenant_id and campus_id = v_enrol.campus_id;
  select * into v_drop from public.transport_stop where id = coalesce(p_drop_stop, p_pickup_stop) and tenant_id = v_enrol.tenant_id and campus_id = v_enrol.campus_id;
  if v_pick.id is null or v_drop.id is null then
    raise exception 'STOP_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_pick.route_id <> v_drop.route_id then
    raise exception 'STOPS_ON_DIFFERENT_ROUTES' using errcode = '22023';
  end if;
  if v_pick.fare_slab_id is null then
    raise exception 'STOP_HAS_NO_FARE' using errcode = '22023';
  end if;
  select * into v_route from public.transport_route where id = v_pick.route_id for update;
  if not v_route.active then
    raise exception 'ROUTE_INACTIVE' using errcode = '22023';
  end if;
  select v.seat_capacity into v_seats
    from public.transport_trip_assignment ta
    join public.transport_vehicle v on v.id = ta.vehicle_id
   where ta.route_id = v_route.id and ta.effective_from <= p_from and (ta.effective_to is null or ta.effective_to >= p_from)
   limit 1;
  if v_seats is null then
    raise exception 'ROUTE_NO_VEHICLE' using errcode = '22023';
  end if;
  select count(*) into v_taken from public.transport_allocation a
   where a.route_id = v_route.id and a.starts_on <= p_from and (a.ends_on is null or a.ends_on >= p_from)
     and not (p_ignore_student_seat and a.student_id = p_student_id);
  if v_taken >= v_seats then
    raise exception 'ROUTE_FULL (%/%)', v_taken, v_seats using errcode = '53400';
  end if;
  insert into public.transport_allocation (tenant_id, campus_id, student_id, enrolment_id, route_id, pickup_stop_id, drop_stop_id, fare_slab_id, starts_on, allocated_by)
  values (v_enrol.tenant_id, v_enrol.campus_id, p_student_id, v_enrol.id, v_route.id, v_pick.id, v_drop.id, v_pick.fare_slab_id, p_from, (select auth.uid()))
  returning id into v_id;
  delete from public.transport_waitlist where route_id = v_route.id and student_id = p_student_id;
  if date_trunc('month', p_from) <= date_trunc('month', app.fn_karachi_today()) then
    perform app.fn_transport_post_allocation(v_id, p_from);
  end if;
  return v_id;
exception when exclusion_violation then
  raise exception 'ALLOCATION_OVERLAP' using errcode = '23P01';
end;
$$;
revoke execute on function app.fn_transport_allocate(uuid, uuid, uuid, date, boolean) from public, anon, authenticated;

create or replace function public.allocate_transport(p_student_id uuid, p_pickup_stop uuid, p_drop_stop uuid, p_from date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.fn_transport_allocator_check();
  return app.fn_transport_allocate(p_student_id, p_pickup_stop, p_drop_stop, p_from, false);
end;
$$;
revoke execute on function public.allocate_transport(uuid, uuid, uuid, date) from public, anon;
grant execute on function public.allocate_transport(uuid, uuid, uuid, date) to authenticated;

-- Ends service on p_last_day and re-prices that month.
create or replace function app.fn_transport_close(p_alloc_id uuid, p_last_day date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.transport_allocation set ends_on = p_last_day where id = p_alloc_id;
  perform app.fn_transport_post_allocation(p_alloc_id, p_last_day);
end;
$$;
revoke execute on function app.fn_transport_close(uuid, date) from public, anon, authenticated;

create or replace function public.end_transport_allocation(p_allocation_id uuid, p_last_day date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a public.transport_allocation%rowtype;
begin
  perform app.fn_transport_allocator_check();
  select * into v_a from public.transport_allocation where id = p_allocation_id and tenant_id = app.auth_tenant_id();
  if not found or (app.auth_role() not in ('owner', 'super_admin') and not (v_a.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'ALLOCATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_a.ends_on is not null or p_last_day < v_a.starts_on then
    raise exception 'ALLOCATION_NOT_OPEN' using errcode = '22023';
  end if;
  perform app.fn_transport_close(v_a.id, p_last_day);
end;
$$;
revoke execute on function public.end_transport_allocation(uuid, date) from public, anon;
grant execute on function public.end_transport_allocation(uuid, date) to authenticated;

-- A mid-month change of stop: the old allocation closes the day before, the new one
-- opens on p_from; each month's lines add up to no more than the dearest slab.
create or replace function public.move_transport_allocation(p_student_id uuid, p_pickup_stop uuid, p_drop_stop uuid, p_from date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old public.transport_allocation%rowtype;
  v_new uuid;
begin
  perform app.fn_transport_allocator_check();
  select * into v_old from public.transport_allocation
   where student_id = p_student_id and tenant_id = app.auth_tenant_id() and starts_on < p_from and (ends_on is null or ends_on >= p_from - 1)
   order by starts_on desc limit 1;
  if not found then
    raise exception 'ALLOCATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_old.campus_id = any (app.auth_campus_ids())) then
    raise exception 'ALLOCATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_old.ends_on is not null and v_old.ends_on >= p_from then
    raise exception 'ALLOCATION_NOT_OPEN' using errcode = '22023';
  end if;
  if v_old.ends_on is null then
    perform app.fn_transport_close(v_old.id, p_from - 1);
  end if;
  v_new := app.fn_transport_allocate(p_student_id, p_pickup_stop, p_drop_stop, p_from, true);
  return v_new;
end;
$$;
revoke execute on function public.move_transport_allocation(uuid, uuid, uuid, date) from public, anon;
grant execute on function public.move_transport_allocation(uuid, uuid, uuid, date) to authenticated;

create or replace function public.join_transport_waitlist(p_student_id uuid, p_route_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_route public.transport_route%rowtype;
  v_id    uuid;
begin
  perform app.fn_transport_allocator_check();
  select * into v_route from public.transport_route where id = p_route_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ROUTE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_route.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.student where id = p_student_id and tenant_id = v_route.tenant_id and campus_id = v_route.campus_id) then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into public.transport_waitlist (tenant_id, campus_id, route_id, student_id, queued_by)
  values (v_route.tenant_id, v_route.campus_id, p_route_id, p_student_id, (select auth.uid()))
  on conflict (route_id, student_id) do nothing;
  select id into v_id from public.transport_waitlist where route_id = p_route_id and student_id = p_student_id;
  return v_id;
end;
$$;
revoke execute on function public.join_transport_waitlist(uuid, uuid) from public, anon;
grant execute on function public.join_transport_waitlist(uuid, uuid) to authenticated;

-- A withdrawn student's bus seat is released and the last month re-priced.
create or replace function app.tg_enrolment_end_transport()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_last date := coalesce(new.left_on, app.fn_karachi_today());
begin
  if new.status <> 'active' and old.status = 'active' then
    for r in select id, starts_on from public.transport_allocation where enrolment_id = new.id and ends_on is null loop
      perform app.fn_transport_close(r.id, greatest(v_last, r.starts_on));
    end loop;
  end if;
  return new;
end;
$$;
create trigger trg_enrolment_end_transport after update of status on public.enrolment
  for each row execute function app.tg_enrolment_end_transport();
