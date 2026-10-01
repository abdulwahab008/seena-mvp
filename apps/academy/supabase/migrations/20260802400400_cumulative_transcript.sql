-- FR-J13: cumulative academic transcript.
--
-- "As a Principal, I want a cumulative transcript covering every session a
-- student attended, so that Transfer Certificates and college admissions can be
-- supported from one document."
--
-- ── Historical, not active ──────────────────────────────────────────────
--
-- The Notes: the transcript "must survive the student leaving: it reads
-- historical enrolments rather than the active one, and must still render when
-- a campus has been closed, merged or renamed." So:
--
--   * v_student_transcript is one row per ENROLMENT (any status — active,
--     transferred, left, graduated), not per active enrolment, and it joins the
--     campus with no status or deleted_at filter. A campus that has been
--     archived or soft-deleted keeps its row, and app.fn_campus_label() names
--     it ("Old Town Campus (closed)") instead of dropping the session.
--   * A campus's name is read from the campus row as it is now. Renaming is the
--     only change a campus can undergo that this does not see; the issued
--     transcript freezes the label it was printed with (payload_snapshot), so
--     a document in someone's hand never changes after the fact.
--
-- ── What the view is, and what the function is ──────────────────────────
--
-- v_student_transcript is WITH (security_invoker = true): whoever reads it gets
-- what the RLS on enrolment / annual_result / promotion_decision lets them see,
-- so a campus principal sees their campus's rows and nothing leaks.
--
-- A cumulative transcript, however, is exactly the document that crosses
-- campuses — a student enrolled 2019-2026 across two campuses of the same
-- tenant (AC1). fn_student_transcript() is SECURITY DEFINER for that reason:
-- it authorises the CALLER explicitly (tenant, role, and that the student has
-- or had an enrolment in a campus the caller works in) and then reads the same
-- view as its owner, so there is one definition of what a session row is.
--
-- ── Session status ──────────────────────────────────────────────────────
--
--   withheld     FR-J08 holds the result: the session is listed and marked
--                "withheld", with no marks (AC3). Prior completed sessions are
--                unaffected.
--   incomplete   the student left before the session ended: the terms they
--                completed are listed and the row is annotated
--                "incomplete — left March 2023" (AC2).
--   complete     a final annual result exists.
--   in_progress  anything else (a current session whose results are not final).
--
-- ── Issuance ────────────────────────────────────────────────────────────
--
-- issue_transcript() allocates a serial per tenant and year (TRN-2026-000001),
-- freezes the whole document into payload_snapshot together with the issuing
-- officer's name and the issue date, and writes the register row (AC4). The PDF
-- is rendered from that snapshot afterwards (lib/transcripts/*), so a reprint is
-- the same document. The register is append-only: no delete, and nothing but
-- the PDF digest and a void marker may ever change on a row.
--
-- The FR asks for 30-day signed URLs. As FR-J09 and FR-T09 did, downloads go
-- through a route that fetches the object AS THE USER and re-hashes it against
-- the sealed digest, which a signed URL cannot do.

-- ═══════════════════════════════════════════════════════════════════════
-- Serials
-- ═══════════════════════════════════════════════════════════════════════

create table public.transcript_serial_counter (
  tenant_id uuid not null references public.tenant(id) on delete cascade,
  year      integer not null,
  last_seq  integer not null default 0,
  primary key (tenant_id, year)
);
alter table public.transcript_serial_counter enable row level security;
-- No policy: only issue_transcript() touches it.

create table public.transcript_issue (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  student_id       uuid not null references public.student(id) on delete cascade,
  serial_no        text not null,
  purpose          text not null check (btrim(purpose) <> '' and char_length(purpose) <= 200),
  issued_by        uuid not null references public.app_user(user_id),
  issued_by_name   text not null,
  issued_at        timestamptz not null default clock_timestamp(),
  issued_on        date not null,
  session_count    integer not null,
  payload_snapshot jsonb not null,
  storage_path     text not null,
  pdf_sha256       text check (pdf_sha256 is null or pdf_sha256 ~ '^[0-9a-f]{64}$'),
  status           text not null default 'pending' check (status in ('pending', 'issued', 'void')),
  void_reason      text,
  constraint chk_transcript_status check (
    (status = 'issued') = (pdf_sha256 is not null) and (status = 'void') = (void_reason is not null))
);
create unique index uq_transcript_serial on public.transcript_issue (tenant_id, serial_no);
create index idx_transcript_issue_student on public.transcript_issue (student_id, issued_at desc);
create index idx_transcript_issue_tenant on public.transcript_issue (tenant_id, issued_at desc);
create index idx_transcript_issue_issuer on public.transcript_issue (issued_by);

create trigger transcript_issue_audit after insert or update or delete on public.transcript_issue
  for each row execute function app.tg_audit_row();

-- The register is append-only. The only legal updates are sealing (digest set
-- once, pending -> issued) and voiding (pending -> void with a reason).
create or replace function app.tg_transcript_issue_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'TRANSCRIPT_REGISTER_IMMUTABLE' using errcode = '42501',
      detail = 'An issued serial number is never reused or removed.';
  end if;
  if (new.tenant_id, new.student_id, new.serial_no, new.purpose, new.issued_by, new.issued_by_name,
      new.issued_at, new.issued_on, new.session_count, new.payload_snapshot, new.storage_path)
     is distinct from
     (old.tenant_id, old.student_id, old.serial_no, old.purpose, old.issued_by, old.issued_by_name,
      old.issued_at, old.issued_on, old.session_count, old.payload_snapshot, old.storage_path) then
    raise exception 'TRANSCRIPT_REGISTER_IMMUTABLE' using errcode = '42501';
  end if;
  if old.status <> 'pending' then
    raise exception 'TRANSCRIPT_REGISTER_IMMUTABLE' using errcode = '42501',
      detail = 'An issued or voided transcript cannot change.';
  end if;
  return new;
end;
$$;
create trigger trg_transcript_issue_guard
  before update or delete on public.transcript_issue
  for each row execute function app.tg_transcript_issue_guard();

comment on table public.transcript_issue is
  'FR-J13: the transcript register. Append-only; payload_snapshot is the document as printed, with serial, issuing officer and date.';

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.transcript_issue enable row level security;

-- Tenant-wide for the people who issue them: a transcript is the one academic
-- document that is not scoped to a single campus.
create policy transcript_tenant_scope on public.transcript_issue
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller')
  );

create policy transcript_student_own on public.transcript_issue
  for select to authenticated
  using (student_id = public.my_student_id() and status = 'issued');

create policy transcript_parent_own_child on public.transcript_issue
  for select to authenticated
  using (student_id = any (app.auth_guardian_student_ids()) and status = 'issued');

-- ═══════════════════════════════════════════════════════════════════════
-- The view
-- ═══════════════════════════════════════════════════════════════════════

-- A campus that was archived or soft-deleted keeps its row; it is named, not
-- dropped.
create or replace function app.fn_campus_label(p_campus_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select c.name || case when c.status = 'archived' or c.deleted_at is not null then ' (closed)' else '' end
    from public.campus c where c.id = p_campus_id and c.tenant_id = app.auth_tenant_id();
$$;
revoke execute on function app.fn_campus_label(uuid) from public, anon;
grant execute on function app.fn_campus_label(uuid) to authenticated;

create view public.v_student_transcript
with (security_invoker = true) as
select e.tenant_id,
       e.student_id,
       e.id                               as enrolment_id,
       e.session_id,
       s.name                             as session_name,
       s.starts_on                        as session_starts_on,
       s.ends_on                          as session_ends_on,
       s.is_current                       as session_is_current,
       e.campus_id,
       app.fn_campus_label(e.campus_id)   as campus_name,
       cl.name_en                         as class_name,
       cl.ordinal                         as class_ordinal,
       sec.name                           as section_name,
       e.status::text                     as enrolment_status,
       e.joined_on,
       e.left_on,
       app.fn_session_withheld(e.session_id, e.id) as is_withheld,
       pd.decision::text                  as promotion_decision,
       (select count(*)::int from public.annual_result a where a.enrolment_id = e.id) as subjects_count,
       (select round(avg(a.weighted_pct), 2) from public.annual_result a where a.enrolment_id = e.id) as aggregate_pct,
       (select count(*)::int from public.annual_result a where a.enrolment_id = e.id and a.is_pass is false) as failed_count,
       coalesce((select bool_and(a.status = 'final') from public.annual_result a where a.enrolment_id = e.id), false) as all_final,
       coalesce((select jsonb_agg(t.name order by t.sequence)
                   from (select distinct sr.exam_term_id from public.subject_result sr where sr.enrolment_id = e.id) d
                   cross join lateral (select app.fn_term_name(d.exam_term_id) as name,
                                              app.fn_term_sequence(d.exam_term_id) as sequence) t),
                '[]'::jsonb)              as terms_completed
  from public.enrolment e
  join public.academic_session s on s.id = e.session_id
  join public.class_level cl on cl.id = e.class_level_id
  left join public.class_section sec on sec.id = e.section_id
  left join public.promotion_decision pd on pd.enrolment_id = e.id
 where e.deleted_at is null;

revoke all on public.v_student_transcript from public, anon;
grant select on public.v_student_transcript to authenticated;

comment on view public.v_student_transcript is
  'FR-J13: one row per HISTORICAL enrolment of a student, any status, with the campus named even when it has since been archived. security_invoker: callers see what the RLS on the base tables lets them.';

-- ═══════════════════════════════════════════════════════════════════════
-- The document
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.fn_month_name(p_date date)
returns text
language sql
immutable
as $$
  select (array['January','February','March','April','May','June','July','August','September','October','November','December'])[extract(month from p_date)::int]
         || ' ' || extract(year from p_date)::int;
$$;

create or replace function app.fn_student_transcript_data(p_student_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_student record;
  v_sessions jsonb;
begin
  select st.id, st.tenant_id, st.name_en, st.name_ur, st.father_name_en, st.gr_number, st.dob, st.gender::text as gender
    into v_student from public.student st where st.id = p_student_id;

  select coalesce(jsonb_agg(r.session order by r.starts_on, r.enrolment_id), '[]'::jsonb)
    into v_sessions
    from (
      select v.session_starts_on as starts_on, v.enrolment_id,
             jsonb_build_object(
               'session_id', v.session_id,
               'session_name', v.session_name,
               'starts_on', v.session_starts_on,
               'ends_on', v.session_ends_on,
               'campus_name', v.campus_name,
               'class_name', v.class_name,
               'section_name', v.section_name,
               'status', case
                 when v.is_withheld then 'withheld'
                 when v.left_on is not null and v.enrolment_status in ('left', 'transferred') and v.left_on < v.session_ends_on then 'incomplete'
                 when v.subjects_count > 0 and v.all_final then 'complete'
                 else 'in_progress' end,
               'note', case
                 when v.is_withheld then 'withheld'
                 when v.left_on is not null and v.enrolment_status in ('left', 'transferred') and v.left_on < v.session_ends_on
                   then 'incomplete — left ' || app.fn_month_name(v.left_on)
                 else null end,
               'left_on', v.left_on,
               'terms_completed', v.terms_completed,
               'promotion_decision', case when v.is_withheld then null else v.promotion_decision end,
               'aggregate_pct', case when v.is_withheld then null else v.aggregate_pct end,
               'subjects', case when v.is_withheld then '[]'::jsonb else coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'subject_name', sub.name_en, 'weighted_pct', a.weighted_pct,
                            'grade_label', a.grade_label, 'is_pass', a.is_pass) order by sub.name_en)
                     from public.annual_result a join public.subject sub on sub.id = a.subject_id
                    where a.enrolment_id = v.enrolment_id), '[]'::jsonb) end
             ) as session
        from public.v_student_transcript v
       where v.student_id = p_student_id
    ) r;

  return jsonb_build_object(
    'school', (select t.legal_name from public.tenant t where t.id = v_student.tenant_id),
    'student', jsonb_build_object(
      'name_en', v_student.name_en, 'name_ur', v_student.name_ur, 'father_name_en', v_student.father_name_en,
      'gr_number', v_student.gr_number, 'dob', v_student.dob, 'gender', v_student.gender),
    'sessions', v_sessions);
end;
$$;
revoke execute on function app.fn_student_transcript_data(uuid) from public, anon, authenticated;

-- Who may read or issue a student's transcript: staff of this tenant who work
-- in a campus where the student is, or was, enrolled (owner and super_admin:
-- any). Raises, so callers cannot forget to check.
create or replace function app.fn_assert_transcript_access(p_student_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.student where id = p_student_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner')
     and not exists (select 1 from public.enrolment e
                      where e.student_id = p_student_id and e.deleted_at is null
                        and e.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function app.fn_assert_transcript_access(uuid) from public, anon, authenticated;

create or replace function public.fn_student_transcript(p_student_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.fn_assert_transcript_access(p_student_id);
  return app.fn_student_transcript_data(p_student_id);
end;
$$;
revoke execute on function public.fn_student_transcript(uuid) from public, anon;
grant execute on function public.fn_student_transcript(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Issue
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.issue_transcript(p_student_id uuid, p_purpose text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant  uuid := app.auth_tenant_id();
  v_officer record;
  v_today   date := app.fn_karachi_today();
  v_year    integer := extract(year from app.fn_karachi_today())::int;
  v_seq     integer;
  v_serial  text;
  v_data    jsonb;
  v_snapshot jsonb;
  v_path    text;
  v_id      uuid;
begin
  perform app.fn_assert_transcript_access(p_student_id);
  if p_purpose is null or btrim(p_purpose) = '' then
    raise exception 'PURPOSE_REQUIRED' using errcode = '22023';
  end if;

  select u.user_id, u.full_name, u.app_role::text as role into v_officer
    from public.app_user u where u.user_id = (select auth.uid()) and u.tenant_id = v_tenant;
  if v_officer.user_id is null then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  v_data := app.fn_student_transcript_data(p_student_id);
  if jsonb_array_length(v_data -> 'sessions') = 0 then
    raise exception 'NO_HISTORY' using errcode = '23514',
      hint = 'This student has no enrolment on record, so there is nothing to put on a transcript.';
  end if;

  insert into public.transcript_serial_counter (tenant_id, year, last_seq) values (v_tenant, v_year, 1)
  on conflict (tenant_id, year) do update set last_seq = public.transcript_serial_counter.last_seq + 1
  returning last_seq into v_seq;
  v_serial := format('TRN-%s-%s', v_year, lpad(v_seq::text, 6, '0'));

  v_snapshot := v_data || jsonb_build_object(
    'serial_no', v_serial,
    'issued_on', v_today,
    'issued_by_name', v_officer.full_name,
    'issued_by_role', v_officer.role,
    'purpose', btrim(p_purpose));
  v_path := format('%s/%s/%s.pdf', v_tenant, p_student_id, v_serial);

  insert into public.transcript_issue (tenant_id, student_id, serial_no, purpose, issued_by, issued_by_name, issued_on,
                                       session_count, payload_snapshot, storage_path)
  values (v_tenant, p_student_id, v_serial, btrim(p_purpose), v_officer.user_id, v_officer.full_name, v_today,
          jsonb_array_length(v_data -> 'sessions'), v_snapshot, v_path)
  returning id into v_id;

  return jsonb_build_object('issue_id', v_id, 'serial_no', v_serial, 'storage_path', v_path, 'snapshot', v_snapshot);
end;
$$;
revoke execute on function public.issue_transcript(uuid, text) from public, anon;
grant execute on function public.issue_transcript(uuid, text) to authenticated;

create or replace function public.attach_transcript_pdf(p_issue_id uuid, p_sha256 text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is null or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'CHECKSUM_INVALID' using errcode = '22023';
  end if;
  update public.transcript_issue set pdf_sha256 = p_sha256, status = 'issued'
   where id = p_issue_id and tenant_id = app.auth_tenant_id() and status = 'pending';
  if not found then
    raise exception 'TRANSCRIPT_NOT_PENDING' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.attach_transcript_pdf(uuid, text) from public, anon;
grant execute on function public.attach_transcript_pdf(uuid, text) to authenticated;

-- A render failure cannot rewind the serial (a number may already have been
-- shown on screen); the row stays in the register, saying it never became a
-- document.
create or replace function public.void_transcript_issue(p_issue_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is null or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;
  update public.transcript_issue set status = 'void', void_reason = left(btrim(p_reason), 500)
   where id = p_issue_id and tenant_id = app.auth_tenant_id() and status = 'pending';
  if not found then
    raise exception 'TRANSCRIPT_NOT_PENDING' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.void_transcript_issue(uuid, text) from public, anon;
grant execute on function public.void_transcript_issue(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Storage
-- ═══════════════════════════════════════════════════════════════════════

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('transcripts', 'transcripts', false, 10485760, array['application/pdf'])
on conflict (id) do nothing;

create policy transcripts_insert_issuer on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'transcripts'
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller')
    and exists (select 1 from public.transcript_issue t
                 where t.storage_path = objects.name and t.tenant_id = app.auth_tenant_id() and t.status = 'pending')
  );

-- Read follows the register's own visibility (staff tenant-wide; the student
-- and parents only once issued), since the subquery is subject to its RLS.
create policy transcripts_read_scope on storage.objects
  for select to authenticated
  using (
    bucket_id = 'transcripts'
    and exists (select 1 from public.transcript_issue t where t.storage_path = objects.name)
  );
-- No UPDATE or DELETE policy: the digest on the register is a statement about
-- these bytes.
