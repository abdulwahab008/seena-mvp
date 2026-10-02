-- FR-O07: nightly overdue fine accrual job.
--
-- accrue_library_fines(p_date) walks every open loan that is past due and tops its fine ledger up
-- to p_date, one row per (loan, day) under uq_fine_per_loan_day. It is built to be re-run safely:
--   * a crash and a re-run on the same date inserts nothing twice (ON CONFLICT DO NOTHING on the
--     unique index);
--   * a missed night is healed by the next run, because it computes every day from due_on to
--     p_date rather than "today only";
--   * the cap is applied by day index (day n costs min(rate, cap - rate*(n-1))), so a loan 300
--     days overdue at PKR 5 against a PKR 500 cap totals exactly PKR 500, however many nights ran.
-- Returned loans are never touched: their fine was finalised at return (FR-O05).
--
-- pg_cron runs in UTC: the job is scheduled at 21:00 UTC (02:00 Asia/Karachi) and passes the
-- Karachi calendar date explicitly. The date is computed when the job starts, and the catch-up
-- semantics above mean even a drifting schedule can neither double-charge nor skip a day.
--
-- A borrower whose unpaid fines reach the policy's block_threshold is "blocked":
-- v_borrower_outstanding_fine (security_invoker) reports it and issue_copy refuses them
-- (BORROWER_BLOCKED). Crossing the threshold in a run also notifies the borrower's guardian.
--
-- Fines are never deleted. An Accountant settles them (recording the receipt) or waives them with
-- a written reason (>= 5 characters), because the fine register is reconciled against the cash book.

-- ── tenant-parametrised policy resolution (so the job can resolve without a JWT) ──────────────

create or replace function app.fn_library_borrower_t(p_tenant uuid, p_borrower_id uuid)
returns table (borrower_role text, campus_id uuid, class_ordinal smallint, display_name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_s public.student%rowtype;
  v_u public.app_user%rowtype;
begin
  if app.auth_tenant_id() is not null and p_tenant is distinct from app.auth_tenant_id() then
    return;
  end if;
  select * into v_s from public.student where id = p_borrower_id and tenant_id = p_tenant;
  if found then
    return query
      select 'student'::text, v_s.campus_id,
             (select cl.ordinal from public.enrolment e join public.class_level cl on cl.id = e.class_level_id
               where e.student_id = v_s.id and e.status = 'active' order by e.joined_on desc, e.created_at desc limit 1),
             v_s.name_en;
    return;
  end if;
  select * into v_u from public.app_user where user_id = p_borrower_id and tenant_id = p_tenant and status = 'active';
  if found then
    return query
      select case when v_u.app_role in ('class_teacher', 'subject_teacher', 'head_of_department') then 'teacher' else 'staff' end,
             (select uc.campus_id from public.user_campus uc where uc.user_id = v_u.user_id and uc.is_active order by uc.campus_id limit 1),
             null::smallint, v_u.full_name;
  end if;
end;
$$;
revoke execute on function app.fn_library_borrower_t(uuid, uuid) from public, anon, authenticated;

create or replace function app.fn_library_borrower(p_borrower_id uuid)
returns table (borrower_role text, campus_id uuid, class_ordinal smallint, display_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.fn_library_borrower_t(app.auth_tenant_id(), p_borrower_id);
$$;
revoke execute on function app.fn_library_borrower(uuid) from public, anon, authenticated;

create or replace function app.fn_library_resolve_policy(p_tenant uuid, p_borrower_id uuid, p_at timestamptz, p_campus_id uuid default null)
returns public.library_borrower_policy
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_b   record;
  v_pol public.library_borrower_policy%rowtype;
  v_day date := (p_at at time zone 'Asia/Karachi')::date;
begin
  if app.auth_tenant_id() is not null and p_tenant is distinct from app.auth_tenant_id() then
    return v_pol;
  end if;
  select * into v_b from app.fn_library_borrower_t(p_tenant, p_borrower_id);
  if v_b.borrower_role is null then
    return v_pol;
  end if;
  select p.* into v_pol
    from public.library_borrower_policy p
   where p.tenant_id = p_tenant
     and p.role = v_b.borrower_role
     and p.effective_from <= v_day
     and (p.campus_id is null or p.campus_id = coalesce(p_campus_id, v_b.campus_id))
     and (p.class_band_from is null or (v_b.class_ordinal is not null and v_b.class_ordinal between p.class_band_from and p.class_band_to))
   order by (p.class_band_from is not null) desc, (p.campus_id is not null) desc, p.effective_from desc, p.created_at desc
   limit 1;
  return v_pol;
end;
$$;
revoke execute on function app.fn_library_resolve_policy(uuid, uuid, timestamptz, uuid) from public, anon;
grant execute on function app.fn_library_resolve_policy(uuid, uuid, timestamptz, uuid) to authenticated;

create or replace function public.resolve_borrower_policy(p_borrower_id uuid, p_at timestamptz default now(), p_campus_id uuid default null)
returns public.library_borrower_policy
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.fn_library_resolve_policy(app.auth_tenant_id(), p_borrower_id, p_at, p_campus_id);
$$;
revoke execute on function public.resolve_borrower_policy(uuid, timestamptz, uuid) from public, anon;
grant execute on function public.resolve_borrower_policy(uuid, timestamptz, uuid) to authenticated;

-- ── outstanding fines and the blocked flag ───────────────────────────────────

create view public.v_borrower_outstanding_fine with (security_invoker = true) as
select f.tenant_id, f.campus_id, f.borrower_id,
       sum(f.amount)::bigint as outstanding_paisa,
       count(distinct f.loan_id)::int as loans_with_fines,
       p.block_threshold,
       (p.block_threshold is not null and sum(f.amount) >= p.block_threshold) as is_blocked
  from public.library_fine f
  left join lateral app.fn_library_resolve_policy(f.tenant_id, f.borrower_id, now(), null) p on true
 where f.status = 'outstanding'
 group by f.tenant_id, f.campus_id, f.borrower_id, p.block_threshold;
grant select on public.v_borrower_outstanding_fine to authenticated;

-- ── the job ──────────────────────────────────────────────────────────────────

create or replace function public.accrue_library_fines(p_date date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_date     date := coalesce(p_date, (now() at time zone 'Asia/Karachi')::date);
  v_loan     record;
  v_before   bigint;
  v_after    bigint;
  v_loans    int := 0;
  v_blocked  int := 0;
  b          record;
  v_pol      public.library_borrower_policy%rowtype;
  v_title    text;
begin
  create temp table if not exists pg_temp.lib_fine_before (tenant_id uuid, borrower_id uuid, campus_id uuid, amount bigint) on commit drop;
  truncate pg_temp.lib_fine_before;
  insert into pg_temp.lib_fine_before
  select f.tenant_id, f.borrower_id, f.campus_id, sum(f.amount) from public.library_fine f where f.status = 'outstanding' group by f.tenant_id, f.borrower_id, f.campus_id;
  select count(*) into v_before from public.library_fine;

  for v_loan in
    select id from public.library_loan where returned_at is null and due_on < v_date order by due_on, id for update skip locked
  loop
    perform app.fn_library_accrue_loan(v_loan.id, v_date);
    v_loans := v_loans + 1;
  end loop;
  select count(*) into v_after from public.library_fine;

  -- borrowers pushed over their block threshold by this run
  for b in
    select a.tenant_id, a.borrower_id, a.campus_id, a.amount as after_amount, coalesce(bf.amount, 0) as before_amount
      from (select f.tenant_id, f.borrower_id, f.campus_id, sum(f.amount) as amount from public.library_fine f where f.status = 'outstanding' group by f.tenant_id, f.borrower_id, f.campus_id) a
      left join pg_temp.lib_fine_before bf on bf.tenant_id = a.tenant_id and bf.borrower_id = a.borrower_id and bf.campus_id = a.campus_id
     where a.amount > coalesce(bf.amount, 0)
  loop
    v_pol := app.fn_library_resolve_policy(b.tenant_id, b.borrower_id, v_date::timestamp at time zone 'Asia/Karachi' + interval '12 hours', null);
    if v_pol.block_threshold is not null and b.after_amount >= v_pol.block_threshold and b.before_amount < v_pol.block_threshold then
      v_blocked := v_blocked + 1;
      perform app.fn_library_notify(b.tenant_id, b.campus_id, b.borrower_id, 'library_blocked', 'Library borrowing suspended',
                                    'Unpaid library fines of PKR ' || to_char(b.after_amount / 100.0, 'FM999,999,990') || ' have reached the limit. Please clear them at the library to borrow again.',
                                    'library_block:' || b.borrower_id || ':' || v_date);
    end if;
  end loop;

  return jsonb_build_object('date', v_date, 'loans_processed', v_loans, 'rows_added', v_after - v_before, 'newly_blocked', v_blocked);
end;
$$;
revoke execute on function public.accrue_library_fines(date) from public, anon, authenticated;
grant execute on function public.accrue_library_fines(date) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('library_fine_accrual', '0 21 * * *', 'select public.accrue_library_fines((now() at time zone ''Asia/Karachi'')::date);');
  end if;
exception
  when others then null;
end;
$$;

-- ── settle / waive ───────────────────────────────────────────────────────────
-- Either one loan's outstanding fines (p_loan_id) or all of a borrower's (p_loan_id null).
-- Returns the amount settled / waived in paisa.

create or replace function public.settle_library_fines(p_borrower_id uuid, p_loan_id uuid default null, p_receipt_id uuid default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_amount bigint;
begin
  if app.auth_role() not in ('accountant', 'principal', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  with s as (
    update public.library_fine
       set status = 'settled', settled_by = (select auth.uid()), settled_at = clock_timestamp(), settled_receipt_id = p_receipt_id
     where tenant_id = app.auth_tenant_id() and borrower_id = p_borrower_id and status = 'outstanding'
       and (p_loan_id is null or loan_id = p_loan_id) and app.fn_library_campus_ok(campus_id)
     returning amount
  )
  select coalesce(sum(amount), 0) into v_amount from s;
  return v_amount;
end;
$$;
revoke execute on function public.settle_library_fines(uuid, uuid, uuid) from public, anon;
grant execute on function public.settle_library_fines(uuid, uuid, uuid) to authenticated;

create or replace function public.waive_library_fines(p_borrower_id uuid, p_reason text, p_loan_id uuid default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_amount bigint;
begin
  if app.auth_role() not in ('accountant', 'principal', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) < 5 then
    raise exception 'REASON_REQUIRED' using errcode = '23514';
  end if;
  with s as (
    update public.library_fine
       set status = 'waived', waived_by = (select auth.uid()), waived_at = clock_timestamp(), waive_reason = btrim(p_reason)
     where tenant_id = app.auth_tenant_id() and borrower_id = p_borrower_id and status = 'outstanding'
       and (p_loan_id is null or loan_id = p_loan_id) and app.fn_library_campus_ok(campus_id)
     returning amount
  )
  select coalesce(sum(amount), 0) into v_amount from s;
  return v_amount;
end;
$$;
revoke execute on function public.waive_library_fines(uuid, text, uuid) from public, anon;
grant execute on function public.waive_library_fines(uuid, text, uuid) to authenticated;
