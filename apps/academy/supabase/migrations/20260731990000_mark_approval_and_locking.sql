-- FR-I16: mark approval and locking.
--
-- "As an Exam Controller, I want to approve a section's marks and have them
-- become read-only, so that nobody edits a result after it has been signed
-- off."
--
-- The requirement in one sentence: move a section's marks for an exam_subject
-- to 'locked' only on an explicit approval action, and thereafter reject every
-- write to those rows from EVERY role — the entering teacher, the Exam
-- Controller who approved them, service_role jobs and the table owner.
--
-- Three earlier migrations built the seams this one drives, and it adds no
-- second mechanism beside any of them:
--
--   FR-I01 (20260731950000) shipped lock_exam_term() with the note "Nothing
--     but tests calls this until mark approval exists". It is called here, for
--     the reason FR-I01 predicted — see AC4 below for exactly when.
--   FR-I12 (20260731970000) shipped mark_status with all five values and
--     wrote only 'draft', and trg_mark_entry_frozen already biting on
--     'approved'/'locked'. This migration is the driver that was missing.
--   FR-I11 (20260731980000) shipped exam_attendance, which is what makes AC1's
--     completeness question answerable at all: a candidate with no mark is not
--     necessarily an incomplete candidate.
--
-- ── The granularity, and how it reconciles with a term-level lock ──────
--
-- Approval is per (exam_subject, section). That is what the acceptance
-- criteria describe ("a section's marks", "40 candidates"), what the FR's own
-- uq_mark_lock (exam_subject_id, section_id) says, and the only granularity
-- that matches who signs off: 9-B Maths is one teacher's paper for one hall,
-- and it is ready when it is ready regardless of whether 10-A Chemistry is.
--
-- exam_subject is per (exam_term, class_subject) — per CLASS, not per section
-- — because three sections of Class 9 share one curriculum row and therefore
-- one component configuration (FR-I02's AC3). So one exam_subject spans
-- several sections and each is approved separately. v_exam_subject_section
-- below is that fan-out, resolved once here rather than re-derived by every
-- caller; it is the same class-level/stream resolution FR-I11's
-- v_exam_result_input already uses.
--
-- lock_exam_term(), by contrast, is term-wide and freezes weightage, component
-- setup, exam attendance and every mark in the term at once. Calling it on the
-- first section approved would freeze papers nobody has marked yet. So the two
-- granularities are reconciled by ORDER rather than by choosing one:
--
--   * every approval writes a mark_lock row and locks that section's marks;
--   * the LAST approval in a term — the one after which no (exam_subject,
--     section) pair in the term is left unlocked — additionally calls
--     lock_exam_term(). At that moment there is nothing left to enter, so the
--     term-wide freeze costs nothing and closes the weightage, the components
--     and the attendance statuses the results were computed against.
--
-- AC4's "when EVERY subject in a term is locked FOR A CLASS" is a narrower
-- question than that — it is per section, and it is answered per section by
-- fn_term_result_ready(). A class whose subjects are all locked can have its
-- results computed while another class is still marking. Both are real and
-- they are different questions; conflating them would either delay one class's
-- results on another's account or freeze the term far too early.
--
-- ── AC3: 'marks_locked', and why it is a trigger ──────────────────────
--
-- The FR's Notes are explicit and correct: "the result recompute job, the OCR
-- promoter and any CSV import run as service role and bypass RLS entirely, so
-- a policy-only lock is not a lock." trg_mark_entry_block_when_locked fires
-- BEFORE INSERT OR UPDATE OR DELETE FOR EACH ROW regardless of caller, so
-- service_role's BYPASSRLS and the table owner's ownership both buy nothing.
-- The FR's suggested marks_locked_readonly policy is therefore deliberately
-- NOT created — the same call FR-I12 made about the same policy, for the same
-- reason, and here the FR's own Notes make the argument.
--
-- INSERT is guarded alongside UPDATE and DELETE even though the FR names only
-- the latter two. A row added to a signed-off set is an edit to that set: it
-- changes the candidate's total and the section's aggregate exactly as
-- changing an existing mark does, and leaving the door open would mean the
-- lock could be walked around by clearing a cell before locking and adding it
-- after.
--
-- The message is 'marks_locked', the acceptance criterion's own token, on
-- errcode 42501. Not SQLSTATE class 55: PostgREST maps class 55 to HTTP 500
-- and replaces the body with {"message":"Something went wrong"} (verified
-- against this stack in FR-I01's migration), and a refusal the caller has to
-- be able to tell apart from a server fault cannot travel on a code that
-- strips it. 42501 maps to 403 with the message intact, and is already what
-- FR-I01, FR-I02, FR-I11, FR-I12 and FR-T08 use for the equivalent refusal.
--
-- FR-I12's trg_mark_entry_frozen still exists and still raises its own
-- sentence. The two do not overlap by accident:
--
--   * trg_mark_entry_block_when_locked fires FIRST (BEFORE row triggers fire
--     in name order, and 'b' < 'f') and answers for a set that has been
--     approved — the case where 'marks_locked' is the truthful answer and
--     where FR-I17's break-glass path is the way through.
--   * trg_mark_entry_frozen answers for a term frozen as a whole, whether by
--     lock_exam_term() or by academic_session.result_locked_at, and keeps
--     pointing at the result-recompute request.
--
-- ── AC1: what "complete" means ────────────────────────────────────────
--
-- "40 candidates of whom 2 have neither a mark nor an attendance status."
-- Completeness is asked per candidate and answered in FR-I11's vocabulary:
--
--   * a candidate recorded absent, exempt or debarred is COMPLETE. There is
--     nothing to enter for them and trg_block_marks_when_not_present refuses a
--     mark for them outright, so demanding one would make the set
--     unapprovable.
--   * every other candidate must have a mark for EVERY configured component.
--     A paper with theory and practical is not signed off with the practicals
--     missing; the result engine would divide by a denominator that includes
--     marks nobody entered.
--
-- The two failures are reported separately because they need different
-- actions. AC1's candidates — nothing entered and no status — get the AC's own
-- sentence with their GR numbers in it. A candidate with theory but no
-- practical gets a second sentence naming the missing component. Both are
-- built as text rather than as a translated code, for the reason FR-I01 gave
-- for its weightage total: the acceptance criterion asserts the LISTING, and a
-- code the UI expands cannot list rows the database found.
--
-- fn_mark_approval_queue() answers the same question without attempting
-- anything, so the controller sees the two GR numbers before clicking rather
-- than as the result of a refusal.
--
-- ── mark_lock is append-only, and that is not decoration ──────────────
--
-- A lock row that can be deleted is not a lock: dropping it would silently
-- return a signed-off set to editable with nothing on the record. So it gets
-- the guard FR-T02 established and FR-T08/FR-T09 extended, layer for layer:
--
--   1. RLS. SELECT is campus-scoped. UPDATE gets a policy whose USING is the
--      SELECT predicate verbatim and whose WITH CHECK is false — so an
--      authenticated caller reaches the trigger and is TOLD, rather than
--      handed a silent `UPDATE 0` (FR-T08's argument, and no row is offered
--      that the caller could not already read). DELETE stays USING false.
--   2. trg_mark_lock_no_update / _no_delete fire FOR EACH ROW regardless of
--      caller, so service_role and the table owner are refused too.
--   3. trg_mark_lock_no_truncate, because TRUNCATE fires no row trigger and
--      consults no RLS — FR-T08's finding, and a real hole without it.
--
-- This migration ships NO legal UPDATE transition at all: nothing here has any
-- business changing an approval after the fact. unlock_state exists (the FR
-- names it) and cannot move, which is the honest state of affairs until
-- FR-I17. When break-glass arrives it must add NAMED transitions with their
-- own stack frames — FR-T09's precedent, stated there as "never as a
-- relaxation of the frozen set" — not soften this guard.
--
-- No mark_lock_audit table: public.audit_log + app.tg_audit_row() already
-- records before/after/changed_columns/actor for every table here, hash
-- chained and verified by FR-T14, and a second narrower trail is a place for
-- the two to disagree (FR-I01's and FR-I12's call, kept).
--
-- ── "enqueue result compute", honestly ────────────────────────────────
--
-- The FR's description of fn_approve_marks ends with "enqueue result compute".
-- There is no result engine in this schema — FR-J02 is a later FR — and no job
-- queue for one to consume. Rather than write to a table nothing reads, what
-- this migration builds is the READINESS the engine will ask for:
-- fn_term_result_ready(exam_term, section) is AC4's gate, computed from
-- mark_lock rather than stored, so it cannot go stale and needs no worker to
-- keep it true.
--
-- ── One change to an existing trigger ─────────────────────────────────
--
-- app.tg_mark_range_check() is re-emitted so its three VALUE rules (negative,
-- above the component maximum, more decimals than the campus allows) run only
-- when the value actually changes. Approval updates status and touches no
-- mark, and without this a campus that lowered mark_precision after entry — or
-- an exam office that trimmed a component's maximum — would find a section
-- unapprovable with "whole numbers only" pointing at a mark nobody is editing.
-- FR-I12's own pgTAP already asserts the principle ("the 45.5 already entered
-- is not retro-actively refused"); this extends it from a later INSERT to a
-- later status transition. Everything else in the trigger — the exam-subject
-- resolution, the enrolment/class check, the tenant/campus derivation — still
-- runs on every write.

-- ═══════════════════════════════════════════════════════════════════════
-- Schema
-- ═══════════════════════════════════════════════════════════════════════

-- The FR's unlock_state. 'locked' is the only value this migration ever
-- writes; FR-I17's break-glass window is what moves it and back again.
create type public.mark_unlock_state as enum ('locked', 'unlocked');

create table public.mark_lock (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  -- Derivable from exam_subject_id and deliberately carried anyway: AC4 and
  -- the approval queue both ask "what is locked in this term", and an
  -- exam_subject never moves between terms.
  exam_term_id    uuid not null references public.exam_term(id) on delete cascade,
  exam_subject_id uuid not null references public.exam_subject(id) on delete cascade,
  section_id      uuid not null references public.class_section(id) on delete cascade,
  locked_by       uuid references public.app_user(user_id),
  locked_at       timestamptz not null default clock_timestamp(),
  -- What was signed off, as of the moment of signing. Kept so a later
  -- discrepancy is visible without replaying the audit log.
  candidate_count integer not null,
  mark_count      integer not null,
  unlock_state    public.mark_unlock_state not null default 'locked',
  created_at      timestamptz not null default now()
);

-- The FR's index, spelled as the FR spells it.
create unique index uq_mark_lock on public.mark_lock (exam_subject_id, section_id);
create index idx_mark_lock_term_section on public.mark_lock (exam_term_id, section_id);
create index idx_mark_lock_campus on public.mark_lock (tenant_id, campus_id);

create trigger mark_lock_audit after insert or update or delete on public.mark_lock
  for each row execute function app.tg_audit_row();

comment on table public.mark_lock is
  'FR-I16: one row per approved (exam_subject, section). Append-only — a lock row that can be removed is not a lock. FR-I17 moves unlock_state and nothing else ever does.';
comment on column public.mark_lock.unlock_state is
  'FR-I16 writes only ''locked''. FR-I17''s break-glass window is the only thing that moves it, through a named transition in the append-only guard.';

-- ═══════════════════════════════════════════════════════════════════════
-- The (exam_subject -> section) fan-out, resolved once
-- ═══════════════════════════════════════════════════════════════════════

-- One row per paper a section actually sits. The join is FR-I11's
-- v_exam_result_input's, verbatim in shape: a stream-less curriculum row
-- applies to every section of the class, a stream-specific one only to the
-- sections in that stream.
create view public.v_exam_subject_section
with (security_invoker = true) as
select es.id             as exam_subject_id,
       es.tenant_id,
       es.campus_id,
       es.exam_term_id,
       es.class_subject_id,
       cs.subject_id,
       cs.class_level_id,
       cs.stream_id,
       sec.id            as section_id,
       sec.name          as section_name,
       l.id              as mark_lock_id,
       l.locked_at,
       l.locked_by,
       l.unlock_state,
       l.id is not null  as is_locked
  from public.exam_subject es
  join public.class_subject cs on cs.id = es.class_subject_id
  join public.class_section sec
    on sec.tenant_id = cs.tenant_id
   and sec.campus_id = cs.campus_id
   and sec.session_id = cs.session_id
   and sec.class_level_id = cs.class_level_id
   and (cs.stream_id is null or cs.stream_id = sec.stream_id)
   and sec.is_active
  left join public.mark_lock l
    on l.exam_subject_id = es.id and l.section_id = sec.id;

revoke all on public.v_exam_subject_section from public, anon;
grant select on public.v_exam_subject_section to authenticated;

comment on view public.v_exam_subject_section is
  'FR-I16: one row per (paper, section). exam_subject is per class; approval is per section, so this is the fan-out both the approval queue and the term-lock check read.';

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the lock, enforced where a service-role job cannot walk past it
-- ═══════════════════════════════════════════════════════════════════════

-- The single predicate. FR-I17 replaces this body to subtract an open
-- break-glass window; every caller below asks it rather than restating the
-- rule, so that replacement is one function.
create or replace function app.fn_marks_locked(
  p_exam_subject_id uuid,
  p_section_id      uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.mark_lock l
     where l.exam_subject_id = p_exam_subject_id
       and l.section_id = p_section_id
  );
$$;

-- The same question from a mark_entry row, which carries an enrolment rather
-- than a section.
create or replace function app.fn_mark_entry_locked(p_mark_entry_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select app.fn_marks_locked(m.exam_subject_id, e.section_id)
       from public.mark_entry m
       join public.enrolment e on e.id = m.enrolment_id
      where m.id = p_mark_entry_id),
    false
  );
$$;

create or replace function app.tg_mark_entry_block_when_locked()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_row        record;
  v_section_id uuid;
begin
  v_row := case when tg_op = 'DELETE' then old else new end;

  select e.section_id into v_section_id
    from public.enrolment e where e.id = v_row.enrolment_id;

  if v_section_id is not null
     and app.fn_marks_locked(v_row.exam_subject_id, v_section_id) then
    -- AC3's own token. See the header for why not SQLSTATE class 55.
    raise exception 'marks_locked'
      using errcode = '42501',
            detail = format('%s on mark_entry for exam_subject %s, section %s (enrolment %s, component %s)',
                            tg_op, v_row.exam_subject_id, v_section_id,
                            v_row.enrolment_id, v_row.component_code),
            hint = 'These marks were approved and signed off. A correction needs a break-glass unlock.';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- Fires ahead of trg_mark_entry_frozen (BEFORE row triggers fire in name
-- order), so an approved set answers 'marks_locked' rather than the term
-- freeze's sentence. See the header for why INSERT is in the list.
create trigger trg_mark_entry_block_when_locked
  before insert or update or delete on public.mark_entry
  for each row execute function app.tg_mark_entry_block_when_locked();

-- ═══════════════════════════════════════════════════════════════════════
-- mark_lock is append-only
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY INVOKER on purpose, exactly as FR-T02's and FR-T08's guards:
-- current_user must still report the executing context, so "the caller is the
-- table owner" means "we are inside a SECURITY DEFINER function running as the
-- owner" and not "a logged-in role".
--
-- This migration's allow-list is EMPTY — every UPDATE is refused. FR-I17 adds
-- named transitions here; nothing else may.
create or replace function app.tg_mark_lock_no_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'mark approval is append-only'
    using errcode = '42501',
          detail = format('update of mark_lock id=%s exam_subject=%s section=%s by %s',
                          old.id, old.exam_subject_id, old.section_id, current_user),
          hint = 'An approval is a signature, not a setting. Reopening a locked set is a break-glass unlock.';
end;
$$;

create trigger trg_mark_lock_no_update
  before update on public.mark_lock
  for each row execute function app.tg_mark_lock_no_update();

create or replace function app.tg_mark_lock_no_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'mark approval is append-only'
    using errcode = '42501',
          detail = format('delete of mark_lock id=%s exam_subject=%s section=%s by %s',
                          old.id, old.exam_subject_id, old.section_id, current_user),
          hint = 'Removing a lock row would silently return signed-off marks to editable with nothing on the record.';
end;
$$;

create trigger trg_mark_lock_no_delete
  before delete on public.mark_lock
  for each row execute function app.tg_mark_lock_no_delete();

-- TRUNCATE fires no row-level trigger and is filtered by no RLS policy, so an
-- append-only table that guards only DELETE can still be emptied in one
-- statement by anyone holding it. FR-T08's finding; it must be its own
-- statement-level trigger because there is nowhere else to catch it.
create or replace function app.tg_mark_lock_no_truncate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'mark approval is append-only'
    using errcode = '42501',
          detail = format('truncate of mark_lock by %s', current_user),
          hint = 'Every approval this school ever made stays on the record.';
end;
$$;

create trigger trg_mark_lock_no_truncate
  before truncate on public.mark_lock
  for each statement execute function app.tg_mark_lock_no_truncate();

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: completeness, asked without attempting anything
-- ═══════════════════════════════════════════════════════════════════════

-- Returns {complete, candidate_count, mark_count, not_started:[gr...],
-- partial:[{gr_number, missing:[component...]}]} for one (paper, section).
--
-- SECURITY DEFINER, so the tenant/campus scope and the soft-delete filters are
-- written out in SQL: a definer function owned by postgres bypasses RLS
-- entirely (FR-K24's finding, b16ba25's convention).
create or replace function app.fn_mark_completeness(
  p_exam_subject_id uuid,
  p_section_id      uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_components  public.mark_component_code[];
  v_candidates  integer := 0;
  v_marks       integer := 0;
  v_not_started jsonb;
  v_partial     jsonb;
begin
  select array_agg(c.component order by c.sequence) into v_components
    from public.exam_subject_component c
   where c.exam_subject_id = p_exam_subject_id;

  select count(*)::int into v_candidates
    from public.enrolment e
    join public.student st on st.id = e.student_id
   where e.section_id = p_section_id
     and e.status = 'active'
     and e.deleted_at is null
     and st.deleted_at is null;

  select count(*)::int into v_marks
    from public.mark_entry m
    join public.enrolment e on e.id = m.enrolment_id
   where m.exam_subject_id = p_exam_subject_id
     and e.section_id = p_section_id;

  with candidate as (
    select e.id as enrolment_id, st.gr_number, e.roll_no, st.name_en,
           coalesce(a.status, 'present') as exam_status
      from public.enrolment e
      join public.student st on st.id = e.student_id
      left join public.exam_attendance a
        on a.exam_subject_id = p_exam_subject_id and a.enrolment_id = e.id
     where e.section_id = p_section_id
       and e.status = 'active'
       and e.deleted_at is null
       and st.deleted_at is null
  ),
  -- A candidate who did not sit the paper is complete: there is nothing to
  -- enter and trg_block_marks_when_not_present would refuse it anyway.
  sitting as (
    select c.*,
           (select array_agg(comp order by comp)
              from unnest(coalesce(v_components, '{}'::public.mark_component_code[])) as comp
             where not exists (
               select 1 from public.mark_entry m
                where m.exam_subject_id = p_exam_subject_id
                  and m.enrolment_id = c.enrolment_id
                  and m.component_code = comp)) as missing
      from candidate c
     where c.exam_status = 'present'
  )
  select
    coalesce(jsonb_agg(jsonb_build_object('gr_number', s.gr_number, 'roll_no', s.roll_no,
                                          'student_name', s.name_en)
                       order by s.roll_no nulls last, s.gr_number)
             filter (where array_length(s.missing, 1) = array_length(v_components, 1)),
             '[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object('gr_number', s.gr_number, 'roll_no', s.roll_no,
                                          'student_name', s.name_en,
                                          'missing', to_jsonb(s.missing))
                       order by s.roll_no nulls last, s.gr_number)
             filter (where s.missing is not null
                       and array_length(s.missing, 1) < array_length(v_components, 1)),
             '[]'::jsonb)
    into v_not_started, v_partial
    from sitting s;

  return jsonb_build_object(
    'components',      to_jsonb(coalesce(v_components, '{}'::public.mark_component_code[])),
    'candidate_count', v_candidates,
    'mark_count',      v_marks,
    'not_started',     v_not_started,
    'partial',         v_partial,
    'complete',        jsonb_array_length(v_not_started) = 0
                       and jsonb_array_length(v_partial) = 0
                       and v_components is not null
  );
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: "term result computation becomes available for that class"
-- ═══════════════════════════════════════════════════════════════════════

-- Computed from mark_lock rather than stored, so it cannot go stale and needs
-- no worker to keep it true. This is what FR-J02 will ask before computing.
create or replace function public.fn_term_result_ready(
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
  v_sec     record;
  v_total   integer;
  v_locked  integer;
  v_pending jsonb;
begin
  select id, tenant_id, campus_id into v_sec
    from public.class_section where id = p_section_id;
  if v_sec.id is null then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_tenant_id() is not null then
    if v_sec.tenant_id <> app.auth_tenant_id() then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if app.auth_role() not in ('super_admin', 'owner')
       and not (v_sec.campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  select count(*)::int,
         count(*) filter (where vs.is_locked)::int,
         coalesce(jsonb_agg(sub.name_en order by sub.name_en) filter (where not vs.is_locked), '[]'::jsonb)
    into v_total, v_locked, v_pending
    from public.v_exam_subject_section vs
    join public.subject sub on sub.id = vs.subject_id
   where vs.exam_term_id = p_exam_term_id
     and vs.section_id = p_section_id;

  return jsonb_build_object(
    'exam_term_id',    p_exam_term_id,
    'section_id',      p_section_id,
    'subject_count',   v_total,
    'locked_count',    v_locked,
    'pending_subjects', v_pending,
    -- A section with no configured papers is not "ready", it is unconfigured.
    'ready',           v_total > 0 and v_locked = v_total
  );
end;
$$;

revoke execute on function public.fn_term_result_ready(uuid, uuid) from public, anon;
grant execute on function public.fn_term_result_ready(uuid, uuid) to authenticated;

-- The controller's queue: every paper this section sits in this term, with its
-- lock state and exactly what is blocking approval. AC1's two GR numbers are
-- visible here BEFORE anyone clicks approve.
create or replace function public.fn_mark_approval_queue(
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
  v_sec    record;
  v_role   text := app.auth_role();
  v_rows   jsonb;
begin
  select id, tenant_id, campus_id into v_sec
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

  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'exam_subject_id', vs.exam_subject_id,
               'subject_id',      vs.subject_id,
               'subject_name',    sub.name_en,
               'is_locked',       vs.is_locked,
               'locked_at',       vs.locked_at,
               'locked_by_name',  locker.full_name,
               'unlock_state',    vs.unlock_state,
               'completeness',    app.fn_mark_completeness(vs.exam_subject_id, p_section_id)
             ) order by sub.name_en
           ),
           '[]'::jsonb
         )
    into v_rows
    from public.v_exam_subject_section vs
    join public.subject sub on sub.id = vs.subject_id
    left join public.app_user locker on locker.user_id = vs.locked_by
   where vs.exam_term_id = p_exam_term_id
     and vs.section_id = p_section_id;

  return jsonb_build_object(
    'exam_term_id', p_exam_term_id,
    'section_id',   p_section_id,
    'can_approve',  app.auth_tenant_id() is null
                      or v_role in ('super_admin', 'owner', 'principal', 'exam_controller'),
    'subjects',     v_rows,
    'result_ready', public.fn_term_result_ready(p_exam_term_id, p_section_id)
  );
end;
$$;

revoke execute on function public.fn_mark_approval_queue(uuid, uuid) from public, anon;
grant execute on function public.fn_mark_approval_queue(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC1 / AC2: the approval itself
-- ═══════════════════════════════════════════════════════════════════════

-- The role gate is FR-I01's lock_exam_term() gate, spelled identically and on
-- purpose: this function calls that one, and an approver who could not lock
-- the term would produce a set that approves the first section and then fails
-- on the last.
create or replace function public.fn_approve_marks(
  p_exam_subject_id uuid,
  p_section_id      uuid
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
  v_es          record;
  v_pair        record;
  v_check       jsonb;
  v_names       text;
  v_count       integer;
  v_marks       integer;
  v_lock_id     uuid;
  v_term_status public.exam_term_status;
  v_unlocked    integer;
  v_term_locked boolean := false;
begin
  if v_tenant_id is null
     or v_role not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select es.id, es.tenant_id, es.campus_id, es.exam_term_id
    into v_es
    from public.exam_subject es
   where es.id = p_exam_subject_id and es.tenant_id = v_tenant_id;
  if v_es.id is null then
    raise exception 'EXAM_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner')
     and not (v_es.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- The section must actually sit this paper. v_exam_subject_section is the
  -- resolution; asking it here means the approval and the queue can never
  -- disagree about which sections a paper covers.
  select vs.exam_subject_id, vs.section_id, vs.is_locked
    into v_pair
    from public.v_exam_subject_section vs
   where vs.exam_subject_id = p_exam_subject_id and vs.section_id = p_section_id;
  if v_pair.exam_subject_id is null then
    raise exception 'SECTION_NOT_IN_EXAM_SUBJECT' using errcode = '23514',
      detail = 'That section does not sit this paper — check the class and stream.';
  end if;
  if v_pair.is_locked then
    raise exception 'MARKS_ALREADY_APPROVED' using errcode = '23505',
      detail = format('exam_subject %s, section %s', p_exam_subject_id, p_section_id),
      hint = 'A set is signed off once. Reopening it is a break-glass unlock.';
  end if;

  v_check := app.fn_mark_completeness(p_exam_subject_id, p_section_id);

  if jsonb_array_length(v_check -> 'components') = 0 then
    raise exception 'EXAM_SETUP_PENDING' using errcode = '55000',
      detail = 'This paper has no components configured, so it has no denominator to sign off.';
  end if;

  -- AC1, in the acceptance criteria's own terms and with the GR numbers in
  -- the message rather than behind a code the UI would have to expand.
  if jsonb_array_length(v_check -> 'not_started') > 0 then
    select string_agg(c ->> 'gr_number', ', ' order by c ->> 'gr_number'), count(*)
      into v_names, v_count
      from jsonb_array_elements(v_check -> 'not_started') as c;
    raise exception '%',
      format('%s candidate%s %s neither a mark nor an exam status: %s',
             v_count, case when v_count = 1 then '' else 's' end,
             case when v_count = 1 then 'has' else 'have' end, v_names)
      using errcode = '23514',
            detail = format('exam_subject %s, section %s', p_exam_subject_id, p_section_id),
            hint = 'Enter their marks, or record them as absent, exempt or debarred.';
  end if;

  if jsonb_array_length(v_check -> 'partial') > 0 then
    select string_agg(format('%s (%s)', c ->> 'gr_number',
                             (select string_agg(m #>> '{}', ', ')
                                from jsonb_array_elements(c -> 'missing') as m)),
                      ', ' order by c ->> 'gr_number'),
           count(*)
      into v_names, v_count
      from jsonb_array_elements(v_check -> 'partial') as c;
    raise exception '%',
      format('%s candidate%s %s missing a component mark: %s',
             v_count, case when v_count = 1 then '' else 's' end,
             case when v_count = 1 then 'is' else 'are' end, v_names)
      using errcode = '23514',
            detail = format('exam_subject %s, section %s', p_exam_subject_id, p_section_id),
            hint = 'Every component of the paper needs a mark before the set can be signed off.';
  end if;

  -- AC2. The status transition runs BEFORE the lock row is written, because
  -- trg_mark_entry_block_when_locked would otherwise refuse this very update.
  -- Approval moves marks straight to 'locked': in this FR approval IS the
  -- lock (the requirement's own wording), and a separate 'approved' resting
  -- state would be one nothing transitions out of.
  update public.mark_entry m
     set status = 'locked'
    from public.enrolment e
   where e.id = m.enrolment_id
     and m.exam_subject_id = p_exam_subject_id
     and e.section_id = p_section_id;
  get diagnostics v_marks = row_count;

  insert into public.mark_lock (
    tenant_id, campus_id, exam_term_id, exam_subject_id, section_id,
    locked_by, candidate_count, mark_count
  ) values (
    v_es.tenant_id, v_es.campus_id, v_es.exam_term_id, p_exam_subject_id, p_section_id,
    v_uid, (v_check ->> 'candidate_count')::int, v_marks
  )
  returning id into v_lock_id;

  -- FR-I01's seam, called at the only moment it is safe to: when nothing in
  -- the term is left to mark. See the header — a term-wide freeze on the
  -- FIRST approval would shut papers nobody has started.
  select count(*)::int into v_unlocked
    from public.v_exam_subject_section vs
   where vs.exam_term_id = v_es.exam_term_id
     and not vs.is_locked;

  select status into v_term_status from public.exam_term where id = v_es.exam_term_id;
  if v_unlocked = 0 and v_term_status = 'active' then
    perform public.lock_exam_term(v_es.exam_term_id);
    v_term_locked := true;
  end if;

  return jsonb_build_object(
    'mark_lock_id',     v_lock_id,
    'exam_subject_id',  p_exam_subject_id,
    'section_id',       p_section_id,
    'candidate_count',  (v_check ->> 'candidate_count')::int,
    'marks_locked',     v_marks,
    'term_locked',      v_term_locked,
    'result_ready',     public.fn_term_result_ready(v_es.exam_term_id, p_section_id)
  );
end;
$$;

revoke execute on function public.fn_approve_marks(uuid, uuid) from public, anon;
grant execute on function public.fn_approve_marks(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- FR-I12's range check, re-emitted
-- ═══════════════════════════════════════════════════════════════════════

-- Same signature, same body, one guard added: the three VALUE rules run only
-- when the value actually changes. See the header for why. Everything else —
-- the exam-subject resolution, the enrolment/class check, the tenant/campus
-- derivation and updated_at — still runs on every write.
create or replace function app.tg_mark_range_check()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_max       integer;
  v_es        record;
  v_enrol     record;
  v_precision smallint;
begin
  select es.id, es.tenant_id, es.campus_id, es.class_subject_id, t.session_id
    into v_es
    from public.exam_subject es
    join public.exam_term t on t.id = es.exam_term_id
   where es.id = new.exam_subject_id;
  if v_es.id is null then
    raise exception 'EXAM_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select max_marks into v_max
    from public.exam_subject_component
   where exam_subject_id = new.exam_subject_id and component = new.component_code;
  if v_max is null then
    raise exception 'MARK_COMPONENT_NOT_CONFIGURED' using errcode = '23514',
      detail = format('%s is not a configured component of this exam subject.', new.component_code);
  end if;

  select e.id, e.section_id, e.class_level_id, e.campus_id, e.session_id
    into v_enrol
    from public.enrolment e
   where e.id = new.enrolment_id and e.deleted_at is null;
  if v_enrol.id is null then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (
    select 1
      from public.class_subject cs
     where cs.id = v_es.class_subject_id
       and cs.campus_id = v_enrol.campus_id
       and cs.session_id = v_enrol.session_id
       and cs.class_level_id = v_enrol.class_level_id
  ) then
    raise exception 'MARK_ENROLMENT_MISMATCH' using errcode = '23514',
      detail = 'That candidate is not in the class this exam subject is configured for.';
  end if;

  -- FR-I16: a mark that is not being typed is not re-judged. A status
  -- transition, or any other update that leaves the number alone, must not be
  -- refused by a rule that changed after the mark was entered.
  if tg_op = 'INSERT' or new.marks_obtained is distinct from old.marks_obtained then
    if new.marks_obtained < 0 then
      raise exception 'marks cannot be negative' using errcode = '23514';
    end if;

    if new.marks_obtained > v_max then
      raise exception 'max %', v_max
        using errcode = '23514',
              detail = format('%s of a maximum of %s for %s',
                              new.marks_obtained, v_max, new.component_code);
    end if;

    v_precision := app.fn_mark_precision(v_es.campus_id);
    if new.marks_obtained <> round(new.marks_obtained, v_precision) then
      if v_precision = 0 then
        raise exception 'whole numbers only' using errcode = '23514';
      end if;
      raise exception '%',
        format('at most %s decimal place%s', v_precision, case v_precision when 1 then '' else 's' end)
        using errcode = '23514';
    end if;
  end if;

  new.tenant_id := v_es.tenant_id;
  new.campus_id := v_es.campus_id;
  new.updated_at := now();
  return new;
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: "the teacher's grid renders read-only on the next load"
-- ═══════════════════════════════════════════════════════════════════════

-- Same three-argument signature as FR-I11's definition, so this is a genuine
-- replacement rather than a second overload — the defaulted-argument ambiguity
-- FR-G05 had to drop-and-recreate around does not arise.
--
-- Two additions: `lock`, so the grid can say WHO signed the set off and when,
-- and can_enter now answers the question the grid actually asks — "may I type
-- here" — which a locked set answers no to for everyone, the approving
-- controller included.
create or replace function public.fn_mark_entry_sheet(
  p_exam_term_id uuid,
  p_section_id   uuid,
  p_subject_id   uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_readiness jsonb;
  v_es_id     uuid;
  v_campus_id uuid;
  v_students  jsonb;
  v_lock      jsonb;
  v_locked    boolean := false;
begin
  v_readiness := public.fn_exam_entry_readiness(p_exam_term_id, p_section_id, p_subject_id);
  v_es_id := nullif(v_readiness ->> 'exam_subject_id', '')::uuid;

  select campus_id into v_campus_id from public.class_section where id = p_section_id;

  if v_es_id is not null then
    v_locked := app.fn_marks_locked(v_es_id, p_section_id);
    select jsonb_build_object(
             'locked_at',      l.locked_at,
             'locked_by',      l.locked_by,
             'locked_by_name', u.full_name,
             'unlock_state',   l.unlock_state,
             'candidate_count', l.candidate_count,
             'mark_count',     l.mark_count
           )
      into v_lock
      from public.mark_lock l
      left join public.app_user u on u.user_id = l.locked_by
     where l.exam_subject_id = v_es_id and l.section_id = p_section_id;
  end if;

  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'enrolment_id',      s.enrolment_id,
               'roll_no',           s.roll_no,
               'student_name',      s.student_name,
               'gr_number',         s.gr_number,
               'marks',             s.marks,
               'status',            s.mark_status,
               'attendance_status', s.attendance_status,
               'absence_reason',    s.absence_reason,
               'report_symbol',     s.report_symbol
             )
             order by s.roll_no nulls last, s.student_name
           ),
           '[]'::jsonb
         )
    into v_students
    from (
      select e.id                as enrolment_id,
             e.roll_no,
             st.name_en          as student_name,
             st.gr_number,
             coalesce(
               (select jsonb_object_agg(m.component_code, m.marks_obtained)
                  from public.mark_entry m
                 where m.exam_subject_id = v_es_id and m.enrolment_id = e.id),
               '{}'::jsonb
             )                   as marks,
             (select max(m.status::text)
                from public.mark_entry m
               where m.exam_subject_id = v_es_id and m.enrolment_id = e.id) as mark_status,
             coalesce(a.status::text, 'present')                            as attendance_status,
             a.reason::text                                                 as absence_reason,
             case a.status
               when 'absent'   then 'AB'
               when 'exempt'   then 'EX'
               when 'debarred' then 'DEB'
               else null
             end                                                            as report_symbol
        from public.enrolment e
        join public.student st on st.id = e.student_id
        left join public.exam_attendance a
          on a.exam_subject_id = v_es_id and a.enrolment_id = e.id
       where e.section_id = p_section_id
         and e.status = 'active'
         and e.deleted_at is null
         and st.deleted_at is null
    ) s;

  return v_readiness
    || jsonb_build_object(
         'can_enter',      app.fn_can_enter_marks(v_es_id, p_section_id) and not v_locked,
         'mark_precision', app.fn_mark_precision(v_campus_id),
         'can_exempt',     app.auth_tenant_id() is null
                             or app.auth_role() in ('super_admin', 'owner', 'principal',
                                                    'vice_principal', 'exam_controller'),
         -- FR-I16. A grid that is read-only because the set was signed off
         -- says so differently from one that is read-only because the caller
         -- does not teach the class.
         'is_locked',      v_locked,
         'lock',           v_lock,
         'can_approve',    app.auth_tenant_id() is null
                             or app.auth_role() in ('super_admin', 'owner', 'principal', 'exam_controller'),
         'students',       v_students
       );
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.mark_lock enable row level security;

create policy mark_lock_campus_scope on public.mark_lock
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- USING is the SELECT predicate verbatim, so the rows an authenticated
-- caller's UPDATE can reach are exactly the rows it can already read — and
-- reaching one is all it buys, because the BEFORE trigger answers first.
-- WITH CHECK stays false so "no authenticated write is ever committed"
-- survives the trigger being dropped. FR-T08's shape and FR-T08's argument.
create policy mark_lock_update_denied on public.mark_lock
  for update to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  )
  with check (false);

-- The absence of a DELETE policy is already a denial; this states it, so a
-- reader does not have to infer a security property from an absence.
create policy mark_lock_delete_denied on public.mark_lock
  for delete to authenticated
  using (false);
