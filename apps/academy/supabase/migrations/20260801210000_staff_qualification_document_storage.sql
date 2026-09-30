-- Migration: 20260801210000_staff_qualification_document_storage.sql
-- Staff qualification document storage bucket and enhanced upload permissions

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('staff-docs', 'staff-docs', false, 10485760, array['image/jpeg', 'image/png', 'application/pdf'])
on conflict (id) do nothing;

drop policy if exists staff_docs_read on storage.objects;
create policy staff_docs_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'staff-docs'
    and (
      app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager')
      or exists (
        select 1 from public.staff_document sd
        where sd.storage_path = objects.name
          and sd.tenant_id = app.auth_tenant_id()
          and sd.staff_id = auth.uid()
      )
    )
  );

drop policy if exists staff_docs_insert on storage.objects;
create policy staff_docs_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'staff-docs'
    and (
      app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager')
      or auth.uid() is not null
    )
  );

drop policy if exists staff_docs_delete on storage.objects;
create policy staff_docs_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'staff-docs'
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager')
  );

-- Update add_staff_document to allow self-upload by staff member when registering qualification
create or replace function public.add_staff_document(p_staff_id uuid, p_label text, p_storage_path text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid;
begin
  if not exists (select 1 from public.app_user where user_id = p_staff_id and tenant_id = v_tenant_id) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') and auth.uid() <> p_staff_id then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.staff_document (tenant_id, staff_id, label, storage_path, uploaded_by)
  values (v_tenant_id, p_staff_id, p_label, p_storage_path, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.add_staff_document(uuid, text, text) from public, anon;
grant execute on function public.add_staff_document(uuid, text, text) to authenticated;
