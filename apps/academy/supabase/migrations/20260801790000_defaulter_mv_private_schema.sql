-- FR-K25 follow-up: mv_fee_defaulter was created in public and granted to
-- authenticated so the security_invoker wrapping view could read it. That
-- also let any signed-in user read every tenant's defaulter rows by name
-- through the API. The app schema is not exposed by PostgREST, so moving the
-- materialized view there keeps the view working and closes the hole.

alter materialized view public.mv_fee_defaulter set schema app;

create or replace function public.refresh_fee_defaulters()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  refresh materialized view app.mv_fee_defaulter;
  select count(*)::int into v_n from app.mv_fee_defaulter;
  insert into public.agg_refresh_log (job_name, status, rows_written) values ('fee_defaulters', 'ok', v_n);
  return v_n;
exception when others then
  insert into public.agg_refresh_log (job_name, status, error) values ('fee_defaulters', 'failed', left(sqlerrm, 500));
  raise;
end;
$$;
revoke execute on function public.refresh_fee_defaulters() from public, anon, authenticated;
grant execute on function public.refresh_fee_defaulters() to service_role;

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
        from app.mv_fee_defaulter m
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
