-- FR-J02: subject term result computation.
--
-- "As an Exam Controller, I want per-subject results computed automatically
-- once marks are locked, so that nobody re-adds columns by hand."
--
-- ── What this consumes, and what it deliberately does not re-derive ────
--
-- FR-I11 (20260731980000) built public.v_exam_result_input specifically so
-- that this migration structurally cannot mistake an exam status for a
-- number. One row per (paper, candidate) with:
--
--   obtained_marks     numeric NOT NULL  — 0 for absent, exempt and debarred
--   denominator_marks  integer NOT NULL  — 0 for EXEMPT, the paper's full
--                                          maximum for absent and debarred
--   blocks_result      boolean           — true for debarred
--   report_symbol      text              — 'AB' / 'EX' / 'DEB' / null
--
-- So AC3 and AC4 are not implemented here at all: they are properties of that
-- view, and this migration's only job is to sum the two columns it is handed.
-- The exempt subject has already removed itself from the denominator; the
-- absent one has already kept its full maximum. Re-deriving either from
-- mark_entry + exam_attendance would be reintroducing exactly the mistake
-- FR-I11 exists to prevent, and there would be two places for the rule to
-- live.
--
-- The ONE thing that view cannot answer is AC2's, because it is not a total:
-- "did this candidate clear every component's own pass mark". That needs
-- component-level marks, so this migration reads mark_entry for that and only
-- that — and only for candidates the view already reports as 'present'.
--
-- ── Stored, not derived, and why that is not a cache ───────────────────
--
-- FR-I17's migration declined to invent a report_card table on the grounds
-- that it would be "a table with no reader". That was right then. It is not a
-- cache decision now, because a derived view CANNOT satisfy FR-J01 AC4:
--
--   "a scheme already referenced by a published result ... prior results keep
--    resolving to the old version"
--
-- A view would re-resolve the grading scheme on every read, so the day a new
-- effective-dated version took effect, every transcript ever issued would
-- silently re-grade — the exact failure FR-J01's Notes describe. subject_result
-- therefore stores grading_scheme_id, grade_label and gpa_point as they were
-- at computation. The scale a result was graded on is part of the result.
--
-- FR-J03 (weighted aggregation), FR-J09 (report card PDF) and FR-J12 (bulk
-- generation) all need a stable, reproducible artifact to aggregate and print;
-- this is it, and obtained/max_marks are stored in the shape FR-J03 needs
-- (sum the numerators, sum the denominators — an exempt subject contributes
-- 0/0 and shrinks the bottom by itself, no special case at the term level
-- either).
--
-- ── Staleness is FR-I17's, not a second concept ───────────────────────
--
-- mark_lock.result_stale_at already exists and is already stamped when a
-- break-glass window changes a mark under a signed-off set, and
-- fn_term_result_ready() already reports it. A stored result is stale exactly
-- when result_stale_at is later than computed_at, so staleness is DERIVED from
-- the two timestamps rather than stored as a third flag that could disagree
-- with either. Recomputing moves computed_at forward and the flag clears
-- itself; nothing has to remember to reset it.
--
-- FR-I17 stamps result_stale_at ONCE PER WINDOW, not once per edited cell.
-- That is correct for its purpose and it makes recomputing DURING an open
-- window unsafe: a recompute at 15:05 would clear the flag, and the 15:06 edit
-- in the same window would not re-raise it. So an explicit recompute is
-- refused while a window is open, naming the window. The automatic path
-- cannot hit this — it fires on the INSERT of a lock, and a lock with an open
-- window is not a lock anyone just signed.
--
-- ── Pass and fail: two rules, both from the requirement ────────────────
--
-- The requirement is "a pass/fail flag evaluated against every component's
-- individual pass mark", and this FR's Notes are about a candidate who "can
-- clear the aggregate and still fail the subject on a component pass mark".
-- Both halves are therefore real, and a subject is a pass only when:
--
--   1. every component with a pass mark above zero was met, AND
--   2. the aggregate lands in a band the SCHEME says is a pass — FBISE F and
--      Cambridge U are grades you can be given and not have passed.
--
-- Rule 1 is what AC2 asserts and what failed_components names. Rule 2 comes
-- from grading_band.is_pass and almost never bites on its own, because a
-- candidate below a board's pass percentage has usually already failed a
-- component — but where a paper carries no component pass marks at all it is
-- the only signal there is, and reading the scheme beats hardcoding 'F'.
--
-- ── The three results that are not a pass or a fail ────────────────────
--
--   * EXEMPT (denominator 0): pct, grade, GPA and is_pass are all null. There
--     is no percentage of nothing, and calling it an F would be the very
--     re-grading of an entitlement FR-I11 was written to stop.
--   * DEBARRED: fn_exam_result_blocked() answers per candidate PER TERM, so a
--     debarment on one paper withholds the whole term — FR-I11's contract,
--     not a new rule. Rows are still written, carrying obtained and max, with
--     is_blocked true and no grade: "Result Withheld" is a thing a report card
--     prints, and a missing row is not.
--   * ABSENT: 0 against the full maximum, which IS a percentage and IS a
--     fail. It grades normally and prints 'AB'.
--
-- ── Rounding ──────────────────────────────────────────────────────────
--
-- pct is round(obtained * 100 / max, 2) in numeric — exact decimal, rounded
-- once. FR-J01's fn_grade_for_percentage() rounds again to the same two
-- decimals before looking up a band, so the grade is read off the number the
-- report card prints and the two can never disagree. See FR-J01's migration
-- header for why this is numeric(5,2) rather than the basis points FR-I01
-- uses for weightage.

-- ═══════════════════════════════════════════════════════════════════════
-- Schema
-- ═══════════════════════════════════════════════════════════════════════

create table public.subject_result (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  exam_term_id      uuid not null references public.exam_term(id) on delete cascade,
  section_id        uuid not null references public.class_section(id) on delete cascade,
  exam_subject_id   uuid not null references public.exam_subject(id) on delete cascade,
  enrolment_id      uuid not null references public.enrolment(id) on delete cascade,
  subject_id        uuid not null references public.subject(id) on delete cascade,
  -- Summed from v_exam_result_input, never re-derived from mark_entry.
  obtained          numeric(7,2) not null,
  max_marks         integer not null,
  -- Null when max_marks is 0 — a fully exempt subject has no percentage.
  pct               numeric(5,2),
  -- FR-J01 AC4: the scale this result was graded on, frozen onto the result.
  -- A later effective-dated version does not re-grade it.
  grading_scheme_id uuid references public.grading_scheme(id),
  grade_label       text,
  gpa_point         numeric(3,2),
  -- Null when there is nothing to pass or fail: exempt, or withheld.
  is_pass           boolean,
  -- AC2: the component that failed, named. Empty for a pass.
  failed_components jsonb not null default '[]'::jsonb,
  -- FR-I11's vocabulary, carried through to the report card: 'AB'/'EX'/'DEB'.
  report_symbol     text,
  -- FR-I11's fn_exam_result_blocked(), asked once per candidate per term.
  is_blocked        boolean not null default false,
  computed_at       timestamptz not null default clock_timestamp(),
  computed_by       uuid references public.app_user(user_id),
  constraint chk_subject_result_nonneg check (obtained >= 0 and max_marks >= 0)
);

-- The FR's index, spelled as the FR spells it.
create unique index uq_subject_result
  on public.subject_result (tenant_id, exam_term_id, enrolment_id, subject_id);
create index idx_subject_result_section on public.subject_result (exam_term_id, section_id);
create index idx_subject_result_enrolment on public.subject_result (enrolment_id, exam_term_id);
-- What FR-J09 opens a report card with, and what FR-J03 aggregates.
create index idx_subject_result_campus on public.subject_result (tenant_id, campus_id, exam_term_id);

create trigger subject_result_audit after insert or update or delete on public.subject_result
  for each row execute function app.tg_audit_row();

comment on table public.subject_result is
  'FR-J02: one computed result per (candidate, subject, term). Stored rather than derived so FR-J01 AC4 holds — the grading scheme it was graded on is frozen onto the row.';
comment on column public.subject_result.max_marks is
  'The denominator FR-I11 handed over: 0 for an exempt subject, the paper''s full maximum for an absent or debarred one. FR-J03 sums these.';
comment on column public.subject_result.is_blocked is
  'FR-I11: this candidate is debarred somewhere in this term, so the whole term''s result is withheld. Not a fail.';

-- ═══════════════════════════════════════════════════════════════════════
-- Staleness, read from FR-I17's own stamp
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY DEFINER because mark_lock's SELECT policy excludes parents, and the
-- row this timestamp belongs to is already gated by subject_result's own RLS.
-- The tenant filter is written out in SQL rather than left to a policy — a
-- definer function owned by postgres bypasses RLS entirely (FR-K24's finding).
create or replace function app.fn_result_stale_at(
  p_exam_subject_id uuid,
  p_section_id      uuid
)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select l.result_stale_at
    from public.mark_lock l
   where l.exam_subject_id = p_exam_subject_id
     and l.section_id = p_section_id
     and (app.auth_tenant_id() is null or l.tenant_id = app.auth_tenant_id());
$$;

comment on function app.fn_result_stale_at(uuid, uuid) is
  'FR-I17 AC3''s stamp, read by FR-J02. A result is stale when this is later than its computed_at — derived, never a second stored flag.';

-- ═══════════════════════════════════════════════════════════════════════
-- The computation
-- ═══════════════════════════════════════════════════════════════════════

-- The engine. No authorisation of its own: both callers below have already
-- established that this section's marks are signed off and that the caller may
-- see them. Splitting it this way is what lets the mark_lock trigger compute
-- without re-running a role gate the approval just passed.
create or replace function app.fn_compute_subject_result(
  p_exam_term_id uuid,
  p_section_id   uuid,
  p_actor        uuid default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_term    record;
  v_scheme  uuid;
  v_board   public.board;
  v_on_date date;
  v_row     record;
  v_blocked boolean;
  v_label   text;
  v_gpa     numeric(3,2);
  v_band_pass boolean;
  v_pct     numeric(5,2);
  v_failed  jsonb;
  v_pass    boolean;
  v_count   integer := 0;
  v_last    uuid;
begin
  select t.id, t.tenant_id, t.campus_id, t.session_id
    into v_term
    from public.exam_term t where t.id = p_exam_term_id;
  if v_term.id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- The date the RESULT belongs to, not today's: recomputing a 2023 term in
  -- 2026 must still resolve 2023's published scale (FR-J01 AC4).
  select s.starts_on into v_on_date
    from public.academic_session s where s.id = v_term.session_id;
  v_board := app.fn_board_for_section(p_section_id);
  v_scheme := app.fn_grading_scheme_for_board(v_term.tenant_id, v_board, coalesce(v_on_date, current_date));

  if v_scheme is null then
    raise exception '%',
      format('no grading scheme is configured for %s as at %s', v_board, coalesce(v_on_date, current_date))
      using errcode = '23514',
            hint = 'Configure and activate a grade scale for this board before computing results.';
  end if;

  for v_row in
    select r.*
      from public.v_exam_result_input r
     where r.exam_term_id = p_exam_term_id
       and r.section_id = p_section_id
     order by r.enrolment_id, r.exam_subject_id
  loop
    -- FR-I11: asked once per candidate per term, not re-derived per paper.
    if v_last is distinct from v_row.enrolment_id then
      v_last := v_row.enrolment_id;
      v_blocked := exists (
        select 1
          from public.exam_attendance a
          join public.exam_subject es on es.id = a.exam_subject_id
         where es.exam_term_id = p_exam_term_id
           and a.enrolment_id = v_row.enrolment_id
           and a.status = 'debarred'
      );
    end if;

    -- AC1: obtained over the denominator FR-I11 handed over, to two decimals.
    -- AC3: an exempt subject's denominator is 0, so there is no percentage.
    v_pct := case when v_row.denominator_marks > 0
                  then round(v_row.obtained_marks * 100 / v_row.denominator_marks, 2)
             end;

    -- AC2: every component's own pass mark. Only a candidate who sat the
    -- paper has marks to compare; an absent or debarred one has none, which
    -- is why the left join reads 0 and names every component with a pass mark.
    if v_row.attendance_status = 'exempt' then
      v_failed := '[]'::jsonb;
    else
      select coalesce(
               jsonb_agg(jsonb_build_object(
                 'component',  c.component,
                 'obtained',   coalesce(m.marks_obtained, 0),
                 'pass_marks', c.pass_marks,
                 'max_marks',  c.max_marks
               ) order by c.sequence),
               '[]'::jsonb)
        into v_failed
        from public.exam_subject_component c
        left join public.mark_entry m
          on m.exam_subject_id = c.exam_subject_id
         and m.component_code = c.component
         and m.enrolment_id = v_row.enrolment_id
       where c.exam_subject_id = v_row.exam_subject_id
         and c.pass_marks > 0
         and coalesce(m.marks_obtained, 0) < c.pass_marks;
    end if;

    -- FR-J01 rounds to two decimals again before matching a band, so the grade
    -- and the printed percentage are read off the same number.
    select b.grade_label, b.gpa_point, b.is_pass
      into v_label, v_gpa, v_band_pass
      from public.fn_grade_for_percentage(v_scheme, v_pct) b;

    -- Nothing to pass or fail: no denominator, or the result is withheld.
    if v_pct is null or v_blocked then
      v_pass := null;
    else
      v_pass := jsonb_array_length(v_failed) = 0 and coalesce(v_band_pass, false);
    end if;

    insert into public.subject_result (
      tenant_id, campus_id, exam_term_id, section_id, exam_subject_id, enrolment_id, subject_id,
      obtained, max_marks, pct, grading_scheme_id, grade_label, gpa_point, is_pass,
      failed_components, report_symbol, is_blocked, computed_at, computed_by
    )
    values (
      v_row.tenant_id, v_row.campus_id, p_exam_term_id, p_section_id,
      v_row.exam_subject_id, v_row.enrolment_id, v_row.subject_id,
      v_row.obtained_marks, v_row.denominator_marks,
      case when v_blocked then null else v_pct end,
      v_scheme,
      case when v_blocked then null else v_label end,
      case when v_blocked then null else v_gpa end,
      v_pass,
      case when v_blocked then '[]'::jsonb else v_failed end,
      v_row.report_symbol,
      coalesce(v_blocked, false),
      clock_timestamp(),
      p_actor
    )
    on conflict (tenant_id, exam_term_id, enrolment_id, subject_id) do update
      set section_id        = excluded.section_id,
          exam_subject_id   = excluded.exam_subject_id,
          obtained          = excluded.obtained,
          max_marks         = excluded.max_marks,
          pct               = excluded.pct,
          grading_scheme_id = excluded.grading_scheme_id,
          grade_label       = excluded.grade_label,
          gpa_point         = excluded.gpa_point,
          is_pass           = excluded.is_pass,
          failed_components = excluded.failed_components,
          report_symbol     = excluded.report_symbol,
          is_blocked        = excluded.is_blocked,
          computed_at       = excluded.computed_at,
          computed_by       = excluded.computed_by;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- The FR's fn_compute_subject_result(p_exam_term_id, p_section_id) returns int:
-- the Exam Controller's explicit recompute, and the gate the automatic path
-- does not need because approval already passed it.
create or replace function public.fn_compute_subject_result(
  p_exam_term_id uuid,
  p_section_id   uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_sec       record;
  v_ready     jsonb;
  v_pending   text;
  v_open      text;
begin
  select id, tenant_id, campus_id into v_sec
    from public.class_section where id = p_section_id;
  if v_sec.id is null then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- The Actors are System and Exam Controller. A null tenant is the System
  -- path (a scheduled job or a migration), the same posture every other
  -- definer function in this module takes.
  if v_tenant_id is not null then
    if v_sec.tenant_id <> v_tenant_id then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if v_role not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if v_role not in ('super_admin', 'owner')
       and not (v_sec.campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  -- FR-I16 AC4's gate, asked rather than restated.
  v_ready := public.fn_term_result_ready(p_exam_term_id, p_section_id);
  if not (v_ready ->> 'ready')::boolean then
    select string_agg(s #>> '{}', ', ')
      into v_pending
      from jsonb_array_elements(v_ready -> 'pending_subjects') s;
    raise exception '%', format('term result computation waits on %s', coalesce(v_pending, 'exam setup for this class'))
      using errcode = '23514',
            detail = format('%s of %s papers locked for this section',
                            v_ready ->> 'locked_count', v_ready ->> 'subject_count'),
            hint = 'Every paper this class sits has to be signed off before its results can be computed.';
  end if;

  -- See the header: FR-I17 stamps staleness once per window, so a recompute
  -- inside an open one would clear a flag a later edit in the same window
  -- could no longer re-raise.
  select sub.name_en into v_open
    from public.v_exam_subject_section vs
    join public.subject sub on sub.id = vs.subject_id
   where vs.exam_term_id = p_exam_term_id
     and vs.section_id = p_section_id
     and app.fn_break_glass_open(vs.exam_subject_id, p_section_id)
   limit 1;
  if v_open is not null then
    raise exception '%', format('marks are open under a break-glass window on %s — recompute when it closes', v_open)
      using errcode = '42501',
            hint = 'A result computed mid-window would be out of date before the window shut.';
  end if;

  return app.fn_compute_subject_result(p_exam_term_id, p_section_id, (select auth.uid()));
end;
$$;

revoke execute on function public.fn_compute_subject_result(uuid, uuid) from public, anon;
grant execute on function public.fn_compute_subject_result(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The FR's trg_enqueue_result_compute
-- ═══════════════════════════════════════════════════════════════════════

-- "computed automatically once marks are locked". FR-I16's migration built
-- fn_term_result_ready() instead of a job queue because there was no engine to
-- consume one; there is now, and the readiness answer is still what decides.
--
-- It computes rather than enqueues because there is no worker in this stack to
-- drain a queue, and a queue table nothing reads is the thing FR-I16 declined
-- to build. Approving the LAST paper of a section is what fires it.
--
-- It must never be able to fail an approval. A school that has not configured
-- a grade scale yet still signs off marks; the result simply waits, and
-- fn_compute_subject_result() says so by name when the controller asks.
create or replace function app.tg_enqueue_result_compute()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session uuid;
  v_on_date date;
begin
  if not (public.fn_term_result_ready(new.exam_term_id, new.section_id) ->> 'ready')::boolean then
    return null;
  end if;

  select t.session_id into v_session from public.exam_term t where t.id = new.exam_term_id;
  select s.starts_on into v_on_date from public.academic_session s where s.id = v_session;

  if app.fn_grading_scheme_for_board(
       new.tenant_id, app.fn_board_for_section(new.section_id), coalesce(v_on_date, current_date)
     ) is null then
    return null;
  end if;

  perform app.fn_compute_subject_result(new.exam_term_id, new.section_id, new.locked_by);
  return null;
end;
$$;

create trigger trg_enqueue_result_compute
  after insert on public.mark_lock
  for each row execute function app.tg_enqueue_result_compute();

-- ═══════════════════════════════════════════════════════════════════════
-- What a screen and FR-J03/J09 read
-- ═══════════════════════════════════════════════════════════════════════

create view public.v_subject_result
with (security_invoker = true) as
select sr.id,
       sr.tenant_id,
       sr.campus_id,
       sr.exam_term_id,
       sr.section_id,
       sr.exam_subject_id,
       sr.enrolment_id,
       sr.subject_id,
       sub.name_en                    as subject_name,
       sub.name_ur                    as subject_name_ur,
       st.name_en                     as student_name,
       st.gr_number,
       e.roll_no,
       sr.obtained,
       sr.max_marks,
       sr.pct,
       sr.grading_scheme_id,
       gs.name                        as grading_scheme_name,
       gs.version                     as grading_scheme_version,
       gs.board,
       sr.grade_label,
       sr.gpa_point,
       sr.is_pass,
       sr.failed_components,
       sr.report_symbol,
       sr.is_blocked,
       sr.computed_at,
       app.fn_result_stale_at(sr.exam_subject_id, sr.section_id) as result_stale_at,
       coalesce(app.fn_result_stale_at(sr.exam_subject_id, sr.section_id) > sr.computed_at, false) as is_stale
  from public.subject_result sr
  join public.subject sub on sub.id = sr.subject_id
  join public.enrolment e on e.id = sr.enrolment_id
  join public.student st on st.id = e.student_id
  left join public.grading_scheme gs on gs.id = sr.grading_scheme_id;

revoke all on public.v_subject_result from public, anon;
grant select on public.v_subject_result to authenticated;

comment on view public.v_subject_result is
  'FR-J02: a computed result with the candidate, the subject, the scale it was graded on, and whether a break-glass edit has made it stale.';

-- The Exam Controller's screen, in one round trip: whether the section is
-- ready, whether anything computed is stale, and every candidate's row.
create or replace function public.fn_subject_result_sheet(
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
  v_sec      record;
  v_role     text := app.auth_role();
  v_ready    jsonb;
  v_scheme   uuid;
  v_board    public.board;
  v_on_date  date;
  v_session  uuid;
  v_students jsonb;
  v_computed timestamptz;
  v_stale    integer := 0;
begin
  select id, tenant_id, campus_id, session_id into v_sec
    from public.class_section where id = p_section_id;
  if v_sec.id is null then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
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

  v_ready := public.fn_term_result_ready(p_exam_term_id, p_section_id);

  select t.session_id into v_session from public.exam_term t where t.id = p_exam_term_id;
  select s.starts_on into v_on_date from public.academic_session s where s.id = v_session;
  v_board := app.fn_board_for_section(p_section_id);
  v_scheme := app.fn_grading_scheme_for_board(v_sec.tenant_id, v_board, coalesce(v_on_date, current_date));

  select coalesce(jsonb_agg(c.payload order by c.roll_no nulls last, c.student_name), '[]'::jsonb),
         max(c.computed_at),
         count(*) filter (where c.any_stale)::int
    into v_students, v_computed, v_stale
    from (
      select st.name_en as student_name,
             e.roll_no,
             max(sr.computed_at) as computed_at,
             bool_or(coalesce(app.fn_result_stale_at(sr.exam_subject_id, sr.section_id) > sr.computed_at, false))
               as any_stale,
             jsonb_build_object(
               'enrolment_id', e.id,
               'roll_no',      e.roll_no,
               'student_name', st.name_en,
               'gr_number',    st.gr_number,
               'is_blocked',   bool_or(sr.is_blocked),
               'subjects',     jsonb_agg(jsonb_build_object(
                                 'subject_id',        sr.subject_id,
                                 'subject_name',      sub.name_en,
                                 'obtained',          sr.obtained,
                                 'max_marks',         sr.max_marks,
                                 'pct',               sr.pct,
                                 'grade_label',       sr.grade_label,
                                 'gpa_point',         sr.gpa_point,
                                 'is_pass',           sr.is_pass,
                                 'failed_components', sr.failed_components,
                                 'report_symbol',     sr.report_symbol,
                                 'is_blocked',        sr.is_blocked,
                                 'is_stale',          coalesce(
                                    app.fn_result_stale_at(sr.exam_subject_id, sr.section_id) > sr.computed_at,
                                    false)
                               ) order by sub.name_en)
             ) as payload
        from public.subject_result sr
        join public.subject sub on sub.id = sr.subject_id
        join public.enrolment e on e.id = sr.enrolment_id
        join public.student st on st.id = e.student_id
       where sr.exam_term_id = p_exam_term_id
         and sr.section_id = p_section_id
       group by e.id, e.roll_no, st.name_en, st.gr_number
    ) c;

  return jsonb_build_object(
    'exam_term_id',   p_exam_term_id,
    'section_id',     p_section_id,
    'readiness',      v_ready,
    'board',          v_board,
    'grading_scheme', (select jsonb_build_object('id', gs.id, 'name', gs.name, 'version', gs.version)
                         from public.grading_scheme gs where gs.id = v_scheme),
    'can_compute',    app.auth_tenant_id() is null
                        or v_role in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller'),
    'computed_at',    v_computed,
    'stale_count',    v_stale,
    'candidates',     v_students
  );
end;
$$;

revoke execute on function public.fn_subject_result_sheet(uuid, uuid) from public, anon;
grant execute on function public.fn_subject_result_sheet(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.subject_result enable row level security;

-- The FR's subject_result_campus_scope. Parents are excluded here and read
-- through the policy below instead, the same split FR-C11 applied to student,
-- enrolment, fee_challan and attendance_day.
create policy subject_result_campus_scope on public.subject_result
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() <> 'parent'
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- The FR's subject_result_parent_own_child, reusing FR-C11's predicate rather
-- than restating it.
create policy subject_result_parent_own_child on public.subject_result
  for select to authenticated
  using (
    enrolment_id in (
      select id from public.enrolment where student_id = any(app.auth_guardian_student_ids())
    )
  );

-- A computed result is not a hand-edited one. There is no INSERT, UPDATE or
-- DELETE policy: fn_compute_subject_result() is the only writer, and a
-- correction is a recompute of the marks it came from, not an edit of the
-- number it produced.
