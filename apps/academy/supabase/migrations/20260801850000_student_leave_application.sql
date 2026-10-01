-- FR-G07: parent leave application submission.
--
-- A parent (or the student, or an office user keying in an application the
-- parent sent by WhatsApp) applies for leave on a linked student. The
-- database owns every rule that two browser tabs could race on:
--   * overlap with a pending or approved application for the same student is
--     an EXCLUDE constraint over daterange(from_date, to_date, '[]'), not a
--     check in the app; the friendly "A leave request already covers <date>"
--     is produced by a pre-check and, for the race that slips past it, by the
--     constraint's own violation;
--   * at most 3 attachments and 10 MB in total, counted under a lock on the
--     application row so two simultaneous uploads cannot both squeeze in.
-- Writes happen only through these functions, so a parent can only ever apply
-- for a child linked to them and a request for any other student is a 403.
-- Remarks are free UTF-8 text (Urdu included) rendered with dir="auto".
-- applied_by_user_id records the office user when staff enter it on behalf.

create type public.student_leave_category as enum ('medical', 'family', 'travel', 'religious', 'other');
create type public.student_leave_status as enum ('pending', 'approved', 'rejected', 'cancelled');

create table public.student_leave_application (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant(id) on delete cascade,
  campus_id          uuid not null references public.campus(id) on delete cascade,
  session_id         uuid not null references public.academic_session(id) on delete cascade,
  enrolment_id       uuid not null references public.enrolment(id) on delete cascade,
  applied_by_user_id uuid not null references auth.users(id),
  applied_via        text not null check (applied_via in ('parent', 'student', 'office')),
  from_date          date not null,
  to_date            date not null,
  reason_category    public.student_leave_category not null,
  remarks            text check (remarks is null or char_length(remarks) <= 500),
  status             public.student_leave_status not null default 'pending',
  decided_by         uuid references auth.users(id),
  decided_at         timestamptz,
  decision_note      text,
  created_at         timestamptz not null default now(),
  constraint chk_student_leave_date_order check (to_date >= from_date),
  constraint ex_student_leave_no_overlap exclude using gist (
    enrolment_id with =, daterange(from_date, to_date, '[]') with &&
  ) where (status in ('pending', 'approved'))
);
create index idx_student_leave_enrol_dates on public.student_leave_application (enrolment_id, from_date, to_date);
create index idx_student_leave_scope on public.student_leave_application (tenant_id, campus_id, status, from_date);
create index idx_student_leave_applicant on public.student_leave_application (applied_by_user_id);
create index idx_student_leave_session on public.student_leave_application (session_id);

create table public.student_leave_attachment (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  leave_application_id uuid not null references public.student_leave_application(id) on delete cascade,
  storage_path         text not null,
  file_name            text not null,
  mime_type            text not null check (mime_type in ('application/pdf', 'image/jpeg', 'image/png')),
  size_bytes           bigint not null check (size_bytes > 0 and size_bytes <= 10485760),
  created_at           timestamptz not null default now()
);
create index idx_student_leave_attachment_app on public.student_leave_attachment (leave_application_id);
create index idx_student_leave_attachment_tenant on public.student_leave_attachment (tenant_id);

create trigger student_leave_application_audit after insert or update or delete on public.student_leave_application
  for each row execute function app.tg_audit_row();

alter table public.student_leave_application enable row level security;
alter table public.student_leave_attachment enable row level security;

create policy leave_parent_select_own on public.student_leave_application for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      enrolment_id in (select e.id from public.enrolment e where e.student_id = any (app.auth_guardian_student_ids()))
      or enrolment_id in (select e.id from public.enrolment e where e.student_id = public.my_student_id())
      or (app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'admissions_officer', 'receptionist', 'class_teacher', 'head_of_department')
          and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())))
    )
  );
create policy leave_attachment_select on public.student_leave_attachment for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.student_leave_application a where a.id = leave_application_id));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('leave-attachments', 'leave-attachments', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do update set file_size_limit = 10485760, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png'];

create or replace function app.fn_leave_covering_date(p_enrolment_id uuid, p_from date, p_to date)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select d::date
    from generate_series(p_from, p_to, interval '1 day') d
   where exists (select 1 from public.student_leave_application a
                  where a.enrolment_id = p_enrolment_id and a.status in ('pending', 'approved') and d::date between a.from_date and a.to_date)
   order by d
   limit 1;
$$;
revoke execute on function app.fn_leave_covering_date(uuid, date, date) from public, anon, authenticated;

create or replace function public.submit_student_leave(
  p_enrolment_id uuid, p_from_date date, p_to_date date, p_reason_category public.student_leave_category, p_remarks text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e     public.enrolment%rowtype;
  v_role  text := app.auth_role();
  v_via   text;
  v_cover date;
  v_id    uuid;
begin
  if app.auth_tenant_id() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;
  select * into v_e from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id() and deleted_at is null;
  if not found then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_role = 'parent' then
    if not (v_e.student_id = any (app.auth_guardian_student_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    v_via := 'parent';
  elsif v_role = 'student' then
    if v_e.student_id is distinct from public.my_student_id() then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    v_via := 'student';
  elsif v_role in ('owner', 'super_admin', 'principal', 'vice_principal', 'admissions_officer', 'receptionist') then
    if v_role not in ('owner', 'super_admin') and not (v_e.campus_id = any (app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    v_via := 'office';
  else
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_e.status <> 'active' then
    raise exception 'ENROLMENT_NOT_ACTIVE' using errcode = '55000';
  end if;
  if p_from_date is null or p_to_date is null or p_to_date < p_from_date then
    raise exception 'LEAVE_END_BEFORE_START' using errcode = '23514';
  end if;
  if char_length(coalesce(p_remarks, '')) > 500 then
    raise exception 'REMARKS_TOO_LONG' using errcode = '23514';
  end if;
  v_cover := app.fn_leave_covering_date(p_enrolment_id, p_from_date, p_to_date);
  if v_cover is not null then
    raise exception 'LEAVE_OVERLAP' using errcode = '23P01', detail = format('date=%s', v_cover);
  end if;

  insert into public.student_leave_application (tenant_id, campus_id, session_id, enrolment_id, applied_by_user_id, applied_via, from_date, to_date, reason_category, remarks)
  values (v_e.tenant_id, v_e.campus_id, v_e.session_id, p_enrolment_id, (select auth.uid()), v_via, p_from_date, p_to_date, p_reason_category, nullif(btrim(p_remarks), ''))
  returning id into v_id;
  return v_id;
exception when exclusion_violation then
  raise exception 'LEAVE_OVERLAP' using errcode = '23P01', detail = format('date=%s', coalesce(app.fn_leave_covering_date(p_enrolment_id, p_from_date, p_to_date), p_from_date));
end;
$$;
revoke execute on function public.submit_student_leave(uuid, date, date, public.student_leave_category, text) from public, anon;
grant execute on function public.submit_student_leave(uuid, date, date, public.student_leave_category, text) to authenticated;

create or replace function app.fn_leave_lock_own(p_leave_id uuid)
returns public.student_leave_application
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a public.student_leave_application%rowtype;
begin
  select * into v_a from public.student_leave_application where id = p_leave_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'LEAVE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_a.applied_by_user_id is distinct from (select auth.uid())
     and not (app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'admissions_officer', 'receptionist')
              and (app.auth_role() in ('owner', 'super_admin') or v_a.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return v_a;
end;
$$;
revoke execute on function app.fn_leave_lock_own(uuid) from public, anon, authenticated;

create or replace function public.add_leave_attachment(p_leave_id uuid, p_file_name text, p_mime_type text, p_size_bytes bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a     public.student_leave_application%rowtype;
  v_count int;
  v_total bigint;
  v_id    uuid := gen_random_uuid();
  v_path  text;
  v_name  text := regexp_replace(coalesce(nullif(btrim(p_file_name), ''), 'attachment'), '[^A-Za-z0-9._-]', '_', 'g');
begin
  v_a := app.fn_leave_lock_own(p_leave_id);
  if v_a.status <> 'pending' then
    raise exception 'LEAVE_NOT_PENDING' using errcode = '55000';
  end if;
  if p_mime_type not in ('application/pdf', 'image/jpeg', 'image/png') then
    raise exception 'ATTACHMENT_TYPE_NOT_ALLOWED' using errcode = '22023';
  end if;
  if p_size_bytes is null or p_size_bytes <= 0 then
    raise exception 'ATTACHMENT_EMPTY' using errcode = '22023';
  end if;
  select count(*), coalesce(sum(size_bytes), 0) into v_count, v_total from public.student_leave_attachment where leave_application_id = p_leave_id;
  if v_count >= 3 then
    raise exception 'TOO_MANY_ATTACHMENTS' using errcode = '54000';
  end if;
  if v_total + p_size_bytes > 10485760 then
    raise exception 'ATTACHMENTS_TOTAL_TOO_LARGE' using errcode = '54000', detail = format('total_bytes=%s', v_total);
  end if;
  v_path := format('%s/%s/%s/%s/%s-%s', v_a.tenant_id, v_a.campus_id, v_a.enrolment_id, v_a.id, v_id, left(v_name, 80));
  insert into public.student_leave_attachment (id, tenant_id, leave_application_id, storage_path, file_name, mime_type, size_bytes)
  values (v_id, v_a.tenant_id, p_leave_id, v_path, left(v_name, 120), p_mime_type, p_size_bytes);
  return jsonb_build_object('attachment_id', v_id, 'storage_path', v_path);
end;
$$;
revoke execute on function public.add_leave_attachment(uuid, text, text, bigint) from public, anon;
grant execute on function public.add_leave_attachment(uuid, text, text, bigint) to authenticated;

create or replace function public.remove_leave_attachment(p_attachment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_leave uuid;
begin
  select leave_application_id into v_leave from public.student_leave_attachment where id = p_attachment_id and tenant_id = app.auth_tenant_id();
  if v_leave is null then
    raise exception 'ATTACHMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_leave_lock_own(v_leave);
  delete from public.student_leave_attachment where id = p_attachment_id;
end;
$$;
revoke execute on function public.remove_leave_attachment(uuid) from public, anon;
grant execute on function public.remove_leave_attachment(uuid) to authenticated;

create or replace function public.cancel_student_leave(p_leave_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a public.student_leave_application%rowtype;
begin
  v_a := app.fn_leave_lock_own(p_leave_id);
  if v_a.status <> 'pending' then
    raise exception 'LEAVE_NOT_PENDING' using errcode = '55000';
  end if;
  update public.student_leave_application set status = 'cancelled', decided_by = (select auth.uid()), decided_at = now() where id = p_leave_id;
end;
$$;
revoke execute on function public.cancel_student_leave(uuid) from public, anon;
grant execute on function public.cancel_student_leave(uuid) to authenticated;
