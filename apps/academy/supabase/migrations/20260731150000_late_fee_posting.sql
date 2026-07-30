-- FR-K13: automated late fee posting.
--
-- Accounting-specific care:
--   * "delta, not recompute-and-adjust" is the whole mechanism: a night's
--     posting is current_owed(as_of) minus whatever's already posted for
--     that challan, appended as one new debit entry — never an update of
--     a prior entry, matching FR-K14/K15's append-only discipline (the
--     ledger has no correction path except reversal, and there's nothing
--     wrong to reverse here). This is also exactly the AC's own framing:
--     "already carrying 150 PKR... one row of 5000 paisa... total 200 PKR"
--     is 150 + 50 = 200, a delta, not a fresh 200 PKR charge.
--   * Because the delta IS the idempotency mechanism (a same-day rerun
--     computes current_owed - already_posted = 0, so nothing is written
--     at all), fee_ledger_late_fee_daily_uq is a backstop against a
--     genuine race between two concurrent job invocations, not the
--     primary guard.
--   * apply_late_fees() is cross-tenant by construction — it is the one
--     function in this whole module that is NOT scoped to app.auth_tenant_id(),
--     because a cron job has no authenticated tenant to scope to; it acts
--     on every open challan across every tenant. That makes it the most
--     dangerous function in the module if it were ever reachable by a
--     logged-in user, so it is service_role only, same as FR-K10's
--     next_challan_no() — not "also grant to accountant for convenience".
--   * compute_late_fee()'s own role/tenant-scoped lookup can't be reused
--     as-is from inside a cron job with no request.jwt.claims: calling it
--     would hit its own FORBIDDEN check. The fix is the same shape as
--     every other public/app split in this schema — the actual
--     computation moves to app.fn_compute_late_fee(challan row, as_of),
--     an internal helper with no auth check of its own; the public RPC
--     now does its permission/tenant check and then just delegates. This
--     is a pure refactor of FR-K12's function — the numbers it returns
--     for every existing AC example are unchanged.
--
-- Scope cuts:
--   * "the exemption reason is recorded" (from the AC) has nowhere to go:
--     an exempt student's delta is 0, nothing gets posted, and the
--     Supabase Objects list for this FR names only the aggregate
--     fee_job_run table, not a per-challan detail table to record a
--     reason against. Recording still requires a schema addition beyond
--     what this FR specifies.
--   * fee_job_run has no tenant_id (per the FR's own object list) — it is
--     an operational log, not tenant business data, so it gets no
--     authenticated-readable RLS policy at all (same "no policy = deny"
--     pattern as FR-K10's challan_counter). A platform operator reads it
--     with service-role tooling, not through the app.
--   * The cron wiring itself (fees_apply_late_fee daily 02:00) is not
--     created — no pg_cron locally, same limitation as every other
--     cron-shaped FR in this catalogue. apply_late_fees(p_run_date) is
--     written to be exactly what that job calls once it exists.

create table public.fee_job_run (
  id           uuid primary key default gen_random_uuid(),
  job_name     text not null,
  run_date     date not null,
  rows_written int not null default 0,
  duration_ms  int,
  status       text not null default 'running',
  error_text   text,
  started_at   timestamptz not null default clock_timestamp(),
  completed_at timestamptz
);

create index idx_fee_job_run_job_date on public.fee_job_run (job_name, run_date desc);

alter table public.fee_job_run enable row level security;
-- No policies at all, deliberately — see the migration header.

-- Keyed on value_date, not posted_at: the FR's own object list names
-- (posted_at::date), but posted_at is "when this row was physically
-- written" while value_date is "which night's assessment this is" — the
-- thing the guard is actually meant to dedupe on. They usually agree, but
-- not always: a job that runs late and crosses midnight, or a manual
-- re-trigger hours after the original attempt, still targets the same
-- logical run_date with a different real insert time. value_date is set
-- explicitly to p_run_date below, so it's the correct key — and, as a
-- secondary benefit, a plain column needs no IMMUTABLE-expression
-- workaround the way (posted_at::date) would (::date on a timestamptz is
-- timezone-dependent, hence only STABLE, and index expressions must be
-- IMMUTABLE).
create unique index fee_ledger_late_fee_daily_uq on public.fee_ledger (challan_id, entry_type, value_date)
  where entry_type = 'late_fee';

-- The actual calculation, extracted verbatim from FR-K12's
-- compute_late_fee() — no auth check, takes the challan row directly, so
-- both the user-facing preview RPC and this FR's cron job can share it.
create or replace function app.fn_compute_late_fee(p_challan public.fee_challan, p_as_of date)
returns bigint
language plpgsql
stable
set search_path = ''
as $$
declare
  v_rule            public.late_fee_rule%rowtype;
  v_shifted_due     date;
  v_days_late       int;
  v_chargeable_days int;
  v_exempt          boolean;
  v_base_amount     bigint;
  v_raw             bigint;
  v_guard           int := 0;
begin
  select * into v_rule from public.late_fee_rule
   where campus_id = p_challan.campus_id and session_id = p_challan.session_id and effective_from <= p_as_of
   order by effective_from desc, created_at desc
   limit 1;
  if not found then
    return 0::bigint;
  end if;

  select exists (
    select 1 from public.concession_award ca
    join public.concession_scheme cs on cs.id = ca.scheme_id
    where ca.enrolment_id = p_challan.enrolment_id and ca.status = 'approved'
      and ca.effective_from <= p_as_of and ca.effective_to >= p_as_of
      and cs.category = any(v_rule.exempt_concession_categories)
  ) into v_exempt;
  if v_exempt then
    return 0::bigint;
  end if;

  v_shifted_due := p_challan.due_date;
  while v_guard < 14 and (
    extract(dow from v_shifted_due) = 0
    or exists (
      select 1 from public.holiday_calendar
       where tenant_id = p_challan.tenant_id and (campus_id = p_challan.campus_id or campus_id is null)
         and holiday_date = v_shifted_due
    )
  ) loop
    v_shifted_due := v_shifted_due + 1;
    v_guard := v_guard + 1;
  end loop;

  v_days_late := p_as_of - v_shifted_due;
  v_chargeable_days := greatest(0, v_days_late - v_rule.grace_days);
  if v_chargeable_days = 0 then
    return 0::bigint;
  end if;

  if v_rule.basis = 'flat' then
    v_raw := v_rule.amount_paisa;
  elsif v_rule.basis = 'per_day' then
    if v_rule.max_days is not null then
      v_chargeable_days := least(v_chargeable_days, v_rule.max_days);
    end if;
    v_raw := v_chargeable_days::bigint * v_rule.amount_paisa;
  else
    select coalesce(sum(net_paisa), 0) into v_base_amount
      from public.fee_challan_line
     where challan_id = p_challan.id
       and (v_rule.applicable_head_ids is null or fee_head_id = any(v_rule.applicable_head_ids));
    v_raw := round(v_base_amount * v_rule.percentage / 100.0)::bigint;
  end if;

  if v_rule.cap_paisa is not null then
    v_raw := least(v_raw, v_rule.cap_paisa);
  end if;

  return greatest(v_raw, 0::bigint);
end;
$$;

revoke execute on function app.fn_compute_late_fee(public.fee_challan, date) from public, anon, authenticated;

-- FR-K12's own RPC, now a thin permission-and-tenant-check wrapper.
create or replace function public.compute_late_fee(p_challan_id uuid, p_as_of date default current_date)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_challan public.fee_challan%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_challan from public.fee_challan where id = p_challan_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  return app.fn_compute_late_fee(v_challan, p_as_of);
end;
$$;

revoke execute on function public.compute_late_fee(uuid, date) from public, anon;
grant execute on function public.compute_late_fee(uuid, date) to authenticated;

-- The nightly job. Cross-tenant, service_role only — see migration header.
create or replace function public.apply_late_fees(p_run_date date default current_date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run_id       uuid;
  v_started      timestamptz := clock_timestamp();
  v_rows_written int;
  v_challan      public.fee_challan%rowtype;
  v_owed         bigint;
  v_already      bigint;
  v_delta        bigint;
begin
  insert into public.fee_job_run (job_name, run_date, status)
  values ('fees_apply_late_fee', p_run_date, 'running')
  returning id into v_run_id;

  for v_challan in select * from public.fee_challan where status in ('unpaid', 'part_paid') loop
    v_owed := app.fn_compute_late_fee(v_challan, p_run_date);

    select coalesce(sum(amount_paisa), 0) into v_already
      from public.fee_ledger
     where challan_id = v_challan.id and entry_type = 'late_fee';

    v_delta := v_owed - v_already;
    if v_delta > 0 then
      insert into public.fee_ledger (
        tenant_id, campus_id, enrolment_id, session_id, challan_id, entry_type, amount_paisa, direction,
        value_date, source_type, source_id
      ) values (
        v_challan.tenant_id, v_challan.campus_id, v_challan.enrolment_id, v_challan.session_id, v_challan.id,
        'late_fee', v_delta, 'debit', p_run_date, 'apply_late_fees', v_run_id
      )
      on conflict (challan_id, entry_type, value_date) where entry_type = 'late_fee' do nothing;
    end if;
  end loop;

  select count(*)::int into v_rows_written
    from public.fee_ledger
   where entry_type = 'late_fee' and source_type = 'apply_late_fees' and source_id = v_run_id;

  update public.fee_job_run
     set status = 'completed', completed_at = clock_timestamp(),
         duration_ms = extract(milliseconds from clock_timestamp() - v_started)::int,
         rows_written = v_rows_written
   where id = v_run_id;

  return jsonb_build_object('run_id', v_run_id, 'run_date', p_run_date, 'rows_written', v_rows_written);
end;
$$;

revoke execute on function public.apply_late_fees(date) from public, anon, authenticated;
grant execute on function public.apply_late_fees(date) to service_role;
