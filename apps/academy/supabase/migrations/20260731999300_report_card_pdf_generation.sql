-- FR-J09: report card PDF generation.
--
-- "As a class teacher, I want a branded report card generated per student per
-- term, so that I hand parents a document that looks like the school's own."
--
-- ── Everything on the card already exists; this migration collects it ──
--
-- Not one number here is computed. The card is the first place the module's
-- five stored artifacts are read together, and it reads each from the place
-- that owns it rather than re-deriving anything:
--
--   subject_result           (FR-J02) the per-subject marks, and — load-bearing
--                            — grading_scheme_id/grade_label/gpa_point FROZEN
--                            per row, so a card reprinted in 2030 renders
--                            2025's scale rather than today's.
--   result_position          (FR-J05) rank_in_section out of ranked_out_of.
--                            AC1's "position 4 of 38". An unranked candidate
--                            keeps a row saying why, so the card prints a dash
--                            and the reason instead of a blank.
--   attendance_month_summary (FR-G14) present_days over working_days. FR-G14's
--                            header names "the report card attendance feed" as
--                            one of the two FRs it was reshaped for; this is
--                            it. Its weighting is inherited verbatim — present
--                            and late count 1, half_day 0.5, absent and
--                            excused 0 — because a second definition of "was
--                            the child in school" is exactly the drift FR-G14
--                            was written to stop.
--   resolve_branding()       (FR-A18) logo, letterhead, signature and stamp,
--                            campus-then-tenant. AC2's "no per-report
--                            configuration" is this function and nothing else.
--   fn_assert_result_        (FR-J03 + FR-J08) the single gate. See below.
--     disclosable()
--
-- ── The attendance date range is the whole of the FR's Notes ──────────
--
-- "Term attendance is routinely incomplete for the last week before results
-- because teachers are invigilating. Printing the exact date range the
-- summary covers is what stops a parent reading a partial figure as the
-- whole term."
--
-- exam_term carries no dates in this schema — FR-I01 chose sequence and
-- integer weightage, deliberately, and inventing a start/end here would be a
-- second calendar for the same year. So the window is not asserted; it is
-- REPORTED. The summary is the union of the attendance_month_summary rows
-- that exist for this candidate in this session, and the printed range is
-- the first and last day those rows actually cover, clipped to the
-- enrolment's own joined_on/left_on exactly as FR-G14 clips them.
--
-- That makes the incompleteness visible rather than hidden: a month nobody
-- has computed yet is simply outside the printed range, and a parent reading
-- "168 of 180 days (93.3%), 1 Apr 2026 – 31 May 2026" can see what they are
-- being told about. A card with no summarised month at all prints the
-- sentence saying so rather than 0%.
--
-- ── A snapshot, and why a report card earns one ───────────────────────
--
-- FR-T03/FR-T09 froze payload_snapshot onto an issued certificate so a
-- reprint is byte-stable. A report card is the weaker case — it is
-- regenerable from stored results, where a Transfer Certificate is not — and
-- it still earns the same treatment, for a reason the certificate did not
-- have:
--
--   FR-J02 froze the grading scheme per subject_result precisely so a
--   reprint could not silently re-grade. But the four other things on the
--   card are NOT frozen anywhere. The position moves when a classmate's mark
--   is corrected (FR-J05 AC4 makes that class-wide). The attendance figure
--   moves every time compute_month_attendance() runs. The branding moves the
--   day the school uploads a new logo. The remark is typed. Rendering from
--   live rows would mean the document in a parent's hand and the document the
--   system reprints under the same revision number are different documents —
--   which is what a revision number exists to make impossible.
--
-- So payload_snapshot is the card. Revision 1 renders from revision 1's
-- snapshot forever, and AC4's "supersedes revision 1" refers to something
-- fixed. The snapshot also carries rendered_at, which is stamped into the
-- PDF's own CreationDate so the bytes are reproducible to the byte — Chromium
-- otherwise writes wall-clock time and no two renders of one document would
-- agree.
--
-- checksum is the FR's own column name and it holds the SHA-256 of what the
-- BUCKET ended up with, read back after upload, exactly as FR-T09 takes it.
-- The download route re-hashes and refuses on a mismatch. It does NOT write a
-- security_event the way FR-T09 does: a certificate is a statutory document a
-- third party relies on and has no successor, so a mismatch there is a
-- forgery signal; a report card has a documented remedy (issue the next
-- revision), so the honest response is to refuse the stale bytes and say so,
-- not to raise a security alert a registrar has no action for.
--
-- ── No report_card_template, and why ──────────────────────────────────
--
-- The FR's Supabase Objects suggest report_card_template (class_id,
-- layout_json, paper_size). FR-T01's certificate_template machinery — version
-- history, a merge-field whitelist, resolve_certificate_template() — was
-- examined for reuse first, and it is the wrong shape twice over:
--
--   * a certificate template is PROSE with {{merge_fields}} substituted into
--     it. A report card is a table of N subject rows plus computed totals; it
--     cannot be expressed as substitution into a sentence, which is why
--     FR-T01's whitelist has nothing to whitelist here.
--   * the ACs need exactly one layout decision — A4 portrait, AC1's "a single
--     A4 page" — and AC2 explicitly requires branding to come from campus
--     branding "with no per-report configuration". A layout_json nothing
--     varies, versioned by a machine nothing invokes, is the
-- 	 table-with-no-reader FR-I16 declined and FR-J03's header cites.
--
-- The layout therefore lives in lib/report-cards/html.ts, next to FR-F15's
-- timetable sheet and FR-T01's certificate, and shares their renderer. If a
-- later FR needs per-class layouts, it adds the table then, against real ACs.
--
-- ── The gate, and AC3 ─────────────────────────────────────────────────
--
-- AC3: "Given the candidate's result is withheld, when rendering is
-- requested, then it is refused with 'result_withheld' and no file is
-- written." Refusing before anything is reserved is what makes "no file"
-- true, so begin_report_card() calls the gate as its first act — before the
-- revision number, before the storage path, before the row. Nothing to void
-- and nothing to clean up.
--
-- fn_assert_report_card_printable() is not a new gate. It calls FR-J08's
-- fn_assert_result_disclosable() (which is itself where FR-J08 put the
-- withhold and debarment refusals) and adds the two term-level conditions
-- FR-J03 already refuses at session level, in FR-J03's own words:
--
--   provisional  the section has not signed off every paper of the term, so
--                the card would print marks the school is still entering;
--   stale        FR-I17's result_stale_at is later than the result's
--                computed_at, or FR-J05's class-wide position staleness is
--                set. Both put a number on paper the database already knows
--                is wrong, and a printed page cannot be recalled.
--
-- Errcode 23514 throughout, never SQLSTATE class 55: PostgREST maps class 55
-- to HTTP 500 and replaces the body, which would strip the sentence naming
-- what is unfinished.

-- ═══════════════════════════════════════════════════════════════════════
-- Schema
-- ═══════════════════════════════════════════════════════════════════════

-- 'pending' exists because the bytes are produced outside the database:
-- begin_report_card() reserves the revision and the path, the server renders
-- and uploads, attach_report_card_pdf() seals the digest. A row that never
-- reaches 'issued' is voided with its reason rather than deleted, FR-T02's
-- rule for a number that has been handed out.
create type public.report_card_status as enum ('pending', 'issued', 'superseded', 'void');

create table public.report_card (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  campus_id           uuid not null references public.campus(id) on delete cascade,
  exam_term_id        uuid not null references public.exam_term(id) on delete cascade,
  section_id          uuid not null references public.class_section(id) on delete cascade,
  enrolment_id        uuid not null references public.enrolment(id) on delete cascade,
  revision_no         integer not null,
  -- AC4's footer reads off this rather than off revision_no - 1, so a future
  -- gap in the series cannot make the sentence a lie.
  supersedes_revision integer,
  storage_path        text not null,
  -- The FR's column name. SHA-256 hex of what the bucket holds, read back.
  checksum            text,
  status              public.report_card_status not null default 'pending',
  -- The card. See the header: everything on it that is not already frozen.
  payload_snapshot    jsonb not null,
  rendered_at         timestamptz not null default clock_timestamp(),
  rendered_by         uuid references public.app_user(user_id),
  void_reason         text,
  constraint chk_report_card_revision check (revision_no >= 1),
  -- Not `revision_no - 1`: a revision that was reserved and never became a
  -- document still consumes its number (FR-T02's rule), so the revision
  -- BEFORE this one is not necessarily the one this one supersedes.
  constraint chk_report_card_supersedes
    check (supersedes_revision is null
           or (supersedes_revision >= 1 and supersedes_revision < revision_no)),
  constraint chk_report_card_checksum
    check (checksum is null or checksum ~ '^[0-9a-f]{64}$'),
  constraint chk_report_card_issued
    check (status <> 'issued' or checksum is not null)
);

-- The FR's index, spelled as the FR spells it.
create unique index uq_report_card
  on public.report_card (enrolment_id, exam_term_id, revision_no);
create unique index uq_report_card_path on public.report_card (storage_path);
create index idx_report_card_term on public.report_card (exam_term_id, section_id);
create index idx_report_card_scope on public.report_card (tenant_id, campus_id, rendered_at desc);

create trigger report_card_audit after insert or update or delete on public.report_card
  for each row execute function app.tg_audit_row();

-- 20260731999100's idiom. A report card register is not derived: the bucket
-- objects would orphan, the revision series would restart and reissue a
-- number already printed on a document in a parent's hand, and the snapshot
-- of what revision 1 actually said is reconstructible from nothing.
select app.guard_table_truncate('report_card');

comment on table public.report_card is
  'FR-J09: one issued report card per (candidate, term, revision). payload_snapshot is the document; a reprint renders from it, never from today''s rows.';
comment on column public.report_card.payload_snapshot is
  'FR-J09: the position, the attendance window, the branding and the remark, frozen. FR-J02 already froze the grading scheme; these four are the rest of what would otherwise drift under a revision number.';
comment on column public.report_card.checksum is
  'FR-J09: SHA-256 of the stored object, read back after upload. The download route re-hashes and refuses on a mismatch.';

-- ═══════════════════════════════════════════════════════════════════════
-- The gate
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.fn_assert_report_card_printable(
  p_enrolment_id uuid,
  p_exam_term_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_enr     record;
  v_pending text;
begin
  select e.id, e.tenant_id, e.campus_id, e.section_id, e.class_level_id into v_enr
    from public.enrolment e where e.id = p_enrolment_id and e.deleted_at is null;
  if v_enr.id is null then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- FR-J08's gate, which carries FR-J08's authorisation as well as its two
  -- refusals. Nothing is duplicated here.
  perform public.fn_assert_result_disclosable(p_enrolment_id, p_exam_term_id);

  -- Readiness is asked FIRST because it is the more informative answer and it
  -- subsumes the other: FR-J02 computes a section's results when its LAST
  -- paper is signed off, so a section that is not ready has no subject_result
  -- rows at all, and "nothing computed" would be a confusing way to say "the
  -- Science paper is still being marked".
  if not (public.fn_term_result_ready(p_exam_term_id, v_enr.section_id) ->> 'ready')::boolean then
    select string_agg(x.value #>> '{}', ', ')
      into v_pending
      from jsonb_array_elements(
             public.fn_term_result_ready(p_exam_term_id, v_enr.section_id) -> 'pending_subjects'
           ) x(value);
    raise exception '%',
      'term result is provisional — a paper is still being marked'
      using errcode = '23514',
            hint = coalesce('Waiting on: ' || v_pending, 'Sign off every paper of this term for this section.');
  end if;

  -- A ready section whose results this candidate is missing entirely: they
  -- were enrolled after the term was computed. A recompute is the fix, and
  -- printing an empty card is not.
  if not exists (
    select 1 from public.subject_result sr
     where sr.enrolment_id = p_enrolment_id and sr.exam_term_id = p_exam_term_id
  ) then
    raise exception '%',
      'no term result has been computed for this candidate yet'
      using errcode = '23514',
            hint = 'Recompute the term results for this section.';
  end if;

  -- FR-I17's stamp, inherited unchanged (FR-J03's rule, at term level).
  if exists (
    select 1 from public.subject_result sr
     where sr.enrolment_id = p_enrolment_id
       and sr.exam_term_id = p_exam_term_id
       and coalesce(app.fn_result_stale_at(sr.exam_subject_id, sr.section_id) > sr.computed_at, false)
  ) then
    raise exception '%',
      'term result is stale — a mark changed after it was computed'
      using errcode = '23514',
            hint = 'Recompute the term results, then print again.';
  end if;

  -- FR-J05 AC4: a mark corrected anywhere in the class moves this
  -- candidate's class rank, so the position on the card is wrong even though
  -- their own marks are untouched.
  if exists (
    select 1 from public.result_position rp
     where rp.enrolment_id = p_enrolment_id
       and rp.exam_term_id = p_exam_term_id
       and app.fn_position_stale(rp.exam_term_id, rp.class_level_id, rp.computed_at)
  ) then
    raise exception '%',
      'position is stale — a mark changed in this class after it was ranked'
      using errcode = '23514',
            hint = 'Recompute the term results, then re-rank the class, then print again.';
  end if;
end;
$$;

revoke execute on function public.fn_assert_report_card_printable(uuid, uuid) from public, anon;
grant execute on function public.fn_assert_report_card_printable(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The card, as data
-- ═══════════════════════════════════════════════════════════════════════

-- FR-G14's summary, unioned over the months that exist, with the range those
-- months actually cover. See the header: the range is reported, not asserted.
create or replace function app.fn_report_card_attendance(p_enrolment_id uuid, p_session_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with clipped as (
    select s.present_days,
           s.working_days,
           greatest(make_date(s.year, s.month, 1), e.joined_on) as from_date,
           least(
             (make_date(s.year, s.month, 1) + interval '1 month - 1 day')::date,
             coalesce(e.left_on, (make_date(s.year, s.month, 1) + interval '1 month - 1 day')::date)
           ) as to_date
      from public.attendance_month_summary s
      join public.enrolment e on e.id = s.enrolment_id
     where s.enrolment_id = p_enrolment_id
       and s.session_id = p_session_id
  )
  select jsonb_build_object(
           'months_counted', count(*)::int,
           'present_days',   coalesce(sum(present_days), 0),
           'working_days',   coalesce(sum(working_days), 0)::int,
           'pct',            case when coalesce(sum(working_days), 0) > 0
                                  then round(sum(present_days) / sum(working_days) * 100, 2)
                             end,
           'from_date',      min(from_date),
           'to_date',        max(to_date)
         )
    from clipped;
$$;

comment on function app.fn_report_card_attendance(uuid, uuid) is
  'FR-J09: FR-G14''s monthly summary rolled up, with the date range the summarised months actually cover. A month nobody has computed is outside the range rather than silently inside the percentage.';

-- The whole card in one jsonb. SECURITY DEFINER because it reads branding and
-- the enrolment chain; the gate above has already answered who may see it.
create or replace function app.fn_build_report_card_payload(
  p_enrolment_id uuid,
  p_exam_term_id uuid,
  p_remark       text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_enr        record;
  v_term       record;
  v_subjects   jsonb;
  v_obtained   numeric(9,2);
  v_max        integer;
  v_pct        numeric(5,2);
  v_scheme     uuid;
  v_grade      record;
  v_position   jsonb;
  v_attendance jsonb;
begin
  select e.id, e.tenant_id, e.campus_id, e.session_id, e.section_id, e.roll_no,
         st.name_en, st.name_ur, st.father_name_en, st.father_name_ur, st.gr_number, st.photo_path,
         sec.name as section_name, cl.name_en as class_name
    into v_enr
    from public.enrolment e
    join public.student st on st.id = e.student_id
    join public.class_section sec on sec.id = e.section_id
    join public.class_level cl on cl.id = e.class_level_id
   where e.id = p_enrolment_id;

  select t.id, t.name, t.name_ur, t.code, s.name as session_name
    into v_term
    from public.exam_term t
    join public.academic_session s on s.id = t.session_id
   where t.id = p_exam_term_id;

  -- FR-J02's rows, with the scale they were graded on read OFF them.
  select jsonb_agg(jsonb_build_object(
           'subject_name',    sub.name_en,
           'subject_name_ur', sub.name_ur,
           'obtained',        sr.obtained,
           'max_marks',       sr.max_marks,
           'pct',             sr.pct,
           'grade_label',     sr.grade_label,
           'report_symbol',   sr.report_symbol,
           'is_pass',         sr.is_pass,
           'failed_components', sr.failed_components
         ) order by sub.name_en),
         sum(sr.obtained),
         sum(sr.max_marks)::int,
         (array_agg(sr.grading_scheme_id) filter (where sr.grading_scheme_id is not null))[1]
    into v_subjects, v_obtained, v_max, v_scheme
    from public.subject_result sr
    join public.subject sub on sub.id = sr.subject_id
   where sr.enrolment_id = p_enrolment_id
     and sr.exam_term_id = p_exam_term_id;

  -- AC1: 612 of 800 at 76.50%. Rounded once, off the two stored sums, and
  -- graded on the FROZEN scheme rather than whatever is active today.
  v_pct := case when coalesce(v_max, 0) > 0 then round(v_obtained * 100 / v_max, 2) end;
  select b.grade_label, b.gpa_point, b.is_pass into v_grade
    from public.fn_grade_for_percentage(v_scheme, v_pct) b;

  -- FR-J05's row. Absent entirely when the class has not been ranked yet,
  -- which the card prints as a dash rather than as a zero.
  select jsonb_build_object(
           'rank_in_section',     rp.rank_in_section,
           'ranked_out_of',       rp.ranked_out_of,
           'rank_in_class',       rp.rank_in_class,
           'ranked_out_of_class', rp.ranked_out_of_class,
           'is_ranked',           rp.is_ranked,
           'exclusion_reason',    rp.exclusion_reason
         )
    into v_position
    from public.result_position rp
   where rp.enrolment_id = p_enrolment_id and rp.exam_term_id = p_exam_term_id;

  v_attendance := app.fn_report_card_attendance(p_enrolment_id, v_enr.session_id);

  return jsonb_build_object(
    'school', (
      select jsonb_build_object(
               'name',           tn.legal_name,
               'campus_name',    c.name,
               'campus_name_ur', c.name_ur,
               'campus_code',    c.code,
               'city',           c.city,
               'address_line',   c.address_line,
               'phone',          c.phone_e164
             )
        from public.campus c
        join public.tenant tn on tn.id = c.tenant_id
       where c.id = v_enr.campus_id
    ),
    -- AC2: from campus branding, resolved once, with NO per-report knob.
    'branding', jsonb_build_object(
      'logo_storage_path',       public.resolve_branding(v_enr.campus_id, 'logo') ->> 'storage_path',
      'letterhead_storage_path', public.resolve_branding(v_enr.campus_id, 'letterhead') ->> 'storage_path',
      'signature_storage_path',  public.resolve_branding(v_enr.campus_id, 'signature') ->> 'storage_path',
      'stamp_storage_path',      public.resolve_branding(v_enr.campus_id, 'stamp') ->> 'storage_path'
    ),
    'student', jsonb_build_object(
      'name_en',        v_enr.name_en,
      'name_ur',        v_enr.name_ur,
      'father_name_en', v_enr.father_name_en,
      'father_name_ur', v_enr.father_name_ur,
      'gr_number',      v_enr.gr_number,
      'roll_no',        v_enr.roll_no,
      'photo_path',     v_enr.photo_path,
      'class_name',     v_enr.class_name,
      'section_name',   v_enr.section_name
    ),
    'term', jsonb_build_object(
      'exam_term_id', v_term.id,
      'code',         v_term.code,
      'name',         v_term.name,
      'name_ur',      v_term.name_ur,
      'session_name', v_term.session_name
    ),
    'subjects', coalesce(v_subjects, '[]'::jsonb),
    'aggregate', jsonb_build_object(
      'obtained',    v_obtained,
      'max_marks',   v_max,
      'pct',         v_pct,
      'grade_label', v_grade.grade_label,
      'gpa_point',   v_grade.gpa_point,
      'is_pass',     v_grade.is_pass
    ),
    'grading_scheme', (
      select jsonb_build_object('name', gs.name, 'version', gs.version, 'board', gs.board)
        from public.grading_scheme gs where gs.id = v_scheme
    ),
    'position',   v_position,
    'attendance', v_attendance,
    'remark',     nullif(btrim(coalesce(p_remark, '')), '')
  );
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- AC3 and AC4: reserving a revision
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.begin_report_card(
  p_enrolment_id uuid,
  p_exam_term_id uuid,
  p_remark       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_enr       record;
  v_prev      record;
  v_revision  integer;
  v_remark    text;
  v_payload   jsonb;
  v_path      text;
  v_id        uuid;
  v_at        timestamptz;
begin
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal',
                                'exam_controller', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select e.id, e.tenant_id, e.campus_id, e.section_id, e.session_id into v_enr
    from public.enrolment e where e.id = p_enrolment_id and e.deleted_at is null;
  if v_enr.id is null then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_enr.tenant_id <> v_tenant_id then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner')
     and not (v_enr.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- AC3, and it is the FIRST thing that happens: refusing before a revision
  -- is reserved is what makes "no file is written" true with nothing to
  -- clean up afterwards. 'result_withheld' goes out as the machine-readable
  -- DETAIL so a caller does not have to pattern-match a sentence, while the
  -- sentence itself — which names the amount, the cut-off and the threshold —
  -- reaches the screen intact.
  begin
    perform public.fn_assert_result_disclosable(p_enrolment_id, p_exam_term_id);
  exception when check_violation then
    raise exception '%', sqlerrm using errcode = '23514', detail = 'result_withheld';
  end;
  perform public.fn_assert_report_card_printable(p_enrolment_id, p_exam_term_id);

  -- AC4. A correction is a new revision, never an edit: the old document is
  -- in a parent's hands and the register has to account for it.
  --
  -- The next number counts EVERY row including voided ones — FR-T02's rule
  -- that a number which has been handed out is never reissued — while the
  -- revision this one SUPERSEDES is the last one that actually became a
  -- document. A footer reading "supersedes revision 1" when revision 1 was
  -- a render that failed would be a lie about a document that never existed.
  select max(rc.revision_no) into v_revision
    from public.report_card rc
   where rc.enrolment_id = p_enrolment_id and rc.exam_term_id = p_exam_term_id;
  v_revision := coalesce(v_revision, 0) + 1;

  select rc.revision_no, rc.payload_snapshot ->> 'remark' as remark
    into v_prev
    from public.report_card rc
   where rc.enrolment_id = p_enrolment_id
     and rc.exam_term_id = p_exam_term_id
     and rc.status in ('issued', 'superseded')
   order by rc.revision_no desc
   limit 1;

  -- A regeneration after a marks correction should not silently drop the
  -- class teacher's words; passing a new remark replaces them deliberately.
  v_remark := coalesce(nullif(btrim(coalesce(p_remark, '')), ''), v_prev.remark);

  v_payload := app.fn_build_report_card_payload(p_enrolment_id, p_exam_term_id, v_remark);
  v_at := clock_timestamp();
  v_payload := v_payload
    || jsonb_build_object(
         'revision_no',         v_revision,
         'supersedes_revision', v_prev.revision_no,
         -- Stamped into the PDF's own CreationDate so two renders of one
         -- revision are byte-identical; Chromium otherwise writes wall clock.
         'rendered_at',         v_at
       );

  v_path := v_tenant_id || '/' || v_enr.campus_id || '/' || p_exam_term_id || '/'
            || p_enrolment_id || '-r' || v_revision || '.pdf';

  insert into public.report_card (
    tenant_id, campus_id, exam_term_id, section_id, enrolment_id,
    revision_no, supersedes_revision, storage_path, status, payload_snapshot,
    rendered_at, rendered_by
  )
  values (
    v_tenant_id, v_enr.campus_id, p_exam_term_id, v_enr.section_id, p_enrolment_id,
    v_revision, v_prev.revision_no, v_path, 'pending', v_payload,
    v_at, (select auth.uid())
  )
  returning id into v_id;

  return jsonb_build_object(
    'report_card_id',   v_id,
    'revision_no',      v_revision,
    'storage_path',     v_path,
    'payload_snapshot', v_payload
  );
end;
$$;

revoke execute on function public.begin_report_card(uuid, uuid, text) from public, anon;
grant execute on function public.begin_report_card(uuid, uuid, text) to authenticated;

-- FR-T09's third step: the digest of what the bucket holds, sealed write-once.
-- An unsealed card is a document no download can verify, so the caller voids
-- rather than issues when this fails.
create or replace function public.attach_report_card_pdf(
  p_report_card_id uuid,
  p_sha256         text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.report_card%rowtype;
begin
  if app.auth_tenant_id() is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal',
                                'exam_controller', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_row from public.report_card where id = p_report_card_id;
  if v_row.id is null or v_row.tenant_id <> app.auth_tenant_id() then
    raise exception 'REPORT_CARD_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'REPORT_CARD_NOT_PENDING' using errcode = '23514';
  end if;
  if p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'REPORT_CARD_DIGEST_INVALID' using errcode = '23514';
  end if;

  -- The predecessor stops being current at the moment its successor exists as
  -- a document, not at the moment one was requested.
  update public.report_card
     set status = 'superseded'
   where enrolment_id = v_row.enrolment_id
     and exam_term_id = v_row.exam_term_id
     and revision_no < v_row.revision_no
     and status = 'issued';

  update public.report_card
     set checksum = p_sha256, status = 'issued'
   where id = p_report_card_id;
end;
$$;

revoke execute on function public.attach_report_card_pdf(uuid, text) from public, anon;
grant execute on function public.attach_report_card_pdf(uuid, text) to authenticated;

-- FR-T03's void path: a reserved revision whose bytes never appeared stays in
-- the register saying why. Deleting it would let the next attempt reuse the
-- number, which is the one thing a revision number must not do.
create or replace function public.void_report_card(
  p_report_card_id uuid,
  p_reason         text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.report_card%rowtype;
begin
  if app.auth_tenant_id() is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal',
                                'exam_controller', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_row from public.report_card where id = p_report_card_id;
  if v_row.id is null or v_row.tenant_id <> app.auth_tenant_id() then
    raise exception 'REPORT_CARD_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'REPORT_CARD_NOT_PENDING' using errcode = '23514';
  end if;

  update public.report_card
     set status = 'void', void_reason = coalesce(nullif(btrim(p_reason), ''), 'UNKNOWN')
   where id = p_report_card_id;
end;
$$;

revoke execute on function public.void_report_card(uuid, text) from public, anon;
grant execute on function public.void_report_card(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- What a screen reads
-- ═══════════════════════════════════════════════════════════════════════

-- The gate asked as a question rather than as a refusal, so a list of forty
-- candidates costs forty answers instead of forty exceptions. Same predicate
-- either way: this catches what fn_assert_report_card_printable() raises.
create or replace function app.fn_report_card_block_reason(
  p_enrolment_id uuid,
  p_exam_term_id uuid
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.fn_assert_report_card_printable(p_enrolment_id, p_exam_term_id);
  return null;
exception
  when check_violation then return sqlerrm;
end;
$$;

-- One section's print list: every candidate, whether their card can be
-- printed, and if not the sentence saying why — the same sentence the refusal
-- would raise, so the screen and the button cannot disagree.
create or replace function public.fn_report_card_sheet(
  p_exam_term_id uuid,
  p_section_id   uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_sec  record;
  v_term record;
  v_role text := app.auth_role();
  v_rows jsonb;
begin
  select s.id, s.tenant_id, s.campus_id, s.name into v_sec
    from public.class_section s where s.id = p_section_id;
  if v_sec.id is null then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  select t.id, t.name, t.session_id into v_term
    from public.exam_term t where t.id = p_exam_term_id;
  if v_term.id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_tenant_id() is not null then
    if v_sec.tenant_id <> app.auth_tenant_id() then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if v_role not in ('super_admin', 'owner')
       and not (v_sec.campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'enrolment_id',   c.enrolment_id,
           'student_name',   c.student_name,
           'gr_number',      c.gr_number,
           'roll_no',        c.roll_no,
           'report_card_id', c.report_card_id,
           'revision_no',    c.revision_no,
           'rendered_at',    c.rendered_at,
           'blocked_reason', c.blocked_reason
         ) order by c.roll_no nulls last, c.student_name), '[]'::jsonb)
    into v_rows
    from (
      select e.id as enrolment_id,
             st.name_en as student_name,
             st.gr_number,
             e.roll_no,
             rc.id as report_card_id,
             rc.revision_no,
             rc.rendered_at,
             app.fn_report_card_block_reason(e.id, p_exam_term_id) as blocked_reason
        from public.enrolment e
        join public.student st on st.id = e.student_id
        left join lateral (
          select r.id, r.revision_no, r.rendered_at
            from public.report_card r
           where r.enrolment_id = e.id and r.exam_term_id = p_exam_term_id and r.status = 'issued'
           order by r.revision_no desc
           limit 1
        ) rc on true
       where e.section_id = p_section_id
         and e.session_id = v_term.session_id
         and e.status = 'active'
         and e.deleted_at is null
    ) c;

  return jsonb_build_object(
    'exam_term_id',   p_exam_term_id,
    'exam_term_name', v_term.name,
    'section_id',     p_section_id,
    'section_name',   v_sec.name,
    'can_print',      v_role in ('super_admin', 'owner', 'principal', 'vice_principal',
                                 'exam_controller', 'class_teacher'),
    'candidates',     v_rows
  );
end;
$$;

revoke execute on function public.fn_report_card_sheet(uuid, uuid) from public, anon;
grant execute on function public.fn_report_card_sheet(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.report_card enable row level security;

create policy report_card_campus_scope on public.report_card
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() <> 'parent'
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- The FR's report_card_parent_own_child, with FR-J08's anti-join built in
-- from the start: a parent sees the CURRENT issued revision of their own
-- child's card, and sees nothing at all while the result is withheld. A
-- superseded revision is a register entry, not a document to hand over.
create policy report_card_parent_own_child on public.report_card
  for select to authenticated
  using (
    status = 'issued'
    and enrolment_id in (
      select id from public.enrolment where student_id = any(app.auth_guardian_student_ids())
    )
    and not app.fn_result_withheld(enrolment_id, exam_term_id)
  );

-- No INSERT, UPDATE or DELETE policy. Every write goes through the SECURITY
-- DEFINER functions above; this states the property rather than leaving it to
-- be inferred from an absence.
create policy report_card_no_direct_dml on public.report_card
  for update to authenticated
  using (false)
  with check (false);

-- ═══════════════════════════════════════════════════════════════════════
-- Storage: private bucket, the row reserves the path
-- ═══════════════════════════════════════════════════════════════════════

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('report-cards', 'report-cards', false, 10485760, array['application/pdf'])
on conflict (id) do nothing;

create policy report_cards_insert_printer on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'report-cards'
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal',
                            'exam_controller', 'class_teacher')
    and exists (
      select 1 from public.report_card rc
       where rc.storage_path = objects.name and rc.tenant_id = app.auth_tenant_id()
    )
  );

-- Read follows the register's own visibility, and the subquery is subject to
-- report_card's RLS as well, so the two cannot drift apart.
create policy report_cards_read_scope on storage.objects
  for select to authenticated
  using (
    bucket_id = 'report-cards'
    and exists (select 1 from public.report_card rc where rc.storage_path = objects.name)
  );

-- No UPDATE or DELETE policy: the checksum on the register is a statement
-- about these bytes, and a document that can be overwritten cannot be
-- verified. A correction is the next revision.
