-- FR-S02: owner cross-campus KPI dashboard.
--
-- Reads only agg_campus_day (FR-S01), so one cheap query serves 8 campuses;
-- the campus_ids claim on that table bounds what any token can see. Every
-- ratio's meaning is stored in metric_definition so the dashboard, the digest
-- and the exported PDF all print the same wording — the owner argues with the
-- definition, not with the number.

create table public.metric_definition (
  metric_key       text primary key check (metric_key ~ '^[a-z][a-z0-9_]+$'),
  display_name     text not null,
  numerator_desc   text not null,
  denominator_desc text not null,
  note             text
);

alter table public.metric_definition enable row level security;
create policy metric_definition_read on public.metric_definition for select to authenticated using (true);

insert into public.metric_definition (metric_key, display_name, numerator_desc, denominator_desc, note) values
  ('collection_rate', 'Collection rate', 'Fees collected this month to date', 'Fees billed this month to date', 'Shown as a percentage to one decimal place.'),
  ('outstanding', 'Outstanding', 'Unpaid balance on issued challans as of the latest refreshed day', 'n/a', 'Split by age of the challan''s due date: 0-30, 31-60 and 60+ days.'),
  ('staff_cost_ratio', 'Staff cost ratio', 'Payroll gross for this month to date', 'Fees COLLECTED this month to date', 'Collected, not billed: billed fees that were never paid cannot fund a salary. A draft payroll is shown and marked "payroll not locked".'),
  ('attendance_rate', 'Attendance rate', 'Students present or late on the latest refreshed day', 'Students enrolled that day', null);

-- staff cost as a share of collected fees for a campus-month (null if nothing was collected)
create or replace function public.fn_staff_cost_ratio(p_campus_id uuid, p_month date)
returns numeric
language sql
stable
set search_path = ''
as $$
  select round(sum(a.staff_cost_paisa)::numeric / nullif(sum(a.collected_paisa), 0), 4)
    from public.agg_campus_day a
   where a.campus_id = p_campus_id
     and a.day >= date_trunc('month', p_month)::date
     and a.day < (date_trunc('month', p_month) + interval '1 month')::date;
$$;
revoke execute on function public.fn_staff_cost_ratio(uuid, date) from public, anon;
grant execute on function public.fn_staff_cost_ratio(uuid, date) to authenticated;

create view public.v_owner_kpi with (security_invoker = true) as
with cur as (
  select app.fn_karachi_today() as today, date_trunc('month', app.fn_karachi_today())::date as month_start
),
m as (
  select a.tenant_id, a.campus_id,
         sum(a.billed_paisa)::bigint as billed_paisa,
         sum(a.collected_paisa)::bigint as collected_paisa,
         sum(a.staff_cost_paisa)::bigint as staff_cost_paisa,
         bool_or(a.payroll_status in ('draft', 'pending_approval')) as payroll_unlocked,
         bool_or(a.payroll_status <> 'none') as has_payroll,
         max(a.last_refreshed_at) as last_refreshed_at
    from public.agg_campus_day a, cur
   where a.day between cur.month_start and cur.today
   group by a.tenant_id, a.campus_id
),
l as (
  select distinct on (a.campus_id) a.*
    from public.agg_campus_day a, cur
   where a.day between cur.month_start and cur.today
   order by a.campus_id, a.day desc
)
select m.tenant_id, m.campus_id, c.name as campus_name,
       m.billed_paisa, m.collected_paisa,
       round(m.collected_paisa * 100.0 / nullif(m.billed_paisa, 0), 1) as collection_pct,
       l.outstanding_paisa, l.outstanding_0_30_paisa, l.outstanding_31_60_paisa, l.outstanding_60plus_paisa,
       m.staff_cost_paisa,
       round(m.staff_cost_paisa::numeric / nullif(m.collected_paisa, 0), 4) as staff_cost_ratio,
       (m.has_payroll and not m.payroll_unlocked) as payroll_locked,
       l.payroll_status,
       l.enrolled_count, l.present_count,
       round(l.present_count * 100.0 / nullif(l.enrolled_count, 0), 1) as attendance_pct,
       l.day as as_of_day, m.last_refreshed_at
  from m
  join l on l.campus_id = m.campus_id
  join public.campus c on c.id = m.campus_id;
