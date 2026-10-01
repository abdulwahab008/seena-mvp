-- FR-K30: fee projection versus collection dashboard.
--
-- Efficiency is measured against what each billing month itself billed, not
-- billed-to-date: a challan's net payable carries earlier months' arrears, so
-- "billed" here is net minus arrears, and "collected" is what has been
-- allocated to that challan capped at the same figure. Paying off an old
-- month's arrears therefore fills the OLD month; it can never push a
-- current month past 100%.
--
-- The materialized view is the only thing that carries the aggregate; the
-- wrapping view applies tenant, role and campus scope (a materialized view
-- cannot have RLS). It lives in the app schema, which PostgREST does not
-- expose, so the grant the invoker view needs cannot be used to read every
-- tenant's rows over the API. Rebuilt hourly at :05 with CONCURRENTLY, and the
-- dashboard rebuilds it itself when it finds the last build older than an
-- hour, so freshness does not depend on pg_cron being installed.

create materialized view app.mv_fee_collection_monthly as
select t.tenant_id, t.campus_id, t.session_id, t.billing_period, t.class_id,
       t.billed_paisa, t.collected_paisa, (t.billed_paisa - t.collected_paisa) as outstanding_paisa,
       t.challan_count, now() as refreshed_at
  from (
    select c.tenant_id, c.campus_id, c.session_id, c.billing_period, e.class_level_id as class_id,
           sum(c.net_paisa - c.arrears_paisa)::bigint as billed_paisa,
           sum(least(coalesce(a.paid, 0), c.net_paisa - c.arrears_paisa))::bigint as collected_paisa,
           count(*)::int as challan_count
      from public.fee_challan c
      join public.enrolment e on e.id = c.enrolment_id
      left join lateral (select sum(al.amount_paisa) as paid from public.fee_payment_allocation al where al.challan_id = c.id) a on true
     where c.deleted_at is null and c.status <> 'cancelled'
     group by c.tenant_id, c.campus_id, c.session_id, c.billing_period, e.class_level_id
  ) t;

create unique index mv_fee_collection_monthly_uq on app.mv_fee_collection_monthly (campus_id, session_id, billing_period, class_id);
create index idx_mv_fee_collection_scope on app.mv_fee_collection_monthly (tenant_id, campus_id, billing_period);
revoke all on app.mv_fee_collection_monthly from anon, authenticated;

create view public.v_fee_collection_monthly with (security_invoker = true) as
select m.tenant_id, m.campus_id, m.session_id, m.billing_period, m.class_id,
       m.billed_paisa, m.collected_paisa, m.outstanding_paisa,
       case when m.billed_paisa > 0 then round(100.0 * m.collected_paisa / m.billed_paisa, 1) end as collection_efficiency_pct,
       m.challan_count, m.refreshed_at
  from app.mv_fee_collection_monthly m
 where m.tenant_id = app.auth_tenant_id()
   and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal', 'vice_principal')
   and m.campus_id = any(app.auth_campus_ids());
grant select on public.v_fee_collection_monthly to authenticated;
grant select on app.mv_fee_collection_monthly to authenticated;

create or replace function public.refresh_fee_collection_metrics()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  if not pg_try_advisory_xact_lock(hashtext('fee_collection_monthly')) then
    return -1;
  end if;
  refresh materialized view concurrently app.mv_fee_collection_monthly;
  select count(*)::int into v_n from app.mv_fee_collection_monthly;
  insert into public.agg_refresh_log (job_name, status, rows_written) values ('fee_collection_monthly', 'ok', v_n);
  return v_n;
exception when others then
  insert into public.agg_refresh_log (job_name, status, error) values ('fee_collection_monthly', 'failed', left(sqlerrm, 500));
  raise;
end;
$$;
revoke execute on function public.refresh_fee_collection_metrics() from public, anon, authenticated;
grant execute on function public.refresh_fee_collection_metrics() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('fees_refresh_collection_metrics', '5 * * * *', 'select public.refresh_fee_collection_metrics();');
  end if;
exception
  when others then null;
end;
$$;

create or replace function public.fee_collection_refresh_due()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal', 'vice_principal')
         and coalesce((select max(l.ran_at) from public.agg_refresh_log l where l.job_name = 'fee_collection_monthly' and l.status = 'ok'), '-infinity'::timestamptz) < now() - interval '55 minutes';
$$;
revoke execute on function public.fee_collection_refresh_due() from public, anon;
grant execute on function public.fee_collection_refresh_due() to authenticated;

create or replace function public.fn_fee_collection_trend(p_campus_id uuid default null, p_months int default 12)
returns table (billing_period date, billed_paisa bigint, collected_paisa bigint, outstanding_paisa bigint, collection_efficiency_pct numeric, challan_count int)
language sql
stable
set search_path = ''
as $$
  select g.m::date,
         coalesce(sum(v.billed_paisa), 0)::bigint,
         coalesce(sum(v.collected_paisa), 0)::bigint,
         coalesce(sum(v.outstanding_paisa), 0)::bigint,
         case when coalesce(sum(v.billed_paisa), 0) > 0 then round(100.0 * sum(v.collected_paisa) / sum(v.billed_paisa), 1) end,
         coalesce(sum(v.challan_count), 0)::int
    from generate_series(
           date_trunc('month', app.fn_karachi_today())::date - ((greatest(least(p_months, 36), 1) - 1) * interval '1 month'),
           date_trunc('month', app.fn_karachi_today())::date, interval '1 month') g(m)
    left join public.v_fee_collection_monthly v
      on date_trunc('month', v.billing_period)::date = g.m::date and (p_campus_id is null or v.campus_id = p_campus_id)
   group by g.m
   order by g.m;
$$;
revoke execute on function public.fn_fee_collection_trend(uuid, int) from public, anon;
grant execute on function public.fn_fee_collection_trend(uuid, int) to authenticated;

-- ── Excel export of the dashboard (FR-S08 pipeline) ───────────────────────

insert into public.report_dataset (dataset_key, display_name, allowed_roles, columns) values
  ('fee_collection_monthly', 'Fee billing versus collection', array['owner', 'super_admin', 'accountant', 'principal', 'vice_principal'],
   '[{"key":"billing_month","label":"Billing month","type":"text"},{"key":"campus_name","label":"Campus","type":"text"},{"key":"class_name","label":"Class","type":"text"},{"key":"billed_paisa","label":"Billed (PKR)","type":"money"},{"key":"collected_paisa","label":"Collected (PKR)","type":"money"},{"key":"outstanding_paisa","label":"Outstanding (PKR)","type":"money"},{"key":"efficiency","label":"Collection efficiency","type":"text"}]')
on conflict (dataset_key) do nothing;

create or replace function app.fn_export_fee_collection_monthly(p_params jsonb, p_offset int, p_limit int)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal', 'vice_principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(r) from (
      select to_char(m.billing_period, 'YYYY-MM') as billing_month, c.name as campus_name, cl.name_en as class_name,
             m.billed_paisa, m.collected_paisa, m.outstanding_paisa,
             case when m.billed_paisa > 0 then round(100.0 * m.collected_paisa / m.billed_paisa, 1)::text || '%' else '' end as efficiency
        from app.mv_fee_collection_monthly m
        join public.campus c on c.id = m.campus_id
        join public.class_level cl on cl.id = m.class_id
       where m.tenant_id = app.auth_tenant_id() and m.campus_id = any(app.auth_campus_ids())
         and (p_params ->> 'campus_id' is null or m.campus_id = (p_params ->> 'campus_id')::uuid)
         and (p_params ->> 'class_id' is null or m.class_id = (p_params ->> 'class_id')::uuid)
         and (p_params ->> 'from' is null or m.billing_period >= (p_params ->> 'from')::date)
         and (p_params ->> 'to' is null or m.billing_period <= (p_params ->> 'to')::date)
       order by m.billing_period, c.name, cl.ordinal
       offset greatest(p_offset, 0) limit least(greatest(p_limit, 1), 10000)
    ) r
  ), '[]'::jsonb);
end;
$$;
revoke execute on function app.fn_export_fee_collection_monthly(jsonb, int, int) from public, anon, authenticated;

-- Dispatch by naming convention so a new dataset is one function, not a redefinition of this one.
create or replace function public.export_job_page(p_job_id uuid, p_offset int, p_limit int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.report_export_job%rowtype;
  v_prev text := current_setting('request.jwt.claims', true);
  v_fn   regprocedure;
  v_rows jsonb;
begin
  select * into v_job from public.report_export_job where id = p_job_id and status = 'running';
  if not found then
    raise exception 'JOB_NOT_RUNNING' using errcode = '55000';
  end if;
  if v_job.dataset_key !~ '^[a-z][a-z0-9_]{1,60}$' then
    raise exception 'DATASET_NOT_IMPLEMENTED' using errcode = '0A000';
  end if;
  v_fn := to_regprocedure(format('app.fn_export_%s(jsonb,integer,integer)', v_job.dataset_key));
  if v_fn is null then
    raise exception 'DATASET_NOT_IMPLEMENTED' using errcode = '0A000';
  end if;
  perform set_config('request.jwt.claims', v_job.claims::text, true);
  execute format('select %s($1, $2, $3)', v_fn::oid::regproc) into v_rows using v_job.params, p_offset, p_limit;
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  return v_rows;
exception when others then
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  raise;
end;
$$;
revoke execute on function public.export_job_page(uuid, int, int) from public, anon, authenticated;
grant execute on function public.export_job_page(uuid, int, int) to service_role;
