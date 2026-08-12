-- FR-C14: validate a bulk student import as a dry run.
--
-- The Principal uploads the school's existing register, sees exactly what
-- is wrong with it — row number, column, message — and NOTHING is written
-- to public.student. This migration is the dry-run half only.
--
-- File format: CSV, not XLSX. There is no XLSX parser anywhere in this
-- workspace and adding one (SheetJS/exceljs) is a heavyweight dependency
-- for a feature whose actual value is the validation report, not the
-- container. A .csv export is one menu item away in Excel, and a CSV
-- template is what `imports`' bucket serves. Swapping the parser for XLSX
-- later touches lib/student-import.ts only — nothing below cares.
--
-- Where each rule lives:
--   * File-shaped rules (header set, required fields, date/gender/B-Form
--     formats, class-name resolution, whole-file duplicate GR/B-Form)
--     live in lib/student-import.ts. That layer has the entire file in
--     memory, so it is the only place that can see a duplicate whose two
--     occurrences land in different 500-row chunks before staging.
--   * Register-state rules (the class actually exists in THIS tenant, the
--     GR number is already on the register, the B-Form already belongs to
--     someone) live here — the client cannot be handed the whole GR
--     register to check against, and must not be trusted with it anyway.
--   * The whole-batch duplicate sweep is repeated here in
--     finalise_import_batch() over the staged rows, because the client's
--     copy of that rule is advisory. fn_merge_row_errors() dedupes per
--     COLUMN, so a row the client already flagged is never double-
--     reported.
--
-- Counting convention (matches the AC's "4,882 ready and 118 blocked"):
--   ok_rows      = rows that would import (severity 'ok' or 'warning')
--   warning_rows = the subset of those carrying at least one warning
--   error_rows   = blocked rows
--   ok_rows + error_rows = total_rows
--
-- import_row.row_no is the SOURCE LINE NUMBER in the uploaded file, so
-- row 1 is the header and the first data row is 2 — the number the
-- Principal sees in Excel's own row gutter, not a 0-based data index.
--
-- ── What FR-C15 (commit bulk import atomically) is expected to add ──────
-- Deliberately NOT built here, but the schema is shaped for it:
--   * import_batch_status already carries 'committed' and 'undone', so
--     C15 needs no ALTER TYPE ... ADD VALUE migration.
--   * C15 adds import_batch.committed_at / undone_at / undo_deadline,
--     import_row.student_id (what the commit created, for undo), and the
--     'import-errors' bucket for the downloadable error report.
--   * C15 adds fn_commit_import_batch(batch_id): one transaction, all-or-
--     nothing, refusing a batch whose status is not 'validated' or whose
--     error_rows > 0. It reads import_row.normalised — which is already
--     keyed exactly like create_student()'s arguments plus class_level_id
--     — and allocates a CONTIGUOUS GR block by taking the gr_sequence row
--     FOR UPDATE once and advancing next_value by the row count in a
--     single step, rather than calling app.fn_allocate_gr_number() per
--     row. Rows whose normalised.gr_number is non-null keep the school's
--     own number and must not consume from that block.
--   * C15 adds fn_undo_import_batch(batch_id), guarded by dependency
--     checks (no enrolment/challan/attendance/result may reference the
--     created students) and by undo_deadline.
-- Nothing below writes to public.student, public.gr_sequence or
-- public.gr_ledger — that is entirely C15's surface.

create type public.import_kind as enum ('student');
create type public.import_batch_status as enum ('validating', 'validated', 'committed', 'undone');
create type public.import_row_severity as enum ('ok', 'warning', 'error');

create table public.import_batch (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  session_id        uuid not null references public.academic_session(id) on delete cascade,
  kind              public.import_kind not null default 'student',
  file_path         text not null unique,
  original_filename text not null,
  status            public.import_batch_status not null default 'validating',
  dry_run           boolean not null default true,
  total_rows        int not null default 0,
  ok_rows           int not null default 0,
  warning_rows      int not null default 0,
  error_rows        int not null default 0,
  created_by        uuid references public.app_user(user_id),
  created_at        timestamptz not null default clock_timestamp()
);

create index idx_import_batch_campus on public.import_batch (campus_id, created_at desc);

create trigger import_batch_audit after insert or update or delete on public.import_batch
  for each row execute function app.tg_audit_row();

-- No audit trigger on import_row: a single 5,000-row upload would write
-- 5,000 audit rows for data that is already fully reconstructible from
-- the source file kept in the `imports` bucket.
create table public.import_row (
  id         uuid primary key default gen_random_uuid(),
  batch_id   uuid not null references public.import_batch(id) on delete cascade,
  row_no     int not null,
  raw        jsonb not null default '{}'::jsonb,
  normalised jsonb not null default '{}'::jsonb,
  errors     jsonb not null default '[]'::jsonb,
  severity   public.import_row_severity not null default 'ok',
  unique (batch_id, row_no)
);

create index idx_import_row_batch_severity on public.import_row (batch_id, severity);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('imports', 'imports', false, 10485760, array['text/csv', 'text/plain', 'application/vnd.ms-excel'])
on conflict (id) do nothing;

-- ── error-list helpers ─────────────────────────────────────────────────
-- An error entry is {column, code, severity, message}. Dedupe is per
-- COLUMN, not per (column, code): once the file layer has said something
-- about `class`, the register-state layer has nothing useful to add about
-- the same cell, and a Principal reading the report wants one line per
-- broken cell, not two.

create or replace function app.fn_merge_row_errors(p_existing jsonb, p_additions jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_existing, '[]'::jsonb) || coalesce(
    (
      select jsonb_agg(a)
        from jsonb_array_elements(coalesce(p_additions, '[]'::jsonb)) as a
       where not exists (
         select 1 from jsonb_array_elements(coalesce(p_existing, '[]'::jsonb)) as e
          where e ->> 'column' = a ->> 'column'
       )
    ),
    '[]'::jsonb
  );
$$;

create or replace function app.fn_row_severity(p_errors jsonb)
returns public.import_row_severity
language sql
immutable
set search_path = ''
as $$
  select case
    when exists (select 1 from jsonb_array_elements(coalesce(p_errors, '[]'::jsonb)) as e where e ->> 'severity' = 'error')
      then 'error'
    when exists (select 1 from jsonb_array_elements(coalesce(p_errors, '[]'::jsonb)) as e where e ->> 'severity' = 'warning')
      then 'warning'
    else 'ok'
  end::public.import_row_severity;
$$;

-- ── create_import_batch ────────────────────────────────────────────────
-- Reserves the row (and therefore the exact object path) BEFORE the file
-- is uploaded, the same reserve-then-upload shape as FR-B10's
-- create_admission_document() — the imports_insert_officer storage policy
-- below requires a matching import_batch row, so a client cannot write to
-- an arbitrary path in the bucket.

create or replace function public.create_import_batch(
  p_campus_id uuid,
  p_session_id uuid,
  p_original_filename text,
  p_kind public.import_kind default 'student'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid := gen_random_uuid();
  v_path      text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  -- A tenant-wide session (campus_id is null) is shared by every campus;
  -- a campus-scoped one only belongs to its own.
  if not exists (
    select 1 from public.academic_session
     where id = p_session_id and tenant_id = v_tenant_id
       and (campus_id is null or campus_id = p_campus_id)
  ) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_path := v_tenant_id::text || '/' || v_id::text || '/source.csv';

  insert into public.import_batch (id, tenant_id, campus_id, session_id, kind, file_path, original_filename, created_by)
  values (v_id, v_tenant_id, p_campus_id, p_session_id, p_kind, v_path, p_original_filename, auth.uid());

  return jsonb_build_object('batch_id', v_id, 'file_path', v_path);
end;
$$;

revoke execute on function public.create_import_batch(uuid, uuid, text, public.import_kind) from public, anon;
grant execute on function public.create_import_batch(uuid, uuid, text, public.import_kind) to authenticated;

-- ── stage_import_rows ──────────────────────────────────────────────────
-- One ~500-row chunk per call. p_rows is
--   [{"row_no": 2, "raw": {...}, "normalised": {...}, "errors": [...]}, ...]
-- with `errors` carrying whatever the file layer already found. Everything
-- added here is a register-state check the client had no way to make.

create or replace function public.stage_import_rows(p_batch_id uuid, p_rows jsonb)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch public.import_batch%rowtype;
  v_count int;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_batch from public.import_batch where id = p_batch_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'IMPORT_BATCH_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_batch.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_batch.status <> 'validating' then
    raise exception 'IMPORT_BATCH_NOT_OPEN' using errcode = '55000';
  end if;

  with incoming as (
    select
      (r ->> 'row_no')::int                    as row_no,
      coalesce(r -> 'raw', '{}'::jsonb)        as raw,
      coalesce(r -> 'normalised', '{}'::jsonb) as normalised,
      coalesce(r -> 'errors', '[]'::jsonb)     as errors
      from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) as r
  ),
  checked as (
    select
      i.row_no,
      i.raw,
      i.normalised,
      app.fn_merge_row_errors(
        i.errors,
        (
          -- AC: an unresolved class blocks the row. The file layer
          -- resolves the class NAME against the configured catalogue and
          -- writes class_level_id; this is the authoritative re-check that
          -- the id it produced is a real, active class in this tenant.
          select coalesce(jsonb_agg(f.entry), '[]'::jsonb) from (
            select jsonb_build_object(
                     'column', 'class', 'code', 'UNKNOWN_CLASS', 'severity', 'error',
                     'message', format('Unknown class %L - it is not a configured class at this school.',
                                       coalesce(i.raw ->> 'class', ''))
                   ) as entry
             -- Compared as text, not cast to uuid: class_level_id arrives
             -- from the client and a malformed value must produce this
             -- error, not abort the whole chunk with 22P02.
             where not exists (
               select 1 from public.class_level cl
                where cl.tenant_id = v_batch.tenant_id
                  and cl.is_active
                  and cl.id::text = i.normalised ->> 'class_level_id'
             )
            union all
            -- FR-A15 established that a soft-deleted student's GR number
            -- stays taken (GR_NUMBER_IN_USE) — so this deliberately does
            -- NOT filter on deleted_at.
            select jsonb_build_object(
                     'column', 'gr_number', 'code', 'GR_IN_USE', 'severity', 'error',
                     'message', format('GR number %L is already on the register.', i.normalised ->> 'gr_number')
                   )
             where nullif(i.normalised ->> 'gr_number', '') is not null
               and exists (
                 select 1 from public.student s
                  where s.tenant_id = v_batch.tenant_id and s.gr_number = i.normalised ->> 'gr_number'
               )
            union all
            -- Mirrors create_student()'s own BFORM_DUPLICATE guard.
            select jsonb_build_object(
                     'column', 'b_form_no', 'code', 'BFORM_IN_USE', 'severity', 'error',
                     'message', format('B-Form number %L already belongs to another student.', i.normalised ->> 'b_form_no')
                   )
             where nullif(i.normalised ->> 'b_form_no', '') is not null
               and exists (
                 select 1 from public.student s
                  where s.tenant_id = v_batch.tenant_id and s.b_form_no = i.normalised ->> 'b_form_no'
               )
          ) as f
        )
      ) as errors
      from incoming i
  )
  insert into public.import_row (batch_id, row_no, raw, normalised, errors, severity)
  select p_batch_id, c.row_no, c.raw, c.normalised, c.errors, app.fn_row_severity(c.errors)
    from checked c;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.stage_import_rows(uuid, jsonb) from public, anon;
grant execute on function public.stage_import_rows(uuid, jsonb) to authenticated;

-- ── finalise_import_batch ──────────────────────────────────────────────
-- The whole-batch sweep: a duplicate whose two occurrences straddle a
-- chunk boundary is invisible to stage_import_rows(), and the file
-- layer's own copy of this rule is advisory, so this is where BOTH
-- occurrences are guaranteed to be blocked.

create or replace function public.finalise_import_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch   public.import_batch%rowtype;
  v_summary jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_batch from public.import_batch where id = p_batch_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'IMPORT_BATCH_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_batch.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_batch.status <> 'validating' then
    raise exception 'IMPORT_BATCH_NOT_OPEN' using errcode = '55000';
  end if;

  -- AC: the same GR number twice within the file blocks BOTH occurrences,
  -- not just the second.
  with dup as (
    select normalised ->> 'gr_number' as value, array_agg(row_no order by row_no) as row_nos
      from public.import_row
     where batch_id = p_batch_id and nullif(normalised ->> 'gr_number', '') is not null
     group by 1
    having count(*) > 1
  )
  update public.import_row r
     set errors = app.fn_merge_row_errors(r.errors, jsonb_build_array(jsonb_build_object(
           'column', 'gr_number', 'code', 'DUPLICATE_IN_FILE', 'severity', 'error',
           'message', format('GR number %L appears more than once in this file (rows %s) - every occurrence is blocked.',
                             d.value, array_to_string(d.row_nos, ', '))
         )))
    from dup d
   where r.batch_id = p_batch_id and (r.normalised ->> 'gr_number') = d.value;

  with dup as (
    select normalised ->> 'b_form_no' as value, array_agg(row_no order by row_no) as row_nos
      from public.import_row
     where batch_id = p_batch_id and nullif(normalised ->> 'b_form_no', '') is not null
     group by 1
    having count(*) > 1
  )
  update public.import_row r
     set errors = app.fn_merge_row_errors(r.errors, jsonb_build_array(jsonb_build_object(
           'column', 'b_form_no', 'code', 'DUPLICATE_IN_FILE', 'severity', 'error',
           'message', format('B-Form number %L appears more than once in this file (rows %s) - every occurrence is blocked.',
                             d.value, array_to_string(d.row_nos, ', '))
         )))
    from dup d
   where r.batch_id = p_batch_id and (r.normalised ->> 'b_form_no') = d.value;

  update public.import_row set severity = app.fn_row_severity(errors) where batch_id = p_batch_id;

  update public.import_batch b
     set total_rows   = c.total_rows,
         ok_rows      = c.ok_rows,
         warning_rows = c.warning_rows,
         error_rows   = c.error_rows,
         status       = 'validated'
    from (
      select count(*)::int                                            as total_rows,
             count(*) filter (where severity <> 'error')::int         as ok_rows,
             count(*) filter (where severity = 'warning')::int        as warning_rows,
             count(*) filter (where severity = 'error')::int          as error_rows
        from public.import_row where batch_id = p_batch_id
    ) c
   where b.id = p_batch_id
  returning jsonb_build_object(
    'batch_id', b.id, 'total_rows', b.total_rows, 'ok_rows', b.ok_rows,
    'warning_rows', b.warning_rows, 'error_rows', b.error_rows, 'status', b.status
  ) into v_summary;

  return v_summary;
end;
$$;

revoke execute on function public.finalise_import_batch(uuid) from public, anon;
grant execute on function public.finalise_import_batch(uuid) to authenticated;

-- ── RLS ────────────────────────────────────────────────────────────────

alter table public.import_batch enable row level security;
alter table public.import_row enable row level security;

-- Role-gated as well as campus-scoped, unlike most read policies in this
-- schema: import_row.raw holds the school's own spreadsheet cells —
-- names, dates of birth and B-Form numbers for children who are not
-- admitted yet and may never be. Only the roles that can start an import
-- can read one back.
create policy import_batch_campus_scope on public.import_batch
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy import_row_read_owner_of_batch on public.import_row
  for select to authenticated
  using (
    app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer')
    and exists (
      select 1 from public.import_batch b
       where b.id = import_row.batch_id
         and b.tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or b.campus_id = any(app.auth_campus_ids()))
    )
  );

-- Same role and campus scoping as the metadata rows, enforced a second
-- time at the storage layer.
create policy imports_read_campus on storage.objects
  for select to authenticated
  using (
    bucket_id = 'imports'
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer')
    and exists (
      select 1 from public.import_batch b
       where b.file_path = objects.name
         and b.tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or b.campus_id = any(app.auth_campus_ids()))
    )
  );

create policy imports_insert_officer on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'imports'
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer')
    and exists (
      select 1 from public.import_batch b
       where b.file_path = objects.name and b.tenant_id = app.auth_tenant_id()
    )
  );
