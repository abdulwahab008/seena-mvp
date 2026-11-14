-- Student and staff photographs, printed on ID cards and shown on profiles. student.photo_path
-- existed (the hostel gate pass and the retention purge read it from a 'student-photos' bucket)
-- but nothing created the bucket or wrote the path. Photos are private, stored at
-- <tenant>/<campus>/<file>, readable by the school's staff on that campus and written only by the
-- roles that may edit the record.
alter table public.staff add column if not exists photo_path text;
-- staff is read column by column (sensitive fields are withheld), so the new column needs its own grant.
grant select (photo_path) on public.staff to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('student-photos', 'student-photos', false, 2097152, array['image/jpeg', 'image/png', 'image/webp']),
       ('staff-photos', 'staff-photos', false, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

create or replace function app.fn_photo_folder_ok(p_name text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select (storage.foldername(p_name))[1] = app.auth_tenant_id()::text
     and (storage.foldername(p_name))[2] ~ '^[0-9a-f-]{36}$'
     and ((storage.foldername(p_name))[2])::uuid = any (app.auth_campus_ids())
     and app.auth_role() not in ('parent', 'student');
$$;
grant execute on function app.fn_photo_folder_ok(text) to authenticated;

create policy student_photo_read on storage.objects for select to authenticated
  using (bucket_id = 'student-photos' and app.fn_photo_folder_ok(name));
create policy student_photo_write on storage.objects for insert to authenticated
  with check (bucket_id = 'student-photos' and app.fn_photo_folder_ok(name)
              and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer'));
create policy student_photo_delete on storage.objects for delete to authenticated
  using (bucket_id = 'student-photos' and app.fn_photo_folder_ok(name)
         and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer'));

create policy staff_photo_read on storage.objects for select to authenticated
  using (bucket_id = 'staff-photos' and app.fn_photo_folder_ok(name));
create policy staff_photo_write on storage.objects for insert to authenticated
  with check (bucket_id = 'staff-photos' and app.fn_photo_folder_ok(name)
              and app.auth_role() in ('super_admin', 'owner', 'hr_manager'));
create policy staff_photo_delete on storage.objects for delete to authenticated
  using (bucket_id = 'staff-photos' and app.fn_photo_folder_ok(name)
         and app.auth_role() in ('super_admin', 'owner', 'hr_manager'));

-- Sets (or clears, with null) the photo and returns the previous path so the caller can remove that file.
create or replace function public.set_student_photo(p_student_id uuid, p_path text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student public.student%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_student from public.student where id = p_student_id and tenant_id = app.auth_tenant_id() and deleted_at is null;
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not (v_student.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_path is not null and p_path not like v_student.tenant_id || '/' || v_student.campus_id || '/' || v_student.id || '-%' then
    raise exception 'PHOTO_PATH_INVALID' using errcode = '22023';
  end if;
  update public.student set photo_path = p_path where id = p_student_id;
  return v_student.photo_path;
end;
$$;
revoke execute on function public.set_student_photo(uuid, text) from public, anon;
grant execute on function public.set_student_photo(uuid, text) to authenticated;

create or replace function public.set_staff_photo(p_staff_id uuid, p_path text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff public.staff%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_staff from public.staff where id = p_staff_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not (v_staff.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_path is not null and p_path not like v_staff.tenant_id || '/' || v_staff.campus_id || '/' || v_staff.id || '-%' then
    raise exception 'PHOTO_PATH_INVALID' using errcode = '22023';
  end if;
  update public.staff set photo_path = p_path where id = p_staff_id;
  return v_staff.photo_path;
end;
$$;
revoke execute on function public.set_staff_photo(uuid, text) from public, anon;
grant execute on function public.set_staff_photo(uuid, text) to authenticated;
