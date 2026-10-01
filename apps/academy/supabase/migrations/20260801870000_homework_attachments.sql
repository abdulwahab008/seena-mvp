-- FR-H02: homework attachments with size and type limits.
--
-- Up to 5 files per assignment, 5 MB each, PDF/JPEG/PNG/WebP only, in a
-- private bucket under tenant_id/campus_id/session_id/homework_id/uuid.ext
-- (tenant first, so one policy enforces tenancy). A file is registered
-- before it is uploaded: register_homework_attachment() applies every limit,
-- under a lock on the homework row so two simultaneous uploads cannot both
-- take the fifth slot, and reserves the path. The storage insert policy only
-- admits an object at a path that was reserved for the uploader, so a client
-- cannot write anywhere else. Content-type sniffing happens in the app before
-- the call (a renamed .exe is refused there and the bucket's MIME allow-list
-- is the second wall).
--
-- Files never outlive their records: deleting an attachment row (directly or
-- by deleting the homework) enqueues the object for removal, a worker drains
-- the queue within seconds, and a weekly sweep queues any object that has no
-- row at all. Reading is by signed URL the app issues after an RLS read of the
-- attachment row, valid 60 minutes; the app link itself never expires.

create table public.homework_attachment (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  session_id        uuid not null references public.academic_session(id) on delete cascade,
  homework_id       uuid not null references public.homework(id) on delete cascade,
  storage_path      text not null,
  original_filename text not null,
  mime_type         text not null check (mime_type in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')),
  size_bytes        bigint not null check (size_bytes > 0 and size_bytes <= 5242880),
  uploaded_by       uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  constraint uq_homework_attachment_path unique (storage_path)
);
create index idx_hw_attachment_homework on public.homework_attachment (homework_id);
create index idx_hw_attachment_scope on public.homework_attachment (tenant_id, campus_id);
create index idx_hw_attachment_session on public.homework_attachment (session_id);
create index idx_hw_attachment_uploader on public.homework_attachment (uploaded_by);

alter table public.homework_attachment enable row level security;
-- An attachment is visible exactly when its homework is: staff of the campus,
-- and parents/students only once it is published.
create policy homework_attachment_read on public.homework_attachment for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.homework h where h.id = homework_id));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('homework-attachments', 'homework-attachments', false, 5242880, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set file_size_limit = 5242880, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];

create policy hw_attach_read on storage.objects for select to authenticated
  using (bucket_id = 'homework-attachments' and exists (select 1 from public.homework_attachment a where a.storage_path = objects.name));
create policy hw_attach_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'homework-attachments'
    and (storage.foldername(objects.name))[1] = app.auth_tenant_id()::text
    and exists (select 1 from public.homework_attachment a where a.storage_path = objects.name and a.uploaded_by = (select auth.uid()))
  );

create table public.storage_delete_queue (
  id          uuid primary key default gen_random_uuid(),
  bucket      text not null,
  path        text not null,
  enqueued_at timestamptz not null default clock_timestamp(),
  attempts    int not null default 0,
  last_error  text,
  done_at     timestamptz
);
create unique index uq_storage_delete_pending on public.storage_delete_queue (bucket, path) where done_at is null;
create index idx_storage_delete_queue on public.storage_delete_queue (enqueued_at) where done_at is null;
alter table public.storage_delete_queue enable row level security;

create or replace function app.tg_hw_attachment_cleanup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.storage_delete_queue (bucket, path) values ('homework-attachments', old.storage_path) on conflict do nothing;
  return null;
end;
$$;
create trigger trg_hw_attachment_cleanup after delete on public.homework_attachment
  for each row execute function app.tg_hw_attachment_cleanup();

create or replace function public.claim_storage_deletes(p_limit int default 100)
returns table (id uuid, bucket text, path text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with c as (
    select q.id from public.storage_delete_queue q
     where q.done_at is null and q.attempts < 5
     order by q.enqueued_at
     for update skip locked
     limit least(greatest(p_limit, 1), 500)
  )
  update public.storage_delete_queue q set attempts = q.attempts + 1 from c where q.id = c.id
  returning q.id, q.bucket, q.path;
end;
$$;
revoke execute on function public.claim_storage_deletes(int) from public, anon, authenticated;
grant execute on function public.claim_storage_deletes(int) to service_role;

create or replace function public.complete_storage_delete(p_id uuid, p_error text default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.storage_delete_queue
     set done_at = case when p_error is null then now() end, last_error = left(p_error, 300)
   where id = p_id;
$$;
revoke execute on function public.complete_storage_delete(uuid, text) from public, anon, authenticated;
grant execute on function public.complete_storage_delete(uuid, text) to service_role;

-- Anything in the bucket with no attachment row, older than an hour (an
-- upload in flight has its row first, so this only finds true orphans).
create or replace function public.homework_orphan_sweep()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  insert into public.storage_delete_queue (bucket, path)
  select o.bucket_id, o.name from storage.objects o
   where o.bucket_id = 'homework-attachments' and o.created_at < now() - interval '1 hour'
     and not exists (select 1 from public.homework_attachment a where a.storage_path = o.name)
  on conflict do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.homework_orphan_sweep() from public, anon, authenticated;
grant execute on function public.homework_orphan_sweep() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('orphan_attachment_sweep', '0 23 * * 6', 'select public.homework_orphan_sweep();');
  end if;
exception
  when others then null;
end;
$$;

create or replace function app.fn_homework_owned(p_homework_id uuid)
returns public.homework
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hw public.homework%rowtype;
begin
  select * into v_hw from public.homework where id = p_homework_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'HOMEWORK_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_hw.teacher_id <> (select auth.uid()) and not (app.auth_role() in ('owner', 'super_admin', 'principal')
       and (app.auth_role() in ('owner', 'super_admin') or v_hw.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return v_hw;
end;
$$;
revoke execute on function app.fn_homework_owned(uuid) from public, anon, authenticated;

create or replace function public.register_homework_attachment(p_homework_id uuid, p_filename text, p_mime_type text, p_size_bytes bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hw   public.homework%rowtype;
  v_id   uuid := gen_random_uuid();
  v_ext  text;
  v_path text;
begin
  v_hw := app.fn_homework_owned(p_homework_id);
  if p_mime_type not in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp') then
    raise exception 'ATTACHMENT_TYPE_NOT_ALLOWED' using errcode = '22023';
  end if;
  if p_size_bytes is null or p_size_bytes <= 0 then
    raise exception 'ATTACHMENT_EMPTY' using errcode = '22023';
  end if;
  if p_size_bytes > 5242880 then
    raise exception 'FILE_EXCEEDS_5MB' using errcode = '54000';
  end if;
  if (select count(*) from public.homework_attachment where homework_id = p_homework_id) >= 5 then
    raise exception 'MAX_5_ATTACHMENTS' using errcode = '54000';
  end if;
  v_ext := case p_mime_type when 'application/pdf' then 'pdf' when 'image/jpeg' then 'jpg' when 'image/png' then 'png' else 'webp' end;
  v_path := format('%s/%s/%s/%s/%s.%s', v_hw.tenant_id, v_hw.campus_id, v_hw.session_id, v_hw.id, v_id, v_ext);
  insert into public.homework_attachment (id, tenant_id, campus_id, session_id, homework_id, storage_path, original_filename, mime_type, size_bytes, uploaded_by)
  values (v_id, v_hw.tenant_id, v_hw.campus_id, v_hw.session_id, p_homework_id, v_path, left(coalesce(nullif(btrim(p_filename), ''), 'attachment'), 200), p_mime_type, p_size_bytes, (select auth.uid()));
  return jsonb_build_object('attachment_id', v_id, 'storage_path', v_path);
end;
$$;
revoke execute on function public.register_homework_attachment(uuid, text, text, bigint) from public, anon;
grant execute on function public.register_homework_attachment(uuid, text, text, bigint) to authenticated;

create or replace function public.remove_homework_attachment(p_attachment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hw uuid;
begin
  select homework_id into v_hw from public.homework_attachment where id = p_attachment_id and tenant_id = app.auth_tenant_id();
  if v_hw is null then
    raise exception 'ATTACHMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_homework_owned(v_hw);
  delete from public.homework_attachment where id = p_attachment_id;
end;
$$;
revoke execute on function public.remove_homework_attachment(uuid) from public, anon;
grant execute on function public.remove_homework_attachment(uuid) to authenticated;

create or replace function public.delete_homework(p_homework_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hw public.homework%rowtype;
begin
  v_hw := app.fn_homework_owned(p_homework_id);
  delete from public.homework where id = p_homework_id;
end;
$$;
revoke execute on function public.delete_homework(uuid) from public, anon;
grant execute on function public.delete_homework(uuid) to authenticated;
