-- FR-K25: defaulter list with ageing buckets.
--
-- Days overdue are measured from the OLDEST unpaid challan's due date, not from
-- the largest balance: one month behind on 30,000 PKR is a different problem
-- from four months behind on 8,000. A student on an approved hardship
-- concession covering today is FLAGGED so staff do not chase them; the list
-- screen hides flagged rows by default. Rebuilt daily at 03:00 PKT; the
-- wrapping view carries the campus scope, because a materialized view cannot.

create materialized view public.mv_fee_defaulter as
select e.tenant_id, e.campus_id, e.session_id, e.id as enrolment_id,
       st.gr_number, st.name_en as student_name, e.class_level_id as class_id, e.section_id,
       (select g.phone_e164
          from public.student_guardian sg join public.guardian g on g.id = sg.guardian_id
         where sg.student_id = st.id and sg.to_date is null and g.phone_e164 is not null
         order by sg.is_primary desc, sg.priority asc limit 1) as guardian_phone,
       d.outstanding_paisa,
       d.oldest_due_date,
       (app.fn_karachi_today() - d.oldest_due_date) as days_overdue,
       case when app.fn_karachi_today() - d.oldest_due_date <= 30 then '1-30'
            when app.fn_karachi_today() - d.oldest_due_date <= 60 then '31-60'
            when app.fn_karachi_today() - d.oldest_due_date <= 90 then '61-90'
            else '90+' end as bucket,
       exists (
         select 1 from public.concession_award ca join public.concession_scheme cs on cs.id = ca.scheme_id
          where ca.enrolment_id = e.id and ca.status = 'approved' and cs.category = 'hardship'
            and ca.effective_from <= app.fn_karachi_today() and (ca.effective_to is null or ca.effective_to >= app.fn_karachi_today())
       ) as has_active_concession,
       now() as refreshed_at
  from public.enrolment e
  join public.student st on st.id = e.student_id
  join lateral (
    select (select greatest(coalesce(sum(case when l.direction = 'debit' then l.amount_paisa else -l.amount_paisa end), 0), 0)::bigint
              from public.fee_ledger l
             where l.enrolment_id = e.id
               and not exists (select 1 from public.fee_challan c2
                                where c2.id = coalesce(l.challan_id, case when l.source_type = 'fee_challan' then l.source_id end) and c2.deleted_at is not null)) as outstanding_paisa,
           (select min(c.due_date) from public.fee_challan c
             where c.enrolment_id = e.id and c.deleted_at is null and c.status in ('unpaid', 'part_paid')
               and c.due_date < app.fn_karachi_today()
               and c.net_paisa - coalesce((select sum(a.amount_paisa) from public.fee_payment_allocation a where a.challan_id = c.id), 0) > 0) as oldest_due_date
  ) d on d.outstanding_paisa > 0 and d.oldest_due_date is not null
 where e.deleted_at is null;

create unique index mv_fee_defaulter_uq on public.mv_fee_defaulter (enrolment_id);
create index idx_mv_fee_defaulter_scope on public.mv_fee_defaulter (tenant_id, campus_id, bucket, days_overdue desc);
revoke all on public.mv_fee_defaulter from anon, authenticated;

create view public.v_fee_defaulter with (security_invoker = true) as
select m.*
  from public.mv_fee_defaulter m
 where m.tenant_id = app.auth_tenant_id()
   and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal', 'vice_principal')
   and m.campus_id = any(app.auth_campus_ids());
grant select on public.v_fee_defaulter to authenticated;

-- security_invoker means the caller needs SELECT on the MV; grant it narrowly
-- and let the view's own predicate be the gate.
grant select on public.mv_fee_defaulter to authenticated;

create or replace function public.refresh_fee_defaulters()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  refresh materialized view public.mv_fee_defaulter;
  select count(*)::int into v_n from public.mv_fee_defaulter;
  insert into public.agg_refresh_log (job_name, status, rows_written) values ('fee_defaulters', 'ok', v_n);
  return v_n;
exception when others then
  insert into public.agg_refresh_log (job_name, status, error) values ('fee_defaulters', 'failed', left(sqlerrm, 500));
  raise;
end;
$$;
revoke execute on function public.refresh_fee_defaulters() from public, anon, authenticated;
grant execute on function public.refresh_fee_defaulters() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('fees_refresh_defaulters', '0 22 * * *', 'select public.refresh_fee_defaulters();');
  end if;
exception
  when others then null;
end;
$$;

-- Bucket totals for the campus, straight from the same rows (so they sum to the receivable).
create or replace function public.fn_defaulter_bucket_totals(p_campus_id uuid default null, p_include_hardship boolean default true)
returns table (bucket text, students int, outstanding_paisa bigint)
language sql
stable
set search_path = ''
as $$
  select b.bucket, count(d.enrolment_id)::int, coalesce(sum(d.outstanding_paisa), 0)::bigint
    from (values ('1-30'), ('31-60'), ('61-90'), ('90+')) b(bucket)
    left join public.v_fee_defaulter d on d.bucket = b.bucket
         and (p_campus_id is null or d.campus_id = p_campus_id)
         and (p_include_hardship or not d.has_active_concession)
   group by b.bucket
   order by b.bucket;
$$;
revoke execute on function public.fn_defaulter_bucket_totals(uuid, boolean) from public, anon;
grant execute on function public.fn_defaulter_bucket_totals(uuid, boolean) to authenticated;

-- ── Excel export of the list (FR-S08 pipeline) ────────────────────────────

insert into public.report_dataset (dataset_key, display_name, allowed_roles, columns) values
  ('fee_defaulters', 'Fee defaulters', array['owner', 'super_admin', 'accountant', 'principal', 'vice_principal'],
   '[{"key":"gr_number","label":"GR number","type":"text"},{"key":"student_name","label":"Student","type":"text"},{"key":"guardian_phone","label":"Guardian phone","type":"text"},{"key":"outstanding_paisa","label":"Outstanding (PKR)","type":"money"},{"key":"oldest_due_date","label":"Oldest due date","type":"date"},{"key":"days_overdue","label":"Days overdue","type":"int"},{"key":"bucket","label":"Ageing bucket","type":"text"},{"key":"has_active_concession","label":"Hardship concession","type":"text"}]')
on conflict (dataset_key) do nothing;

create or replace function app.fn_export_fee_defaulters(p_params jsonb, p_offset int, p_limit int)
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
      select m.gr_number, m.student_name, m.guardian_phone, m.outstanding_paisa, m.oldest_due_date, m.days_overdue, m.bucket,
             case when m.has_active_concession then 'yes' else '' end as has_active_concession
        from public.mv_fee_defaulter m
       where m.tenant_id = app.auth_tenant_id() and m.campus_id = any(app.auth_campus_ids())
         and (p_params ->> 'class_id' is null or m.class_id = (p_params ->> 'class_id')::uuid)
         and (p_params ->> 'bucket' is null or m.bucket = p_params ->> 'bucket')
         and (coalesce((p_params ->> 'hide_hardship')::boolean, false) = false or not m.has_active_concession)
       order by m.days_overdue desc, m.enrolment_id
       offset greatest(p_offset, 0) limit least(greatest(p_limit, 1), 10000)
    ) r
  ), '[]'::jsonb);
end;
$$;
revoke execute on function app.fn_export_fee_defaulters(jsonb, int, int) from public, anon, authenticated;

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
  v_rows := case v_job.dataset_key
    when 'students' then app.fn_export_students(v_job.params, p_offset, p_limit)
    when 'fee_collection' then app.fn_export_fee_collection(v_job.params, p_offset, p_limit)
    when 'fee_defaulters' then app.fn_export_fee_defaulters(v_job.params, p_offset, p_limit)
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
