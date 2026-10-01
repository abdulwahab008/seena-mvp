-- FR-Q06: hostel and mess fee derivation.
--
-- Boarders' charges come from three things already recorded: the room tariff for
-- the room type of the bed they hold, the mess rate per day times billable mess
-- days (FR-Q05), and a refundable security deposit charged once at the first
-- allocation. Nothing is typed per student.
--
--  * Room fee: tariff x days of the month the student holds a bed / days in the
--    month, rounded to whole rupees. A full month is exactly the tariff (a
--    mess-off never reduces the room charge); a stay ending 12 November in a
--    30-day month is 12/30. When a student changes room type mid-month the
--    month's room charge never exceeds the dearest tariff.
--  * Mess: mess rate x billable_mess_days, i.e. days housed minus approved
--    mess-off days, so a boarder who leaves on the 12th is charged for 12 days.
--  * Deposit: one HOSTEL_DEPOSIT line, ever, against a refundable head flagged as a
--    liability (is_refundable, gl_code LIAB-HOSTEL-DEPOSIT), never income. The
--    deposit row keeps the ledger entry id, so a refund on leaving is traceable;
--    refund_hostel_deposit releases it with an adjustment credit and a refund debit
--    (the same pattern as the school security deposit, FR-K28).
--  * Concessions: a scheme reduces a head only if its applicable_head_ids names
--    that head, so a staff-child scheme scoped to HOSTEL_ROOM never touches
--    HOSTEL_MESS.
--  * Posting writes fee_ledger lines (HOSTEL_ROOM, HOSTEL_MESS, HOSTEL_DEPOSIT,
--    concession credits), one per student, head and month, and is idempotent: a re-run
--    posts only the difference (an adjustment line), so a mess-off approved or a
--    bed vacated after the 1st is trued up by the next run. The monthly job runs on
--    day 1 at 20:20 UTC, ahead of challan generation, trues up last month, then posts
--    the current one. Like transport (FR-P04) the charges are ledger debits; the
--    plan-line challan generator is not modified.

create table public.hostel_tariff (
  id                     uuid primary key default gen_random_uuid(),
  tenant_id              uuid not null references public.tenant(id) on delete cascade,
  campus_id              uuid not null references public.campus(id) on delete cascade,
  room_type              public.hostel_room_type not null,
  monthly_amount_paisa   bigint not null check (monthly_amount_paisa > 0),
  mess_rate_per_day_paisa bigint not null default 0 check (mess_rate_per_day_paisa >= 0),
  security_deposit_paisa bigint not null default 0 check (security_deposit_paisa >= 0),
  effective_from         date not null,
  created_by             uuid references auth.users(id),
  created_at             timestamptz not null default now(),
  constraint uq_hostel_tariff unique (tenant_id, campus_id, room_type, effective_from)
);
create index idx_hostel_tariff_scope on public.hostel_tariff (tenant_id, campus_id);

create table public.hostel_security_deposit (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant(id) on delete cascade,
  campus_id          uuid not null references public.campus(id) on delete cascade,
  student_id         uuid not null references public.student(id),
  enrolment_id       uuid not null references public.enrolment(id),
  amount_paisa       bigint not null check (amount_paisa > 0),
  charged_on         date not null,
  ledger_id          uuid references public.fee_ledger(id),
  received_on        date,
  refunded_on        date,
  refund_voucher_no  text check (refund_voucher_no is null or char_length(refund_voucher_no) <= 40),
  created_at         timestamptz not null default now(),
  constraint chk_deposit_refund check (refunded_on is null or (received_on is not null and refund_voucher_no is not null))
);
create unique index uq_hostel_deposit_active on public.hostel_security_deposit (student_id) where refunded_on is null;
create index idx_hostel_deposit_scope on public.hostel_security_deposit (tenant_id, campus_id);
create index idx_hostel_deposit_enrolment on public.hostel_security_deposit (enrolment_id);
create index idx_hostel_deposit_ledger on public.hostel_security_deposit (ledger_id);

-- One first line per student, head and month.
create unique index fee_ledger_hostel_month_uq on public.fee_ledger (source_id, value_date) where source_type in ('hostel_charge', 'hostel_concession');

create trigger hostel_tariff_audit after insert or update or delete on public.hostel_tariff
  for each row execute function app.tg_audit_row();
create trigger hostel_security_deposit_audit after insert or update or delete on public.hostel_security_deposit
  for each row execute function app.tg_audit_row();

-- Fees staff: accountant plus the hostel's own managers.
create or replace function app.fn_hostel_fee_staff(p_tenant uuid, p_campus uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_tenant = app.auth_tenant_id()
     and (app.auth_role() in ('owner', 'super_admin')
          or (p_campus = any (app.auth_campus_ids()) and app.auth_role() in ('accountant', 'principal', 'vice_principal')));
$$;
grant execute on function app.fn_hostel_fee_staff(uuid, uuid) to authenticated;

alter table public.hostel_tariff enable row level security;
alter table public.hostel_security_deposit enable row level security;
create policy hostel_tariff_campus_scope on public.hostel_tariff for select to authenticated
  using (app.fn_hostel_fee_staff(tenant_id, campus_id));
create policy hostel_deposit_accountant_write on public.hostel_security_deposit for select to authenticated
  using (app.fn_hostel_fee_staff(tenant_id, campus_id)
         or (tenant_id = app.auth_tenant_id() and (student_id = any (app.auth_guardian_student_ids()) or student_id = public.my_student_id())));

create or replace function public.save_hostel_tariff(
  p_campus_id uuid, p_room_type public.hostel_room_type, p_monthly_paisa bigint, p_mess_rate_paisa bigint, p_deposit_paisa bigint, p_effective_from date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_id     uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select tenant_id into v_tenant from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id();
  if v_tenant is null then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (p_campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_monthly_paisa <= 0 or p_mess_rate_paisa < 0 or p_deposit_paisa < 0 then
    raise exception 'AMOUNT_INVALID' using errcode = '23514';
  end if;
  insert into public.hostel_tariff (tenant_id, campus_id, room_type, monthly_amount_paisa, mess_rate_per_day_paisa, security_deposit_paisa, effective_from, created_by)
  values (v_tenant, p_campus_id, p_room_type, p_monthly_paisa, p_mess_rate_paisa, p_deposit_paisa, p_effective_from, (select auth.uid()))
  on conflict (tenant_id, campus_id, room_type, effective_from)
  do update set monthly_amount_paisa = excluded.monthly_amount_paisa, mess_rate_per_day_paisa = excluded.mess_rate_per_day_paisa, security_deposit_paisa = excluded.security_deposit_paisa
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.save_hostel_tariff(uuid, public.hostel_room_type, bigint, bigint, bigint, date) from public, anon;
grant execute on function public.save_hostel_tariff(uuid, public.hostel_room_type, bigint, bigint, bigint, date) to authenticated;

-- Fee heads, created on first use. The deposit head is a refundable liability.
create or replace function app.fn_hostel_fee_head(p_tenant uuid, p_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.fee_head where tenant_id = p_tenant and lower(code) = lower(p_code);
  if v_id is null then
    insert into public.fee_head (tenant_id, code, name_en, name_ur, is_refundable, gl_code, default_frequency, carry_forward_on_arrears)
    values (p_tenant, p_code,
            case p_code when 'HOSTEL_ROOM' then 'Hostel room fee' when 'HOSTEL_MESS' then 'Hostel mess charge' else 'Hostel security deposit (refundable)' end,
            case p_code when 'HOSTEL_ROOM' then 'ہاسٹل کمرے کی فیس' when 'HOSTEL_MESS' then 'ہاسٹل میس چارجز' else 'ہاسٹل سیکیورٹی ڈپازٹ (قابلِ واپسی)' end,
            p_code = 'HOSTEL_DEPOSIT', case when p_code = 'HOSTEL_DEPOSIT' then 'LIAB-HOSTEL-DEPOSIT' end,
            case when p_code = 'HOSTEL_DEPOSIT' then 'one_time'::public.fee_frequency else 'monthly'::public.fee_frequency end, true)
    on conflict (tenant_id, lower(code)) do nothing;
    select id into v_id from public.fee_head where tenant_id = p_tenant and lower(code) = lower(p_code);
  end if;
  return v_id;
end;
$$;
revoke execute on function app.fn_hostel_fee_head(uuid, text) from public, anon, authenticated;

-- ── The calculation ─────────────────────────────────────────────────────────
-- A concession on one head for the month, from awards whose scheme names that head.
create or replace function app.fn_hostel_concession(p_enrolment_id uuid, p_head_id uuid, p_gross bigint, p_ms date, p_me date)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select least(p_gross, coalesce(sum(case ca.calc_type when 'percentage' then round(p_gross * ca.value / 100.0) else round(ca.value * 100) end), 0))::bigint
    from public.concession_award ca join public.concession_scheme cs on cs.id = ca.scheme_id
   where ca.enrolment_id = p_enrolment_id and ca.status = 'approved' and ca.effective_from <= p_me and ca.effective_to >= p_ms
     and cs.applicable_head_ids @> array[p_head_id];
$$;
revoke execute on function app.fn_hostel_concession(uuid, uuid, bigint, date, date) from public, anon, authenticated;

-- The month, explained line by line. Amounts are paisa.
create or replace function app.fn_hostel_breakdown(p_student_id uuid, p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ms     date := date_trunc('month', p_month)::date;
  v_me     date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_dim    int := extract(day from (date_trunc('month', p_month) + interval '1 month - 1 day'))::int;
  r        record;
  v_segs   jsonb := '[]'::jsonb;
  v_room   bigint := 0;
  v_cap    bigint := 0;
  v_rate   bigint := 0;
  v_days   int;
  v_enrol  uuid;
  v_tenant uuid;
  v_campus uuid;
  v_missing boolean := false;
  v_amt    bigint;
  v_t      public.hostel_tariff%rowtype;
begin
  for r in
    select a.id, a.enrolment_id, a.tenant_id, a.campus_id, greatest(a.starts_on, v_ms) as seg_from, least(coalesce(a.ends_on, v_me), v_me) as seg_to, rm.room_type
      from public.hostel_allocation a join public.hostel_bed d on d.id = a.bed_id join public.hostel_room rm on rm.id = d.room_id
     where a.student_id = p_student_id and a.starts_on <= v_me and coalesce(a.ends_on, v_me) >= v_ms
     order by a.starts_on
  loop
    v_enrol := r.enrolment_id; v_tenant := r.tenant_id; v_campus := r.campus_id;
    select * into v_t from public.hostel_tariff
     where tenant_id = r.tenant_id and campus_id = r.campus_id and room_type = r.room_type and effective_from <= r.seg_from
     order by effective_from desc limit 1;
    if not found then
      v_missing := true;
      v_segs := v_segs || jsonb_build_object('room_type', r.room_type, 'from', r.seg_from, 'to', r.seg_to, 'days', r.seg_to - r.seg_from + 1, 'tariff_missing', true);
      continue;
    end if;
    v_days := r.seg_to - r.seg_from + 1;
    v_amt := (round((v_t.monthly_amount_paisa::numeric * v_days / v_dim) / 100) * 100)::bigint;
    v_room := v_room + v_amt;
    v_cap := greatest(v_cap, v_t.monthly_amount_paisa);
    v_rate := v_t.mess_rate_per_day_paisa;
    v_segs := v_segs || jsonb_build_object('room_type', r.room_type, 'from', r.seg_from, 'to', r.seg_to, 'days', v_days, 'monthly_paisa', v_t.monthly_amount_paisa, 'amount_paisa', v_amt);
  end loop;
  if v_enrol is null then
    return jsonb_build_object('housed', false);
  end if;
  v_room := least(v_room, v_cap);
  return jsonb_build_object(
    'housed', true, 'enrolment_id', v_enrol, 'tenant_id', v_tenant, 'campus_id', v_campus, 'tariff_missing', v_missing,
    'days_in_month', v_dim, 'segments', v_segs, 'room_paisa', v_room,
    'mess_days', app.fn_billable_mess_days(p_student_id, v_ms), 'mess_rate_paisa', v_rate,
    'mess_paisa', v_rate * app.fn_billable_mess_days(p_student_id, v_ms));
end;
$$;
revoke execute on function app.fn_hostel_breakdown(uuid, date) from public, anon, authenticated;

create or replace function public.hostel_monthly_amount(p_student_id uuid, p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_s      public.student%rowtype;
  v_b      jsonb;
  v_ms     date := date_trunc('month', p_month)::date;
  v_me     date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_room_c bigint := 0;
  v_mess_c bigint := 0;
begin
  select * into v_s from public.student where id = p_student_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not (app.fn_hostel_fee_staff(v_s.tenant_id, v_s.campus_id) or app.fn_hostel_staff(v_s.tenant_id, v_s.campus_id)) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  v_b := app.fn_hostel_breakdown(p_student_id, v_ms);
  if (v_b ->> 'housed')::boolean then
    v_room_c := app.fn_hostel_concession((v_b ->> 'enrolment_id')::uuid, app.fn_hostel_fee_head(v_s.tenant_id, 'HOSTEL_ROOM'), (v_b ->> 'room_paisa')::bigint, v_ms, v_me);
    v_mess_c := app.fn_hostel_concession((v_b ->> 'enrolment_id')::uuid, app.fn_hostel_fee_head(v_s.tenant_id, 'HOSTEL_MESS'), (v_b ->> 'mess_paisa')::bigint, v_ms, v_me);
  end if;
  return v_b || jsonb_build_object('room_concession_paisa', v_room_c, 'mess_concession_paisa', v_mess_c,
                                   'room_net_paisa', coalesce((v_b ->> 'room_paisa')::bigint, 0) - v_room_c,
                                   'mess_net_paisa', coalesce((v_b ->> 'mess_paisa')::bigint, 0) - v_mess_c);
end;
$$;
revoke execute on function public.hostel_monthly_amount(uuid, date) from public, anon;
grant execute on function public.hostel_monthly_amount(uuid, date) to authenticated;

-- ── Posting ─────────────────────────────────────────────────────────────────
-- Brings one ledger "slot" (student, head, month, kind) to the desired amount.
-- First line is a charge/concession; later differences are adjustment lines.
create or replace function app.fn_hostel_post_line(
  p_alloc public.hostel_allocation, p_session uuid, p_head uuid, p_key text, p_month date, p_desired bigint, p_credit boolean)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sid      uuid := md5(p_key)::uuid;
  v_type     text := case when p_credit then 'hostel_concession' else 'hostel_charge' end;
  v_existing bigint;
  v_actor    uuid := (select au.user_id from public.app_user au where au.user_id = (select auth.uid()));
begin
  select coalesce(sum(case when (direction = 'debit') <> p_credit then amount_paisa else -amount_paisa end), 0)::bigint into v_existing
    from public.fee_ledger where source_id = v_sid and value_date = p_month and source_type in (v_type, 'hostel_adj');
  if v_existing = p_desired then
    return 0;
  end if;
  if v_existing = 0 then
    insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction, value_date, source_type, source_id, created_by)
    values (p_alloc.tenant_id, p_alloc.campus_id, p_alloc.enrolment_id, p_session, case when p_credit then 'concession'::public.fee_ledger_entry_type else 'charge'::public.fee_ledger_entry_type end,
            p_head, p_desired, case when p_credit then 'credit'::public.fee_ledger_direction else 'debit'::public.fee_ledger_direction end, p_month, v_type, v_sid, v_actor);
  else
    insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction, value_date, source_type, source_id, reason, created_by)
    values (p_alloc.tenant_id, p_alloc.campus_id, p_alloc.enrolment_id, p_session, 'adjustment', p_head, abs(p_desired - v_existing),
            case when (p_desired > v_existing) <> p_credit then 'debit'::public.fee_ledger_direction else 'credit'::public.fee_ledger_direction end,
            p_month, 'hostel_adj', v_sid, 'Hostel charge re-derived after a change of stay or mess-off', v_actor);
  end if;
  return 1;
end;
$$;
revoke execute on function app.fn_hostel_post_line(public.hostel_allocation, uuid, uuid, text, date, bigint, boolean) from public, anon, authenticated;

create or replace function app.fn_hostel_post_student(p_student_id uuid, p_month date)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ms     date := date_trunc('month', p_month)::date;
  v_me     date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_b      jsonb := app.fn_hostel_breakdown(p_student_id, v_ms);
  v_alloc  public.hostel_allocation%rowtype;
  v_session uuid;
  v_room_h uuid;
  v_mess_h uuid;
  v_dep_h  uuid;
  v_n      int := 0;
  v_t      public.hostel_tariff%rowtype;
  v_dep_id uuid;
  v_led    uuid;
  v_room_c bigint;
  v_mess_c bigint;
begin
  if not coalesce((v_b ->> 'housed')::boolean, false) or coalesce((v_b ->> 'tariff_missing')::boolean, false) then
    return 0;
  end if;
  select * into v_alloc from public.hostel_allocation where student_id = p_student_id and starts_on <= v_me and coalesce(ends_on, v_me) >= v_ms order by starts_on desc limit 1;
  select session_id into v_session from public.enrolment where id = v_alloc.enrolment_id;
  v_room_h := app.fn_hostel_fee_head(v_alloc.tenant_id, 'HOSTEL_ROOM');
  v_mess_h := app.fn_hostel_fee_head(v_alloc.tenant_id, 'HOSTEL_MESS');

  v_n := v_n + app.fn_hostel_post_line(v_alloc, v_session, v_room_h, p_student_id || '|' || v_ms || '|ROOM', v_ms, (v_b ->> 'room_paisa')::bigint, false);
  if (v_b ->> 'mess_paisa')::bigint > 0 or exists (select 1 from public.fee_ledger where source_id = md5(p_student_id || '|' || v_ms || '|MESS')::uuid) then
    v_n := v_n + app.fn_hostel_post_line(v_alloc, v_session, v_mess_h, p_student_id || '|' || v_ms || '|MESS', v_ms, (v_b ->> 'mess_paisa')::bigint, false);
  end if;
  v_room_c := app.fn_hostel_concession(v_alloc.enrolment_id, v_room_h, (v_b ->> 'room_paisa')::bigint, v_ms, v_me);
  v_mess_c := app.fn_hostel_concession(v_alloc.enrolment_id, v_mess_h, (v_b ->> 'mess_paisa')::bigint, v_ms, v_me);
  if v_room_c > 0 or exists (select 1 from public.fee_ledger where source_id = md5(p_student_id || '|' || v_ms || '|ROOM-C')::uuid) then
    v_n := v_n + app.fn_hostel_post_line(v_alloc, v_session, v_room_h, p_student_id || '|' || v_ms || '|ROOM-C', v_ms, v_room_c, true);
  end if;
  if v_mess_c > 0 or exists (select 1 from public.fee_ledger where source_id = md5(p_student_id || '|' || v_ms || '|MESS-C')::uuid) then
    v_n := v_n + app.fn_hostel_post_line(v_alloc, v_session, v_mess_h, p_student_id || '|' || v_ms || '|MESS-C', v_ms, v_mess_c, true);
  end if;

  -- The refundable deposit: once, at the first month the student is billed.
  if not exists (select 1 from public.hostel_security_deposit where student_id = p_student_id) then
    select t.* into v_t from public.hostel_tariff t
      join public.hostel_bed d on d.id = v_alloc.bed_id join public.hostel_room rm on rm.id = d.room_id
     where t.tenant_id = v_alloc.tenant_id and t.campus_id = v_alloc.campus_id and t.room_type = rm.room_type and t.effective_from <= greatest(v_alloc.starts_on, v_ms)
     order by t.effective_from desc limit 1;
    if found and v_t.security_deposit_paisa > 0 then
      v_dep_h := app.fn_hostel_fee_head(v_alloc.tenant_id, 'HOSTEL_DEPOSIT');
      v_dep_id := gen_random_uuid();
      insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction, value_date, source_type, source_id, created_by)
      values (v_alloc.tenant_id, v_alloc.campus_id, v_alloc.enrolment_id, v_session, 'charge', v_dep_h, v_t.security_deposit_paisa, 'debit', v_ms, 'hostel_deposit', v_dep_id,
              (select au.user_id from public.app_user au where au.user_id = (select auth.uid())))
      returning id into v_led;
      insert into public.hostel_security_deposit (id, tenant_id, campus_id, student_id, enrolment_id, amount_paisa, charged_on, ledger_id)
      values (v_dep_id, v_alloc.tenant_id, v_alloc.campus_id, p_student_id, v_alloc.enrolment_id, v_t.security_deposit_paisa, v_ms, v_led);
      v_n := v_n + 1;
    end if;
  end if;
  return v_n;
end;
$$;
revoke execute on function app.fn_hostel_post_student(uuid, date) from public, anon, authenticated;

create or replace function app.fn_post_hostel_month(p_tenant uuid, p_month date)
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
    select distinct a.student_id from public.hostel_allocation a
     where (p_tenant is null or a.tenant_id = p_tenant) and a.starts_on <= v_me and coalesce(a.ends_on, v_me) >= v_ms
  loop
    v_n := v_n + app.fn_hostel_post_student(r.student_id, v_ms);
  end loop;
  return v_n;
end;
$$;
revoke execute on function app.fn_post_hostel_month(uuid, date) from public, anon, authenticated;

create or replace function public.post_hostel_charges(p_month date)
returns int
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return app.fn_post_hostel_month(app.auth_tenant_id(), p_month);
end;
$$;
revoke execute on function public.post_hostel_charges(date) from public, anon;
grant execute on function public.post_hostel_charges(date) to authenticated;

-- Day 1, 20:20 UTC: true up last month, then post this one.
create or replace function public.hostel_fee_monthly_post(p_today date default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := coalesce(p_today, app.fn_karachi_today());
begin
  return app.fn_post_hostel_month(null, (date_trunc('month', v_today) - interval '1 month')::date)
       + app.fn_post_hostel_month(null, date_trunc('month', v_today)::date);
end;
$$;
revoke execute on function public.hostel_fee_monthly_post(date) from public, anon, authenticated;
grant execute on function public.hostel_fee_monthly_post(date) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('hostel_fee_monthly_post', '20 20 1 * *', 'select public.hostel_fee_monthly_post();');
  end if;
exception
  when others then null;
end;
$$;

-- ── Deposit received and refunded ───────────────────────────────────────────
create or replace function public.receive_hostel_deposit(p_deposit_id uuid, p_received_on date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_d public.hostel_security_deposit%rowtype;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_d from public.hostel_security_deposit where id = p_deposit_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'DEPOSIT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_d.refunded_on is not null then
    raise exception 'DEPOSIT_REFUNDED' using errcode = '22023';
  end if;
  update public.hostel_security_deposit set received_on = coalesce(received_on, p_received_on) where id = p_deposit_id;
end;
$$;
revoke execute on function public.receive_hostel_deposit(uuid, date) from public, anon;
grant execute on function public.receive_hostel_deposit(uuid, date) to authenticated;

-- Refund on leaving: the liability is released to the student's account and paid out.
create or replace function public.refund_hostel_deposit(p_deposit_id uuid, p_voucher_no text, p_refunded_on date default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_d    public.hostel_security_deposit%rowtype;
  v_head uuid;
  v_sess uuid;
  v_day  date := coalesce(p_refunded_on, app.fn_karachi_today());
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_d from public.hostel_security_deposit where id = p_deposit_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'DEPOSIT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_d.refunded_on is not null then
    raise exception 'DEPOSIT_REFUNDED' using errcode = '22023';
  end if;
  if v_d.received_on is null then
    raise exception 'DEPOSIT_NOT_RECEIVED' using errcode = '22023';
  end if;
  if exists (select 1 from public.hostel_allocation a where a.student_id = v_d.student_id and (a.ends_on is null or a.ends_on >= v_day)) then
    raise exception 'STUDENT_STILL_HOUSED' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_voucher_no, ''))) < 3 then
    raise exception 'VOUCHER_REQUIRED' using errcode = '23514';
  end if;
  v_head := app.fn_hostel_fee_head(v_d.tenant_id, 'HOSTEL_DEPOSIT');
  select session_id into v_sess from public.enrolment where id = v_d.enrolment_id;
  insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction, value_date, source_type, source_id, reason, created_by)
  values (v_d.tenant_id, v_d.campus_id, v_d.enrolment_id, v_sess, 'adjustment', v_head, v_d.amount_paisa, 'credit', v_day, 'hostel_deposit_release', v_d.id,
          'Hostel security deposit released on leaving', (select auth.uid())),
         (v_d.tenant_id, v_d.campus_id, v_d.enrolment_id, v_sess, 'refund', v_head, v_d.amount_paisa, 'debit', v_day, 'hostel_deposit_refund', v_d.id,
          'Hostel security deposit refunded, voucher ' || btrim(p_voucher_no), (select auth.uid()));
  update public.hostel_security_deposit set refunded_on = v_day, refund_voucher_no = btrim(p_voucher_no) where id = p_deposit_id;
end;
$$;
revoke execute on function public.refund_hostel_deposit(uuid, text, date) from public, anon;
grant execute on function public.refund_hostel_deposit(uuid, text, date) to authenticated;
