-- FR-D17: final settlement statement computation.
--
-- compute_final_settlement(exit) builds the leaver's dues line by line from
-- data already in the system; create_settlement_draft() stores it; an
-- Accountant or the Owner approves it, at which point the statement (header and
-- lines) is frozen and its PDF is rendered ONCE, stored in the private
-- staff-settlements bucket and sealed with its SHA-256. Every later download
-- serves the stored bytes and re-checks the hash; nothing is recomputed.
--
-- Money is bigint paisa, like the loans table it reads; the AC figures are the
-- same numbers (Rs 51,612.90 = 5,161,290 paisa). Each line is rounded to the
-- paisa on its own and the total is the SUM of the rounded lines, so the
-- printed lines always tie to the printed total.
--
--   salary           gross x days worked in the last month / days in that month
--                    (from the later of the 1st or the joining date to the last
--                    working date, inclusive)
--   leave_encashment per ENCASHABLE leave type (leave_type.is_encashable - never
--                    hardcoded): min(unused balance, encashment_cap_days) x daily rate,
--                    daily rate = gross / 30 rounded to the paisa
--   notice_recovery  the notice shortfall carried from the exit x daily rate (a deduction)
--   advance_recovery every active or paused loan's outstanding balance (a deduction)
--   gratuity / asset_recovery / other   entered by hand on a draft
--
-- Approval also posts the encashed days to the leave ledger. Marking the
-- statement paid closes the recovered loans.
--
-- Not computed: gratuity has no statutory formula configured in this system, so
-- it is a manual line; a month already paid through a payroll run is not
-- netted off the salary line (the Accountant removes or adjusts it).

alter table public.leave_type add column if not exists encashment_cap_days numeric(5, 2) check (encashment_cap_days is null or encashment_cap_days >= 0);

create type public.settlement_status as enum ('draft', 'approved', 'paid');
create type public.settlement_line_type as enum ('salary', 'leave_encashment', 'gratuity', 'notice_recovery', 'advance_recovery', 'asset_recovery', 'other');

create table public.staff_settlement (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  exit_id           uuid not null references public.staff_exit(id),
  version           smallint not null default 1,
  status            public.settlement_status not null default 'draft',
  net_payable_paisa bigint not null default 0,
  created_by        uuid references public.app_user(user_id),
  created_at        timestamptz not null default now(),
  approved_by       uuid references public.app_user(user_id),
  approved_at       timestamptz,
  paid_by           uuid references public.app_user(user_id),
  paid_at           timestamptz,
  superseded_at     timestamptz,
  pdf_storage_path  text,
  pdf_sha256        text check (pdf_sha256 is null or pdf_sha256 ~ '^[0-9a-f]{64}$'),
  constraint uq_settlement_exit_version unique (exit_id, version),
  constraint chk_settlement_approved check ((status = 'draft') = (approved_at is null)),
  constraint chk_settlement_pdf_pair check ((pdf_storage_path is null) = (pdf_sha256 is null))
);
create index idx_settlement_exit on public.staff_settlement (exit_id);
create index idx_settlement_tenant_status on public.staff_settlement (tenant_id, status);
create index idx_settlement_campus on public.staff_settlement (campus_id);

create table public.staff_settlement_line (
  id            uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references public.staff_settlement(id) on delete cascade,
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  line_type     public.settlement_line_type not null,
  description   text not null check (char_length(btrim(description)) between 1 and 300),
  amount_paisa  bigint not null check (amount_paisa >= 0),
  sign          smallint not null check (sign in (1, -1)),
  sort_order    smallint not null default 0,
  is_manual     boolean not null default false,
  leave_type_id uuid references public.leave_type(id),
  leave_days    numeric(5, 2),
  loan_id       uuid references public.staff_loan(id)
);
create index idx_settlement_line_settlement on public.staff_settlement_line (settlement_id, sort_order);
create index idx_settlement_line_tenant on public.staff_settlement_line (tenant_id);

create trigger staff_settlement_audit after insert or update or delete on public.staff_settlement
  for each row execute function app.tg_audit_row();
create trigger staff_settlement_line_audit after insert or update or delete on public.staff_settlement_line
  for each row execute function app.tg_audit_row();

-- ── immutability once approved ────────────────────────────────────────────

create or replace function app.tg_settlement_no_update_when_approved()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_strip text[] := array['status', 'paid_at', 'paid_by', 'pdf_storage_path', 'pdf_sha256', 'superseded_at'];
begin
  if tg_op = 'DELETE' then
    if old.status <> 'draft' then
      raise exception 'SETTLEMENT_IMMUTABLE' using errcode = '42501';
    end if;
    return old;
  end if;
  if old.status = 'draft' then
    return new;
  end if;
  -- approved / paid: only the pay transition, the one-time PDF seal and the superseded stamp may change
  if (to_jsonb(new) - v_strip) is distinct from (to_jsonb(old) - v_strip) then
    raise exception 'SETTLEMENT_IMMUTABLE' using errcode = '42501';
  end if;
  if new.status is distinct from old.status and not (old.status = 'approved' and new.status = 'paid') then
    raise exception 'SETTLEMENT_IMMUTABLE' using errcode = '42501';
  end if;
  if old.pdf_sha256 is not null and (new.pdf_sha256 is distinct from old.pdf_sha256 or new.pdf_storage_path is distinct from old.pdf_storage_path) then
    raise exception 'SETTLEMENT_PDF_SEALED' using errcode = '42501';
  end if;
  if old.superseded_at is not null and new.superseded_at is distinct from old.superseded_at then
    raise exception 'SETTLEMENT_IMMUTABLE' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger settlement_no_update_when_approved before update or delete on public.staff_settlement
  for each row execute function app.tg_settlement_no_update_when_approved();

create or replace function app.tg_settlement_line_draft_only()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.settlement_status;
begin
  select status into v_status from public.staff_settlement where id = coalesce(new.settlement_id, old.settlement_id);
  -- the parent being deleted with its draft cascades through here with no parent left to read
  if v_status is not null and v_status <> 'draft' then
    raise exception 'SETTLEMENT_IMMUTABLE' using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;
create trigger settlement_line_draft_only before insert or update or delete on public.staff_settlement_line
  for each row execute function app.tg_settlement_line_draft_only();

alter table public.staff_settlement enable row level security;
alter table public.staff_settlement_line enable row level security;
create policy settlement_accountant_hr_owner_only on public.staff_settlement for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
create policy settlement_line_accountant_hr_owner_only on public.staff_settlement_line for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.staff_settlement s where s.id = settlement_id));
revoke insert, update, delete on public.staff_settlement, public.staff_settlement_line from authenticated, anon;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('staff-settlements', 'staff-settlements', false, 5242880, array['application/pdf'])
on conflict (id) do nothing;

-- 12.00 -> '12', 10.50 -> '10.5' (never strips the zeros of a whole number)
create or replace function app.fn_days_text(p_days numeric)
returns text
language sql
immutable
set search_path = ''
as $$ select trim(trailing '.' from regexp_replace(round(p_days, 2)::numeric(9, 2)::text, '0+$', '')); $$;
revoke execute on function app.fn_days_text(numeric) from public, anon, authenticated;

-- ── the arithmetic ────────────────────────────────────────────────────────

create or replace function app.fn_settlement_lines(p_exit_id uuid)
returns table (line_type public.settlement_line_type, description text, amount_paisa bigint, sign smallint, sort_order smallint,
               leave_type_id uuid, leave_days numeric, loan_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_exit    public.staff_exit%rowtype;
  v_staff   public.staff%rowtype;
  v_gross   numeric(12, 2);
  v_gross_p bigint;
  v_daily_p bigint;
  v_start   date;
  v_days    integer;
  v_dim     integer;
  v_amount  bigint;
  lt        record;
  ln        record;
  v_bal     numeric;
  v_unused  numeric;
  v_enc     numeric;
  v_order   smallint := 10;
begin
  select * into v_exit from public.staff_exit where id = p_exit_id;
  if not found then
    raise exception 'EXIT_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into v_staff from public.staff where id = v_exit.staff_id;

  select p.gross_salary into v_gross
    from public.staff_contract c join public.staff_contract_pay p on p.contract_id = c.id
   where c.staff_id = v_exit.staff_id
   order by (c.start_date <= v_exit.last_working_date and (c.end_date is null or c.end_date >= v_exit.last_working_date)) desc, c.start_date desc
   limit 1;
  if v_gross is null then
    raise exception 'NO_SALARY_ON_FILE' using errcode = '22023';
  end if;
  v_gross_p := round(v_gross * 100)::bigint;
  v_daily_p := round(v_gross_p / 30.0)::bigint;

  -- salary for the final (part) month
  v_start := greatest(date_trunc('month', v_exit.last_working_date)::date, v_staff.doj);
  v_days := v_exit.last_working_date - v_start + 1;
  v_dim := extract(day from (date_trunc('month', v_exit.last_working_date) + interval '1 month - 1 day'))::integer;
  if v_days > 0 then
    v_amount := round(v_gross_p::numeric * v_days / v_dim)::bigint;
    return query select 'salary'::public.settlement_line_type,
      format('Salary %s to %s (%s of %s days)', to_char(v_start, 'DD Mon YYYY'), to_char(v_exit.last_working_date, 'DD Mon YYYY'), v_days, v_dim),
      v_amount, 1::smallint, 1::smallint, null::uuid, null::numeric, null::uuid;
  end if;

  -- encashable leave only: the leave type decides, nothing is hardcoded
  for lt in
    select t.id, t.name_en, t.encashment_cap_days
      from public.leave_type t
     where t.tenant_id = v_exit.tenant_id and t.is_encashable and t.is_active
     order by t.code
  loop
    -- read the ledger directly: fn_leave_balance() is scoped to the caller's own role, and the Accountant is not an HR role
    select coalesce(sum(ll.days), 0) into v_bal from public.leave_ledger ll where ll.staff_id = v_exit.staff_id and ll.leave_type_id = lt.id;
    v_unused := greatest(v_bal, 0);
    v_enc := least(v_unused, coalesce(lt.encashment_cap_days, v_unused));
    if v_enc > 0 then
      return query select 'leave_encashment'::public.settlement_line_type,
        format('%s encashment: %s day(s)%s at %s per day', lt.name_en, app.fn_days_text(v_enc),
               case when lt.encashment_cap_days is not null and v_unused > lt.encashment_cap_days
                    then format(' (%s unused, capped at %s)', app.fn_days_text(v_unused), app.fn_days_text(lt.encashment_cap_days)) else '' end,
               to_char(v_daily_p / 100.0, 'FM999,999,990.00')),
        round(v_enc * v_daily_p)::bigint, 1::smallint, v_order, lt.id, v_enc, null::uuid;
      v_order := v_order + 1;
    end if;
  end loop;

  -- notice shortfall carried from the exit
  if v_exit.notice_shortfall_days > 0 then
    return query select 'notice_recovery'::public.settlement_line_type,
      format('Notice shortfall recovery: %s day(s) at %s per day', v_exit.notice_shortfall_days, to_char(v_daily_p / 100.0, 'FM999,999,990.00')),
      v_exit.notice_shortfall_days * v_daily_p, (-1)::smallint, 50::smallint, null::uuid, null::numeric, null::uuid;
  end if;

  -- outstanding loans and advances
  v_order := 60;
  for ln in
    select l.id, l.loan_type, l.principal_paisa - l.total_repaid_paisa as outstanding
      from public.staff_loan l
     where l.staff_id = v_exit.staff_id and l.status in ('active', 'paused') and l.principal_paisa - l.total_repaid_paisa > 0
     order by l.disbursed_at, l.id
  loop
    return query select 'advance_recovery'::public.settlement_line_type,
      format('Outstanding %s recovery', replace(ln.loan_type, '_', ' ')), ln.outstanding, (-1)::smallint, v_order, null::uuid, null::numeric, ln.id;
    v_order := v_order + 1;
  end loop;
end;
$$;
revoke execute on function app.fn_settlement_lines(uuid) from public, anon, authenticated;

create or replace function app.fn_settlement_actor_ok(p_exit_id uuid)
returns public.staff_exit
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_exit public.staff_exit%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_exit from public.staff_exit where id = p_exit_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'EXIT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_exit.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return v_exit;
end;
$$;
revoke execute on function app.fn_settlement_actor_ok(uuid) from public, anon, authenticated;

create or replace function public.compute_final_settlement(p_exit_id uuid)
returns table (line_type public.settlement_line_type, description text, amount_paisa bigint, sign smallint)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.fn_settlement_actor_ok(p_exit_id);
  return query select l.line_type, l.description, l.amount_paisa, l.sign from app.fn_settlement_lines(p_exit_id) l order by l.sort_order;
end;
$$;
revoke execute on function public.compute_final_settlement(uuid) from public, anon;
grant execute on function public.compute_final_settlement(uuid) to authenticated;

create or replace function app.fn_settlement_recalc(p_settlement_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.staff_settlement s
     set net_payable_paisa = coalesce((select sum(l.sign * l.amount_paisa) from public.staff_settlement_line l where l.settlement_id = s.id), 0)
   where s.id = p_settlement_id;
$$;
revoke execute on function app.fn_settlement_recalc(uuid) from public, anon, authenticated;

-- ── draft, manual lines, approval ─────────────────────────────────────────

create or replace function public.create_settlement_draft(p_exit_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_exit public.staff_exit%rowtype;
  v_cur  public.staff_settlement%rowtype;
  v_id   uuid;
begin
  v_exit := app.fn_settlement_actor_ok(p_exit_id);
  select * into v_cur from public.staff_settlement where exit_id = p_exit_id and superseded_at is null order by version desc limit 1;
  if found and v_cur.status <> 'draft' then
    raise exception 'SETTLEMENT_ALREADY_APPROVED' using errcode = '55000';
  end if;
  if found then
    v_id := v_cur.id;
    delete from public.staff_settlement_line where settlement_id = v_id and not is_manual;
  else
    insert into public.staff_settlement (tenant_id, campus_id, exit_id, version, created_by)
    values (v_exit.tenant_id, v_exit.campus_id, p_exit_id, coalesce((select max(version) from public.staff_settlement where exit_id = p_exit_id), 0) + 1, (select auth.uid()))
    returning id into v_id;
  end if;
  insert into public.staff_settlement_line (settlement_id, tenant_id, line_type, description, amount_paisa, sign, sort_order, leave_type_id, leave_days, loan_id)
  select v_id, v_exit.tenant_id, l.line_type, l.description, l.amount_paisa, l.sign, l.sort_order, l.leave_type_id, l.leave_days, l.loan_id
    from app.fn_settlement_lines(p_exit_id) l;
  perform app.fn_settlement_recalc(v_id);
  return v_id;
end;
$$;
revoke execute on function public.create_settlement_draft(uuid) from public, anon;
grant execute on function public.create_settlement_draft(uuid) to authenticated;

-- A corrected statement after approval: a new version (copy of every line), the old one stays on record.
create or replace function public.revise_settlement(p_settlement_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old public.staff_settlement%rowtype;
  v_id  uuid;
begin
  select * into v_old from public.staff_settlement where id = p_settlement_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'SETTLEMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_settlement_actor_ok(v_old.exit_id);
  if v_old.status <> 'approved' or v_old.superseded_at is not null then
    raise exception 'SETTLEMENT_NOT_REVISABLE' using errcode = '55000';
  end if;
  update public.staff_settlement set superseded_at = clock_timestamp() where id = p_settlement_id;
  insert into public.staff_settlement (tenant_id, campus_id, exit_id, version, created_by)
  values (v_old.tenant_id, v_old.campus_id, v_old.exit_id, (select max(version) from public.staff_settlement where exit_id = v_old.exit_id) + 1, (select auth.uid()))
  returning id into v_id;
  insert into public.staff_settlement_line (settlement_id, tenant_id, line_type, description, amount_paisa, sign, sort_order, is_manual, leave_type_id, leave_days, loan_id)
  select v_id, tenant_id, line_type, description, amount_paisa, sign, sort_order, is_manual, leave_type_id, leave_days, loan_id
    from public.staff_settlement_line where settlement_id = p_settlement_id;
  perform app.fn_settlement_recalc(v_id);
  return v_id;
end;
$$;
revoke execute on function public.revise_settlement(uuid) from public, anon;
grant execute on function public.revise_settlement(uuid) to authenticated;

create or replace function public.add_settlement_line(p_settlement_id uuid, p_line_type public.settlement_line_type, p_description text, p_amount_paisa bigint, p_sign smallint)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s  public.staff_settlement%rowtype;
  v_id uuid;
begin
  select * into v_s from public.staff_settlement where id = p_settlement_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SETTLEMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_settlement_actor_ok(v_s.exit_id);
  if v_s.status <> 'draft' then
    raise exception 'SETTLEMENT_IMMUTABLE' using errcode = '42501';
  end if;
  if p_line_type in ('salary', 'leave_encashment', 'notice_recovery') then
    raise exception 'LINE_TYPE_COMPUTED' using errcode = '22023';
  end if;
  if p_amount_paisa is null or p_amount_paisa <= 0 or p_sign not in (1, -1) then
    raise exception 'LINE_INVALID' using errcode = '22023';
  end if;
  if p_line_type in ('advance_recovery', 'asset_recovery') and p_sign <> -1 then
    raise exception 'LINE_INVALID' using errcode = '22023';
  end if;
  insert into public.staff_settlement_line (settlement_id, tenant_id, line_type, description, amount_paisa, sign, sort_order, is_manual)
  values (p_settlement_id, v_s.tenant_id, p_line_type, btrim(p_description), p_amount_paisa, p_sign, 100 + (select count(*) from public.staff_settlement_line where settlement_id = p_settlement_id), true)
  returning id into v_id;
  perform app.fn_settlement_recalc(p_settlement_id);
  return v_id;
end;
$$;
revoke execute on function public.add_settlement_line(uuid, public.settlement_line_type, text, bigint, smallint) from public, anon;
grant execute on function public.add_settlement_line(uuid, public.settlement_line_type, text, bigint, smallint) to authenticated;

create or replace function public.remove_settlement_line(p_line_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_l public.staff_settlement_line%rowtype;
  v_s public.staff_settlement%rowtype;
begin
  select * into v_l from public.staff_settlement_line where id = p_line_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'LINE_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into v_s from public.staff_settlement where id = v_l.settlement_id;
  perform app.fn_settlement_actor_ok(v_s.exit_id);
  if v_s.status <> 'draft' then
    raise exception 'SETTLEMENT_IMMUTABLE' using errcode = '42501';
  end if;
  if not v_l.is_manual then
    raise exception 'LINE_IS_COMPUTED' using errcode = '22023';
  end if;
  delete from public.staff_settlement_line where id = p_line_id;
  perform app.fn_settlement_recalc(v_s.id);
end;
$$;
revoke execute on function public.remove_settlement_line(uuid) from public, anon;
grant execute on function public.remove_settlement_line(uuid) to authenticated;

create or replace function public.approve_settlement(p_settlement_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s   public.staff_settlement%rowtype;
  v_exit public.staff_exit%rowtype;
  l     record;
begin
  select * into v_s from public.staff_settlement where id = p_settlement_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'SETTLEMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_exit := app.fn_settlement_actor_ok(v_s.exit_id);
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_s.status <> 'draft' then
    raise exception 'SETTLEMENT_IMMUTABLE' using errcode = '42501';
  end if;
  perform app.fn_settlement_recalc(p_settlement_id);
  update public.staff_settlement set status = 'approved', approved_by = (select auth.uid()), approved_at = clock_timestamp() where id = p_settlement_id;
  -- the encashed days leave the leave ledger
  for l in select * from public.staff_settlement_line where settlement_id = p_settlement_id and line_type = 'leave_encashment' and leave_type_id is not null loop
    insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
    values (v_s.tenant_id, v_exit.staff_id, l.leave_type_id, 'encashment', -l.leave_days, p_settlement_id, (select auth.uid()));
  end loop;
end;
$$;
revoke execute on function public.approve_settlement(uuid) from public, anon;
grant execute on function public.approve_settlement(uuid) to authenticated;

create or replace function public.mark_settlement_paid(p_settlement_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s public.staff_settlement%rowtype;
begin
  select * into v_s from public.staff_settlement where id = p_settlement_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'SETTLEMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_settlement_actor_ok(v_s.exit_id);
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_s.status <> 'approved' or v_s.superseded_at is not null then
    raise exception 'SETTLEMENT_NOT_PAYABLE' using errcode = '55000';
  end if;
  update public.staff_settlement set status = 'paid', paid_by = (select auth.uid()), paid_at = clock_timestamp() where id = p_settlement_id;
  update public.staff_loan l set status = 'closed', total_repaid_paisa = l.principal_paisa
   where l.id in (select loan_id from public.staff_settlement_line where settlement_id = p_settlement_id and loan_id is not null);
end;
$$;
revoke execute on function public.mark_settlement_paid(uuid) from public, anon;
grant execute on function public.mark_settlement_paid(uuid) to authenticated;

-- ── the PDF is rendered once and sealed (called by the render route with the service role) ──

create or replace function public.store_settlement_pdf(p_settlement_id uuid, p_storage_path text, p_sha256 text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s public.staff_settlement%rowtype;
begin
  select * into v_s from public.staff_settlement where id = p_settlement_id for update;
  if not found then
    raise exception 'SETTLEMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_s.status = 'draft' then
    raise exception 'SETTLEMENT_NOT_APPROVED' using errcode = '55000';
  end if;
  if v_s.pdf_sha256 is not null then
    raise exception 'SETTLEMENT_PDF_SEALED' using errcode = '42501';
  end if;
  update public.staff_settlement set pdf_storage_path = p_storage_path, pdf_sha256 = lower(p_sha256) where id = p_settlement_id;
end;
$$;
revoke execute on function public.store_settlement_pdf(uuid, text, text) from public, anon, authenticated;
grant execute on function public.store_settlement_pdf(uuid, text, text) to service_role;
