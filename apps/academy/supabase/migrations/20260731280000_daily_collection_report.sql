-- FR-K29: daily collection report and cash-book.
--
-- Scope cut, same shape as FR-K11/FR-K17: the FR's own "edge fn:
-- collection-report-export" and "bucket: fee-reports" (PDF/XLSX
-- rendering, a 15-minute signed URL) are not built. Everything the AC
-- actually tests — the report ties exactly to the ledger, mode
-- subtotals sum to the grand total with no residual bucket, and a later
-- reversal never rewrites an already-reported day — is built and
-- tested. build_collection_report_payload() hands a future exporter the
-- exact jsonb it would render, same pattern as
-- build_challan_render_payload() (FR-K11).
--
-- Reports key on value_date, per the FR's own Notes ("a payment keyed in
-- at 00:20 for yesterday's cash lands in the wrong day"), never
-- posted_at. A reversal is its own, later ledger row with entry_type =
-- 'reversal' and ITS OWN value_date (reverse_ledger_entry always uses
-- current_date, never backdated to the original entry's date) — so the
-- 12 August report, once run, only ever sees 12 August's own 'payment'
-- credits and never silently changes when a reversal posted on the 15th
-- comes along; the 15th's report picks up the reversal as its own line.
--
-- cash_book_day is the actual "close the day" record, and once
-- finalised it is immutable — re-finalising an already-finalised day is
-- refused outright, not just discouraged, because "reversals must never
-- rewrite a signed-off day" (the FR's own words) is exactly the
-- append-only discipline this whole module already holds fee_ledger to.

create index idx_fee_ledger_value_date on public.fee_ledger (campus_id, value_date) where entry_type in ('payment', 'refund');

-- Per-ledger-row detail, mode-joined, security_invoker so a caller only
-- ever sees rows their own RLS on fee_ledger/fee_payment already allows.
create view public.v_daily_collection
with (security_invoker = true) as
select
  fl.id as ledger_id, fl.tenant_id, fl.campus_id, fl.value_date, fl.enrolment_id, fl.amount_paisa,
  fp.mode, fp.id as payment_id
from public.fee_ledger fl
join public.fee_payment fp on fp.id = fl.source_id and fl.source_type = 'fee_payment'
where fl.entry_type = 'payment';

create or replace function public.daily_collection_report(p_campus_id uuid, p_from date, p_to date)
returns table (value_date date, mode public.fee_payment_mode, payment_count bigint, amount_paisa bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select vdc.value_date, vdc.mode, count(*)::bigint, sum(vdc.amount_paisa)::bigint
    from public.v_daily_collection vdc
   where vdc.tenant_id = app.auth_tenant_id()
     and vdc.campus_id = p_campus_id
     and vdc.value_date between p_from and p_to
     and (app.auth_role() in ('super_admin', 'owner', 'accountant', 'principal'))
   group by vdc.value_date, vdc.mode
   order by vdc.value_date, vdc.mode;
$$;

revoke execute on function public.daily_collection_report(uuid, date, date) from public, anon;
grant execute on function public.daily_collection_report(uuid, date, date) to authenticated;

-- Everything a future PDF/XLSX exporter needs: the same rows
-- daily_collection_report() returns, reshaped into a per-day
-- breakdown-by-mode plus a grand total, so "the three mode subtotals sum
-- to the grand total with no residual bucket" (the AC's own words) is
-- true by construction, not by client-side arithmetic.
create or replace function public.build_collection_report_payload(p_campus_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_by_day  jsonb;
  v_total   bigint;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'value_date', d.value_date,
           'by_mode', d.by_mode,
           'day_total_paisa', d.day_total
         ) order by d.value_date), '[]'::jsonb)
    into v_by_day
    from (
      select mc.value_date,
             jsonb_object_agg(mc.mode, jsonb_build_object('count', mc.payment_count, 'amount_paisa', mc.amount_paisa)) as by_mode,
             sum(mc.amount_paisa) as day_total
        from (
          select value_date, mode, count(*) as payment_count, sum(amount_paisa) as amount_paisa
            from public.v_daily_collection
           where tenant_id = app.auth_tenant_id() and campus_id = p_campus_id and value_date between p_from and p_to
           group by value_date, mode
        ) mc
       group by mc.value_date
    ) d;

  select coalesce(sum(amount_paisa), 0) into v_total
    from public.v_daily_collection
   where tenant_id = app.auth_tenant_id() and campus_id = p_campus_id and value_date between p_from and p_to;

  return jsonb_build_object('campus_id', p_campus_id, 'from', p_from, 'to', p_to, 'grand_total_paisa', v_total, 'by_day', v_by_day);
end;
$$;

revoke execute on function public.build_collection_report_payload(uuid, date, date) from public, anon;
grant execute on function public.build_collection_report_payload(uuid, date, date) to authenticated;

create table public.cash_book_day (
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  book_date        date not null,
  opening_paisa    bigint not null,
  receipts_paisa   bigint not null,
  disbursements_paisa bigint not null,
  closing_paisa    bigint not null,
  finalised_by     uuid references public.app_user(user_id),
  finalised_at     timestamptz not null default clock_timestamp(),
  primary key (tenant_id, campus_id, book_date)
);

-- Closes a day's cash book: opening = the previous finalised day's
-- closing (0 if this is the first day ever finalised for the campus),
-- receipts = that day's 'payment' credits, disbursements = that day's
-- 'reversal' entries reversing a payment (the only cash-out entry type
-- this module can post today), closing = opening + receipts -
-- disbursements. Refuses to run twice for the same day — a signed-off
-- day is exactly that.
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
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.cash_book_day where tenant_id = v_tenant_id and campus_id = p_campus_id and book_date = p_book_date) then
    raise exception 'ALREADY_FINALISED' using errcode = '55000';
  end if;

  select closing_paisa into v_opening
    from public.cash_book_day
   where tenant_id = v_tenant_id and campus_id = p_campus_id and book_date < p_book_date
   order by book_date desc
   limit 1;
  v_opening := coalesce(v_opening, 0);

  select coalesce(sum(amount_paisa), 0) into v_receipts
    from public.v_daily_collection
   where tenant_id = v_tenant_id and campus_id = p_campus_id and value_date = p_book_date;

  select coalesce(sum(fl.amount_paisa), 0) into v_disbursements
    from public.fee_ledger fl
   where fl.tenant_id = v_tenant_id and fl.campus_id = p_campus_id and fl.value_date = p_book_date
     and fl.entry_type = 'reversal'
     and exists (
       select 1 from public.fee_ledger orig
        where orig.id = fl.reversal_of_id and orig.entry_type = 'payment'
     );

  insert into public.cash_book_day (tenant_id, campus_id, book_date, opening_paisa, receipts_paisa, disbursements_paisa, closing_paisa, finalised_by)
  values (v_tenant_id, p_campus_id, p_book_date, v_opening, v_receipts, v_disbursements, v_opening + v_receipts - v_disbursements, auth.uid())
  returning * into v_row;

  return v_row;
end;
$$;

revoke execute on function public.finalise_cash_book_day(uuid, date) from public, anon;
grant execute on function public.finalise_cash_book_day(uuid, date) to authenticated;

alter table public.cash_book_day enable row level security;

create policy cash_book_day_campus_scope on public.cash_book_day
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
