-- Newer Supabase blocks direct "delete from storage.objects" (trigger
-- storage.protect_delete) and on hosted Supabase a row delete would orphan the
-- blob anyway. purge_timetable_exports now enqueues the blobs on the existing
-- public.storage_delete_queue (drained through the Storage API by the
-- claim_storage_deletes / complete_storage_delete worker) instead.
create or replace function public.purge_timetable_exports(p_older_than_days int default 30)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cutoff       timestamptz := now() - make_interval(days => p_older_than_days);
  v_objects      int;
  v_jobs         int;
begin
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.storage_delete_queue (bucket, path)
  select 'timetable-exports', j.file_path
    from public.timetable_export_job j
   where j.requested_at < v_cutoff
     and j.file_path is not null
     and (app.auth_tenant_id() is null or j.tenant_id = app.auth_tenant_id())
  on conflict do nothing;
  get diagnostics v_objects = row_count;

  delete from public.timetable_export_job
   where requested_at < v_cutoff
     and (app.auth_tenant_id() is null or tenant_id = app.auth_tenant_id());
  get diagnostics v_jobs = row_count;

  return jsonb_build_object('jobs_deleted', v_jobs, 'objects_deleted', v_objects);
end;
$$;

revoke execute on function public.purge_timetable_exports(int) from public, anon;
grant execute on function public.purge_timetable_exports(int) to authenticated, service_role;
