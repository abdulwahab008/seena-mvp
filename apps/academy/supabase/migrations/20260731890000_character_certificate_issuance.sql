-- FR-T05: Character Certificate issuance.
--
-- "As a Principal, I want to issue a Character Certificate stating the
-- student's conduct during their time at the school, so that the student
-- can satisfy college and board admission requirements."
--
-- Fourth of module T's certificates cluster, and the first document in it
-- that is issued to a student who has ALREADY LEFT. FR-T01
-- (20260731860000) authored the wording and the field catalogue, FR-T02
-- (20260731870000) built the gapless allocator, FR-T03 (20260731880000)
-- built certificate_issue, the storage bucket, the issuance transaction
-- shape and void_certificate_issue(). Everything below reuses those; the
-- only new table-level object is a check constraint and an index.
--
-- ── The issuance shape is FR-T03's, unchanged ──────────────────────────
--
-- Every fallible step — role, campus scope, the student's state, the
-- conduct grade, the attendance period, the current session, the template,
-- the whole merge payload — runs BEFORE allocate_certificate_serial(), and
-- only the certificate_issue insert follows it. A failure after the
-- allocation is an ordinary transactional rollback that takes the counter
-- increment with it (FR-T02's AC2). The PDF render happens after the
-- commit, in the server action, and a render or upload failure calls
-- void_certificate_issue(), which marks the row 'void' and KEEPS its
-- serial. The counter is never rewound. void_certificate_issue() needed no
-- change: its enrolment-reverting branch is already guarded by
-- certificate_type = 'transfer', and a character certificate changes no
-- enrolment state to revert.
--
-- ── AC1: the attendance period is DERIVED, never guessed from today ────
--
-- The story is a student who left in 2023 asking in 2026, so "the period"
-- can only come from the enrolment history. FR-A06's rollover creates ONE
-- ENROLMENT PER SESSION (a student from 2018 to 2023 has ~5 rows, chained
-- by previous_enrolment_id), so the span is across all of them:
--
--     from = min(enrolment.joined_on)
--     to   = max(coalesce(enrolment.left_on, least(session.ends_on, today)))
--
-- coalesce is the whole of the still-enrolled case. Rollover deliberately
-- does NOT stamp left_on on the enrolment it supersedes — the row simply
-- stops being the current one — so most historical enrolments have a NULL
-- left_on and their real end is the end of the session they belonged to.
-- least(..., current_date) then keeps a currently enrolled student's period
-- ending TODAY rather than at the far end of a session that has not
-- finished: a certificate may not certify conduct that has not happened
-- yet. Soft-deleted enrolments (FR-A15) are excluded, so restoring one
-- restores the period it contributed to.
--
-- p_period_from / p_period_to are therefore OVERRIDES, defaulting to NULL,
-- and each falls back independently to the derived value. The AC's point is
-- that the system already knows the period; making the caller pass it would
-- put a typed date on a statutory document where a recorded one exists, and
-- a UI would have had to derive it anyway. The overrides exist because
-- pre-import history is real (a school onboarding in 2026 has no enrolment
-- rows for 2018) and are validated exactly as hard as the derived values:
-- start before end, and nothing in the future.
--
-- public.student_attendance_span() is the same derivation exposed as a
-- read, so the issuing UI can SHOW the period before anyone clicks Issue,
-- and so the derivation is assertable without issuing a certificate.
--
-- ── AC2: the conduct grade, guarded twice ─────────────────────────────
--
-- chk_conduct_grade is the floor: any INSERT of a character row whose
-- snapshot does not carry one of the four permitted grades is refused by
-- the table itself, whatever wrote it — PostgREST, psql, a future RPC. It
-- is written with coalesce(...) rather than as a plain IN, because a
-- missing conduct must FAIL: `false or null` is null, and a null CHECK
-- result passes. A Character Certificate that does not state the conduct is
-- not a Character Certificate.
--
-- The constraint reads payload_snapshot -> 'values' ->> the merge field
-- path rather than a top-level key, so what is constrained is exactly the
-- string that gets PRINTED. A top-level copy would be a second version of
-- the same fact, free to drift from the document.
--
-- issue_character_certificate() checks the same four values up front and
-- raises CONDUCT_GRADE_INVALID with the permitted list in DETAIL, because a
-- clerk who picked the wrong word needs to be told which words exist, not
-- handed a bare 23514 naming a constraint. The constraint is the backstop
-- for everything that does not come through the function.
--
-- ── AC3: an independent series, inherited rather than built ────────────
--
-- certificate_type is part of FR-T02's counter key, so 'character' has its
-- own counter row, its own 'CC-{YEAR}-{SEQ}' pattern and its own 1..n run;
-- a campus whose transfer series is at 147 issues its first character
-- certificate as CC-<year>-000001. The FR's literal `CC/2026/00001` is not
-- reproduced: the separator and the six-digit width are FR-T02's frozen
-- per-type pattern (its trigger refuses to change prefix_pattern for the
-- life of a series, deliberately — changing the format halfway through a
-- year is how a register stops looking like one), and re-shaping the
-- transfer and character series to differ from each other in punctuation
-- would create exactly the inconsistency the register is meant to preclude.
-- What the AC is actually about — a series that starts at 1 and knows
-- nothing of the TC counter — is what is built and tested.
--
-- The serial is numbered against the CURRENT academic session, not the one
-- the student attended: the number belongs to the year the register page
-- was written, which is what an inspector reads it as.
--
-- ── AC4: not one per enrolment ────────────────────────────────────────
--
-- uq_one_active_tc is partial on certificate_type = 'transfer', so nothing
-- limits how many character certificates a student holds — a fourth is an
-- ordinary insert. enrolment_id is set to the student's LATEST enrolment
-- where there is one (the conduct being certified was observed there, and
-- it is what the register links back to), which for a character
-- certificate is context rather than a key; certificate_issue.enrolment_id
-- was already made nullable by FR-T03 for exactly this. A student with no
-- enrolment row at all — pre-import history — still gets a certificate, and
-- an explicit period.
--
-- Nothing here requires an ACTIVE enrolment. That requirement is FR-T03's
-- and belongs to transfer certificates only: a character certificate is
-- issued to precisely the students who have left. What IS still refused is
-- a soft-deleted student (FR-A15) — a record in the recycle bin is not a
-- record to print a statutory document from.
--
-- ── What the catalogue gains ──────────────────────────────────────────
--
-- character.conduct was authored by FR-T01 as free text with the sample
-- 'Excellent'. It is RENAMED to character.conduct_grade and made required,
-- rather than left beside a second conduct field: two conduct fields on one
-- certificate type is an invitation to print the wrong one, and the sample
-- FR-T01 chose is already a member of the graded scale this FR defines. No
-- character template exists anywhere to be broken by the rename — the type
-- could not be issued until this migration.
--
-- character.period_from / character.period_to are new and required, for the
-- same reason FR-T01 made enrolment.left_on required on transfer templates:
-- the fields the acceptance criteria pin are the fields a document of that
-- type is not accepted without. Their samples are DD-MM-YYYY, which is what
-- FR-T03 established issued dates actually print as.
--
-- ── What the rest of the cluster adds (NOT built here) ────────────────
--
--   * FR-T08 (statutory register): still owns the append-only triggers and
--     v_certificate_register — deliberately still an unused name. Nothing
--     here updates a certificate_issue row after insert, so character rows
--     need no exemption from those triggers; cancellation and replacement
--     reach them through the same 'cancelled' status and
--     replaced_by_issue_id FR-T03 already shipped, and a cancelled
--     character certificate keeps its serial exactly as a voided one does.
--   * FR-T09 (digital signature/stamp): pdf_sha256 and
--     signing_identity_id on certificate_issue. The pdf_path shape here is
--     FR-T03's — {tenant}/{campus}/{type}/{serial}.pdf — so one hashing
--     pass covers every certificate type, and signatory.name /
--     signatory.designation resolve to the issuing user until it lands.
--   * Duplicate issuance still owns original_issue_id, which stays unused.
--
-- Every function below has its full signature fixed. Adding a defaulted
-- argument with CREATE OR REPLACE creates a DISTINCT overload and makes
-- existing calls ambiguous (FR-G05 hit exactly this) — drop and recreate,
-- and re-issue the grants.

-- ═══════════════════════════════════════════════════════════════════════
-- The field catalogue
-- ═══════════════════════════════════════════════════════════════════════

update public.certificate_type_field_catalog
   set field_path = 'character.conduct_grade',
       required   = true,
       label_en   = 'Conduct grade',
       sample_en  = 'Excellent',
       sample_ur  = 'بہترین'
 where certificate_type = 'character' and field_path = 'character.conduct';

insert into public.certificate_type_field_catalog
  (certificate_type, field_path, required, label_en, sample_en, sample_ur)
values
  ('character', 'character.period_from', true, 'Attended from', '01-04-2018', '۰۱-۰۴-۲۰۱۸'),
  ('character', 'character.period_to',   true, 'Attended to',   '31-03-2023', '۳۱-۰۳-۲۰۲۳');

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: the conduct grade is a scale, at the table
-- ═══════════════════════════════════════════════════════════════════════

alter table public.certificate_issue
  add constraint chk_conduct_grade check (
    certificate_type <> 'character'
    or coalesce(payload_snapshot -> 'values' ->> 'character.conduct_grade', '')
       in ('Excellent', 'Very Good', 'Good', 'Satisfactory')
  );

-- "this student's certificates of this type, newest first" — the register
-- panel on the issuing page, and the AC4 check that a fourth is allowed.
-- idx_cert_issue_student (FR-T03) is a strict prefix of this one and is
-- dropped rather than left to be maintained on every write for nothing.
create index idx_cert_issue_student_type
  on public.certificate_issue (student_id, certificate_type, issued_at desc);
drop index public.idx_cert_issue_student;

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: the attendance period, derived from the enrolment history
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.student_attendance_span(p_student_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_student   record;
  v_from      date;
  v_to        date;
  v_count     int;
begin
  select s.campus_id, s.deleted_at
    into v_student
    from public.student s
   where s.id = p_student_id and s.tenant_id = v_tenant_id;
  if not found or v_student.deleted_at is not null then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  -- SECURITY DEFINER bypasses RLS, so the campus scope is checked out loud
  -- (b16ba25's convention).
  if app.auth_role() not in ('super_admin', 'owner')
     and not (v_student.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- Every enrolment the student ever held, not just the current one: a
  -- 2018-2023 student has one row per session.
  select min(e.joined_on),
         max(coalesce(e.left_on, least(sess.ends_on, current_date))),
         count(*)::int
    into v_from, v_to, v_count
    from public.enrolment e
    join public.academic_session sess on sess.id = e.session_id
   where e.student_id = p_student_id
     and e.deleted_at is null;

  return jsonb_build_object(
    'period_from',     v_from,
    -- A single enrolment created today inside a session that has already
    -- ended would otherwise read as ending before it began.
    'period_to',       greatest(v_to, v_from),
    'enrolment_count', coalesce(v_count, 0)
  );
end;
$$;

revoke execute on function public.student_attendance_span(uuid) from public, anon;
grant execute on function public.student_attendance_span(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Issuance
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.issue_character_certificate(
  p_student_id uuid,
  p_conduct text,
  p_period_from date default null,
  p_period_to date default null,
  p_remarks text default null,
  p_board_code text default null,
  p_language public.certificate_language default 'en'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid := app.auth_tenant_id();
  v_role        text := app.auth_role();
  v_uid         uuid := (select auth.uid());
  v_s           record;
  v_e           record;
  v_session     record;
  v_span        jsonb;
  v_from        date;
  v_to          date;
  v_template    public.certificate_template%rowtype;
  v_template_id uuid;
  v_signatory   text;
  v_issued_on   date := current_date;
  v_values      jsonb;
  v_snapshot    jsonb;
  v_serial      text;
  v_pdf_path    text;
  v_issue_id    uuid;
begin
  if v_role not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select s.tenant_id, s.campus_id, s.deleted_at,
         s.name_en, s.name_ur, s.father_name_en, s.father_name_ur, s.gr_number,
         s.dob, s.gender::text as gender, s.religion, s.b_form_no,
         c.name as campus_name, c.name_ur as campus_name_ur, c.code as campus_code, c.city as campus_city,
         t.name as tenant_name, t.name_ur as tenant_name_ur
    into v_s
    from public.student s
    join public.campus c on c.id = s.campus_id
    join public.tenant t on t.id = s.tenant_id
   where s.id = p_student_id
     and s.tenant_id = v_tenant_id;

  -- FR-A15: a student in the recycle bin is not a record to print a
  -- statutory document from.
  if not found or v_s.deleted_at is not null then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_role not in ('super_admin', 'owner') and not (v_s.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- AC2's friendly half. chk_conduct_grade below is the same rule at the
  -- table, for writers that never reach this function.
  if coalesce(p_conduct, '') not in ('Excellent', 'Very Good', 'Good', 'Satisfactory') then
    raise exception 'CONDUCT_GRADE_INVALID'
      using errcode = '23514',
            detail = format('conduct=%s permitted=Excellent,Very Good,Good,Satisfactory', coalesce(p_conduct, '(null)')),
            hint = 'Conduct must be one of Excellent, Very Good, Good or Satisfactory.';
  end if;

  -- AC1. Each end falls back independently, so an override may correct one
  -- side of an imported history without discarding the recorded other side.
  v_span := public.student_attendance_span(p_student_id);
  v_from := coalesce(p_period_from, (v_span ->> 'period_from')::date);
  v_to   := coalesce(p_period_to,   (v_span ->> 'period_to')::date);

  if v_from is null or v_to is null then
    raise exception 'ATTENDANCE_PERIOD_UNKNOWN'
      using errcode = 'P0002',
            detail = format('student_id=%s enrolment_count=%s', p_student_id, v_span ->> 'enrolment_count'),
            hint = 'This student has no enrolment history to derive the period from; state it explicitly.';
  end if;
  if v_to < v_from then
    raise exception 'PERIOD_END_BEFORE_START'
      using errcode = '23514',
            detail = format('period_from=%s period_to=%s', v_from, v_to),
            hint = 'The end of the attendance period cannot precede its start.';
  end if;
  if v_to > v_issued_on then
    raise exception 'PERIOD_IN_FUTURE'
      using errcode = '23514',
            detail = format('period_to=%s today=%s', v_to, v_issued_on),
            hint = 'A certificate cannot certify conduct that has not happened yet.';
  end if;

  -- The enrolment the conduct was observed in — the latest one — for the
  -- class the student was last in and for the register's own link back.
  -- NOT a uniqueness key: AC4 allows any number of these.
  select e.id, e.deleted_at,
         cl.name_en as class_name,
         cs.name as section_name,
         sess.name as session_name
    into v_e
    from public.enrolment e
    join public.class_level cl on cl.id = e.class_level_id
    join public.class_section cs on cs.id = e.section_id
    join public.academic_session sess on sess.id = e.session_id
   where e.student_id = p_student_id
     and e.deleted_at is null
   order by e.joined_on desc, sess.starts_on desc
   limit 1;

  -- AC3. The serial belongs to the year the register page is written in,
  -- which is the CURRENT session — not the session the student attended.
  select s.id, s.name
    into v_session
    from public.academic_session s
   where s.tenant_id = v_tenant_id
     and s.is_current
     and (s.campus_id = v_s.campus_id or s.campus_id is null)
   order by (s.campus_id is not null) desc
   limit 1;
  if not found then
    raise exception 'ACADEMIC_SESSION_NOT_FOUND'
      using errcode = 'P0002',
            hint = 'A certificate serial belongs to an academic session; the campus has no current one.';
  end if;

  v_template_id := public.resolve_certificate_template(
    v_s.campus_id, 'character'::public.certificate_type, p_board_code, p_language);
  if v_template_id is null then
    raise exception 'TEMPLATE_NOT_FOUND'
      using errcode = 'P0002',
            detail = format('campus_id=%s board_code=%s language=%s', v_s.campus_id, p_board_code, p_language),
            hint = 'Activate a Character Certificate template for this campus, board and language first.';
  end if;
  select * into v_template from public.certificate_template where id = v_template_id;

  select au.full_name into v_signatory
    from public.app_user au where au.user_id = v_uid;

  v_values := jsonb_build_object(
    'school.name_en',            v_s.tenant_name,
    'school.name_ur',            v_s.tenant_name_ur,
    'campus.name',               v_s.campus_name,
    'campus.code',               v_s.campus_code,
    'issue.date',                to_char(v_issued_on, 'DD-MM-YYYY'),
    'issue.place',               v_s.campus_city,
    'student.name_en',           v_s.name_en,
    'student.name_ur',           v_s.name_ur,
    'student.father_name_en',    v_s.father_name_en,
    'student.father_name_ur',    v_s.father_name_ur,
    'student.gr_number',         v_s.gr_number,
    'student.dob',               to_char(v_s.dob, 'DD-MM-YYYY'),
    'student.dob_words',         public.dob_to_words(v_s.dob, v_template.language::text),
    'student.gender',            initcap(v_s.gender),
    'student.religion',          v_s.religion,
    'student.b_form_no',         v_s.b_form_no,
    -- The class and session the conduct was last observed in. A student
    -- with no enrolment row leaves these visibly blank rather than
    -- inventing them.
    'enrolment.class_name',      v_e.class_name,
    'enrolment.section_name',    v_e.section_name,
    'enrolment.session_name',    v_e.session_name,
    'enrolment.joined_on',       to_char(v_from, 'DD-MM-YYYY'),
    'character.conduct_grade',   p_conduct,
    'character.period_from',     to_char(v_from, 'DD-MM-YYYY'),
    'character.period_to',       to_char(v_to, 'DD-MM-YYYY'),
    'character.remarks',         p_remarks,
    -- FR-T09 replaces these with a real signing identity.
    'signatory.name',            nullif(v_signatory, ''),
    'signatory.designation',     initcap(replace(v_role, '_', ' '))
  );

  -- LAST fallible statement before the write, exactly as FR-T03: everything
  -- above can still refuse without touching the counter, and everything
  -- below takes the number down with it if it fails.
  v_serial := public.allocate_certificate_serial(
    v_s.campus_id, 'character'::public.certificate_type, v_session.id);
  v_values := v_values || jsonb_build_object('issue.serial_no', v_serial);

  -- A prefix_pattern may legitimately contain '/', which would otherwise
  -- turn into extra storage folders and break the three-segment path every
  -- FR-T03 storage policy reads.
  v_pdf_path := v_s.tenant_id::text || '/' || v_s.campus_id::text || '/character/'
                || replace(v_serial, '/', '-') || '.pdf';

  v_snapshot := jsonb_build_object(
    'template', jsonb_build_object(
      'id',               v_template.id,
      'certificate_type', v_template.certificate_type,
      'board_code',       v_template.board_code,
      'language',         v_template.language,
      'version',          v_template.version,
      'status',           'issued',
      'title',            v_template.title,
      'body_html',        v_template.body_html,
      'page_size',        v_template.page_size
    ),
    'tenant', jsonb_build_object('name', v_s.tenant_name, 'name_ur', v_s.tenant_name_ur),
    'campus', jsonb_build_object('name', v_s.campus_name, 'name_ur', v_s.campus_name_ur,
                                 'code', v_s.campus_code, 'city', v_s.campus_city),
    'letterhead_storage_path',
      (public.resolve_branding(v_s.campus_id, 'letterhead'::public.branding_asset_type)) ->> 'storage_path',
    'logo_storage_path',
      (public.resolve_branding(v_s.campus_id, 'logo'::public.branding_asset_type)) ->> 'storage_path',
    'values', v_values
  );

  insert into public.certificate_issue (
    tenant_id, campus_id, student_id, enrolment_id, session_id, certificate_type,
    serial_no, template_id, template_version, language, pdf_path, payload_snapshot, issued_by
  ) values (
    v_s.tenant_id, v_s.campus_id, p_student_id, v_e.id, v_session.id, 'character',
    v_serial, v_template.id, v_template.version, v_template.language, v_pdf_path, v_snapshot, v_uid
  )
  returning id into v_issue_id;

  return jsonb_build_object(
    'issue_id',         v_issue_id,
    'serial_no',        v_serial,
    'pdf_path',         v_pdf_path,
    'certificate_type', 'character',
    'status',           'issued',
    'template_id',      v_template.id,
    'template_version', v_template.version,
    'language',         v_template.language,
    'period_from',      v_from,
    'period_to',        v_to,
    'payload_snapshot', v_snapshot
  );
end;
$$;

revoke execute on function public.issue_character_certificate(
  uuid, text, date, date, text, text, public.certificate_language
) from public, anon;
grant execute on function public.issue_character_certificate(
  uuid, text, date, date, text, text, public.certificate_language
) to authenticated;
