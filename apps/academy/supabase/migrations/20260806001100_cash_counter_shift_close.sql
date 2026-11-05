-- FR-K18: cash counter shift open, close and physical tally.
--
-- FR-K17 left fee_receipt.counter_session_id as a bare uuid because no table defined a
-- "counter session". This one does. A person opens a counter with an opening float, every cash
-- receipt they take lands on that session, and closing it compares what the system says was
-- collected with what was physically counted, note by note. A shortfall is then attributed to a
-- named person on the same day.
--
--  * A cash receipt needs the collector's own open session at the challan's campus. There is no
--    fallback to "some open session": cash taken on someone else's shift would defeat the point.
--    A BEFORE INSERT trigger on fee_receipt repeats the rule so no other writer can get around it,
--    and a closed session refuses a late receipt (the back-dated case).
--  * variance = declared physical count - (opening float + cash receipts on the session).
--    A variance larger than the counter's threshold cannot be closed until a principal, owner or
--    super admin countersigns it with a remark. The countersign is a separate call so the person
--    who is short is never the one who signs it off.
--  * Closing is final. Session rows have no write policy; every change goes through a function.

create type public.counter_session_status as enum ('open', 'closed', 'closed_with_variance');

create table public.cash_counter (
  id                       uuid primary key default gen_random_uuid(),
  tenant_id                uuid not null references public.tenant(id) on delete cascade,
  campus_id                uuid not null references public.campus(id) on delete cascade,
  name                     text not null check (btrim(name) <> ''),
  variance_threshold_paisa bigint not null default 50000 check (variance_threshold_paisa >= 0),
  is_active                boolean not null default true,
  created_at               timestamptz not null default now()
);

create unique index cash_counter_campus_name_uq on public.cash_counter (tenant_id, campus_id, lower(name));
create index idx_cash_counter_campus on public.cash_counter (campus_id);

create table public.cash_counter_session (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  counter_id           uuid not null references public.cash_counter(id) on delete cascade,
  opened_by            uuid not null references public.app_user(user_id),
  opened_at            timestamptz not null default clock_timestamp(),
  closed_by            uuid references public.app_user(user_id),
  closed_at            timestamptz,
  opening_float_paisa  bigint not null default 0 check (opening_float_paisa >= 0),
  system_total_paisa   bigint,
  declared_total_paisa bigint,
  variance_paisa       bigint,
  status               public.counter_session_status not null default 'open',
  countersigned_by     uuid references public.app_user(user_id),
  countersigned_at     timestamptz,
  countersign_remark   text,
  constraint ck_counter_session_closed_shape check (
    (status = 'open' and closed_at is null and declared_total_paisa is null)
    or (status <> 'open' and closed_at is not null and declared_total_paisa is not null and variance_paisa is not null)
  ),
  constraint ck_counter_session_variance_status check (
    status <> 'closed' or variance_paisa = 0
  )
);

-- A counter is worked by one person at a time, and a person works one counter at a campus.
create unique index cash_counter_session_one_open_per_counter on public.cash_counter_session (counter_id) where status = 'open';
create unique index cash_counter_session_one_open_per_person on public.cash_counter_session (opened_by, campus_id) where status = 'open';
create index idx_cash_counter_session_campus on public.cash_counter_session (campus_id, opened_at desc);
create index idx_cash_counter_session_counter on public.cash_counter_session (counter_id);

create table public.cash_denomination_count (
  session_id   uuid not null references public.cash_counter_session(id) on delete cascade,
  denomination int not null check (denomination > 0),
  count        int not null check (count >= 0),
  primary key (session_id, denomination)
);

alter table public.fee_receipt
  add constraint fee_receipt_counter_session_fk
  foreign key (counter_session_id) references public.cash_counter_session(id);
create index idx_fee_receipt_counter_session on public.fee_receipt (counter_session_id) where counter_session_id is not null;

create trigger cash_counter_audit after insert or update or delete on public.cash_counter
  for each row execute function app.tg_audit_row();
create trigger cash_counter_session_audit after insert or update or delete on public.cash_counter_session
  for each row execute function app.tg_audit_row();

-- ── reads: the people who handle fees, at their own campuses ──────────────────────────

alter table public.cash_counter enable row level security;
alter table public.cash_counter_session enable row level security;
alter table public.cash_denomination_count enable row level security;

create policy cash_counter_campus_scope on public.cash_counter
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.fn_fee_staff()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy counter_session_campus_scope on public.cash_counter_session
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.fn_fee_staff()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy cash_denomination_count_read on public.cash_denomination_count
  for select to authenticated
  using (
    session_id in (
      select id from public.cash_counter_session
       where tenant_id = app.auth_tenant_id()
         and app.fn_fee_staff()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );

-- ── writes ────────────────────────────────────────────────────────────────────────────

create or replace function public.create_cash_counter(p_campus_id uuid, p_name text, p_variance_threshold_paisa bigint default 50000)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  perform app.fn_assert_campus_access(p_campus_id);
  if p_name is null or btrim(p_name) = '' then
    raise exception 'COUNTER_NAME_REQUIRED' using errcode = '23514';
  end if;

  insert into public.cash_counter (tenant_id, campus_id, name, variance_threshold_paisa)
  values (app.auth_tenant_id(), p_campus_id, btrim(p_name), coalesce(p_variance_threshold_paisa, 50000))
  returning id into v_id;
  return v_id;
exception
  when unique_violation then
    raise exception 'COUNTER_NAME_TAKEN' using errcode = '23505';
end;
$$;

create or replace function public.open_counter_session(p_counter_id uuid, p_opening_float_paisa bigint default 0)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_counter public.cash_counter%rowtype;
  v_id      uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if auth.uid() is null then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_counter from public.cash_counter where id = p_counter_id and tenant_id = app.auth_tenant_id();
  if not found or not v_counter.is_active then
    raise exception 'COUNTER_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_counter.campus_id);

  insert into public.cash_counter_session (tenant_id, campus_id, counter_id, opened_by, opening_float_paisa)
  values (v_counter.tenant_id, v_counter.campus_id, v_counter.id, auth.uid(), coalesce(p_opening_float_paisa, 0))
  returning id into v_id;
  return v_id;
exception
  when unique_violation then
    raise exception 'COUNTER_SESSION_ALREADY_OPEN' using errcode = '23505';
end;
$$;

create or replace function public.countersign_counter_session(p_session_id uuid, p_remark text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session public.cash_counter_session%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_remark is null or char_length(btrim(p_remark)) < 10 then
    raise exception 'REMARK_TOO_SHORT' using errcode = '23514';
  end if;

  select * into v_session from public.cash_counter_session
   where id = p_session_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_session.campus_id);
  if v_session.status <> 'open' then
    raise exception 'SESSION_NOT_OPEN' using errcode = '55000';
  end if;
  if v_session.opened_by = auth.uid() then
    raise exception 'CANNOT_COUNTERSIGN_OWN_SESSION' using errcode = '42501';
  end if;

  update public.cash_counter_session
     set countersigned_by = auth.uid(), countersigned_at = clock_timestamp(), countersign_remark = btrim(p_remark)
   where id = p_session_id;
end;
$$;

-- p_denominations is an object of note value in rupees to how many notes or coins were counted,
-- e.g. {"5000": 3, "1000": 40, "10": 25}.
create or replace function public.close_counter_session(p_session_id uuid, p_denominations jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session   public.cash_counter_session%rowtype;
  v_counter   public.cash_counter%rowtype;
  v_system    bigint;
  v_declared  bigint;
  v_variance  bigint;
  v_status    public.counter_session_status;
  v_entry     record;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_denominations is null or jsonb_typeof(p_denominations) <> 'object' then
    raise exception 'DENOMINATIONS_REQUIRED' using errcode = '23514';
  end if;

  select * into v_session from public.cash_counter_session
   where id = p_session_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_session.campus_id);
  if v_session.status <> 'open' then
    raise exception 'SESSION_NOT_OPEN' using errcode = '55000';
  end if;
  if v_session.opened_by <> auth.uid() and app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_counter from public.cash_counter where id = v_session.counter_id;

  for v_entry in select key, value from jsonb_each_text(p_denominations) loop
    if v_entry.key !~ '^[0-9]+$' or v_entry.value !~ '^[0-9]+$' or v_entry.key::int <= 0 then
      raise exception 'DENOMINATIONS_INVALID' using errcode = '23514';
    end if;
    insert into public.cash_denomination_count (session_id, denomination, count)
    values (p_session_id, v_entry.key::int, v_entry.value::int);
  end loop;

  select coalesce(sum(fp.amount_paisa), 0) into v_system
    from public.fee_receipt fr
    join public.fee_payment fp on fp.id = fr.payment_id
   where fr.counter_session_id = p_session_id and fp.mode = 'cash';

  select coalesce(sum(denomination::bigint * count * 100), 0) into v_declared
    from public.cash_denomination_count where session_id = p_session_id;

  v_variance := v_declared - (v_session.opening_float_paisa + v_system);

  if abs(v_variance) > v_counter.variance_threshold_paisa and v_session.countersigned_by is null then
    raise exception 'COUNTERSIGN_REQUIRED' using errcode = '55000';
  end if;

  v_status := case when v_variance = 0 then 'closed'::public.counter_session_status
                   else 'closed_with_variance'::public.counter_session_status end;

  update public.cash_counter_session
     set closed_by = auth.uid(), closed_at = clock_timestamp(),
         system_total_paisa = v_system, declared_total_paisa = v_declared,
         variance_paisa = v_variance, status = v_status
   where id = p_session_id;

  return jsonb_build_object(
    'session_id', p_session_id, 'system_total_paisa', v_system, 'declared_total_paisa', v_declared,
    'opening_float_paisa', v_session.opening_float_paisa, 'variance_paisa', v_variance, 'status', v_status
  );
end;
$$;

-- Running totals for an open session. Security invoker: fee_receipt and fee_payment already limit
-- who can read them.
create or replace function public.counter_session_totals(p_session_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'receipt_count', count(fr.id),
    'cash_total_paisa', coalesce(sum(fp.amount_paisa), 0)
  )
  from public.fee_receipt fr
  join public.fee_payment fp on fp.id = fr.payment_id
  where fr.counter_session_id = p_session_id and fp.mode = 'cash';
$$;

revoke execute on function public.create_cash_counter(uuid, text, bigint) from public, anon;
revoke execute on function public.open_counter_session(uuid, bigint) from public, anon;
revoke execute on function public.countersign_counter_session(uuid, text) from public, anon;
revoke execute on function public.close_counter_session(uuid, jsonb) from public, anon;
revoke execute on function public.counter_session_totals(uuid) from public, anon;
grant execute on function public.create_cash_counter(uuid, text, bigint) to authenticated;
grant execute on function public.open_counter_session(uuid, bigint) to authenticated;
grant execute on function public.countersign_counter_session(uuid, text) to authenticated;
grant execute on function public.close_counter_session(uuid, jsonb) to authenticated;
grant execute on function public.counter_session_totals(uuid) to authenticated;

-- ── the rule: no cash receipt without the collector's open session ─────────────────────

create or replace function app.tg_fee_receipt_require_open_session()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mode    public.fee_payment_mode;
  v_session public.cash_counter_session%rowtype;
begin
  select mode into v_mode from public.fee_payment where id = new.payment_id;
  if v_mode is distinct from 'cash' then
    return new;
  end if;

  if new.counter_session_id is null then
    raise exception 'COUNTER_SESSION_REQUIRED: open a counter session first' using errcode = '55000';
  end if;

  select * into v_session from public.cash_counter_session where id = new.counter_session_id;
  if not found or v_session.campus_id <> new.campus_id then
    raise exception 'COUNTER_SESSION_REQUIRED: open a counter session first' using errcode = '55000';
  end if;
  if v_session.status <> 'open' then
    raise exception 'COUNTER_SESSION_CLOSED: record this receipt against a currently open session' using errcode = '55000';
  end if;
  return new;
end;
$$;

create trigger fee_receipt_bi_require_open_session before insert on public.fee_receipt
  for each row execute function app.tg_fee_receipt_require_open_session();

-- collect_cash_payment(): as in 20260806000400, plus the session. Resolved before any money moves so
-- a missing session costs nothing.
create or replace function public.collect_cash_payment(p_challan_id uuid, p_amount_paisa bigint, p_client_idempotency_key text, p_mode public.fee_payment_mode default 'cash'::public.fee_payment_mode, p_reference_no text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_challan    public.fee_challan%rowtype;
  v_existing   record;
  v_payment_id uuid;
  v_receipt_id uuid;
  v_receipt_no text;
  v_session_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_client_idempotency_key is null or btrim(p_client_idempotency_key) = '' then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED' using errcode = '23514';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('collect-cash:' || v_tenant_id::text || ':' || p_client_idempotency_key, 0));

  select fr.id as receipt_id, fr.receipt_no, fr.payment_id
    into v_existing
    from public.fee_receipt fr
   where fr.tenant_id = v_tenant_id and fr.client_idempotency_key = p_client_idempotency_key;
  if found then
    return jsonb_build_object(
      'receipt_id', v_existing.receipt_id, 'receipt_no', v_existing.receipt_no,
      'payment_id', v_existing.payment_id, 'is_replay', true
    );
  end if;

  select * into v_challan from public.fee_challan where id = p_challan_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform app.fn_assert_campus_access(v_challan.campus_id);

  if p_mode = 'cash' then
    select id into v_session_id from public.cash_counter_session
     where opened_by = auth.uid() and campus_id = v_challan.campus_id and status = 'open';
    if v_session_id is null then
      raise exception 'COUNTER_SESSION_REQUIRED: open a counter session first' using errcode = '55000';
    end if;
  end if;

  v_payment_id := public.record_payment(v_challan.enrolment_id, p_amount_paisa, p_mode, p_reference_no);
  v_receipt_no := app.fn_next_receipt_no(v_tenant_id, v_challan.campus_id, v_challan.session_id);

  insert into public.fee_receipt (tenant_id, campus_id, payment_id, receipt_no, counter_session_id, client_idempotency_key)
  values (v_tenant_id, v_challan.campus_id, v_payment_id, v_receipt_no, v_session_id, p_client_idempotency_key)
  returning id into v_receipt_id;

  return jsonb_build_object(
    'receipt_id', v_receipt_id, 'receipt_no', v_receipt_no, 'payment_id', v_payment_id, 'is_replay', false
  );
end;
$function$;
