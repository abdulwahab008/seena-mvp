-- FR-S01: nightly campus-day aggregate layer.
--
-- One row per campus per day, recomputed by RANGE (never append-only):
-- back-dated receipts, corrected attendance and cancelled challans all change
-- the past. Every day boundary is Asia/Karachi; the DB runs UTC, so a naive
-- date_trunc would put a 01:00 PKT collection on the previous day.
--
-- Definitions (also what the dashboards print — see metric_definition, FR-S02):
--   collected  = payment credits dated that day, minus reversals of payments dated that day
--   billed     = charges + late fees posted that day, minus concessions posted that day
--   outstanding= receivable on challans issued by that day, as of that day's close, split by age
--                (so the three buckets always sum to the total, to the paisa)
--   staff cost = that month's payroll gross for the campus, spread over the month's days
--                (remainder on the last day so the month sums exactly)
--   enrolled   = roster size that day from joined_on/left_on
--
-- A failed refresh rolls back its own writes, leaves yesterday's rows intact,
-- and logs a failure row; the dashboards show a stale banner after 26 hours.

create table public.agg_campus_day (
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  day                  date not null,
  enrolled_count       int not null default 0,
  present_count        int not null default 0,
  marked_sections      int not null default 0,
  collected_paisa      bigint not null default 0,
  billed_paisa         bigint not null default 0,
  outstanding_paisa    bigint not null default 0,
  outstanding_0_30_paisa   bigint not null default 0,
  outstanding_31_60_paisa  bigint not null default 0,
  outstanding_60plus_paisa bigint not null default 0,
  staff_cost_paisa     bigint not null default 0,
  payroll_status       text not null default 'none',
  last_refreshed_at    timestamptz not null default now(),
  constraint agg_buckets_sum check (outstanding_paisa = outstanding_0_30_paisa + outstanding_31_60_paisa + outstanding_60plus_paisa)
);
create unique index uq_agg_campus_day on public.agg_campus_day (campus_id, day);
create index idx_agg_tenant_day on public.agg_campus_day (tenant_id, day desc);

create table public.agg_refresh_log (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid references public.tenant(id) on delete cascade,
  job_name    text not null,
  from_date   date,
  to_date     date,
  status      text not null check (status in ('ok', 'failed')),
  rows_written int not null default 0,
  error       text,
  ran_at      timestamptz not null default now()
);
create index idx_agg_log_tenant on public.agg_refresh_log (tenant_id, ran_at desc);

alter table public.agg_campus_day enable row level security;
alter table public.agg_refresh_log enable row level security;

-- campus_ids claim for EVERY role: an owner whose token lists 3 of 8 campuses sees 3.
create policy agg_campus_scope on public.agg_campus_day
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'accountant')
    and campus_id = any(app.auth_campus_ids())
  );

create policy agg_refresh_log_owner_read on public.agg_refresh_log
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin'));

create or replace function app.fn_karachi_today()
returns date
language sql
stable
set search_path = ''
as $$ select (now() at time zone 'Asia/Karachi')::date; $$;

create or replace function app.fn_agg_compute(p_tenant_id uuid, p_campus_id uuid, p_day date)
returns public.agg_campus_day
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.agg_campus_day;
  v_month date := date_trunc('month', p_day)::date;
  v_dim int := extract(day from (v_month + interval '1 month - 1 day'))::int;
  v_payroll record;
begin
  r.tenant_id := p_tenant_id;
  r.campus_id := p_campus_id;
  r.day := p_day;

  select count(*)::int into r.enrolled_count
    from public.enrolment e
   where e.tenant_id = p_tenant_id and e.campus_id = p_campus_id and e.deleted_at is null
     and coalesce(e.joined_on, (e.created_at at time zone 'Asia/Karachi')::date) <= p_day
     and (e.left_on is null or e.left_on > p_day);

  select count(distinct a.enrolment_id) filter (where a.status in ('present', 'late', 'half_day'))::int,
         count(distinct a.section_id)::int
    into r.present_count, r.marked_sections
    from public.attendance_day a
   where a.tenant_id = p_tenant_id and a.campus_id = p_campus_id and a.attendance_date = p_day;

  select coalesce(sum(case when entry_type = 'payment' and direction = 'credit' then amount_paisa else 0 end), 0)
         - coalesce(sum(case when entry_type = 'reversal' and exists (select 1 from public.fee_ledger o where o.id = fl.reversal_of_id and o.entry_type = 'payment') then amount_paisa else 0 end), 0),
         coalesce(sum(case when entry_type in ('charge', 'late_fee') and direction = 'debit' then amount_paisa else 0 end), 0)
         - coalesce(sum(case when entry_type = 'concession' and direction = 'credit' then amount_paisa else 0 end), 0)
    into r.collected_paisa, r.billed_paisa
    from public.fee_ledger fl
   where fl.tenant_id = p_tenant_id and fl.campus_id = p_campus_id and fl.value_date = p_day;

  select coalesce(sum(bal) filter (where age <= 30), 0), coalesce(sum(bal) filter (where age between 31 and 60), 0), coalesce(sum(bal) filter (where age > 60), 0)
    into r.outstanding_0_30_paisa, r.outstanding_31_60_paisa, r.outstanding_60plus_paisa
    from (
      select c.net_paisa - coalesce((select sum(al.amount_paisa) from public.fee_payment_allocation al
                                      join public.fee_payment p on p.id = al.payment_id
                                     where al.challan_id = c.id and p.value_date <= p_day), 0) as bal,
             p_day - c.due_date as age
        from public.fee_challan c
       where c.tenant_id = p_tenant_id and c.campus_id = p_campus_id and c.deleted_at is null and c.status <> 'cancelled'
         and c.issue_date <= p_day
    ) q
   where bal > 0;
  r.outstanding_paisa := r.outstanding_0_30_paisa + r.outstanding_31_60_paisa + r.outstanding_60plus_paisa;

  select status::text as status, total_gross_paisa into v_payroll
    from public.payroll_run
   where tenant_id = p_tenant_id and campus_id = p_campus_id and period_month = v_month and status <> 'cancelled'
   order by generated_at desc limit 1;
  if v_payroll.status is null then
    r.staff_cost_paisa := 0;
    r.payroll_status := 'none';
  else
    r.staff_cost_paisa := v_payroll.total_gross_paisa / v_dim
      + case when extract(day from p_day)::int = v_dim then v_payroll.total_gross_paisa % v_dim else 0 end;
    r.payroll_status := v_payroll.status;
  end if;

  r.last_refreshed_at := now();
  return r;
end;
$$;
revoke execute on function app.fn_agg_compute(uuid, uuid, date) from public, anon, authenticated;

create or replace function app.fn_agg_upsert(p_tenant_id uuid, p_campus_id uuid, p_day date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.agg_campus_day := app.fn_agg_compute(p_tenant_id, p_campus_id, p_day);
begin
  insert into public.agg_campus_day as a
  values (r.tenant_id, r.campus_id, r.day, r.enrolled_count, r.present_count, r.marked_sections, r.collected_paisa, r.billed_paisa,
          r.outstanding_paisa, r.outstanding_0_30_paisa, r.outstanding_31_60_paisa, r.outstanding_60plus_paisa,
          r.staff_cost_paisa, r.payroll_status, r.last_refreshed_at)
  on conflict (campus_id, day) do update set
    enrolled_count = excluded.enrolled_count, present_count = excluded.present_count, marked_sections = excluded.marked_sections,
    collected_paisa = excluded.collected_paisa, billed_paisa = excluded.billed_paisa, outstanding_paisa = excluded.outstanding_paisa,
    outstanding_0_30_paisa = excluded.outstanding_0_30_paisa, outstanding_31_60_paisa = excluded.outstanding_31_60_paisa,
    outstanding_60plus_paisa = excluded.outstanding_60plus_paisa, staff_cost_paisa = excluded.staff_cost_paisa,
    payroll_status = excluded.payroll_status, last_refreshed_at = excluded.last_refreshed_at;
end;
$$;
revoke execute on function app.fn_agg_upsert(uuid, uuid, date) from public, anon, authenticated;

-- Explicit range for one tenant, all its campuses. Failure rolls back this
-- tenant's writes, keeps the previous rows, and is logged.
create or replace function public.refresh_agg_campus_day(p_from date, p_to date, p_tenant_id uuid default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_t       record;
  v_c       record;
  v_d       date;
  v_rows    int;
  v_total   int := 0;
begin
  if p_to < p_from or p_to - p_from > 800 then
    raise exception 'RANGE_INVALID' using errcode = '22023';
  end if;

  for v_t in select id from public.tenant where p_tenant_id is null or id = p_tenant_id loop
    v_rows := 0;
    begin
      for v_c in select id from public.campus where tenant_id = v_t.id loop
        for v_d in select (p_from + g)::date from generate_series(0, p_to - p_from) g loop
          perform app.fn_agg_upsert(v_t.id, v_c.id, v_d);
          v_rows := v_rows + 1;
        end loop;
      end loop;
      insert into public.agg_refresh_log (tenant_id, job_name, from_date, to_date, status, rows_written)
      values (v_t.id, 'agg_campus_day_range', p_from, p_to, 'ok', v_rows);
      v_total := v_total + v_rows;
    exception when others then
      insert into public.agg_refresh_log (tenant_id, job_name, from_date, to_date, status, error)
      values (v_t.id, 'agg_campus_day_range', p_from, p_to, 'failed', left(sqlerrm, 500));
    end;
  end loop;
  return v_total;
end;
$$;
revoke execute on function public.refresh_agg_campus_day(date, date, uuid) from public, anon, authenticated;
grant execute on function public.refresh_agg_campus_day(date, date, uuid) to service_role;

-- The 01:30 Asia/Karachi job: yesterday for every campus, a rolling week (cancelled
-- challans have no change timestamp), plus exactly the campus-days touched since the
-- last successful run (back-dated receipts, corrected attendance).
create or replace function public.refresh_agg_nightly()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_t       record;
  v_last_ok timestamptz;
  v_yday    date := app.fn_karachi_today() - 1;
  v_pair    record;
  v_rows    int;
  v_total   int := 0;
begin
  for v_t in select id from public.tenant loop
    v_rows := 0;
    begin
      select max(ran_at) into v_last_ok from public.agg_refresh_log where tenant_id = v_t.id and status = 'ok' and job_name = 'agg_campus_day_nightly';
      v_last_ok := coalesce(v_last_ok, '-infinity'::timestamptz);

      for v_pair in
        select campus_id, day from (
          select c.id as campus_id, (v_yday - 6 + g)::date as day
            from public.campus c, generate_series(0, 6) as g
           where c.tenant_id = v_t.id
          union
          select fl.campus_id, fl.value_date from public.fee_ledger fl
           where fl.tenant_id = v_t.id and fl.posted_at > v_last_ok and fl.value_date <= v_yday
          union
          select a.campus_id, a.attendance_date from public.attendance_day a
           where a.tenant_id = v_t.id and a.marked_at > v_last_ok and a.attendance_date <= v_yday
        ) pairs
      loop
        perform app.fn_agg_upsert(v_t.id, v_pair.campus_id, v_pair.day);
        v_rows := v_rows + 1;
      end loop;

      insert into public.agg_refresh_log (tenant_id, job_name, from_date, to_date, status, rows_written)
      values (v_t.id, 'agg_campus_day_nightly', v_yday - 6, v_yday, 'ok', v_rows);
      v_total := v_total + v_rows;
    exception when others then
      insert into public.agg_refresh_log (tenant_id, job_name, from_date, to_date, status, error)
      values (v_t.id, 'agg_campus_day_nightly', v_yday - 6, v_yday, 'failed', left(sqlerrm, 500));
    end;
  end loop;
  return v_total;
end;
$$;
revoke execute on function public.refresh_agg_nightly() from public, anon, authenticated;
grant execute on function public.refresh_agg_nightly() to service_role;

-- Dashboards call this: how old is the data, and is it stale (> 26 h)?
create or replace function public.agg_freshness()
returns table (last_refreshed_at timestamptz, is_stale boolean, last_failure_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select m.t,
         (m.t is null or m.t < now() - interval '26 hours'),
         (select max(l.ran_at) from public.agg_refresh_log l where l.tenant_id = app.auth_tenant_id() and l.status = 'failed')
    from (select max(a.last_refreshed_at) as t from public.agg_campus_day a where a.tenant_id = app.auth_tenant_id()) m
   where app.auth_tenant_id() is not null;
$$;
revoke execute on function public.agg_freshness() from public, anon;
grant execute on function public.agg_freshness() to authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('agg_campus_day_nightly', '30 20 * * *', 'select public.refresh_agg_nightly();');
  end if;
exception
  when others then null;
end;
$$;
