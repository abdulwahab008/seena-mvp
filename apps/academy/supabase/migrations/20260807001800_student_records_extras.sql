-- Student records extras: campus transfers, vaccinations, and merging a
-- student entered twice.
--
-- Campus transfer: the sending campus asks, the receiving campus approves.
-- Approval moves the student and this session's enrolment to the new campus
-- and section; section history is end-dated like any section move. Challans
-- already issued stay with the campus that issued them.
--
-- Merge: everything that points at the duplicate is repointed at the record
-- being kept, then the duplicate goes to the recycle bin. It is one
-- transaction: if any table refuses (two enrolments in the same session, or a
-- sealed record such as an issued certificate), nothing moves and the error
-- names the table.

-- ── campus transfer ───────────────────────────────────────────────────────

create table public.campus_transfer (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  student_id     uuid not null references public.student(id) on delete cascade,
  enrolment_id   uuid not null references public.enrolment(id) on delete cascade,
  from_campus_id uuid not null references public.campus(id),
  to_campus_id   uuid not null references public.campus(id),
  to_section_id  uuid not null references public.class_section(id),
  reason         text not null check (length(btrim(reason)) between 1 and 500),
  status         text not null default 'requested' check (status in ('requested', 'approved', 'rejected')),
  decision_note  text check (decision_note is null or length(decision_note) <= 500),
  requested_by   uuid default auth.uid() references auth.users(id),
  requested_at   timestamptz not null default now(),
  decided_by     uuid references auth.users(id),
  decided_at     timestamptz,
  constraint chk_campus_transfer_campuses check (from_campus_id <> to_campus_id),
  constraint chk_campus_transfer_decided check ((status = 'requested') = (decided_at is null))
);
create unique index uq_campus_transfer_open on public.campus_transfer (student_id) where status = 'requested';
create index idx_campus_transfer_from on public.campus_transfer (tenant_id, from_campus_id);
create index idx_campus_transfer_to on public.campus_transfer (tenant_id, to_campus_id);
alter table public.campus_transfer enable row level security;
create policy campus_transfer_read on public.campus_transfer for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'admissions_officer')
         and (app.auth_role() in ('super_admin', 'owner') or from_campus_id = any (app.auth_campus_ids()) or to_campus_id = any (app.auth_campus_ids())));
select app.fn_block_portal_roles('public.campus_transfer');

create or replace function public.request_campus_transfer(p_enrolment_id uuid, p_to_section_id uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  e  public.enrolment%rowtype;
  s  public.class_section%rowtype;
  v_id uuid;
begin
  select * into e from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id() and status = 'active';
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'admissions_officer')
     or (app.auth_role() not in ('super_admin', 'owner') and not (e.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into s from public.class_section where id = p_to_section_id and tenant_id = e.tenant_id and is_active;
  if not found or s.session_id <> e.session_id then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002', hint = 'Choose an active section in the same session at the other campus.';
  end if;
  if s.campus_id = e.campus_id then
    raise exception 'SAME_CAMPUS' using errcode = '22023', hint = 'Moving within a campus is a section change, not a transfer.';
  end if;
  insert into public.campus_transfer (tenant_id, student_id, enrolment_id, from_campus_id, to_campus_id, to_section_id, reason)
  values (e.tenant_id, e.student_id, e.id, e.campus_id, s.campus_id, s.id, btrim(p_reason))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.request_campus_transfer(uuid, uuid, text) from public, anon;
grant execute on function public.request_campus_transfer(uuid, uuid, text) to authenticated;

create or replace function public.decide_campus_transfer(p_id uuid, p_approve boolean, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.campus_transfer%rowtype;
  v_old_section uuid;
begin
  select * into t from public.campus_transfer where id = p_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'TRANSFER_NOT_FOUND' using errcode = 'P0002';
  end if;
  -- The receiving campus decides: it is taking on the student.
  if app.auth_role() not in ('super_admin', 'owner', 'principal')
     or (app.auth_role() not in ('super_admin', 'owner') and not (t.to_campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if t.status <> 'requested' then
    raise exception 'TRANSFER_DECIDED' using errcode = '55000';
  end if;

  update public.campus_transfer
     set status = case when p_approve then 'approved' else 'rejected' end,
         decision_note = nullif(btrim(coalesce(p_note, '')), ''), decided_by = auth.uid(), decided_at = now()
   where id = p_id;
  if not p_approve then
    return;
  end if;

  select section_id into v_old_section from public.enrolment where id = t.enrolment_id for update;
  update public.section_membership_history set to_date = current_date - 1
   where enrolment_id = t.enrolment_id and section_id = v_old_section and to_date is null;
  update public.enrolment
     set campus_id = t.to_campus_id, section_id = t.to_section_id,
         class_level_id = (select class_level_id from public.class_section where id = t.to_section_id),
         override_reason = 'Campus transfer'
   where id = t.enrolment_id;
  insert into public.section_membership_history (enrolment_id, section_id, from_date, moved_by, reason)
  values (t.enrolment_id, t.to_section_id, current_date, auth.uid(), 'Campus transfer');
  update public.student set campus_id = t.to_campus_id where id = t.student_id;
end;
$$;
revoke execute on function public.decide_campus_transfer(uuid, boolean, text) from public, anon;
grant execute on function public.decide_campus_transfer(uuid, boolean, text) to authenticated;

-- ── vaccinations ──────────────────────────────────────────────────────────

create table public.student_vaccination (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  student_id uuid not null references public.student(id) on delete cascade,
  vaccine    text not null check (length(btrim(vaccine)) between 1 and 80),
  dose_no    int not null default 1 check (dose_no between 1 and 10),
  due_on     date,
  given_on   date,
  notes      text check (notes is null or length(notes) <= 300),
  created_by uuid default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  constraint chk_vaccination_date check (due_on is not null or given_on is not null)
);
create unique index uq_student_vaccination on public.student_vaccination (student_id, lower(vaccine), dose_no);
create index idx_student_vaccination_due on public.student_vaccination (tenant_id, campus_id, due_on) where given_on is null;
alter table public.student_vaccination enable row level security;
create policy student_vaccination_read on public.student_vaccination for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'nurse', 'class_teacher')
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
select app.fn_block_portal_roles('public.student_vaccination');

create or replace function public.save_student_vaccination(p_student_id uuid, p_vaccine text, p_dose_no int, p_due_on date default null, p_given_on date default null, p_notes text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campus uuid;
  v_id     uuid;
begin
  select campus_id into v_campus from public.student where id = p_student_id and tenant_id = app.auth_tenant_id() and deleted_at is null;
  if v_campus is null then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'nurse')
     or (app.auth_role() not in ('super_admin', 'owner') and not (v_campus = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_given_on is not null and p_given_on > current_date then
    raise exception 'DATE_INVALID' using errcode = '22023', hint = 'A dose cannot be given in the future.';
  end if;
  insert into public.student_vaccination (tenant_id, campus_id, student_id, vaccine, dose_no, due_on, given_on, notes)
  values (app.auth_tenant_id(), v_campus, p_student_id, btrim(p_vaccine), coalesce(p_dose_no, 1), p_due_on, p_given_on, nullif(btrim(coalesce(p_notes, '')), ''))
  on conflict (student_id, lower(vaccine), dose_no) do update
     set due_on = excluded.due_on, given_on = excluded.given_on, notes = excluded.notes
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.save_student_vaccination(uuid, text, int, date, date, text) from public, anon;
grant execute on function public.save_student_vaccination(uuid, text, int, date, date, text) to authenticated;

-- ── merging duplicates ────────────────────────────────────────────────────

-- Every single-column foreign key that points at student(id), except the
-- student table's own.
create or replace function app.fn_student_references()
returns table (table_name regclass, column_name text)
language sql
stable
set search_path = ''
as $$
  select c.conrelid::regclass, a.attname::text
    from pg_catalog.pg_constraint c
    join pg_catalog.pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
   where c.contype = 'f' and c.confrelid = 'public.student'::regclass and array_length(c.conkey, 1) = 1
     and c.conrelid <> 'public.student'::regclass;
$$;
revoke execute on function app.fn_student_references() from public, anon, authenticated;

create or replace function app.fn_assert_merge(p_keep_id uuid, p_remove_id uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_keep_id = p_remove_id then
    raise exception 'SAME_STUDENT' using errcode = '22023';
  end if;
  if (select count(*) from public.student where id in (p_keep_id, p_remove_id) and tenant_id = app.auth_tenant_id() and deleted_at is null
        and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids()))) <> 2 then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function app.fn_assert_merge(uuid, uuid) from public, anon, authenticated;

-- What a merge would move: table and row count, before anything changes.
create or replace function public.preview_student_merge(p_keep_id uuid, p_remove_id uuid)
returns table (table_name text, row_count bigint)
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  n bigint;
begin
  perform app.fn_assert_merge(p_keep_id, p_remove_id);
  for r in select * from app.fn_student_references() loop
    execute format('select count(*) from %s where %I = $1', r.table_name, r.column_name) into n using p_remove_id;
    if n > 0 then
      table_name := replace(r.table_name::text, 'public.', '');
      row_count := n;
      return next;
    end if;
  end loop;
end;
$$;
revoke execute on function public.preview_student_merge(uuid, uuid) from public, anon;
grant execute on function public.preview_student_merge(uuid, uuid) to authenticated;

create or replace function public.merge_students(p_keep_id uuid, p_remove_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  n int;
  v_moved int := 0;
begin
  perform app.fn_assert_merge(p_keep_id, p_remove_id);
  for r in select * from app.fn_student_references() loop
    begin
      execute format('update %s set %I = $1 where %I = $2', r.table_name, r.column_name, r.column_name) using p_keep_id, p_remove_id;
    exception
      when unique_violation then
        raise exception 'MERGE_CONFLICT' using errcode = '23505', detail = replace(r.table_name::text, 'public.', ''),
          hint = 'Both records have an entry that can exist only once (for example, an enrolment in the same session). Remove one first.';
      when others then
        raise exception 'MERGE_BLOCKED' using errcode = '55000', detail = replace(r.table_name::text, 'public.', '') || ': ' || sqlerrm;
    end;
    get diagnostics n = row_count;
    v_moved := v_moved + n;
  end loop;
  update public.student set deleted_at = now(), deleted_by = auth.uid(), status = 'inactive' where id = p_remove_id;
  return v_moved;
end;
$$;
revoke execute on function public.merge_students(uuid, uuid) from public, anon;
grant execute on function public.merge_students(uuid, uuid) to authenticated;
