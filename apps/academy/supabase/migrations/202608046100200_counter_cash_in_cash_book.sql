-- Gap closing: money taken at a counter feeds the cash-counter day close and the daily collection
-- report exactly once.
--
--   * FR-R02  cash counter sales of stock (and cash credit-note refunds) -> v_inv_cash_book_entry
--   * FR-O07  library fines settled at the counter (not those settled by a lost-book write-off,
--             whose amount is inside the LIB_RECOVERY charge on the fee ledger, and not waived ones)
--   * FR-O08  the LIB_RECOVERY charge itself is a fee-ledger charge collected on the challan, so it
--             reaches the cash book through the normal fee payment, never directly (checked, no change)
--
-- How the numbers flow, with no double counting:
--   v_daily_collection is the one source of "money received on a day". It already carried fee
--   payments (ledger 'payment' credits); it now also carries cash counter sales and cash-settled
--   library fines as mode 'cash' rows. daily_collection_report(), build_collection_report_payload()
--   and finalise_cash_book_day() all read that view, so the report, the mode subtotals, the grand
--   total and the day close agree by construction. Charge-to-fee sales are not cash and stay out
--   (they are on the challan; their ledger charge is not a 'payment').
--   Cash refunds of returned stock (credit notes with cash settlement) are cash out: they are
--   counted in the day's disbursements, like a reversed payment, and are not in the collection report.
--
-- Finalised days stay immutable:
--   * a sale / credit note / fine settlement is stamped with a book_date when it happens. If that
--     calendar day (Asia/Karachi) is already closed for the campus, the entry is booked on the next
--     open day, so a closed day's totals can never change after the fact. The stamp is written
--     once, in a BEFORE trigger, and inv_sale rows are immutable afterwards.
--   * finalise_cash_book_day and the stamping trigger take the same per-campus advisory lock, so a
--     sale racing the close lands wholly inside the day or wholly on the next one.
--   * cash_book_day rows can no longer be updated or deleted at all.

-- ── immutable close ─────────────────────────────────────────────────────────
create or replace function app.tg_cash_book_day_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'CASH_BOOK_DAY_IMMUTABLE' using errcode = '55000', detail = 'A finalised cash book day is never changed.';
end;
$$;
drop trigger if exists trg_cash_book_day_immutable on public.cash_book_day;
create trigger trg_cash_book_day_immutable before update or delete on public.cash_book_day
  for each row execute function app.tg_cash_book_day_immutable();

-- ── the day an entry is booked on ───────────────────────────────────────────
create or replace function app.fn_cash_book_date(p_tenant uuid, p_campus uuid)
returns date
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := (clock_timestamp() at time zone 'Asia/Karachi')::date;
  v_last  date;
begin
  perform pg_advisory_xact_lock(hashtextextended('cash-book:' || p_campus::text, 0));
  select max(book_date) into v_last from public.cash_book_day where tenant_id = p_tenant and campus_id = p_campus;
  return greatest(v_today, coalesce(v_last + 1, v_today));
end;
$$;
revoke execute on function app.fn_cash_book_date(uuid, uuid) from public, anon, authenticated;

alter table public.inv_sale add column if not exists book_date date;
alter table public.library_fine add column if not exists settled_book_date date;

create or replace function app.tg_inv_sale_book_date()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.settlement = 'cash' then
    new.book_date := app.fn_cash_book_date(new.tenant_id, new.campus_id);
  end if;
  return new;
end;
$$;
revoke execute on function app.tg_inv_sale_book_date() from public, anon, authenticated;
drop trigger if exists trg_inv_sale_book_date on public.inv_sale;
create trigger trg_inv_sale_book_date before insert on public.inv_sale
  for each row execute function app.tg_inv_sale_book_date();

-- A fine counts as cash received when it is settled at the counter. One settled by a write-off
-- (write_off_id set in the same update) is part of the LIB_RECOVERY charge, not cash.
create or replace function app.tg_library_fine_book_date()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'settled' and new.write_off_id is null then
    if old.status is distinct from 'settled' or old.settled_book_date is null then
      new.settled_book_date := app.fn_cash_book_date(new.tenant_id, new.campus_id);
    end if;
  else
    new.settled_book_date := null;
  end if;
  return new;
end;
$$;
revoke execute on function app.tg_library_fine_book_date() from public, anon, authenticated;
drop trigger if exists trg_library_fine_book_date on public.library_fine;
create trigger trg_library_fine_book_date before update on public.library_fine
  for each row execute function app.tg_library_fine_book_date();

-- ── sources ─────────────────────────────────────────────────────────────────
create or replace view public.v_inv_cash_book_entry
with (security_invoker = true) as
select s.tenant_id, s.campus_id, coalesce(s.book_date, (s.sold_at at time zone 'Asia/Karachi')::date) as book_date,
       s.id as sale_id, s.serial, s.doc_type,
       case when s.doc_type = 'sale' then s.total else -s.total end as amount_paisa
  from public.inv_sale s
 where s.settlement = 'cash';

-- One row per settlement (receipt when given, else per loan) so a fine that accrued over six nights
-- and was settled in one go counts as one receipt, not six.
drop view if exists public.v_daily_collection;
drop view if exists public.v_library_fine_cash_entry;
create view public.v_library_fine_cash_entry
with (security_invoker = true) as
select f.tenant_id, f.campus_id, f.settled_book_date as book_date,
       coalesce(f.settled_receipt_id::text, f.loan_id::text) as receipt_key, sum(f.amount)::bigint as amount_paisa
  from public.library_fine f
 where f.status = 'settled' and f.write_off_id is null and f.settled_book_date is not null
 group by f.tenant_id, f.campus_id, f.settled_book_date, coalesce(f.settled_receipt_id::text, f.loan_id::text);
revoke all on public.v_library_fine_cash_entry from public, anon;
grant select on public.v_library_fine_cash_entry to authenticated;

-- One view of money received on a day. Existing columns keep their order and types.
create view public.v_daily_collection
with (security_invoker = true) as
select
  fl.id as ledger_id, fl.tenant_id, fl.campus_id, fl.value_date, fl.enrolment_id, fl.amount_paisa,
  fp.mode, fp.id as payment_id, 'fee_payment'::text as source
from public.fee_ledger fl
join public.fee_payment fp on fp.id = fl.source_id and fl.source_type = 'fee_payment'
where fl.entry_type = 'payment'
union all
select null::uuid, c.tenant_id, c.campus_id, c.book_date, null::uuid, c.amount_paisa,
       'cash'::public.fee_payment_mode, null::uuid, 'inv_sale'::text
  from public.v_inv_cash_book_entry c
 where c.doc_type = 'sale'
union all
select null::uuid, f.tenant_id, f.campus_id, f.book_date, null::uuid, f.amount_paisa,
       'cash'::public.fee_payment_mode, null::uuid, 'library_fine'::text
  from public.v_library_fine_cash_entry f;

-- ── the day close ───────────────────────────────────────────────────────────
create or replace function public.finalise_cash_book_day(p_campus_id uuid, p_book_date date)
returns public.cash_book_day
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_opening       bigint;
  v_receipts      bigint;
  v_disbursements bigint;
  v_row           public.cash_book_day%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Same lock the counter-sale / fine-settlement stamping takes, so nothing slips in mid-close.
  perform pg_advisory_xact_lock(hashtextextended('cash-book:' || p_campus_id::text, 0));

  if exists (select 1 from public.cash_book_day where tenant_id = v_tenant_id and campus_id = p_campus_id and book_date = p_book_date) then
    raise exception 'ALREADY_FINALISED' using errcode = '55000';
  end if;
  if exists (select 1 from public.cash_book_day where tenant_id = v_tenant_id and campus_id = p_campus_id and book_date > p_book_date) then
    raise exception 'CANNOT_FINALISE_BEFORE_A_LATER_FINALISED_DAY' using errcode = '55000';
  end if;

  select closing_paisa into v_opening
    from public.cash_book_day
   where tenant_id = v_tenant_id and campus_id = p_campus_id and book_date < p_book_date
   order by book_date desc
   limit 1;
  v_opening := coalesce(v_opening, 0);

  -- fee payments + cash counter sales + cash-settled library fines
  select coalesce(sum(amount_paisa), 0) into v_receipts
    from public.v_daily_collection
   where tenant_id = v_tenant_id and campus_id = p_campus_id and value_date = p_book_date;

  -- reversed payments + cash refunds of returned stock
  select coalesce((
           select sum(fl.amount_paisa)
             from public.fee_ledger fl
            where fl.tenant_id = v_tenant_id and fl.campus_id = p_campus_id and fl.value_date = p_book_date
              and fl.entry_type = 'reversal'
              and exists (select 1 from public.fee_ledger orig where orig.id = fl.reversal_of_id and orig.entry_type = 'payment')
         ), 0)
       + coalesce((
           select sum(-c.amount_paisa)
             from public.v_inv_cash_book_entry c
            where c.tenant_id = v_tenant_id and c.campus_id = p_campus_id and c.book_date = p_book_date and c.doc_type = 'credit_note'
         ), 0)
    into v_disbursements;

  insert into public.cash_book_day (tenant_id, campus_id, book_date, opening_paisa, receipts_paisa, disbursements_paisa, closing_paisa, finalised_by)
  values (v_tenant_id, p_campus_id, p_book_date, v_opening, v_receipts, v_disbursements, v_opening + v_receipts - v_disbursements, auth.uid())
  returning * into v_row;

  return v_row;
end;
$$;
revoke execute on function public.finalise_cash_book_day(uuid, date) from public, anon;
grant execute on function public.finalise_cash_book_day(uuid, date) to authenticated;
