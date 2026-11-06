-- Audit BUG-16: admission-fee cash (walk-in desk and application pipeline) bypassed the cash
-- counter, so it never appeared in any shift tally. Front-desk staff (Admissions Officer and
-- Receptionist) can now run a counter shift like the Accountant, cash admission payments need
-- the collector's own open shift at that campus, and shift totals count them.

create or replace function app.fn_counter_staff()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('super_admin', 'owner', 'principal', 'accountant', 'admissions_officer', 'receptionist');
$$;

alter table public.admission_fee_payment add column if not exists counter_session_id uuid references public.cash_counter_session(id);
create index if not exists idx_admission_fee_payment_counter_session on public.admission_fee_payment (counter_session_id) where counter_session_id is not null;

drop policy if exists cash_counter_campus_scope on public.cash_counter;
create policy cash_counter_campus_scope on public.cash_counter
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.fn_counter_staff()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

drop policy if exists counter_session_campus_scope on public.cash_counter_session;
create policy counter_session_campus_scope on public.cash_counter_session
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.fn_counter_staff()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

drop policy if exists cash_denomination_count_read on public.cash_denomination_count;
create policy cash_denomination_count_read on public.cash_denomination_count
  for select to authenticated
  using (
    session_id in (
      select id from public.cash_counter_session
       where tenant_id = app.auth_tenant_id()
         and app.fn_counter_staff()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );

-- Totals now cover both kinds of cash. Security definer, with its own check, because a front-desk
-- collector cannot read fee_receipt or fee_payment.
create or replace function public.counter_session_totals(p_session_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_session public.cash_counter_session%rowtype;
  v_fee_count int;
  v_fee_cash bigint;
  v_adm_count int;
  v_adm_cash bigint;
begin
  select * into v_session from public.cash_counter_session where id = p_session_id;
  if not found or (app.auth_tenant_id() is not null and (v_session.tenant_id <> app.auth_tenant_id() or not app.fn_counter_staff())) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  select count(fr.id), coalesce(sum(fp.amount_paisa), 0) into v_fee_count, v_fee_cash
    from public.fee_receipt fr join public.fee_payment fp on fp.id = fr.payment_id
   where fr.counter_session_id = p_session_id and fp.mode = 'cash';
  select count(*), coalesce(sum(amount_paisa), 0) into v_adm_count, v_adm_cash
    from public.admission_fee_payment
   where counter_session_id = p_session_id and mode = 'cash';

  return jsonb_build_object(
    'receipt_count', v_fee_count + v_adm_count,
    'cash_total_paisa', v_fee_cash + v_adm_cash,
    'admission_cash_paisa', v_adm_cash
  );
end;
$$;

revoke execute on function public.counter_session_totals(uuid) from public, anon;
grant execute on function public.counter_session_totals(uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.open_counter_session(p_counter_id uuid, p_opening_float_paisa bigint DEFAULT 0)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_counter public.cash_counter%rowtype;
  v_id      uuid;
begin
  if not app.fn_counter_staff() or app.auth_role() = 'principal' then
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
$function$;

CREATE OR REPLACE FUNCTION public.close_counter_session(p_session_id uuid, p_denominations jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_session   public.cash_counter_session%rowtype;
  v_counter   public.cash_counter%rowtype;
  v_system    bigint;
  v_declared  bigint;
  v_variance  bigint;
  v_status    public.counter_session_status;
  v_entry     record;
begin
  if not app.fn_counter_staff() then
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

  v_system := ((public.counter_session_totals(p_session_id)) ->> 'cash_total_paisa')::bigint;

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
$function$;

create or replace function app.tg_admission_payment_require_open_session()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session_id uuid;
begin
  if new.mode <> 'cash' then
    return new;
  end if;
  select id into v_session_id from public.cash_counter_session
   where opened_by = auth.uid() and campus_id = new.campus_id and status = 'open'
   limit 1;
  if v_session_id is null then
    raise exception 'COUNTER_SESSION_REQUIRED: open a counter session first' using errcode = '55000';
  end if;
  new.counter_session_id := v_session_id;
  return new;
end;
$$;

drop trigger if exists admission_fee_payment_bi_require_open_session on public.admission_fee_payment;
create trigger admission_fee_payment_bi_require_open_session before insert on public.admission_fee_payment
  for each row execute function app.tg_admission_payment_require_open_session();
