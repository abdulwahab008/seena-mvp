-- Module K accounting hardening — two bugs found by an independent
-- second-pass review of this session's own new payment/receipt/report
-- code (FR-K16/K24/K17/K29), before the Agent tool that would normally
-- run this review became temporarily unavailable — reviewed directly
-- instead, same rigor.

-- ── 1. collect_cash_payment()'s idempotency check-then-insert could
--    race under a genuine concurrent double-submit ──────────────────────
--
-- Two near-simultaneous calls under the SAME client_idempotency_key (a
-- flaky counter connection firing the same "Confirm" click twice) could
-- both pass the "does a receipt already exist for this key" SELECT
-- before either committed, then both proceed to record_payment() and
-- the fee_receipt insert. The loser's insert hits fee_receipt_idem_uq
-- as an uncaught unique_violation, which rolls its ENTIRE transaction
-- back (Postgres transaction atomicity means no money actually ends up
-- double-committed), but the caller sees a raw, unhandled database
-- error instead of the graceful idempotent replay the AC's own
-- flaky-connection scenario asks for. Fixed with an advisory lock keyed
-- on (tenant, idempotency key), acquired BEFORE the existence check, so
-- the second call blocks until the first's transaction has fully
-- committed (or rolled back) and then correctly finds — and replays —
-- the first call's real receipt.

create or replace function public.collect_cash_payment(
  p_challan_id uuid, p_amount_paisa bigint, p_client_idempotency_key text,
  p_mode public.fee_payment_mode default 'cash', p_reference_no text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_challan    public.fee_challan%rowtype;
  v_existing   record;
  v_payment_id uuid;
  v_receipt_id uuid;
  v_receipt_no text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_client_idempotency_key is null or btrim(p_client_idempotency_key) = '' then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED' using errcode = '23514';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('collect-cash:' || v_tenant_id::text || ':' || p_client_idempotency_key, 0));

  -- A retry (flaky connection, double-tapped Confirm) replays the
  -- original outcome untouched — no second payment, no second ledger
  -- credit, no second receipt number burned.
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

  v_payment_id := public.record_payment(v_challan.enrolment_id, p_amount_paisa, p_mode, p_reference_no);
  v_receipt_no := app.fn_next_receipt_no(v_tenant_id, v_challan.campus_id, v_challan.session_id);

  insert into public.fee_receipt (tenant_id, campus_id, payment_id, receipt_no, client_idempotency_key)
  values (v_tenant_id, v_challan.campus_id, v_payment_id, v_receipt_no, p_client_idempotency_key)
  returning id into v_receipt_id;

  return jsonb_build_object(
    'receipt_id', v_receipt_id, 'receipt_no', v_receipt_no, 'payment_id', v_payment_id, 'is_replay', false
  );
end;
$$;

-- ── 2. finalise_cash_book_day() allowed finalising days out of
--    chronological order ───────────────────────────────────────────────
--
-- Nothing stopped finalising, say, the 15th before the 12th. Since a
-- finalised row is immutable (this function's own point, and the
-- module's whole "reversals must never rewrite a signed-off day"
-- design), finalising out of order permanently corrupts the running
-- opening/closing chain: the 15th would open at whatever was the most
-- recent finalised day AT THE TIME (possibly zero, if nothing had been
-- finalised yet), and there is no way to correct it afterwards once the
-- 12th's real closing exists — the 15th's own closing balance is simply
-- wrong forever. Fixed by refusing to finalise a day while any LATER
-- day is already finalised for the same campus. Gaps are still allowed
-- (skipping a Sunday with no transactions) — only going backwards past
-- an already-finalised day is refused.

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
  if exists (select 1 from public.cash_book_day where tenant_id = v_tenant_id and campus_id = p_campus_id and book_date > p_book_date) then
    raise exception 'CANNOT_FINALISE_BEFORE_A_LATER_FINALISED_DAY' using errcode = '55000';
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
