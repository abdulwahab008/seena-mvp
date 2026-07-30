-- FR-K17: cash counter collection and receipt.
--
-- Scope cut, same shape as FR-K11 (three-copy bank challan PDF): the
-- actual PDF rendering (the FR's own "edge fn: receipt-pdf" and
-- "bucket: receipts") is not built. Every OTHER acceptance criterion —
-- barcode/challan lookup with pre-filled amount, amount-in-words,
-- gapless receipt numbering, duplicate-print watermarking with a logged
-- reprint event, and client-idempotency-key protection against a flaky
-- connection double-charging a parent — is built and tested at the data
-- layer. A future renderer consumes print_receipt()'s jsonb payload
-- exactly the way FR-K11's challan renderer consumes
-- build_challan_render_payload()'s.
--
-- fee_receipt.counter_session_id exists as a bare nullable uuid, no FK
-- yet — FR-K18 (counter shift close and cash tally), which is what
-- would actually define a countable "counter session", is not built.
-- Same deferred-FK pattern already used for fee_ledger.challan_id before
-- FR-K09 shipped the table it references.
--
-- Idempotency (the AC's flaky-connection scenario) is enforced by
-- collect_cash_payment() checking for an existing fee_receipt under the
-- same (tenant_id, client_idempotency_key) BEFORE calling
-- record_payment() at all — a retry with the same key returns the
-- original receipt untouched, never a second payment or a second
-- ledger credit.

create table public.fee_receipt_counter (
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  session_id uuid not null references public.academic_session(id) on delete cascade,
  last_no    bigint not null default 0,
  primary key (tenant_id, campus_id, session_id)
);

-- Internal, service-role-shaped counter allocator — same row-locked
-- pattern as next_challan_no() (FR-K10), app.fn_allocate_gr_number()
-- (FR-C01) and app.fn_next_employee_code() (FR-D01). Not exposed
-- directly: only collect_cash_payment() calls it, already inside a
-- SECURITY DEFINER, role-checked, tenant-validated transaction.
create or replace function app.fn_next_receipt_no(p_tenant_id uuid, p_campus_id uuid, p_session_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_next bigint;
begin
  insert into public.fee_receipt_counter (tenant_id, campus_id, session_id, last_no)
  values (p_tenant_id, p_campus_id, p_session_id, 0)
  on conflict (tenant_id, campus_id, session_id) do nothing;

  update public.fee_receipt_counter set last_no = last_no + 1
   where tenant_id = p_tenant_id and campus_id = p_campus_id and session_id = p_session_id
  returning last_no into v_next;

  return 'RCP-' || lpad(v_next::text, 8, '0');
end;
$$;

revoke execute on function app.fn_next_receipt_no(uuid, uuid, uuid) from public, anon, authenticated;

create table public.fee_receipt (
  id                     uuid primary key default gen_random_uuid(),
  tenant_id              uuid not null references public.tenant(id) on delete cascade,
  campus_id              uuid not null references public.campus(id) on delete cascade,
  payment_id             uuid not null references public.fee_payment(id) on delete cascade,
  receipt_no             text not null,
  counter_session_id     uuid,
  printed_count          int not null default 0,
  client_idempotency_key text,
  created_at             timestamptz not null default now()
);

create unique index fee_receipt_no_uq on public.fee_receipt (tenant_id, receipt_no);
-- Partial: only counter-collected payments carry a client idempotency
-- key at all (record_payment() calls made elsewhere in the app, e.g.
-- directly from a student's ledger, have none) — a non-partial unique
-- index would collide the second and every later NULL.
create unique index fee_receipt_idem_uq on public.fee_receipt (tenant_id, client_idempotency_key) where client_idempotency_key is not null;
create index idx_fee_receipt_payment on public.fee_receipt (payment_id);

create table public.fee_receipt_print_log (
  id          uuid primary key default gen_random_uuid(),
  receipt_id  uuid not null references public.fee_receipt(id) on delete cascade,
  printed_by  uuid references public.app_user(user_id),
  printed_at  timestamptz not null default clock_timestamp()
);

create index idx_fee_receipt_print_log_receipt on public.fee_receipt_print_log (receipt_id);

-- ── amount-in-words ──────────────────────────────────────────────────
-- South Asian (lakh/crore) grouping, per the Pakistani-receipt
-- convention the AC's own example uses. Both helpers are pure
-- computation (no table access) but stay in the app schema, unexecutable
-- directly by authenticated — the same "internal helper, only reachable
-- through a SECURITY DEFINER caller" shape used everywhere else in this
-- schema, here needed only so the nested call from amount_in_words()
-- resolves under the definer's privileges rather than the caller's.

create or replace function app.fn_two_digit_words(p_n int)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_n = 0 then ''
    when p_n < 20 then (array['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine',
                               'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen',
                               'Seventeen', 'Eighteen', 'Nineteen'])[p_n + 1]
    else
      (array['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'])[p_n / 10 + 1]
      || case when p_n % 10 > 0
           then ' ' || (array['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine'])[p_n % 10 + 1]
           else '' end
  end;
$$;

create or replace function app.fn_three_digit_words(p_n int)
returns text
language sql
immutable
set search_path = ''
as $$
  select btrim(
    case when p_n >= 100
      then (array['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine'])[p_n / 100 + 1] || ' Hundred '
      else ''
    end
    || app.fn_two_digit_words(p_n % 100)
  );
$$;

revoke execute on function app.fn_two_digit_words(int) from public, anon, authenticated;
revoke execute on function app.fn_three_digit_words(int) from public, anon, authenticated;

-- security definer purely so the nested app.fn_three_digit_words() call
-- resolves (it executes as the function owner, same as every other
-- public function in this schema that calls an app.* helper) — this
-- function itself never touches a table.
create or replace function public.amount_in_words(p_amount_paisa bigint)
returns text
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  v_rupees   bigint := round(p_amount_paisa / 100.0);
  v_crore    bigint;
  v_lakh     bigint;
  v_thousand bigint;
  v_rest     bigint;
  v_parts    text[] := '{}';
begin
  if v_rupees < 0 then
    raise exception 'AMOUNT_MUST_BE_NONNEGATIVE' using errcode = '22023';
  end if;
  if v_rupees = 0 then
    return 'Rupees Zero Only';
  end if;

  v_crore := v_rupees / 10000000;
  v_rupees := v_rupees % 10000000;
  v_lakh := v_rupees / 100000;
  v_rupees := v_rupees % 100000;
  v_thousand := v_rupees / 1000;
  v_rest := v_rupees % 1000;

  if v_crore > 0 then
    v_parts := v_parts || (app.fn_three_digit_words(v_crore::int) || ' Crore');
  end if;
  if v_lakh > 0 then
    v_parts := v_parts || (app.fn_three_digit_words(v_lakh::int) || ' Lakh');
  end if;
  if v_thousand > 0 then
    v_parts := v_parts || (app.fn_three_digit_words(v_thousand::int) || ' Thousand');
  end if;
  if v_rest > 0 then
    v_parts := v_parts || app.fn_three_digit_words(v_rest::int);
  end if;

  return 'Rupees ' || array_to_string(v_parts, ' ') || ' Only';
end;
$$;

revoke execute on function public.amount_in_words(bigint) from public, anon;
grant execute on function public.amount_in_words(bigint) to authenticated;

-- ── counter flow ─────────────────────────────────────────────────────

-- AC: scanning a challan barcode pre-fills the amount field with net
-- payable — this is that lookup. "Outstanding" is THIS challan's own
-- remaining amount (net_paisa minus what has already been allocated to
-- it), not the student's whole-account balance — the accountant is
-- collecting against the scanned challan specifically.
create or replace function public.lookup_challan_for_counter(p_challan_no text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_challan  public.fee_challan%rowtype;
  v_student  record;
  v_allocated bigint;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_challan from public.fee_challan where challan_no = p_challan_no and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  select s.name_en, s.gr_number into v_student
    from public.enrolment e join public.student s on s.id = e.student_id
   where e.id = v_challan.enrolment_id;

  select coalesce(sum(amount_paisa), 0) into v_allocated from public.fee_payment_allocation where challan_id = v_challan.id;

  return jsonb_build_object(
    'challan_id', v_challan.id,
    'enrolment_id', v_challan.enrolment_id,
    'student_name', v_student.name_en,
    'gr_number', v_student.gr_number,
    'net_paisa', v_challan.net_paisa,
    'outstanding_paisa', greatest(v_challan.net_paisa - v_allocated, 0),
    'status', v_challan.status
  );
end;
$$;

revoke execute on function public.lookup_challan_for_counter(text) from public, anon;
grant execute on function public.lookup_challan_for_counter(text) to authenticated;

-- The counter's one atomic action: record the payment (FR-K16's own
-- waterfall decides how it applies), mint a gapless receipt number, and
-- return everything a receipt needs to render — all replayable, byte
-- for byte, under the same client_idempotency_key.
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

revoke execute on function public.collect_cash_payment(uuid, bigint, text, public.fee_payment_mode, text) from public, anon;
grant execute on function public.collect_cash_payment(uuid, bigint, text, public.fee_payment_mode, text) to authenticated;

-- AC: a second print is watermarked DUPLICATE, and every print — first
-- or repeat — logs who and when. The caller (a future renderer) decides
-- how to show is_duplicate; this function only records the fact and
-- reports it.
create or replace function public.print_receipt(p_receipt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_receipt  public.fee_receipt%rowtype;
  v_payment  public.fee_payment%rowtype;
  v_student  record;
  v_balance  bigint;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_receipt from public.fee_receipt where id = p_receipt_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'RECEIPT_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.fee_receipt set printed_count = printed_count + 1 where id = p_receipt_id
  returning * into v_receipt;

  insert into public.fee_receipt_print_log (receipt_id, printed_by) values (p_receipt_id, auth.uid());

  select * into v_payment from public.fee_payment where id = v_receipt.payment_id;
  select s.name_en, s.gr_number into v_student
    from public.enrolment e join public.student s on s.id = e.student_id
   where e.id = v_payment.enrolment_id;
  v_balance := public.student_balance(v_payment.enrolment_id);

  return jsonb_build_object(
    'receipt_no', v_receipt.receipt_no,
    'student_name', v_student.name_en,
    'gr_number', v_student.gr_number,
    'amount_paisa', v_payment.amount_paisa,
    'amount_words', public.amount_in_words(v_payment.amount_paisa),
    'value_date', v_payment.value_date,
    'post_payment_outstanding_paisa', greatest(v_balance, 0),
    'printed_count', v_receipt.printed_count,
    'is_duplicate', v_receipt.printed_count > 1
  );
end;
$$;

revoke execute on function public.print_receipt(uuid) from public, anon;
grant execute on function public.print_receipt(uuid) to authenticated;

alter table public.fee_receipt_counter enable row level security;
alter table public.fee_receipt enable row level security;
alter table public.fee_receipt_print_log enable row level security;

-- No policies on the counter table: internal-only, matching
-- challan_counter's own "authenticated correctly sees zero rows" intent.

create policy fee_receipt_campus_scope on public.fee_receipt
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy fee_receipt_print_log_read on public.fee_receipt_print_log
  for select to authenticated
  using (
    receipt_id in (
      select id from public.fee_receipt
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );
