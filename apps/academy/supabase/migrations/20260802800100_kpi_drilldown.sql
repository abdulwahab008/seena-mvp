-- FR-S04: KPI drill-down to source rows.
--
-- A dashboard number is only useful if the owner can click it and see the
-- students or staff behind it. The drill-down reads LIVE from the base tables
-- (never the nightly aggregate), through security_invoker views: the views add
-- no access of their own, so the RLS on fee_challan / enrolment / student /
-- attendance_day / payroll_run is what bounds the rows. A definer view here
-- would turn the drill-down into a cross-campus leak that the KPI layer's
-- campus_ids claim never sees.
--
-- Who may see the rows behind a number is stricter than who may see the number:
-- a vice principal reads the collection KPI but not the per-student outstanding
-- list. That rule is data (metric_definition.drilldown_roles), checked inside the
-- views AND by fn_drilldown_permitted(), so the page can say "not permitted"
-- instead of rendering an empty list that looks like "nothing owed".
--
-- The aggregate and the live figure will disagree the moment someone back-dates
-- a receipt. fn_metric_reconcile() states both and the aggregate's refresh time;
-- beyond metric_definition.tolerance_pct (0.5%) the page prints a notice. Trying
-- to guarantee equality would be dishonest and expensive.

alter table public.metric_definition
  add column drilldown_view  text,
  add column drilldown_roles text[],
  add column tolerance_pct   numeric(5, 2) not null default 0.50 check (tolerance_pct >= 0);

update public.metric_definition set drilldown_view = 'v_drilldown_outstanding', drilldown_roles = array['owner', 'super_admin', 'principal', 'accountant'] where metric_key = 'outstanding';
update public.metric_definition set drilldown_view = 'v_drilldown_absentees', drilldown_roles = array['owner', 'super_admin', 'principal', 'vice_principal'] where metric_key = 'attendance_rate';
update public.metric_definition set drilldown_view = 'v_drilldown_staff_cost', drilldown_roles = array['owner', 'super_admin', 'principal'] where metric_key = 'staff_cost_ratio';

-- Role gate shared by the views, the reconciliation function and the export reader.
create or replace function app.fn_drilldown_role_ok(p_metric_key text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((select app.auth_role()::text = any (m.drilldown_roles) from public.metric_definition m where m.metric_key = p_metric_key), false);
$$;

create or replace function public.fn_drilldown_permitted(p_metric_key text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.fn_drilldown_role_ok(p_metric_key);
$$;
revoke execute on function public.fn_drilldown_permitted(text) from public, anon;
grant execute on function public.fn_drilldown_permitted(text) to authenticated;

-- ── views: live rows, RLS of the base tables applies ──────────────────────

create view public.v_drilldown_outstanding with (security_invoker = true) as
select c.tenant_id, c.campus_id, ca.name as campus_name, c.id as challan_id, c.challan_no, e.student_id, st.gr_number, st.name_en as student_name,
       cl.name_en as class_name, sec.name as section_name, c.issue_date, c.due_date,
       (c.net_paisa - coalesce(a.paid, 0))::bigint as balance_paisa,
       (app.fn_karachi_today() - c.due_date) as age_days,
       case when app.fn_karachi_today() - c.due_date <= 30 then '0_30'
            when app.fn_karachi_today() - c.due_date <= 60 then '31_60'
            else '60_plus' end as bucket
  from public.fee_challan c
  join public.enrolment e on e.id = c.enrolment_id
  join public.student st on st.id = e.student_id
  join public.class_level cl on cl.id = e.class_level_id
  join public.class_section sec on sec.id = e.section_id
  join public.campus ca on ca.id = c.campus_id
  left join lateral (select sum(al.amount_paisa) as paid from public.fee_payment_allocation al where al.challan_id = c.id) a on true
 where c.deleted_at is null and c.status <> 'cancelled'
   and c.net_paisa - coalesce(a.paid, 0) > 0
   and app.fn_drilldown_role_ok('outstanding');

create view public.v_drilldown_absentees with (security_invoker = true) as
select d.tenant_id, d.campus_id, ca.name as campus_name, d.attendance_date, e.student_id, st.gr_number, st.name_en as student_name,
       cl.name_en as class_name, sec.name as section_name, d.status::text as status
  from public.attendance_day d
  join public.enrolment e on e.id = d.enrolment_id
  join public.student st on st.id = e.student_id
  join public.class_level cl on cl.id = e.class_level_id
  join public.class_section sec on sec.id = d.section_id
  join public.campus ca on ca.id = d.campus_id
 where d.status = 'absent'
   and app.fn_drilldown_role_ok('attendance_rate');

create view public.v_drilldown_staff_cost with (security_invoker = true) as
select r.tenant_id, r.campus_id, ca.name as campus_name, r.period_month, r.status::text as run_status, l.staff_id, s.employee_code, s.full_name,
       l.gross_paisa, l.net_paisa
  from public.payroll_run_line l
  join public.payroll_run r on r.id = l.payroll_run_id
  join public.staff s on s.id = l.staff_id
  join public.campus ca on ca.id = r.campus_id
 where r.status <> 'cancelled'
   and app.fn_drilldown_role_ok('staff_cost_ratio');

grant select on public.v_drilldown_outstanding, public.v_drilldown_absentees, public.v_drilldown_staff_cost to authenticated;

-- ── reconciliation: aggregate vs live ─────────────────────────────────────
-- SECURITY INVOKER: both sides are read through the caller's RLS, so a
-- campus-limited token reconciles only its own campuses.

create or replace function public.fn_metric_reconcile(metric_key text, campus_id uuid, on_day date)
returns table (agg_value numeric, live_value numeric, delta_pct numeric, agg_refreshed_at timestamptz, tolerance_pct numeric, exceeds_tolerance boolean)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_def     public.metric_definition%rowtype;
  v_agg     numeric;
  v_live    numeric;
  v_at      timestamptz;
  v_month   date := date_trunc('month', on_day)::date;
  v_dim     int := extract(day from (date_trunc('month', on_day) + interval '1 month - 1 day'))::int;
  v_delta   numeric;
begin
  select * into v_def from public.metric_definition m where m.metric_key = fn_metric_reconcile.metric_key and m.drilldown_view is not null;
  if not found then
    raise exception 'METRIC_NOT_DRILLABLE' using errcode = '22023';
  end if;
  if not app.fn_drilldown_role_ok(metric_key) then
    return;
  end if;

  if metric_key = 'outstanding' then
    select coalesce(sum(a.outstanding_paisa), 0), max(a.last_refreshed_at) into v_agg, v_at
      from public.agg_campus_day a where a.day = on_day and (fn_metric_reconcile.campus_id is null or a.campus_id = fn_metric_reconcile.campus_id);
    select coalesce(sum(q.bal), 0) into v_live from (
      select c.net_paisa - coalesce((select sum(al.amount_paisa) from public.fee_payment_allocation al join public.fee_payment p on p.id = al.payment_id
                                      where al.challan_id = c.id and p.value_date <= on_day), 0) as bal
        from public.fee_challan c
       where c.deleted_at is null and c.status <> 'cancelled' and c.issue_date <= on_day
         and (fn_metric_reconcile.campus_id is null or c.campus_id = fn_metric_reconcile.campus_id)
    ) q where q.bal > 0;
  elsif metric_key = 'attendance_rate' then
    -- the drilled-down figure is the number of absentees: enrolled minus present
    select coalesce(sum(a.enrolled_count - a.present_count), 0), max(a.last_refreshed_at) into v_agg, v_at
      from public.agg_campus_day a where a.day = on_day and (fn_metric_reconcile.campus_id is null or a.campus_id = fn_metric_reconcile.campus_id);
    select coalesce(sum(x.enrolled - x.present), 0) into v_live from (
      select (select count(*) from public.enrolment e
               where e.campus_id = ca.id and e.deleted_at is null
                 and coalesce(e.joined_on, (e.created_at at time zone 'Asia/Karachi')::date) <= on_day and (e.left_on is null or e.left_on > on_day)) as enrolled,
             (select count(distinct d.enrolment_id) from public.attendance_day d
               where d.campus_id = ca.id and d.attendance_date = on_day and d.status in ('present', 'late', 'half_day')) as present
        from public.campus ca where fn_metric_reconcile.campus_id is null or ca.id = fn_metric_reconcile.campus_id
    ) x;
  else
    select coalesce(sum(a.staff_cost_paisa), 0), max(a.last_refreshed_at) into v_agg, v_at
      from public.agg_campus_day a where a.day = on_day and (fn_metric_reconcile.campus_id is null or a.campus_id = fn_metric_reconcile.campus_id);
    select coalesce(sum(r.total_gross_paisa / v_dim + case when extract(day from on_day)::int = v_dim then r.total_gross_paisa % v_dim else 0 end), 0) into v_live
      from (select distinct on (pr.campus_id) pr.campus_id, pr.total_gross_paisa
              from public.payroll_run pr
             where pr.period_month = v_month and pr.status <> 'cancelled'
               and (fn_metric_reconcile.campus_id is null or pr.campus_id = fn_metric_reconcile.campus_id)
             order by pr.campus_id, pr.generated_at desc) r;
  end if;

  v_delta := coalesce(round(abs(v_live - v_agg) * 100.0 / nullif(case when v_agg <> 0 then abs(v_agg) else abs(v_live) end, 0), 2), 0);
  return query select v_agg, v_live, v_delta, v_at, v_def.tolerance_pct, v_delta > v_def.tolerance_pct;
end;
$$;
revoke execute on function public.fn_metric_reconcile(text, uuid, date) from public, anon;
grant execute on function public.fn_metric_reconcile(text, uuid, date) to authenticated;

-- ── export: the same filter set travels to the async export job ───────────

alter table public.report_dataset add column if not exists description text;

insert into public.report_dataset (dataset_key, display_name, allowed_roles, columns) values
  ('drilldown_outstanding', 'Outstanding fees by challan', array['owner', 'super_admin', 'principal', 'accountant'],
   '[{"key":"challan_no","label":"Challan no","type":"text"},{"key":"gr_number","label":"GR number","type":"text"},{"key":"student_name","label":"Student","type":"text"},{"key":"class_name","label":"Class","type":"text"},{"key":"section_name","label":"Section","type":"text"},{"key":"campus_name","label":"Campus","type":"text"},{"key":"due_date","label":"Due date","type":"date"},{"key":"age_days","label":"Days overdue","type":"int"},{"key":"balance_paisa","label":"Outstanding (PKR)","type":"money"}]'),
  ('drilldown_absentees', 'Absentees', array['owner', 'super_admin', 'principal', 'vice_principal'],
   '[{"key":"attendance_date","label":"Date","type":"date"},{"key":"gr_number","label":"GR number","type":"text"},{"key":"student_name","label":"Student","type":"text"},{"key":"class_name","label":"Class","type":"text"},{"key":"section_name","label":"Section","type":"text"},{"key":"campus_name","label":"Campus","type":"text"}]'),
  ('drilldown_staff_cost', 'Staff cost by employee', array['owner', 'super_admin', 'principal'],
   '[{"key":"employee_code","label":"Employee code","type":"text"},{"key":"full_name","label":"Staff member","type":"text"},{"key":"campus_name","label":"Campus","type":"text"},{"key":"period_month","label":"Month","type":"date"},{"key":"run_status","label":"Payroll status","type":"text"},{"key":"gross_paisa","label":"Gross (PKR)","type":"money"},{"key":"net_paisa","label":"Net (PKR)","type":"money"}]');

-- Reads a drill-down view as the job's requester (claims already re-established
-- by export_job_page) with exactly the filters the user was looking at.
create or replace function app.fn_export_drilldown(p_dataset_key text, p_params jsonb, p_offset int, p_limit int)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_campus uuid := nullif(p_params ->> 'campus_id', '')::uuid;
  v_off    int := greatest(p_offset, 0);
  v_lim    int := least(greatest(p_limit, 1), 10000);
begin
  if p_dataset_key = 'drilldown_outstanding' then
    if not app.fn_drilldown_role_ok('outstanding') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
    return coalesce((select jsonb_agg(r) from (
      select v.challan_no, v.gr_number, v.student_name, v.class_name, v.section_name, v.campus_name, v.due_date, v.age_days, v.balance_paisa
        from public.v_drilldown_outstanding v
       where v.tenant_id = app.auth_tenant_id() and v.campus_id = any (app.auth_campus_ids())
         and (v_campus is null or v.campus_id = v_campus)
         and (p_params ->> 'bucket' is null or v.bucket = p_params ->> 'bucket')
       order by v.balance_paisa desc, v.challan_no offset v_off limit v_lim) r), '[]'::jsonb);
  elsif p_dataset_key = 'drilldown_absentees' then
    if not app.fn_drilldown_role_ok('attendance_rate') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
    return coalesce((select jsonb_agg(r) from (
      select v.attendance_date, v.gr_number, v.student_name, v.class_name, v.section_name, v.campus_name
        from public.v_drilldown_absentees v
       where v.tenant_id = app.auth_tenant_id() and v.campus_id = any (app.auth_campus_ids())
         and (v_campus is null or v.campus_id = v_campus)
         and v.attendance_date = coalesce(nullif(p_params ->> 'on_day', '')::date, app.fn_karachi_today())
       order by v.class_name, v.section_name, v.gr_number offset v_off limit v_lim) r), '[]'::jsonb);
  else
    if not app.fn_drilldown_role_ok('staff_cost_ratio') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
    return coalesce((select jsonb_agg(r) from (
      select v.employee_code, v.full_name, v.campus_name, v.period_month, v.run_status, v.gross_paisa, v.net_paisa
        from public.v_drilldown_staff_cost v
       where v.tenant_id = app.auth_tenant_id() and v.campus_id = any (app.auth_campus_ids())
         and (v_campus is null or v.campus_id = v_campus)
         and v.period_month = date_trunc('month', coalesce(nullif(p_params ->> 'on_day', '')::date, app.fn_karachi_today()))::date
       order by v.full_name, v.staff_id offset v_off limit v_lim) r), '[]'::jsonb);
  end if;
end;
$$;
revoke execute on function app.fn_export_drilldown(text, jsonb, int, int) from public, anon, authenticated;

create or replace function public.export_job_page(p_job_id uuid, p_offset int, p_limit int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.report_export_job%rowtype;
  v_prev text := current_setting('request.jwt.claims', true);
  v_rows jsonb;
begin
  select * into v_job from public.report_export_job where id = p_job_id and status = 'running';
  if not found then
    raise exception 'JOB_NOT_RUNNING' using errcode = '55000';
  end if;
  perform set_config('request.jwt.claims', v_job.claims::text, true);
  v_rows := case
    when v_job.dataset_key = 'students' then app.fn_export_students(v_job.params, p_offset, p_limit)
    when v_job.dataset_key = 'fee_collection' then app.fn_export_fee_collection(v_job.params, p_offset, p_limit)
    when v_job.dataset_key like 'drilldown\_%' then app.fn_export_drilldown(v_job.dataset_key, v_job.params, p_offset, p_limit)
    else null end;
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  if v_rows is null then
    raise exception 'DATASET_NOT_IMPLEMENTED' using errcode = '0A000';
  end if;
  return v_rows;
exception when others then
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  raise;
end;
$$;
revoke execute on function public.export_job_page(uuid, int, int) from public, anon, authenticated;
grant execute on function public.export_job_page(uuid, int, int) to service_role;
