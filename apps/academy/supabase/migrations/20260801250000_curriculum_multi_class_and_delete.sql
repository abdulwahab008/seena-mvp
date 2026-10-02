-- Migration: 20260801250000_curriculum_multi_class_and_delete.sql
-- Description: Add delete_class_subject RPC and bulk copy helper.

create or replace function public.delete_class_subject(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  delete from public.class_subject
  where id = p_id and tenant_id = app.auth_tenant_id();

  if not found then
    raise exception 'CLASS_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function public.delete_class_subject(uuid) from public, anon;
grant execute on function public.delete_class_subject(uuid) to authenticated;
