-- FR-H05: homework submission by student.
--
-- One submission per (homework, enrolment). Submitting is three steps so the
-- teacher can never grade half an upload: begin_submission() stages the text
-- and opens a pending version, add_submission_file() reserves each file, and
-- finalize_submission() flips it live in one transaction. Until then a first
-- submission is a 'draft' the teacher cannot see, and a replacement leaves the
-- previous version showing. Replacing archives the old version (text, files,
-- timing) in homework_submission_version and increments version; a submission
-- the teacher has checked can no longer change.
--
-- Lateness is computed here, in Asia/Karachi, against the end of the due date
-- (midnight at the start of the next day); the client clock plays no part.
-- Only a student of that section (or their parent) can submit, for a published
-- homework; there is no INSERT policy, so the function checks are the only way
-- in.

create table public.homework_submission (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  session_id      uuid not null references public.academic_session(id) on delete cascade,
  homework_id     uuid not null references public.homework(id) on delete cascade,
  enrolment_id    uuid not null references public.enrolment(id) on delete cascade,
  submission_text text check (submission_text is null or char_length(submission_text) <= 2000),
  pending_text    text check (pending_text is null or char_length(pending_text) <= 2000),
  version         int not null default 1,
  pending_version int,
  status          text not null default 'draft' check (status in ('draft', 'submitted', 'checked')),
  submitted_at    timestamptz,
  is_late         boolean not null default false,
  late_by_minutes int not null default 0 check (late_by_minutes >= 0),
  submitted_by    uuid references auth.users(id),
  checked_by      uuid references auth.users(id),
  checked_at      timestamptz,
  created_at      timestamptz not null default now(),
  constraint uq_homework_submission unique (homework_id, enrolment_id),
  constraint chk_submission_live check (status = 'draft' or submitted_at is not null)
);
create index idx_hw_sub_homework on public.homework_submission (homework_id, status);
create index idx_hw_sub_enrolment on public.homework_submission (enrolment_id);
create index idx_hw_sub_scope on public.homework_submission (tenant_id, campus_id);
create index idx_hw_sub_session on public.homework_submission (session_id);

create table public.homework_submission_file (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  submission_id     uuid not null references public.homework_submission(id) on delete cascade,
  version           int not null,
  storage_path      text not null,
  original_filename text not null,
  mime_type         text not null check (mime_type in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')),
  size_bytes        bigint not null check (size_bytes > 0 and size_bytes <= 5242880),
  uploaded_by       uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  constraint uq_submission_file_path unique (storage_path)
);
create index idx_hw_sub_file_submission on public.homework_submission_file (submission_id, version);
create index idx_hw_sub_file_tenant on public.homework_submission_file (tenant_id);
create index idx_hw_sub_file_uploader on public.homework_submission_file (uploaded_by);

create table public.homework_submission_version (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  submission_id uuid not null references public.homework_submission(id) on delete cascade,
  version       int not null,
  snapshot      jsonb not null,
  archived_at   timestamptz not null default now(),
  constraint uq_submission_version unique (submission_id, version)
);
create index idx_hw_sub_version_tenant on public.homework_submission_version (tenant_id);

create trigger homework_submission_audit after insert or update or delete on public.homework_submission
  for each row execute function app.tg_audit_row();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('homework-submissions', 'homework-submissions', false, 5242880, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set file_size_limit = 5242880, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];

-- Student themselves, or a guardian linked to the student.
create or replace function app.fn_is_own_enrolment(p_enrolment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.enrolment e
     where e.id = p_enrolment_id
       and (e.student_id = public.my_student_id() or e.student_id = any (app.auth_guardian_student_ids()))
  );
$$;
revoke execute on function app.fn_is_own_enrolment(uuid) from public, anon;
grant execute on function app.fn_is_own_enrolment(uuid) to authenticated;

create or replace function app.fn_teacher_of_homework(p_homework_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.homework h
     where h.id = p_homework_id and h.tenant_id = app.auth_tenant_id()
       and (h.teacher_id = (select auth.uid())
            or (app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal')
                and (app.auth_role() in ('owner', 'super_admin') or h.campus_id = any (app.auth_campus_ids()))))
  );
$$;
revoke execute on function app.fn_teacher_of_homework(uuid) from public, anon;
grant execute on function app.fn_teacher_of_homework(uuid) to authenticated;

alter table public.homework_submission enable row level security;
alter table public.homework_submission_file enable row level security;
alter table public.homework_submission_version enable row level security;

create policy hw_sub_read on public.homework_submission for select to authenticated
  using (tenant_id = app.auth_tenant_id() and (app.fn_is_own_enrolment(enrolment_id) or (status in ('submitted', 'checked') and app.fn_teacher_of_homework(homework_id))));
create policy hw_sub_file_read on public.homework_submission_file for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and exists (select 1 from public.homework_submission s where s.id = submission_id
                 and (app.fn_is_own_enrolment(s.enrolment_id) or (version <= s.version and s.status in ('submitted', 'checked') and app.fn_teacher_of_homework(s.homework_id))))
  );
create policy hw_sub_version_read on public.homework_submission_version for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.homework_submission s where s.id = submission_id));

create policy hw_sub_file_object_read on storage.objects for select to authenticated
  using (bucket_id = 'homework-submissions' and exists (select 1 from public.homework_submission_file f where f.storage_path = objects.name));
create policy hw_sub_file_object_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'homework-submissions'
    and (storage.foldername(objects.name))[1] = app.auth_tenant_id()::text
    and exists (select 1 from public.homework_submission_file f where f.storage_path = objects.name and f.uploaded_by = (select auth.uid()))
  );

create or replace function app.tg_submission_file_cleanup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.storage_delete_queue (bucket, path) values ('homework-submissions', old.storage_path) on conflict do nothing;
  return null;
end;
$$;
create trigger trg_submission_file_cleanup after delete on public.homework_submission_file
  for each row execute function app.tg_submission_file_cleanup();

-- Minutes past the end of the due date (Asia/Karachi); 0 when on time.
create or replace function app.fn_late_minutes(p_due_date date, p_at timestamptz)
returns int
language sql
immutable
set search_path = ''
as $$
  select greatest(0, ceil(extract(epoch from (p_at - (((p_due_date + 1)::timestamp) at time zone 'Asia/Karachi'))) / 60.0))::int;
$$;
revoke execute on function app.fn_late_minutes(date, timestamptz) from public, anon;
grant execute on function app.fn_late_minutes(date, timestamptz) to authenticated;

create or replace function app.fn_submission_access(p_submission_id uuid)
returns public.homework_submission
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s public.homework_submission%rowtype;
begin
  select * into v_s from public.homework_submission where id = p_submission_id and tenant_id = app.auth_tenant_id() for update;
  if not found or not app.fn_is_own_enrolment(v_s.enrolment_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_s.status = 'checked' then
    raise exception 'SUBMISSION_CHECKED' using errcode = '55000';
  end if;
  return v_s;
end;
$$;
revoke execute on function app.fn_submission_access(uuid) from public, anon, authenticated;

create or replace function public.begin_submission(p_homework_id uuid, p_enrolment_id uuid, p_text text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hw public.homework%rowtype;
  v_e  public.enrolment%rowtype;
  v_s  public.homework_submission%rowtype;
  v_pending int;
begin
  select * into v_hw from public.homework where id = p_homework_id and tenant_id = app.auth_tenant_id() and status = 'published';
  select * into v_e from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id() and deleted_at is null;
  if v_hw.id is null or v_e.id is null or v_e.section_id <> v_hw.section_id or v_e.status <> 'active' or not app.fn_is_own_enrolment(p_enrolment_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if char_length(coalesce(p_text, '')) > 2000 then
    raise exception 'TEXT_TOO_LONG' using errcode = '23514';
  end if;

  select * into v_s from public.homework_submission where homework_id = p_homework_id and enrolment_id = p_enrolment_id for update;
  if not found then
    insert into public.homework_submission (tenant_id, campus_id, session_id, homework_id, enrolment_id, pending_text, pending_version, submitted_by)
    values (v_hw.tenant_id, v_hw.campus_id, v_hw.session_id, p_homework_id, p_enrolment_id, nullif(btrim(p_text), ''), 1, (select auth.uid()))
    returning * into v_s;
    return v_s.id;
  end if;
  if v_s.status = 'checked' then
    raise exception 'SUBMISSION_CHECKED' using errcode = '55000';
  end if;
  v_pending := case v_s.status when 'draft' then 1 else v_s.version + 1 end;
  delete from public.homework_submission_file where submission_id = v_s.id and version >= v_pending;
  update public.homework_submission set pending_text = nullif(btrim(p_text), ''), pending_version = v_pending where id = v_s.id;
  return v_s.id;
end;
$$;
revoke execute on function public.begin_submission(uuid, uuid, text) from public, anon;
grant execute on function public.begin_submission(uuid, uuid, text) to authenticated;

create or replace function public.add_submission_file(p_submission_id uuid, p_filename text, p_mime_type text, p_size_bytes bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s    public.homework_submission%rowtype;
  v_id   uuid := gen_random_uuid();
  v_ext  text;
  v_path text;
begin
  v_s := app.fn_submission_access(p_submission_id);
  if v_s.pending_version is null then
    raise exception 'NO_SUBMISSION_IN_PROGRESS' using errcode = '55000';
  end if;
  if p_mime_type not in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp') then
    raise exception 'ATTACHMENT_TYPE_NOT_ALLOWED' using errcode = '22023';
  end if;
  if p_size_bytes is null or p_size_bytes <= 0 then
    raise exception 'ATTACHMENT_EMPTY' using errcode = '22023';
  end if;
  if p_size_bytes > 5242880 then
    raise exception 'FILE_EXCEEDS_5MB' using errcode = '54000';
  end if;
  if (select count(*) from public.homework_submission_file where submission_id = p_submission_id and version = v_s.pending_version) >= 5 then
    raise exception 'MAX_5_FILES' using errcode = '54000';
  end if;
  v_ext := case p_mime_type when 'application/pdf' then 'pdf' when 'image/jpeg' then 'jpg' when 'image/png' then 'png' else 'webp' end;
  v_path := format('%s/%s/%s/%s/%s.%s', v_s.tenant_id, v_s.campus_id, v_s.homework_id, v_s.enrolment_id, v_id, v_ext);
  insert into public.homework_submission_file (id, tenant_id, submission_id, version, storage_path, original_filename, mime_type, size_bytes, uploaded_by)
  values (v_id, v_s.tenant_id, p_submission_id, v_s.pending_version, v_path, left(coalesce(nullif(btrim(p_filename), ''), 'file'), 200), p_mime_type, p_size_bytes, (select auth.uid()));
  return jsonb_build_object('file_id', v_id, 'storage_path', v_path);
end;
$$;
revoke execute on function public.add_submission_file(uuid, text, text, bigint) from public, anon;
grant execute on function public.add_submission_file(uuid, text, text, bigint) to authenticated;

create or replace function public.remove_submission_file(p_file_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_f public.homework_submission_file%rowtype;
  v_s public.homework_submission%rowtype;
begin
  select * into v_f from public.homework_submission_file where id = p_file_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'FILE_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_s := app.fn_submission_access(v_f.submission_id);
  if v_f.version is distinct from v_s.pending_version then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  delete from public.homework_submission_file where id = p_file_id;
end;
$$;
revoke execute on function public.remove_submission_file(uuid) from public, anon;
grant execute on function public.remove_submission_file(uuid) to authenticated;

create or replace function public.finalize_submission(p_submission_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s    public.homework_submission%rowtype;
  v_hw   public.homework%rowtype;
  v_late int;
  v_now  timestamptz := clock_timestamp();
begin
  v_s := app.fn_submission_access(p_submission_id);
  if v_s.pending_version is null then
    raise exception 'NO_SUBMISSION_IN_PROGRESS' using errcode = '55000';
  end if;
  if v_s.pending_text is null and not exists (select 1 from public.homework_submission_file where submission_id = p_submission_id and version = v_s.pending_version) then
    raise exception 'EMPTY_SUBMISSION' using errcode = '22023';
  end if;
  select * into v_hw from public.homework where id = v_s.homework_id;
  v_late := app.fn_late_minutes(v_hw.due_date, v_now);

  if v_s.status = 'submitted' then
    insert into public.homework_submission_version (tenant_id, submission_id, version, snapshot)
    values (v_s.tenant_id, v_s.id, v_s.version, jsonb_build_object(
      'text', v_s.submission_text, 'submitted_at', v_s.submitted_at, 'is_late', v_s.is_late, 'late_by_minutes', v_s.late_by_minutes, 'submitted_by', v_s.submitted_by,
      'files', coalesce((select jsonb_agg(jsonb_build_object('path', f.storage_path, 'name', f.original_filename, 'mime', f.mime_type, 'size', f.size_bytes) order by f.created_at)
                           from public.homework_submission_file f where f.submission_id = v_s.id and f.version = v_s.version), '[]'::jsonb)));
  end if;

  update public.homework_submission
     set submission_text = pending_text, version = pending_version, pending_text = null, pending_version = null, status = 'submitted',
         submitted_at = v_now, is_late = v_late > 0, late_by_minutes = v_late, submitted_by = (select auth.uid())
   where id = p_submission_id;
  return jsonb_build_object('version', v_s.pending_version, 'is_late', v_late > 0, 'late_by_minutes', v_late);
end;
$$;
revoke execute on function public.finalize_submission(uuid) from public, anon;
grant execute on function public.finalize_submission(uuid) to authenticated;

-- Abandoned uploads: a draft never finalized, or a replacement never finalized,
-- for a week. The files go with them and the cleanup trigger queues the objects.
create or replace function public.homework_submission_sweep()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  delete from public.homework_submission where status = 'draft' and created_at < now() - interval '7 days';
  get diagnostics v_n = row_count;
  delete from public.homework_submission_file f using public.homework_submission s
   where s.id = f.submission_id and s.pending_version is not null and f.version >= s.pending_version and f.created_at < now() - interval '7 days';
  update public.homework_submission set pending_text = null, pending_version = null
   where status in ('submitted', 'checked') and pending_version is not null
     and not exists (select 1 from public.homework_submission_file f where f.submission_id = homework_submission.id and f.version >= homework_submission.pending_version);
  return v_n;
end;
$$;
revoke execute on function public.homework_submission_sweep() from public, anon, authenticated;
grant execute on function public.homework_submission_sweep() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('homework_submission_sweep', '30 23 * * 6', 'select public.homework_submission_sweep();');
  end if;
exception
  when others then null;
end;
$$;
