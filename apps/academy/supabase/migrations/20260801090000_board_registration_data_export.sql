-- ═══════════════════════════════════════════════════════════════════════
-- FR-T11 — Board registration data export
--
-- An Exam Controller uploads one file to FBISE/Punjab/Sindh/KPK/
-- Balochistan/AKU-EB and the board either accepts all 412 rows or bounces
-- the file. There is no partial accept. So the shape of this feature is
-- not "produce a file" — it is "prove the file will be accepted, then
-- produce it".
--
-- Three traps drove the design:
--
--  1. Board formats change without notice and differ by year. The column
--     order, the header labels, the date format and the code lists are
--     therefore DATA (board_profile.column_spec / code_map / date_format /
--     validation_rules), never code. A board that renames a header in
--     August is one INSERT with a later effective_from, not a release.
--     Resolution mirrors app.fn_grading_scheme_for_board: newest profile
--     whose effective_from is on or before the session's start, tenant
--     override beating the platform default.
--
--  2. B-Form / CNIC formatting is the number one rejection cause. This
--     schema's canonical storage is DASHED — app.fn_normalize_pk_id() and
--     student.chk_bform_format both insist on 35202-1234567-8 — and FBISE
--     wants 13 bare digits. The rule is "store canonical, format on
--     export, never the reverse", so column_spec carries transform
--     'digits_only' and the file always leaves in board shape. What is NOT
--     automatic is the Exam Controller finding out: AC1 requires the
--     export to BLOCK on the mismatch, list the 7 offending rows with
--     field, current value and expected pattern, and offer one-click
--     normalise. normalise_board_export_run() is that click — it does not
--     touch a single student row (it cannot; the check constraint forbids
--     the undashed form), it records that the controller has seen and
--     approved the reshaping, and re-validation then clears exactly the
--     errors a normaliser can fix and no others.
--
--  3. Registration deadlines are hard and an export that fails at 11pm on
--     deadline night is a lost year for a child. Validation therefore is
--     not a step inside "generate" — a run in status 'draft' is a standing
--     readiness dashboard that validate_board_export() refreshes on
--     demand, weeks before anyone presses export, over the SAME code path
--     the export itself uses. One implementation, so the dashboard can
--     never disagree with the gate.
--
-- Consent. This ships a child's name, date of birth, B-Form and father's
-- CNIC to a third party, and FR-T15 already seeded the purpose that covers
-- it verbatim: third_party_data_sharing, "Sharing the student's personal
-- data with third parties such as boards, partners and vendors",
-- requires_explicit_grant = true. It is not defensible to read that seed
-- and then export anyway. But the other two options are both wrong too:
-- silently dropping an unconsented child from the file is trap 3 — nobody
-- notices until the board's list comes back 4 short and the year is gone —
-- and blocking the whole file on deadline night is trap 3 with extra
-- steps. So a missing consent is a BLOCKING ROW ERROR like any other,
-- surfaced on the same dashboard, weeks early, naming the child. The
-- controller chases the guardian in September instead of discovering it in
-- March. any-guardian-denial wins, because has_consent() decides it.
--
-- Volume. A class level is 300-500 children. That is one page of a
-- keyset-free query and a file of a few hundred kilobytes, so this is
-- deliberately NOT built on FR-J12's claim/finish batch machinery — there
-- is nothing to resume, and a resumable worker for 412 rows is a second
-- failure mode bolted onto a request that finishes in under a second.
-- The seam is still here (begin/validate/complete/fail) if a board ever
-- demands a whole-campus file.
--
-- Soft delete. Every query below says `deleted_at is null` out loud.
-- These functions are SECURITY DEFINER owned by postgres and so bypass
-- RLS entirely; the recycle bin (FR-A15) is not a filter that arrives for
-- free here, and a child in it must not be registered for an exam.
-- ═══════════════════════════════════════════════════════════════════════

create type public.board_export_status as enum ('draft', 'completed', 'failed');
create type public.board_export_severity as enum ('blocking', 'warning');

-- ═══════════════════════════════════════════════════════════════════════
-- 1. board_profile — the format, as data
-- ═══════════════════════════════════════════════════════════════════════

-- tenant_id null is the profile this software ships with. A tenant row for
-- the same (board_code, export_kind) shadows it, which is the escape hatch
-- for trap 1 when a board changes its spec faster than we ship.
--
-- export_kind is text-with-a-check rather than an enum on purpose: adding
-- 'result_submission' later must not be an ALTER TYPE ... ADD VALUE that
-- cannot be used in the migration that adds it.
create table public.board_profile (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references public.tenant(id) on delete cascade,
  board_code      public.board not null,
  export_kind     text not null default 'registration',
  effective_from  date not null default date '2000-01-01',
  label           text not null,
  date_format     text not null default 'DD/MM/YYYY',
  -- Urdu names ride in these files (student.name_ur). The glyphs are never
  -- the problem — UTF-8 carries Nastaliq fine — but the board clerk opens
  -- the CSV in Excel, and Excel without a BOM guesses the local ANSI
  -- codepage and turns every Urdu column into mojibake. A board whose
  -- automated importer chokes on the BOM instead turns this off, as data.
  byte_order_mark boolean not null default true,
  column_spec     jsonb not null,
  validation_rules jsonb not null default '[]'::jsonb,
  code_map        jsonb not null default '{}'::jsonb,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  constraint chk_board_profile_kind check (export_kind in ('registration')),
  constraint chk_board_profile_columns
    check (jsonb_typeof(column_spec) = 'array' and jsonb_array_length(column_spec) > 0),
  constraint chk_board_profile_rules check (jsonb_typeof(validation_rules) = 'array'),
  constraint chk_board_profile_code_map check (jsonb_typeof(code_map) = 'object')
);

create unique index uq_board_profile_tenant
  on public.board_profile (tenant_id, board_code, export_kind, effective_from)
  where tenant_id is not null;
create unique index uq_board_profile_global
  on public.board_profile (board_code, export_kind, effective_from)
  where tenant_id is null;

-- No audit trigger, on purpose: the platform rows carry tenant_id null and
-- are written by migrations only, exactly like certificate_type_field_catalog.
-- The migration file IS the history.

-- ═══════════════════════════════════════════════════════════════════════
-- 2. board_export_run + board_export_row_error
-- ═══════════════════════════════════════════════════════════════════════

-- AC4 falls out of the shape rather than needing enforcement: a completed
-- run is terminal, so regenerating necessarily begins a NEW run with a new
-- id, and file_path is keyed by that id — nothing is ever overwritten and
-- yesterday's file stays downloadable forever.
create table public.board_export_run (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  board_code        public.board not null,
  export_kind       text not null default 'registration',
  session_id        uuid not null references public.academic_session(id) on delete cascade,
  class_level_id    uuid not null references public.class_level(id),
  profile_id        uuid not null references public.board_profile(id),
  status            public.board_export_status not null default 'draft',
  -- Trap 2's audit trail: which human decided that stripping the dashes
  -- out of 412 identity numbers was the right call, and when.
  normalise_applied boolean not null default false,
  normalised_by     uuid references public.app_user(user_id),
  normalised_at     timestamptz,
  validated_at      timestamptz,
  row_count         int,
  file_path         text,
  checksum          text,
  error             text,
  requested_by      uuid references public.app_user(user_id),
  requested_at      timestamptz not null default now(),
  generated_by      uuid references public.app_user(user_id),
  generated_at      timestamptz
);

create index idx_board_export_run on public.board_export_run (campus_id, board_code, generated_at desc);
create index idx_board_export_run_scope
  on public.board_export_run (tenant_id, session_id, class_level_id, requested_at desc);

create trigger board_export_run_audit after insert or update or delete on public.board_export_run
  for each row execute function app.tg_audit_row();

-- One row per broken cell, not per child: a student missing both a B-Form
-- and a father's CNIC is two lines, because the controller fixes two
-- things. Same shape FR-C14's import failure report settled on.
create table public.board_export_row_error (
  id            uuid primary key default gen_random_uuid(),
  run_id        uuid not null references public.board_export_run(id) on delete cascade,
  student_id    uuid not null references public.student(id) on delete cascade,
  field_path    text not null,
  current_value text,
  expected      text,
  rule_code     text not null,
  severity      public.board_export_severity not null,
  -- True when a normaliser exists that would make this value pass. Drives
  -- AC1's one-click offer: it is only offered when it would actually work.
  normalisable  boolean not null default false,
  created_at    timestamptz not null default now()
);

create index idx_board_export_row_error_run on public.board_export_row_error (run_id, severity);
create index idx_board_export_row_error_student on public.board_export_row_error (student_id);

-- ═══════════════════════════════════════════════════════════════════════
-- 3. Profile resolution
-- ═══════════════════════════════════════════════════════════════════════

-- Newest effective profile on the date the export BELONGS to (the
-- session's start), not today's — regenerating the 2024 file in 2026 must
-- still resolve 2024's column order. Tenant override beats platform
-- default at equal dates, which is what `tenant_id is not null` sorting
-- first buys.
create or replace function app.fn_resolve_board_profile(
  p_tenant_id uuid,
  p_board     public.board,
  p_kind      text,
  p_on_date   date
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select bp.id
    from public.board_profile bp
   where bp.board_code = p_board
     and bp.export_kind = p_kind
     and bp.is_active
     and bp.effective_from <= p_on_date
     and (bp.tenant_id is null or bp.tenant_id = p_tenant_id)
   order by bp.effective_from desc, (bp.tenant_id is not null) desc
   limit 1;
$$;

revoke execute on function app.fn_resolve_board_profile(uuid, public.board, text, date)
  from public, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 4. Access guard
-- ═══════════════════════════════════════════════════════════════════════

-- Campus guard, stated once. app.auth_campus_ids() can legitimately be
-- '{}' for a badly-provisioned principal, and `not (c = any('{}'))` is
-- TRUE for every campus in existence — so the membership test is written
-- as the positive `= any(...)` and an empty claim simply fails it, closed.
create or replace function app.fn_assert_board_export_access(p_run_id uuid, p_write boolean)
returns public.board_export_run
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_run public.board_export_run;
begin
  select * into v_run from public.board_export_run where id = p_run_id;
  if not found then
    raise exception 'RUN_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_run.tenant_id is distinct from app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_write then
    if app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  elsif app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if app.auth_role() not in ('super_admin', 'owner')
     and not (v_run.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  return v_run;
end;
$$;

revoke execute on function app.fn_assert_board_export_access(uuid, boolean) from public, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 5. The row source — one query, shared by validation and the file
-- ═══════════════════════════════════════════════════════════════════════

-- Every field a column_spec or a validation rule may name, resolved once
-- per child into a flat jsonb. Validation reading a different set of rows
-- from the file writer is precisely how a "validated" export gets bounced,
-- so there is exactly one of these.
--
-- SECURITY DEFINER and callable only from the definer functions below —
-- an app.<resolver>_unscoped in the sense of 20260801010000: it does no
-- campus check because its callers already did, and it must be able to
-- read the whole run.
create or replace function app.fn_board_export_students(p_run_id uuid)
returns table (student_id uuid, sort_key text, fields jsonb)
language sql
stable
security definer
set search_path = ''
as $$
  with run as (
    select * from public.board_export_run where id = p_run_id
  ),
  father as (
    select sg.student_id, g.cnic, g.name_en, g.name_ur, g.phone_e164,
           row_number() over (partition by sg.student_id order by sg.priority, g.created_at) as rn
      from public.student_guardian sg
      join public.guardian g on g.id = sg.guardian_id
     where sg.relationship = 'father'
       and sg.to_date is null
  )
  select s.id,
         lpad(coalesce(e.roll_no, 999999)::text, 6, '0') || ' ' || s.gr_number,
         jsonb_strip_nulls(jsonb_build_object(
           'student.gr_number',      s.gr_number,
           'student.name_en',        s.name_en,
           'student.name_ur',        s.name_ur,
           'student.father_name_en', s.father_name_en,
           'student.father_name_ur', s.father_name_ur,
           'student.dob',            to_char(s.dob, 'YYYY-MM-DD'),
           'student.gender',         s.gender::text,
           'student.b_form_no',      s.b_form_no,
           'student.religion',       s.religion,
           'student.nationality',    s.nationality,
           'student.blood_group',    s.blood_group,
           'student.address',        nullif(btrim(coalesce(s.address ->> 'line1', '') || ' ' || coalesce(s.address ->> 'city', '')), ''),
           'guardian.father_cnic',   f.cnic,
           'guardian.father_name',   f.name_en,
           'guardian.father_phone',  f.phone_e164,
           'enrolment.roll_no',      e.roll_no::text,
           'class_level.name_en',    cl.name_en,
           'class_level.code',       cl.code,
           'section.name',           sec.name,
           'section.medium',         sec.medium::text,
           'stream.name_en',         st.name_en,
           'stream.code',            st.code,
           'session.name',           ses.name,
           'campus.name',            c.name,
           'campus.code',            c.code,
           'campus.district',        c.district,
           'campus.city',            c.city
         ))
    from run r
    join public.enrolment e
      on e.session_id = r.session_id
     and e.class_level_id = r.class_level_id
     and e.campus_id = r.campus_id
     and e.status = 'active'
     and e.deleted_at is null
    join public.student s on s.id = e.student_id and s.deleted_at is null
    join public.class_section sec on sec.id = e.section_id
    join public.class_level cl on cl.id = e.class_level_id
    join public.academic_session ses on ses.id = e.session_id
    join public.campus c on c.id = e.campus_id
    left join public.stream st on st.id = sec.stream_id
    left join father f on f.student_id = s.id and f.rn = 1
   where app.fn_board_for_section(sec.id) = r.board_code;
$$;

revoke execute on function app.fn_board_export_students(uuid) from public, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 6. Transforms and normalisers
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.fn_board_export_normalise(p_value text, p_normaliser text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_normaliser
    when 'digits_only' then regexp_replace(p_value, '[^0-9]', '', 'g')
    when 'upper'       then upper(p_value)
    when 'trim'        then btrim(p_value)
    else null
  end
  where p_value is not null and p_normaliser is not null;
$$;

-- One cell. code_map is applied BEFORE transform so a board can both map
-- 'Pre-Medical' -> 'PM' and then upper-case it, which is the order AC2's
-- gender M/F and group PM/PE/CS/COM/ART both need.
create or replace function app.fn_board_export_cell(
  p_fields      jsonb,
  p_col         jsonb,
  p_date_format text,
  p_code_map    jsonb
)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_raw text;
  v_map jsonb;
begin
  if p_col ? 'constant' then
    return p_col ->> 'constant';
  end if;

  v_raw := nullif(p_fields ->> (p_col ->> 'source'), '');
  if v_raw is null then
    return coalesce(p_col ->> 'default', '');
  end if;

  if p_col ? 'code_map' then
    v_map := p_code_map -> (p_col ->> 'code_map');
    if v_map is not null and v_map ? v_raw then
      v_raw := v_map ->> v_raw;
    end if;
  end if;

  case coalesce(p_col ->> 'transform', 'none')
    when 'digits_only' then v_raw := regexp_replace(v_raw, '[^0-9]', '', 'g');
    when 'upper'       then v_raw := upper(v_raw);
    when 'date'        then v_raw := to_char(v_raw::date, p_date_format);
    else null;
  end case;

  return v_raw;
end;
$$;

revoke execute on function app.fn_board_export_normalise(text, text) from public, anon;
revoke execute on function app.fn_board_export_cell(jsonb, jsonb, text, jsonb) from public, anon;

-- ═══════════════════════════════════════════════════════════════════════
-- 7. begin_board_export_run
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.begin_board_export_run(
  p_campus_id      uuid,
  p_session_id     uuid,
  p_class_level_id uuid,
  p_board          public.board default null,
  p_export_kind    text default 'registration'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_boards     public.board[];
  v_board      public.board;
  v_profile_id uuid;
  v_starts_on  date;
  v_run_id     uuid;
begin
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner')
     and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.campus
     where id = p_campus_id and tenant_id = v_tenant_id and deleted_at is null
  ) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  select ses.starts_on into v_starts_on
    from public.academic_session ses
   where ses.id = p_session_id and ses.tenant_id = v_tenant_id;
  if v_starts_on is null then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from public.class_level where id = p_class_level_id and tenant_id = v_tenant_id
  ) then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- FR-J01's resolver decides, per section: the section's stream carries
  -- the board where one exists, else the campus setting, else FBISE. A
  -- Class 9 split into a Matric wing and an O-Level wing therefore
  -- genuinely has two boards and the caller must say which file this is.
  select array_agg(distinct app.fn_board_for_section(sec.id))
    into v_boards
    from public.enrolment e
    join public.class_section sec on sec.id = e.section_id
    join public.student s on s.id = e.student_id and s.deleted_at is null
   where e.session_id = p_session_id
     and e.class_level_id = p_class_level_id
     and e.campus_id = p_campus_id
     and e.status = 'active'
     and e.deleted_at is null;

  if p_board is not null then
    v_board := p_board;
  elsif v_boards is null or array_length(v_boards, 1) = 0 then
    raise exception 'NO_STUDENTS_ENROLLED' using errcode = '23514';
  elsif array_length(v_boards, 1) > 1 then
    raise exception 'BOARD_AMBIGUOUS' using errcode = '23514',
      detail = format('boards=%s', array_to_string(v_boards, ','));
  else
    v_board := v_boards[1];
  end if;

  v_profile_id := app.fn_resolve_board_profile(v_tenant_id, v_board, p_export_kind, v_starts_on);
  if v_profile_id is null then
    raise exception 'BOARD_PROFILE_NOT_FOUND' using errcode = 'P0002',
      detail = format('board=%s kind=%s', v_board, p_export_kind);
  end if;

  insert into public.board_export_run (
    tenant_id, campus_id, board_code, export_kind, session_id, class_level_id, profile_id, requested_by
  ) values (
    v_tenant_id, p_campus_id, v_board, p_export_kind, p_session_id, p_class_level_id, v_profile_id, auth.uid()
  )
  returning id into v_run_id;

  return v_run_id;
end;
$$;

revoke execute on function public.begin_board_export_run(uuid, uuid, uuid, public.board, text) from public, anon;
grant execute on function public.begin_board_export_run(uuid, uuid, uuid, public.board, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 8. validate_board_export
-- ═══════════════════════════════════════════════════════════════════════

-- Idempotent: recomputed from scratch every call, because it is the
-- dashboard (trap 3) as well as the gate, and a controller who fixes a
-- B-Form wants to press refresh and watch the count drop.
create or replace function public.validate_board_export(p_run_id uuid)
returns setof public.board_export_row_error
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run     public.board_export_run;
  v_profile public.board_profile;
  v_stu     record;
  v_rule    jsonb;
  v_raw     text;
  v_norm    text;
  v_fixable boolean;
  v_sev     public.board_export_severity;
begin
  v_run := app.fn_assert_board_export_access(p_run_id, true);
  if v_run.status <> 'draft' then
    raise exception 'RUN_NOT_EDITABLE' using errcode = '23514',
      detail = format('status=%s', v_run.status);
  end if;

  select * into v_profile from public.board_profile where id = v_run.profile_id;

  delete from public.board_export_row_error where run_id = p_run_id;

  for v_stu in select * from app.fn_board_export_students(p_run_id) loop
    -- See the header. A child whose guardians have not agreed to third
    -- party data sharing is named here, weeks early, not dropped.
    if not public.has_consent(v_stu.student_id, 'third_party_data_sharing') then
      insert into public.board_export_row_error (
        run_id, student_id, field_path, current_value, expected, rule_code, severity, normalisable
      ) values (
        p_run_id, v_stu.student_id, 'consent.third_party_data_sharing', null,
        'a guardian consent to share this student''s data with the board',
        'CONSENT_MISSING', 'blocking', false
      );
    end if;

    for v_rule in select * from jsonb_array_elements(v_profile.validation_rules) loop
      v_raw := nullif(v_stu.fields ->> (v_rule ->> 'field_path'), '');
      v_sev := coalesce(v_rule ->> 'severity', 'blocking')::public.board_export_severity;

      -- AC3 lives here and nowhere else: father CNIC is one rule whose
      -- `required` and `severity` differ between the FBISE profile and the
      -- AKU-EB profile. No branch in this function knows either board.
      if v_raw is null then
        if coalesce((v_rule ->> 'required')::boolean, false) then
          insert into public.board_export_row_error (
            run_id, student_id, field_path, current_value, expected, rule_code, severity, normalisable
          ) values (
            p_run_id, v_stu.student_id, v_rule ->> 'field_path', null,
            coalesce(v_rule ->> 'expected', 'a value'), v_rule ->> 'rule_code', v_sev, false
          );
        end if;
        continue;
      end if;

      if (v_rule ? 'pattern') and v_raw !~ (v_rule ->> 'pattern') then
        v_norm := app.fn_board_export_normalise(v_raw, v_rule ->> 'normaliser');
        v_fixable := v_norm is not null and v_norm ~ (v_rule ->> 'pattern');

        if v_fixable and v_run.normalise_applied then
          continue;
        end if;

        insert into public.board_export_row_error (
          run_id, student_id, field_path, current_value, expected, rule_code, severity, normalisable
        ) values (
          p_run_id, v_stu.student_id, v_rule ->> 'field_path', v_raw,
          coalesce(v_rule ->> 'expected', v_rule ->> 'pattern'), v_rule ->> 'rule_code', v_sev, v_fixable
        );
      end if;
    end loop;
  end loop;

  update public.board_export_run set validated_at = now() where id = p_run_id;

  return query
    select * from public.board_export_row_error
     where run_id = p_run_id
     order by student_id, field_path;
end;
$$;

revoke execute on function public.validate_board_export(uuid) from public, anon;
grant execute on function public.validate_board_export(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 9. normalise_board_export_run — AC1's one click
-- ═══════════════════════════════════════════════════════════════════════

-- Deliberately does NOT write to public.student. The canonical dashed form
-- is correct and constrained; what the board wants is a rendering of it.
-- This records the controller's approval of that rendering, and returns
-- how many blocking errors it cleared so the UI can say so.
create or replace function public.normalise_board_export_run(p_run_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run    public.board_export_run;
  v_before int;
  v_after  int;
begin
  v_run := app.fn_assert_board_export_access(p_run_id, true);
  if v_run.status <> 'draft' then
    raise exception 'RUN_NOT_EDITABLE' using errcode = '23514',
      detail = format('status=%s', v_run.status);
  end if;

  select count(*) into v_before
    from public.board_export_row_error
   where run_id = p_run_id and severity = 'blocking';

  update public.board_export_run
     set normalise_applied = true,
         normalised_by = auth.uid(),
         normalised_at = now()
   where id = p_run_id;

  perform public.validate_board_export(p_run_id);

  select count(*) into v_after
    from public.board_export_row_error
   where run_id = p_run_id and severity = 'blocking';

  return v_before - v_after;
end;
$$;

revoke execute on function public.normalise_board_export_run(uuid) from public, anon;
grant execute on function public.normalise_board_export_run(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 10. Headers and rows
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.fn_board_export_headers(p_run_id uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_run public.board_export_run;
begin
  v_run := app.fn_assert_board_export_access(p_run_id, false);
  return (
    select array_agg(col ->> 'header' order by ord)
      from public.board_profile bp,
           lateral jsonb_array_elements(bp.column_spec) with ordinality as t(col, ord)
     where bp.id = v_run.profile_id
  );
end;
$$;

-- The gate. Blocking errors stop the file existing at all — that is AC1's
-- "the export is blocked" — and an unvalidated run is refused outright,
-- because an empty error table means "nobody has looked", not "clean".
create or replace function public.fn_board_export_rows(p_run_id uuid)
returns table (student_id uuid, cells text[])
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_run     public.board_export_run;
  v_profile public.board_profile;
  v_blocked int;
begin
  v_run := app.fn_assert_board_export_access(p_run_id, false);
  if v_run.validated_at is null then
    raise exception 'EXPORT_NOT_VALIDATED' using errcode = '23514';
  end if;

  select count(*) into v_blocked
    from public.board_export_row_error e
   where e.run_id = p_run_id and e.severity = 'blocking';
  if v_blocked > 0 then
    raise exception 'EXPORT_BLOCKED' using errcode = '23514',
      detail = format('blocking_errors=%s', v_blocked);
  end if;

  select * into v_profile from public.board_profile where id = v_run.profile_id;

  -- row.serial is the only field that is a property of the FILE rather
  -- than of the child, so it is stamped here, after the ordering the file
  -- is written in has been decided, rather than in the row source.
  return query
    with ordered as (
      select s.student_id,
             s.fields || jsonb_build_object(
               'row.serial', row_number() over (order by s.sort_key, s.student_id)::text
             ) as fields,
             row_number() over (order by s.sort_key, s.student_id) as serial
        from app.fn_board_export_students(p_run_id) s
    )
    select o.student_id,
           (select array_agg(app.fn_board_export_cell(o.fields, t.col, v_profile.date_format, v_profile.code_map)
                             order by t.ord)
              from jsonb_array_elements(v_profile.column_spec) with ordinality as t(col, ord))
      from ordered o
     order by o.serial;
end;
$$;

revoke execute on function public.fn_board_export_headers(uuid) from public, anon;
grant execute on function public.fn_board_export_headers(uuid) to authenticated;
revoke execute on function public.fn_board_export_rows(uuid) from public, anon;
grant execute on function public.fn_board_export_rows(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 11. Readiness — trap 3's dashboard
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.fn_board_export_readiness(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_run public.board_export_run;
begin
  v_run := app.fn_assert_board_export_access(p_run_id, false);
  return jsonb_build_object(
    'run_id', v_run.id,
    'board_code', v_run.board_code,
    'status', v_run.status,
    'validated_at', v_run.validated_at,
    'normalise_applied', v_run.normalise_applied,
    'byte_order_mark', (select bp.byte_order_mark from public.board_profile bp where bp.id = v_run.profile_id),
    'student_count', (select count(*) from app.fn_board_export_students(p_run_id)),
    'blocking_count', (select count(*) from public.board_export_row_error
                        where run_id = p_run_id and severity = 'blocking'),
    'warning_count', (select count(*) from public.board_export_row_error
                       where run_id = p_run_id and severity = 'warning'),
    'normalisable_count', (select count(*) from public.board_export_row_error
                            where run_id = p_run_id and severity = 'blocking' and normalisable),
    'students_blocked', (select count(distinct student_id) from public.board_export_row_error
                          where run_id = p_run_id and severity = 'blocking')
  );
end;
$$;

revoke execute on function public.fn_board_export_readiness(uuid) from public, anon;
grant execute on function public.fn_board_export_readiness(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 12. complete / fail
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.complete_board_export_run(
  p_run_id    uuid,
  p_row_count int,
  p_file_path text,
  p_checksum  text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run public.board_export_run;
begin
  v_run := app.fn_assert_board_export_access(p_run_id, true);
  if v_run.status <> 'draft' then
    raise exception 'RUN_NOT_EDITABLE' using errcode = '23514',
      detail = format('status=%s', v_run.status);
  end if;
  if v_run.validated_at is null then
    raise exception 'EXPORT_NOT_VALIDATED' using errcode = '23514';
  end if;
  if exists (
    select 1 from public.board_export_row_error
     where run_id = p_run_id and severity = 'blocking'
  ) then
    raise exception 'EXPORT_BLOCKED' using errcode = '23514';
  end if;
  if p_file_path is null or btrim(p_file_path) = '' or p_checksum is null or btrim(p_checksum) = '' then
    raise exception 'EXPORT_FILE_MISSING' using errcode = '23514';
  end if;

  update public.board_export_run
     set status = 'completed',
         row_count = p_row_count,
         file_path = p_file_path,
         checksum = p_checksum,
         generated_by = auth.uid(),
         generated_at = now()
   where id = p_run_id;
end;
$$;

create or replace function public.fail_board_export_run(p_run_id uuid, p_error text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run public.board_export_run;
begin
  v_run := app.fn_assert_board_export_access(p_run_id, true);
  if v_run.status <> 'draft' then
    raise exception 'RUN_NOT_EDITABLE' using errcode = '23514',
      detail = format('status=%s', v_run.status);
  end if;
  update public.board_export_run
     set status = 'failed', error = left(coalesce(p_error, 'unknown'), 500), generated_at = now()
   where id = p_run_id;
end;
$$;

revoke execute on function public.complete_board_export_run(uuid, int, text, text) from public, anon;
grant execute on function public.complete_board_export_run(uuid, int, text, text) to authenticated;
revoke execute on function public.fail_board_export_run(uuid, text) from public, anon;
grant execute on function public.fail_board_export_run(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 13. RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.board_profile enable row level security;
alter table public.board_export_run enable row level security;
alter table public.board_export_row_error enable row level security;

-- The platform's own profiles (tenant_id null) are readable by everyone
-- signed in — they describe what this software can produce, like
-- certificate_type_field_catalog — and a tenant's override only by that
-- tenant. Writable by a migration alone.
create policy board_profile_read on public.board_profile
  for select to authenticated
  using (tenant_id is null or tenant_id = app.auth_tenant_id());

create policy board_export_campus_scope on public.board_export_run
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'student')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy board_export_row_error_scope on public.board_export_row_error
  for select to authenticated
  using (exists (select 1 from public.board_export_run r where r.id = run_id));

-- The requirement asks for a board_export_write_exam_controller policy, and
-- the write rule it names — super admin, owner, principal or exam controller,
-- within their own campuses — is enforced, once, inside
-- app.fn_assert_board_export_access(). It is deliberately NOT also an UPDATE
-- policy here: granting UPDATE at all would let a controller PostgREST a run
-- straight to 'completed' with a file_path and checksum of their choosing,
-- and "we filed the registration" is the one claim in this feature that must
-- be true. So the write path is revoked outright, same as
-- report_card_batch's.
revoke insert, update, delete on public.board_profile from authenticated, anon;
revoke insert, update, delete on public.board_export_run from authenticated, anon;
revoke insert, update, delete on public.board_export_row_error from authenticated, anon;

-- ═══════════════════════════════════════════════════════════════════════
-- 14. Storage: private bucket, {tenant_id}/{run_id}/... , 7-year retention
-- ═══════════════════════════════════════════════════════════════════════

-- 7 years: a board registration file is the evidence that a child was
-- entered for the exam they later hold a certificate for, and the
-- certificate outlives the school's own record-keeping instinct. Nothing
-- here deletes it; the retention purge (FR-T16) reads generated_at.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('board-exports', 'board-exports', false, 52428800, array['text/csv', 'text/plain'])
on conflict (id) do nothing;

create policy board_export_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'board-exports'
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'exam_controller')
    and (storage.foldername(name))[1] = app.auth_tenant_id()::text
  );

create policy board_export_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'board-exports'
    and (storage.foldername(name))[1] = app.auth_tenant_id()::text
    and exists (
      select 1 from public.board_export_run r
       where r.id::text = (storage.foldername(name))[2]
         and r.tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or r.campus_id = any(app.auth_campus_ids()))
    )
  );

-- ═══════════════════════════════════════════════════════════════════════
-- 15. Platform board profiles
-- ═══════════════════════════════════════════════════════════════════════

-- These are DATA. Correcting a header a board renamed is an INSERT with a
-- later effective_from in a new migration, not an edit to this one.

-- Punjab: AC2's file. Exactly 24 headers, in this order, DD/MM/YYYY dates,
-- M/F gender, PM/PE/CS/COM/ART groups.
insert into public.board_profile (tenant_id, board_code, export_kind, label, date_format, column_spec, validation_rules, code_map)
values (
  null, 'PUNJAB', 'registration', 'Punjab Board — Grade 9/11 registration', 'DD/MM/YYYY',
  '[
    {"header": "Sr. No.",            "source": "row.serial"},
    {"header": "GR No.",             "source": "student.gr_number"},
    {"header": "Candidate Name",     "source": "student.name_en",        "transform": "upper"},
    {"header": "Candidate Name Urdu","source": "student.name_ur"},
    {"header": "Father Name",        "source": "student.father_name_en", "transform": "upper"},
    {"header": "Father Name Urdu",   "source": "student.father_name_ur"},
    {"header": "Date of Birth",      "source": "student.dob",            "transform": "date"},
    {"header": "Gender",             "source": "student.gender",         "code_map": "gender"},
    {"header": "B-Form No.",         "source": "student.b_form_no",      "transform": "digits_only"},
    {"header": "Father CNIC",        "source": "guardian.father_cnic",   "transform": "digits_only"},
    {"header": "Religion",           "source": "student.religion",       "transform": "upper"},
    {"header": "Nationality",        "source": "student.nationality",    "transform": "upper"},
    {"header": "Group",              "source": "stream.name_en",         "code_map": "group"},
    {"header": "Class",              "source": "class_level.name_en"},
    {"header": "Section",            "source": "section.name"},
    {"header": "Roll No.",           "source": "enrolment.roll_no"},
    {"header": "Medium",             "source": "section.medium",         "code_map": "medium"},
    {"header": "Session",            "source": "session.name"},
    {"header": "Institution Name",   "source": "campus.name"},
    {"header": "Institution Code",   "source": "campus.code",            "transform": "upper"},
    {"header": "District",           "source": "campus.district"},
    {"header": "Blood Group",        "source": "student.blood_group"},
    {"header": "Contact No.",        "source": "guardian.father_phone"},
    {"header": "Address",            "source": "student.address"}
  ]'::jsonb,
  '[
    {"rule_code": "NAME_REQUIRED",    "field_path": "student.name_en",        "required": true,  "severity": "blocking", "expected": "the candidate name as it must appear on the certificate"},
    {"rule_code": "FATHER_REQUIRED",  "field_path": "student.father_name_en", "required": true,  "severity": "blocking", "expected": "the father''s name"},
    {"rule_code": "DOB_REQUIRED",     "field_path": "student.dob",            "required": true,  "severity": "blocking", "expected": "a date of birth"},
    {"rule_code": "BFORM_FORMAT",     "field_path": "student.b_form_no",      "required": true,  "severity": "blocking", "pattern": "^[0-9]{13}$", "normaliser": "digits_only", "expected": "13 digits, no dashes"},
    {"rule_code": "FATHER_CNIC",      "field_path": "guardian.father_cnic",   "required": true,  "severity": "blocking", "pattern": "^[0-9]{13}$", "normaliser": "digits_only", "expected": "13 digits, no dashes"},
    {"rule_code": "GROUP_REQUIRED",   "field_path": "stream.name_en",         "required": true,  "severity": "blocking", "expected": "a stream on the section, which supplies the board group code"},
    {"rule_code": "ROLL_REQUIRED",    "field_path": "enrolment.roll_no",      "required": false, "severity": "warning",  "expected": "a roll number"}
  ]'::jsonb,
  '{
    "gender": {"male": "M", "female": "F", "other": "O"},
    "group":  {"Pre-Medical": "PM", "Pre-Engineering": "PE", "Computer Science": "CS", "Commerce": "COM", "Arts": "ART"},
    "medium": {"ENGLISH": "E", "URDU": "U"}
  }'::jsonb
);

-- FBISE: AC1's and AC3's file. B-Form as 13 bare digits, father CNIC
-- blocking, ISO dates.
insert into public.board_profile (tenant_id, board_code, export_kind, label, date_format, column_spec, validation_rules, code_map)
values (
  null, 'FBISE', 'registration', 'FBISE — Grade 9/11 registration', 'DD/MM/YYYY',
  '[
    {"header": "SR",             "source": "row.serial"},
    {"header": "NAME",           "source": "student.name_en",        "transform": "upper"},
    {"header": "NAME_URDU",      "source": "student.name_ur"},
    {"header": "FATHER_NAME",    "source": "student.father_name_en", "transform": "upper"},
    {"header": "DOB",            "source": "student.dob",            "transform": "date"},
    {"header": "GENDER",         "source": "student.gender",         "code_map": "gender"},
    {"header": "BFORM",          "source": "student.b_form_no",      "transform": "digits_only"},
    {"header": "FATHER_CNIC",    "source": "guardian.father_cnic",   "transform": "digits_only"},
    {"header": "RELIGION",       "source": "student.religion",       "transform": "upper"},
    {"header": "GROUP",          "source": "stream.name_en",         "code_map": "group"},
    {"header": "CLASS",          "source": "class_level.name_en"},
    {"header": "INST_CODE",      "source": "campus.code",            "transform": "upper"},
    {"header": "SESSION",        "source": "session.name"}
  ]'::jsonb,
  '[
    {"rule_code": "NAME_REQUIRED",   "field_path": "student.name_en",        "required": true, "severity": "blocking", "expected": "the candidate name as it must appear on the certificate"},
    {"rule_code": "FATHER_REQUIRED", "field_path": "student.father_name_en", "required": true, "severity": "blocking", "expected": "the father''s name"},
    {"rule_code": "DOB_REQUIRED",    "field_path": "student.dob",            "required": true, "severity": "blocking", "expected": "a date of birth"},
    {"rule_code": "BFORM_FORMAT",    "field_path": "student.b_form_no",      "required": true, "severity": "blocking", "pattern": "^[0-9]{13}$", "normaliser": "digits_only", "expected": "13 digits, no dashes"},
    {"rule_code": "FATHER_CNIC",     "field_path": "guardian.father_cnic",   "required": true, "severity": "blocking", "pattern": "^[0-9]{13}$", "normaliser": "digits_only", "expected": "13 digits, no dashes"},
    {"rule_code": "GROUP_REQUIRED",  "field_path": "stream.name_en",         "required": true, "severity": "blocking", "expected": "a stream on the section, which supplies the board group code"}
  ]'::jsonb,
  '{
    "gender": {"male": "M", "female": "F", "other": "O"},
    "group":  {"Pre-Medical": "PM", "Pre-Engineering": "PE", "Computer Science": "CS", "Commerce": "COM", "Arts": "ART"}
  }'::jsonb
);

-- AKU-EB: AC3's counterpart. Same missing father CNIC, warning only —
-- the difference between the two boards is these two words, in data.
insert into public.board_profile (tenant_id, board_code, export_kind, label, date_format, column_spec, validation_rules, code_map)
values (
  null, 'AKU_EB', 'registration', 'AKU-EB — Grade 9/11 registration', 'YYYY-MM-DD',
  '[
    {"header": "Serial",             "source": "row.serial"},
    {"header": "Candidate Name",     "source": "student.name_en"},
    {"header": "Father/Guardian",    "source": "student.father_name_en"},
    {"header": "Date of Birth",      "source": "student.dob",          "transform": "date"},
    {"header": "Sex",                "source": "student.gender",       "code_map": "gender"},
    {"header": "B-Form",             "source": "student.b_form_no",    "transform": "digits_only"},
    {"header": "Guardian CNIC",      "source": "guardian.father_cnic", "transform": "digits_only"},
    {"header": "Group",              "source": "stream.name_en",       "code_map": "group"},
    {"header": "Class",              "source": "class_level.name_en"},
    {"header": "School Code",        "source": "campus.code",          "transform": "upper"},
    {"header": "Academic Year",      "source": "session.name"}
  ]'::jsonb,
  '[
    {"rule_code": "NAME_REQUIRED",   "field_path": "student.name_en",        "required": true,  "severity": "blocking", "expected": "the candidate name as it must appear on the certificate"},
    {"rule_code": "DOB_REQUIRED",    "field_path": "student.dob",            "required": true,  "severity": "blocking", "expected": "a date of birth"},
    {"rule_code": "BFORM_FORMAT",    "field_path": "student.b_form_no",      "required": true,  "severity": "blocking", "pattern": "^[0-9]{13}$", "normaliser": "digits_only", "expected": "13 digits, no dashes"},
    {"rule_code": "FATHER_CNIC",     "field_path": "guardian.father_cnic",   "required": true,  "severity": "warning",  "pattern": "^[0-9]{13}$", "normaliser": "digits_only", "expected": "13 digits, no dashes"},
    {"rule_code": "FATHER_REQUIRED", "field_path": "student.father_name_en", "required": true,  "severity": "warning",  "expected": "the father''s or guardian''s name"}
  ]'::jsonb,
  '{
    "gender": {"male": "M", "female": "F", "other": "O"},
    "group":  {"Pre-Medical": "PM", "Pre-Engineering": "PE", "Computer Science": "CS", "Commerce": "COM", "Arts": "ART"}
  }'::jsonb
);

-- Sindh, KPK and Balochistan share the Punjab column set today. They are
-- separate rows, not a shared one, precisely because trap 1 says they will
-- diverge — and when one does, it is one INSERT here and nothing else.
insert into public.board_profile (tenant_id, board_code, export_kind, label, date_format, column_spec, validation_rules, code_map)
select null, b.code, 'registration', b.label, 'DD/MM/YYYY', p.column_spec, p.validation_rules, p.code_map
  from public.board_profile p
  cross join (values
    ('SINDH'::public.board,       'Sindh Board — Grade 9/11 registration'),
    ('KPK'::public.board,         'KPK Board — Grade 9/11 registration'),
    ('BALOCHISTAN'::public.board, 'Balochistan Board — Grade 9/11 registration')
  ) as b(code, label)
 where p.tenant_id is null and p.board_code = 'PUNJAB' and p.export_kind = 'registration';
