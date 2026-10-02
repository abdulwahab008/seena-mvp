-- FR-K16: partial payment and allocation waterfall.
--
-- The core accounting piece Module K has been missing: until now,
-- fee_ledger only ever recorded charges/concessions/late fees and a
-- single generic post_ledger_entry() credit — nothing tracked WHICH
-- challan(s)/head(s) a payment actually settled, so a challan's own
-- status (unpaid/part_paid/paid) never moved off its default. This FR
-- adds that: fee_payment is the receipt of money; fee_payment_allocation
-- is the (challan, fee_head) breakdown of where it went; the balance
-- itself is still never cached anywhere new — student_balance() (FR-K14)
-- already sums the ledger, and a single ledger 'payment' credit entry
-- per fee_payment is all this FR adds there.
--
-- Waterfall order: within one challan, outstanding amounts are settled
-- head-by-head in ascending fee_head_priority.priority (a real,
-- per-tenant-configurable table, not a hardcoded head-type list) —
-- unconfigured heads fall back to a shared lowest priority (999) rather
-- than an assumed order, since no default ordering was specified.
-- Across challans, oldest billing_period is always settled first.
--
-- Advance credit (a payment exceeding everything currently outstanding)
-- is NOT a new concept to track: it's simply a fee_payment whose
-- amount_paisa exceeds the sum of its own fee_payment_allocation rows.
-- student_balance() already goes negative for it (more credits than
-- debits) with no new column or table. Applying it to a later challan
-- (apply_advance_credit, wired into generate_challans()) never creates a
-- second ledger entry for the same money — it only ever adds
-- fee_payment_allocation rows against the ORIGINAL payment's leftover,
-- exactly the same allocator every payment goes through
-- (app.fn_allocate_to_challan). A second ledger credit here would
-- double-count money that was already credited once, at receipt time.
--
-- Concurrency: allocation runs under an advisory lock keyed on
-- enrolment_id (the same pattern as apply_for_leave's balance-hold lock)
-- so two payments/credit-applications for the same student can never
-- both read the same "already allocated" totals and over-allocate past
-- a challan's net_paisa. Like every other advisory-lock claim in this
-- codebase, the "two concurrent payments, no double-allocation" race
-- itself is not exercised here — pgTAP runs single-connection — only the
-- sequential boundary (amounts add up correctly, in order) is.

create type public.fee_payment_mode as enum ('cash', 'bank_challan', 'online', 'cheque', 'adjustment');

create table public.fee_payment (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  enrolment_id uuid not null references public.enrolment(id) on delete cascade,
  amount_paisa bigint not null,
  mode         public.fee_payment_mode not null,
  received_at  timestamptz not null default clock_timestamp(),
  value_date   date not null default current_date,
  reference_no text,
  collected_by uuid references public.app_user(user_id),
  constraint ck_payment_amount_positive check (amount_paisa > 0)
);

create index idx_fee_payment_enrolment on public.fee_payment (enrolment_id, received_at);

create trigger fee_payment_audit after insert or update or delete on public.fee_payment
  for each row execute function app.tg_audit_row();

create table public.fee_payment_allocation (
  id           uuid primary key default gen_random_uuid(),
  payment_id   uuid not null references public.fee_payment(id) on delete cascade,
  challan_id   uuid not null references public.fee_challan(id) on delete cascade,
  fee_head_id  uuid not null references public.fee_head(id),
  amount_paisa bigint not null check (amount_paisa > 0),
  created_at   timestamptz not null default now()
);

create index idx_fee_payment_allocation_payment on public.fee_payment_allocation (payment_id);
create index idx_fee_payment_allocation_challan on public.fee_payment_allocation (challan_id);

create table public.fee_head_priority (
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  fee_head_id uuid not null references public.fee_head(id) on delete cascade,
  priority    int not null,
  primary key (tenant_id, fee_head_id)
);

create or replace function public.set_fee_head_priority(p_fee_head_id uuid, p_priority int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.fee_head where id = p_fee_head_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'FEE_HEAD_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.fee_head_priority (tenant_id, fee_head_id, priority)
  values (app.auth_tenant_id(), p_fee_head_id, p_priority)
  on conflict (tenant_id, fee_head_id) do update set priority = excluded.priority;
end;
$$;

revoke execute on function public.set_fee_head_priority(uuid, int) from public, anon;
grant execute on function public.set_fee_head_priority(uuid, int) to authenticated;

-- Internal, not exposed as an RPC: allocates up to p_max_amount of one
-- payment against one challan's outstanding heads, in priority order,
-- and returns the amount actually placed (may be less than p_max_amount
-- once every head on this challan is fully covered). The single place
-- fee_challan.status gets recomputed, so a fresh payment
-- (allocate_payment) and a later advance-credit application
-- (apply_advance_credit) can never disagree about what "part_paid" means.
create or replace function app.fn_allocate_to_challan(p_payment_id uuid, p_challan_id uuid, p_max_amount bigint)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_remaining   bigint := p_max_amount;
  v_allocated   bigint := 0;
  v_head        record;
  v_line_alloc  bigint;
  v_total_net   bigint;
  v_total_alloc bigint;
begin
  if v_remaining <= 0 then
    return 0;
  end if;

  for v_head in
    with head_totals as (
      select fcl.fee_head_id,
             sum(fcl.net_paisa) as head_net,
             coalesce((
               select sum(fpa.amount_paisa) from public.fee_payment_allocation fpa
                where fpa.challan_id = p_challan_id and fpa.fee_head_id = fcl.fee_head_id
             ), 0) as head_allocated
        from public.fee_challan_line fcl
       where fcl.challan_id = p_challan_id and fcl.line_type in ('charge', 'late_fee')
       group by fcl.fee_head_id
    )
    select ht.fee_head_id, ht.head_net, ht.head_allocated
      from head_totals ht
      left join public.fee_head_priority fhp on fhp.fee_head_id = ht.fee_head_id and fhp.tenant_id = app.auth_tenant_id()
     order by coalesce(fhp.priority, 999) asc, ht.fee_head_id asc
  loop
    exit when v_remaining <= 0;
    if v_head.head_net - v_head.head_allocated <= 0 then
      continue;
    end if;
    v_line_alloc := least(v_head.head_net - v_head.head_allocated, v_remaining);
    insert into public.fee_payment_allocation (payment_id, challan_id, fee_head_id, amount_paisa)
    values (p_payment_id, p_challan_id, v_head.fee_head_id, v_line_alloc);
    v_remaining := v_remaining - v_line_alloc;
    v_allocated := v_allocated + v_line_alloc;
  end loop;

  if v_allocated > 0 then
    select net_paisa into v_total_net from public.fee_challan where id = p_challan_id;
    select coalesce(sum(amount_paisa), 0) into v_total_alloc from public.fee_payment_allocation where challan_id = p_challan_id;
    update public.fee_challan
       set status = case when v_total_alloc >= v_total_net then 'paid' else 'part_paid' end::public.fee_challan_status
     where id = p_challan_id;
  end if;

  return v_allocated;
end;
$$;

revoke execute on function app.fn_allocate_to_challan(uuid, uuid, bigint) from public, anon, authenticated;

-- Allocates a payment's still-unallocated amount against this
-- enrolment's currently outstanding challans, oldest billing_period
-- first. Safe to call more than once for the same payment (e.g. a fresh
-- payment that outran its own then-outstanding challans, later
-- re-checked) — it only ever considers the remainder, never re-spends
-- what a prior call already placed.
create or replace function public.allocate_payment(p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment         public.fee_payment%rowtype;
  v_available       bigint;
  v_challan         record;
  v_this_alloc      bigint;
  v_total_allocated bigint := 0;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_payment from public.fee_payment where id = p_payment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('payment-alloc:' || v_payment.enrolment_id::text, 0));

  select v_payment.amount_paisa - coalesce(sum(amount_paisa), 0) into v_available
    from public.fee_payment_allocation where payment_id = p_payment_id;

  for v_challan in
    select id from public.fee_challan
     where enrolment_id = v_payment.enrolment_id and status in ('unpaid', 'part_paid')
     order by billing_period asc
  loop
    exit when v_available <= 0;
    v_this_alloc := app.fn_allocate_to_challan(p_payment_id, v_challan.id, v_available);
    v_available := v_available - v_this_alloc;
    v_total_allocated := v_total_allocated + v_this_alloc;
  end loop;

  return jsonb_build_object('payment_id', p_payment_id, 'allocated', v_total_allocated, 'unallocated', v_available);
end;
$$;

revoke execute on function public.allocate_payment(uuid) from public, anon;
grant execute on function public.allocate_payment(uuid) to authenticated;

-- Records money received and, in the same transaction, allocates it —
-- the AC's own requirement ("allocation must run in the same
-- transaction as the payment insert"), satisfied simply by this function
-- doing both, not by any special isolation trick.
create or replace function public.record_payment(
  p_enrolment_id uuid, p_amount_paisa bigint, p_mode public.fee_payment_mode,
  p_reference_no text default null, p_value_date date default current_date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enrolment public.enrolment%rowtype;
  v_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_amount_paisa <= 0 then
    raise exception 'AMOUNT_MUST_BE_POSITIVE' using errcode = '23514';
  end if;

  select * into v_enrolment from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.fee_payment (tenant_id, campus_id, enrolment_id, amount_paisa, mode, value_date, reference_no, collected_by)
  values (v_enrolment.tenant_id, v_enrolment.campus_id, p_enrolment_id, p_amount_paisa, p_mode, p_value_date, p_reference_no, auth.uid())
  returning id into v_id;

  perform public.post_ledger_entry(p_enrolment_id, 'payment', p_amount_paisa, 'credit', null, p_value_date, 'fee_payment', v_id);
  perform public.allocate_payment(v_id);

  return v_id;
end;
$$;

revoke execute on function public.record_payment(uuid, bigint, public.fee_payment_mode, text, date) from public, anon;
grant execute on function public.record_payment(uuid, bigint, public.fee_payment_mode, text, date) to authenticated;

-- Applies existing advance credit (money already received and ledgered,
-- just not yet linked to a specific challan) to a challan — always this
-- ONE specific challan, never a general re-scan, since the only caller
-- is generate_challans() right after minting a brand new one. Never
-- posts a new ledger entry: the money was already credited to the
-- ledger the moment its payment was recorded. Oldest unallocated
-- payment first (first-received credit consumed first).
create or replace function public.apply_advance_credit(p_enrolment_id uuid, p_challan_id uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid;
  v_challan_tenant uuid;
  v_net_paisa      bigint;
  v_credit_pay     record;
  v_this_alloc     bigint;
  v_total_applied  bigint := 0;
  v_remaining_need bigint;
begin
  select tenant_id into v_tenant_id from public.enrolment where id = p_enrolment_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  select tenant_id, net_paisa into v_challan_tenant, v_net_paisa from public.fee_challan where id = p_challan_id;
  if v_challan_tenant is null or v_challan_tenant <> app.auth_tenant_id() then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('payment-alloc:' || p_enrolment_id::text, 0));

  for v_credit_pay in
    select fp.id, fp.amount_paisa - coalesce(sum(fpa.amount_paisa), 0) as unallocated
      from public.fee_payment fp
      left join public.fee_payment_allocation fpa on fpa.payment_id = fp.id
     where fp.enrolment_id = p_enrolment_id
     group by fp.id, fp.amount_paisa, fp.received_at
    having fp.amount_paisa - coalesce(sum(fpa.amount_paisa), 0) > 0
     order by fp.received_at asc
  loop
    select coalesce(sum(amount_paisa), 0) into v_remaining_need from public.fee_payment_allocation where challan_id = p_challan_id;
    v_remaining_need := v_net_paisa - v_remaining_need;
    exit when v_remaining_need <= 0;

    v_this_alloc := app.fn_allocate_to_challan(v_credit_pay.id, p_challan_id, least(v_credit_pay.unallocated, v_remaining_need)::bigint);
    v_total_applied := v_total_applied + v_this_alloc;
  end loop;

  return v_total_applied;
end;
$$;

revoke execute on function public.apply_advance_credit(uuid, uuid) from public, anon;
grant execute on function public.apply_advance_credit(uuid, uuid) to authenticated;

-- Widened with the one new call this FR adds — apply any pre-existing
-- advance credit to the challan just generated, before it's counted.
-- Everything else in this function is unchanged from the module_k_review
-- version.
create or replace function public.generate_challans(
  p_campus_id uuid, p_session_id uuid, p_period date, p_dry_run boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_batch_id      uuid;
  v_month         int := extract(month from p_period)::int;
  v_period_start  date := date_trunc('month', p_period)::date;
  v_period_end    date := (date_trunc('month', p_period) + interval '1 month - 1 day')::date;
  v_generated     int := 0;
  v_skipped       int := 0;
  v_failed        int := 0;
  v_enrol         record;
  v_gross         bigint;
  v_concession    bigint;
  v_gap_head      text;
  v_challan_id    uuid;
  v_challan_no    text;
  v_preview       jsonb := '{}'::jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = v_tenant_id) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if not p_dry_run then
    insert into public.fee_challan_batch (tenant_id, campus_id, session_id, billing_period, requested_by)
    values (v_tenant_id, p_campus_id, p_session_id, v_period_start, auth.uid())
    returning id into v_batch_id;
  end if;

  for v_enrol in
    select e.id as enrolment_id, e.class_level_id, fp.id as plan_id, cl.name_en as class_name
      from public.enrolment e
      join public.student s on s.id = e.student_id
      join public.class_level cl on cl.id = e.class_level_id
      left join public.fee_plan fp on fp.enrolment_id = e.id
     where e.tenant_id = v_tenant_id and e.campus_id = p_campus_id and e.session_id = p_session_id
       and e.status = 'active' and s.status = 'active'
  loop
    if exists (
      select 1 from public.fee_challan
       where enrolment_id = v_enrol.enrolment_id and session_id = p_session_id
         and billing_period = v_period_start and status <> 'cancelled'
    ) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    if v_enrol.plan_id is null then
      v_failed := v_failed + 1;
      if not p_dry_run then
        insert into public.fee_challan_batch_error (batch_id, enrolment_id, reason)
        values (v_batch_id, v_enrol.enrolment_id, 'NO_FEE_PLAN');
      end if;
      continue;
    end if;

    select fh.code into v_gap_head
      from public.fee_head fh
     where fh.tenant_id = v_tenant_id and fh.is_mandatory
       and not exists (
         select 1 from public.fee_plan_line fpl where fpl.plan_id = v_enrol.plan_id and fpl.fee_head_id = fh.id
       )
     limit 1;
    if v_gap_head is not null then
      v_failed := v_failed + 1;
      if not p_dry_run then
        insert into public.fee_challan_batch_error (batch_id, enrolment_id, reason)
        values (v_batch_id, v_enrol.enrolment_id, 'MANDATORY_HEAD_COVERAGE_GAP: ' || v_gap_head);
      end if;
      continue;
    end if;

    select coalesce(sum(amount_paisa), 0), coalesce(sum(concession_paisa), 0)
      into v_gross, v_concession
      from app.fn_plan_line_period_charges(v_enrol.plan_id, v_enrol.enrolment_id, v_tenant_id, v_period_start, v_period_end, v_month);

    if v_gross = 0 then
      -- Nothing applicable this billing month (e.g. a quarterly-only plan
      -- between its billing months) — not a failure, just nothing to bill.
      v_skipped := v_skipped + 1;
      continue;
    end if;

    if p_dry_run then
      v_preview := jsonb_set(
        v_preview, array[v_enrol.class_name],
        to_jsonb(coalesce((v_preview ->> v_enrol.class_name)::bigint, 0) + (v_gross - v_concession))
      );
      v_generated := v_generated + 1;
      continue;
    end if;

    v_challan_no := public.next_challan_no(v_tenant_id, p_campus_id, p_session_id);

    begin
      insert into public.fee_challan (
        tenant_id, campus_id, enrolment_id, session_id, billing_period, challan_no,
        due_date, gross_paisa, concession_paisa, net_paisa, batch_id
      ) values (
        v_tenant_id, p_campus_id, v_enrol.enrolment_id, p_session_id, v_period_start, v_challan_no,
        v_period_end + 10, v_gross, v_concession, v_gross - v_concession, v_batch_id
      ) returning id into v_challan_id;

      insert into public.fee_challan_line (challan_id, fee_head_id, amount_paisa, concession_paisa, net_paisa, line_type, applied_award_ids)
      select v_challan_id, fee_head_id, amount_paisa, concession_paisa, amount_paisa - concession_paisa, 'charge', applied_award_ids
        from app.fn_plan_line_period_charges(v_enrol.plan_id, v_enrol.enrolment_id, v_tenant_id, v_period_start, v_period_end, v_month);

      perform public.post_ledger_entry(
        v_enrol.enrolment_id, 'charge', v_gross, 'debit', null, v_period_start, 'fee_challan', v_challan_id
      );
      if v_concession > 0 then
        perform public.post_ledger_entry(
          v_enrol.enrolment_id, 'concession', v_concession, 'credit', null, v_period_start, 'fee_challan', v_challan_id
        );
      end if;

      perform public.apply_advance_credit(v_enrol.enrolment_id, v_challan_id);

      v_generated := v_generated + 1;
    exception
      when unique_violation then
        -- A genuinely concurrent invocation won the race and already
        -- created this challan between our existence check and this
        -- insert — same outcome as the pre-check path: skip, not abort.
        v_skipped := v_skipped + 1;
    end;
  end loop;

  if not p_dry_run then
    update public.fee_challan_batch
       set generated_count = v_generated, skipped_count = v_skipped, failed_count = v_failed, completed_at = now()
     where id = v_batch_id;
  end if;

  return jsonb_build_object(
    'batch_id', v_batch_id, 'generated', v_generated, 'skipped', v_skipped, 'failed', v_failed,
    'dry_run', p_dry_run, 'preview_by_class', v_preview
  );
end;
$$;

alter table public.fee_payment enable row level security;
alter table public.fee_payment_allocation enable row level security;
alter table public.fee_head_priority enable row level security;

create policy fee_payment_campus_scope on public.fee_payment
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy fee_payment_allocation_read on public.fee_payment_allocation
  for select to authenticated
  using (
    payment_id in (
      select id from public.fee_payment
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );

create policy fee_head_priority_tenant_read on public.fee_head_priority
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());
