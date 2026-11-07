-- Download centre: syllabus, study material and other files a campus shares
-- with a whole campus, one class, or one section, for staff and parents.
--
-- The file goes up through a server action: register_download_item() checks
-- the caller and reserves the path, then the action writes the bytes with the
-- service role into the private 'downloads' bucket (no client storage policy
-- is needed). Reading is by a short-lived signed URL the app issues only after
-- download_item_path() has said yes. Deleting a row queues the object in the
-- existing storage_delete_queue (homework_attachments.sql), so files never
-- outlive their records.

create table public.download_item (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  category          text not null check (category in ('syllabus', 'material', 'other')),
  title             text not null check (length(btrim(title)) between 1 and 200),
  class_level_id    uuid references public.class_level(id) on delete cascade,
  section_id        uuid references public.class_section(id) on delete cascade,
  storage_path      text not null unique,
  original_filename text not null,
  mime_type         text not null check (mime_type in (
    'application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'text/plain',
    'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation')),
  size_bytes        bigint not null check (size_bytes > 0 and size_bytes <= 10485760),
  uploaded_by       uuid not null default auth.uid() references auth.users(id),
  created_at        timestamptz not null default now()
);

create index idx_download_item_scope on public.download_item (tenant_id, campus_id, created_at desc);
create index idx_download_item_class on public.download_item (class_level_id) where class_level_id is not null;
create index idx_download_item_section on public.download_item (section_id) where section_id is not null;

alter table public.download_item enable row level security;

create policy download_item_staff_read on public.download_item
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

select app.fn_block_portal_roles('public.download_item');

insert into storage.buckets (id, name, public, file_size_limit)
values ('downloads', 'downloads', false, 10485760)
on conflict (id) do update set file_size_limit = 10485760;

create or replace function app.tg_download_item_cleanup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.storage_delete_queue (bucket, path) values ('downloads', old.storage_path) on conflict do nothing;
  return null;
end;
$$;
create trigger trg_download_item_cleanup after delete on public.download_item
  for each row execute function app.tg_download_item_cleanup();

create or replace function app.fn_download_manager()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'head_of_department', 'class_teacher', 'subject_teacher', 'exam_controller', 'admissions_officer');
$$;

create or replace function public.register_download_item(
  p_campus_id      uuid,
  p_category       text,
  p_title          text,
  p_class_level_id uuid,
  p_section_id     uuid,
  p_filename       text,
  p_mime_type      text,
  p_size_bytes     bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid := gen_random_uuid();
  v_ext       text := lower(coalesce(nullif(substring(p_filename from '\.([A-Za-z0-9]{1,8})$'), ''), 'bin'));
  v_path      text;
begin
  if v_tenant_id is null or not app.fn_download_manager() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id and deleted_at is null) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501', detail = 'campus outside your scope';
  end if;
  if p_class_level_id is not null and not exists (select 1 from public.class_level where id = p_class_level_id and tenant_id = v_tenant_id) then
    raise exception 'CLASS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_section_id is not null and not exists (
    select 1 from public.class_section where id = p_section_id and campus_id = p_campus_id
       and (p_class_level_id is null or class_level_id = p_class_level_id)
  ) then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_path := v_tenant_id || '/' || p_campus_id || '/' || v_id || '.' || v_ext;
  insert into public.download_item (id, tenant_id, campus_id, category, title, class_level_id, section_id, storage_path, original_filename, mime_type, size_bytes)
  values (v_id, v_tenant_id, p_campus_id, p_category, btrim(p_title), p_class_level_id, p_section_id, v_path, p_filename, p_mime_type, p_size_bytes);
  return jsonb_build_object('id', v_id, 'storage_path', v_path);
end;
$$;
revoke execute on function public.register_download_item(uuid, text, text, uuid, uuid, text, text, bigint) from public, anon;
grant execute on function public.register_download_item(uuid, text, text, uuid, uuid, text, text, bigint) to authenticated;

create or replace function public.delete_download_item(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is null or not app.fn_download_manager() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  delete from public.download_item d
   where d.id = p_id and d.tenant_id = app.auth_tenant_id()
     and (d.uploaded_by = (select auth.uid()) or app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal'))
     and (app.auth_role() in ('super_admin', 'owner') or d.campus_id = any(app.auth_campus_ids()));
  if not found then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function public.delete_download_item(uuid) from public, anon;
grant execute on function public.delete_download_item(uuid) to authenticated;

-- ── what a parent or student may see: their children's campus, class, section ──

create or replace function app.fn_portal_download_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select d.id
    from public.download_item d
    join public.enrolment e on e.campus_id = d.campus_id and e.status = 'active'
   where d.tenant_id = app.auth_tenant_id()
     and (d.class_level_id is null or d.class_level_id = e.class_level_id)
     and (d.section_id is null or d.section_id = e.section_id)
     and (
       (app.auth_role() = 'parent' and e.student_id = any(app.auth_guardian_student_ids()))
       or (app.auth_role() = 'student' and e.student_id = public.my_student_id())
     );
$$;
revoke execute on function app.fn_portal_download_ids() from public, anon;
grant execute on function app.fn_portal_download_ids() to authenticated;

create or replace function public.portal_download_items()
returns table (id uuid, category text, title text, original_filename text, size_bytes bigint, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select d.id, d.category, d.title, d.original_filename, d.size_bytes, d.created_at
    from public.download_item d
   where d.id in (select app.fn_portal_download_ids())
   order by d.created_at desc;
$$;
revoke execute on function public.portal_download_items() from public, anon;
grant execute on function public.portal_download_items() to authenticated;

create or replace function public.download_item_path(p_id uuid)
returns table (storage_path text, original_filename text, mime_type text)
language sql
stable
security definer
set search_path = ''
as $$
  select d.storage_path, d.original_filename, d.mime_type
    from public.download_item d
   where d.id = p_id
     and d.tenant_id = app.auth_tenant_id()
     and (
       (app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('super_admin', 'owner') or d.campus_id = any(app.auth_campus_ids())))
       or d.id in (select app.fn_portal_download_ids())
     );
$$;
revoke execute on function public.download_item_path(uuid) from public, anon;
grant execute on function public.download_item_path(uuid) to authenticated;
