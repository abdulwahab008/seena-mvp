-- FR-I14: mandatory teacher override of OCR marks.
--
-- "As a Principal, I want every machine-suggested mark confirmed by a named
-- teacher before it counts, so that no mark on a report card was assigned
-- solely by software."
--
-- The FR's Notes are the whole brief: "This is the liability firewall for the
-- whole product. An LLM-assigned mark that reaches a report card without a
-- named human is indefensible to a parent, a board or a court, so the guard
-- must live in the database function that promotes marks, never only in the
-- UI."
--
-- ── FR-I13 does not exist yet, and this migration does not pretend it does ──
--
-- FR-I13 ("OCR-assisted provisional grading", P1, XL) is the pipeline that
-- photographs a script, runs the engine and produces the numbers. It is not
-- built. This FR gates a source that has no producer yet, and there are three
-- ways to handle that; two of them are wrong.
--
-- Building a fake OCR engine here would be a lie in the schema. Skipping the FR
-- would leave FR-I13 free to write machine marks straight into mark_entry,
-- which is the exact failure this requirement exists to prevent. So this
-- migration takes FR-I01's approach with lock_exam_term(), which shipped as an
-- explicit seam that only tests called until FR-I16 drove it: the gate, the
-- provenance model, the review ledger and the promotion function are all REAL
-- and complete, and the only thing missing is the caller.
--
-- THE SEAM IS EXACTLY ONE FUNCTION: public.fn_open_ocr_job(). FR-I13 runs its
-- engine however it likes and hands the result over in one call —
--
--   select public.fn_open_ocr_job(
--            p_exam_subject_id => ..., p_section_id => ..., p_component => 'theory',
--            p_suggestions => '[{"enrolment_id":"...","question_no":1,
--                                "ocr_value":52,"confidence":0.97}, ...]',
--            p_engine => 'whatever-model-v3');
--
-- and NOTHING else in this file has to change for that to work. FR-I13 does not
-- touch the review path, the promotion function, the completeness check or the
-- approval gate. What it may reasonably add is its own columns on
-- ocr_mark_job (storage paths, page counts, engine confidence thresholds) and
-- the 'pending' status this migration ships unwritten — see below.
--
-- What FR-I13 must NOT do, and structurally CANNOT do, is write a mark. See
-- trg_mark_entry_source_guard.
--
-- ── Where provenance lives, and why a column alone would not be enough ──
--
-- mark_entry gains two columns:
--
--   source     public.mark_source not null default 'manual'
--   ocr_job_id uuid references public.ocr_mark_job(id)
--
-- with chk_mark_entry_source_job making the pair inseparable: 'manual' means no
-- job, and either OCR value means a named job. A row cannot claim machine
-- provenance without pointing at the batch it came from.
--
-- The enum is the FR's three values and no more — 'manual', 'ocr_confirmed',
-- 'ocr_overridden'. There is deliberately NO 'ocr_pending' or 'ocr_suggested',
-- because an unreviewed machine value must never be a mark_entry row at all. It
-- lives in ocr_mark_suggestion until a human affirms it, and the only thing
-- that can move it across is fn_promote_ocr_marks(), which refuses unless every
-- script has been reviewed. "Unreviewed OCR mark" is therefore not a state
-- mark_entry can represent, which is a stronger guarantee than a status column
-- policed by convention.
--
-- FR-I12 reserved mark_status 'submitted' for FR-I13, and it is NOT what this
-- needs: status says where a mark is in the workflow, source says who produced
-- the number, and they are orthogonal — a mark can be ocr_confirmed AND draft.
-- Promotion writes 'draft' and leaves 'submitted' reserved, exactly as FR-I12
-- left it, because a promoted mark is still the teacher's to fix in the grid
-- before the set is signed off.
--
-- The column is only half of it. FR-I11 built v_exam_result_input as a typed
-- contract so downstream code structurally cannot mistake a status for a
-- number; the same discipline applies here, and a column anyone can set is a
-- convention, not a contract. So:
--
--   trg_mark_entry_source_guard refuses any write that ACQUIRES OCR
--   provenance unless the executing stack contains
--   public.fn_promote_ocr_marks(.
--
-- FR-T09's named-transition precedent, and FR-I17's on mark_lock. It fires FOR
-- EACH ROW for every caller, so service_role's BYPASSRLS and the table owner's
-- ownership both buy nothing — which matters precisely because FR-I16's own
-- Notes anticipated this writer: "the result recompute job, THE OCR PROMOTER
-- and any CSV import run as service role and bypass RLS entirely, so a
-- policy-only lock is not a lock."
--
-- Provenance can always be LOST and never silently gained: fn_upsert_marks
-- resets source to 'manual' when a teacher types a different number over a
-- promoted one, because at that point the number is hand-entered and saying
-- otherwise would be false. Nothing is lost by that — the machine's value, the
-- teacher's value, the actor and the timestamp all stay in ocr_review_action
-- for as long as the school exists, which is what AC4 actually asks for.
--
-- ── Confidence is stored and grants nothing ────────────────────────────
--
-- ocr_mark_suggestion.confidence exists because FR-I13 will produce one and the
-- review screen is better for being able to sort by it. It buys NO bypass. The
-- acceptance criteria describe one gate — every script, every question, one
-- human action — and admit no high-confidence fast path, so there is none. A
-- suggestion at 0.999 blocks promotion exactly as hard as one at 0.4, and the
-- pgTAP asserts it.
--
-- ── A job is one paper's worth of one component ────────────────────────
--
-- The FR spells ocr_review_action as (job_id, enrolment_id, question_no, ...)
-- with no component, so question_no is unique within a script within a job. That
-- is also how it physically works: the theory booklet and the practical sheet
-- are different piles of paper and different scans. So ocr_mark_job carries the
-- component, and mark_entry.marks_obtained for that component is the SUM of the
-- final values of its questions — which for a single-question job (the whole
-- script marked as one total) is AC2's "one script, 52 or 55" exactly.
--
-- ── AC1's message, and the FR's 'unreviewed_scripts' ───────────────────
--
-- The two are not the same string and both are built. AC1 asserts what the
-- teacher READS — "0 of 40 scripts reviewed" — and that is the message, on
-- 23514 so PostgREST delivers it intact (class 55 becomes HTTP 500 with the
-- body replaced by {"message":"Something went wrong"}; FR-I01 verified that
-- against this stack). The FR's 'unreviewed_scripts' token is the DETAIL, where
-- a caller that wants to branch on the kind of failure can find it without
-- parsing English. Same call FR-I16 made about its own AC1: the criterion
-- asserts a sentence the database composes, and a code the UI expands cannot
-- carry counts the database found.
--
-- ── The three tables are append-only, and that is the point ────────────
--
-- AC4 is "a parent disputes a mark 6 months later". A suggestion that could be
-- rewritten, or a review action that could be deleted, is not evidence — it is
-- a value with a story attached. All three get the guard FR-T02 established and
-- FR-T08/T09/I16/I17 extended, layer for layer:
--
--   1. RLS. SELECT is scoped to people who may see the paper. UPDATE gets a
--      policy whose USING is the SELECT predicate verbatim and WITH CHECK
--      false, so an authenticated caller reaches the trigger and is TOLD rather
--      than handed a silent `UPDATE 0`. DELETE stays USING false.
--   2. Row triggers, FOR EACH ROW, regardless of caller — service_role and the
--      table owner included.
--   3. Statement-level TRUNCATE guards, because TRUNCATE fires no row trigger
--      and consults no RLS (FR-T08's finding).
--
-- ocr_review_action and ocr_mark_suggestion have NO legal UPDATE at all. The
-- FR's suggested `ocr_review_insert_only (no UPDATE/DELETE grant)` policy is
-- built this way rather than as a bare grant for the reason FR-I12, FR-I16 and
-- FR-I17 each gave about their own writes: a policy binds only the roles it
-- names, and "the record of who confirmed this mark is not editable" is exactly
-- the rule that has to hold for every caller.
--
-- ocr_mark_job has exactly TWO named transitions, each with its own stack
-- frame, on top of eleven frozen columns:
--
--   PROMOTE — frame public.fn_promote_ocr_marks(. 'ready' -> 'promoted'.
--   CANCEL  — frame public.fn_cancel_ocr_job(.     'ready' -> 'cancelled',
--             write-once, with a written reason.
--
-- CANCEL is not a convenience. Without it a job whose scan came out garbage
-- could never be promoted (the values are wrong) and never abandoned, and
-- because an open job blocks approval, one bad photograph would make a section
-- permanently unapprovable. Abandoning the machine's attempt and typing the
-- marks by hand has to be a door, and it has to be a recorded one.
--
-- The 'pending' status is shipped in the enum and never written here, for
-- FR-I12's reason: ALTER TYPE ... ADD VALUE cannot share a transaction with its
-- use, so an enum value a later FR needs has to exist before that FR starts.
-- FR-I13 will want it for "scan uploaded, engine not finished", and it will
-- need to add its own named transition to reach 'ready' — deliberately, with a
-- frame, exactly as FR-I17 added its three to mark_lock and "never as a
-- relaxation of the frozen set".
--
-- ── Why approval refuses an unreviewed set, and where that lives ───────
--
-- FR-I16's fn_approve_marks is the last gate before a mark is signed off, and
-- AC1 of that FR already refuses an incomplete set by LISTING GR numbers. An
-- unreviewed OCR job belongs in exactly the same place and reads the same way,
-- so fn_mark_completeness gains a third failure list — ocr_unreviewed — beside
-- not_started and partial, and fn_approve_marks raises on it FIRST.
--
-- First, because it is the more specific diagnosis of the same fact. A
-- candidate whose script is sitting unreviewed usually has no mark either and
-- would otherwise be reported as "neither a mark nor an exam status", which is
-- true and useless: the marks are not missing, they are waiting for a human.
-- And the case the ordering really exists for is the nastier one — a teacher
-- keyed all forty marks by hand while an OCR job for the same paper sat
-- unreviewed. not_started and partial are both empty, the set looks complete,
-- and without this check it would be signed off with a machine's unexamined
-- opinion of the same scripts still on file.
--
-- ── Frozen-column allow-lists: checked, and not extended ───────────────
--
-- FR-I16 and FR-I17 keep frozen-column allow-lists in
-- app.tg_mark_lock_no_update() (eleven columns) and
-- app.tg_mark_unlock_request_no_update() (ten). Both were read before writing
-- this. NEITHER is touched, and neither needs to be: this migration adds no
-- column to mark_lock and none to mark_unlock_request. The columns it adds are
-- on mark_entry, which has no column allow-list — its guards
-- (trg_mark_entry_block_when_locked, trg_mark_entry_frozen) refuse the whole
-- write rather than a column list — so the new columns are covered by them
-- from the moment they exist. FR-T09's precedent for extending an allow-list
-- deliberately is noted and simply does not apply here.

-- ═══════════════════════════════════════════════════════════════════════
-- Schema
-- ═══════════════════════════════════════════════════════════════════════

-- The FR's source enum, its three values and no more. See the header for why
-- there is deliberately no value meaning "machine said so, nobody looked".
create type public.mark_source as enum ('manual', 'ocr_confirmed', 'ocr_overridden');

-- 'pending' and 'cancelled' are shipped now and 'pending' is never written
-- here — FR-I12's precedent, because ALTER TYPE ... ADD VALUE cannot share a
-- migration with its use.
create type public.ocr_job_status as enum ('pending', 'ready', 'promoted', 'cancelled');

-- One batch of scanned scripts: one paper, one section, one component.
create table public.ocr_mark_job (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  exam_term_id      uuid not null references public.exam_term(id) on delete cascade,
  exam_subject_id   uuid not null references public.exam_subject(id) on delete cascade,
  section_id        uuid not null references public.class_section(id) on delete cascade,
  component_code    public.mark_component_code not null,
  status            public.ocr_job_status not null default 'ready',
  -- Whatever produced the numbers. FR-I13's to fill in meaningfully; kept as
  -- free text because pinning a model naming scheme now would be inventing one.
  engine            text,
  created_by        uuid references public.app_user(user_id),
  created_at        timestamptz not null default now(),
  promoted_by       uuid references public.app_user(user_id),
  promoted_at       timestamptz,
  cancelled_by      uuid references public.app_user(user_id),
  cancelled_at      timestamptz,
  cancelled_reason  text,
  constraint chk_ocr_job_cancel_reason check (
    cancelled_reason is null or length(btrim(cancelled_reason)) >= 10
  )
);

-- One live job per (paper, section, component): two machines' opinions of the
-- same pile of scripts is not a thing a teacher can review.
create unique index uq_ocr_job_open on public.ocr_mark_job (exam_subject_id, section_id, component_code)
  where status in ('pending', 'ready');
create index idx_ocr_job_subject_section on public.ocr_mark_job (exam_subject_id, section_id);
create index idx_ocr_job_campus on public.ocr_mark_job (tenant_id, campus_id, created_at desc);

create trigger ocr_mark_job_audit after insert or update or delete on public.ocr_mark_job
  for each row execute function app.tg_audit_row();

comment on table public.ocr_mark_job is
  'FR-I14: one batch of machine-read scripts awaiting human confirmation. FR-I13 creates these through fn_open_ocr_job(); nothing in this schema promotes one without a review action for every question of every script.';

-- What the machine said, exactly as it said it. Append-only: AC2 requires the
-- original OCR value to survive an override, and AC4 requires it to survive six
-- months.
create table public.ocr_mark_suggestion (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  job_id        uuid not null references public.ocr_mark_job(id) on delete cascade,
  enrolment_id  uuid not null references public.enrolment(id) on delete cascade,
  question_no   integer not null,
  ocr_value     numeric(6,2) not null,
  -- Stored because FR-I13 produces one and the review screen is better for it.
  -- It grants no bypass whatsoever — see the header.
  confidence    numeric(4,3),
  created_at    timestamptz not null default now(),
  constraint chk_ocr_question_no check (question_no >= 1),
  constraint chk_ocr_value_nonneg check (ocr_value >= 0),
  constraint chk_ocr_confidence check (confidence is null or (confidence >= 0 and confidence <= 1))
);

create unique index uq_ocr_suggestion on public.ocr_mark_suggestion (job_id, enrolment_id, question_no);
create index idx_ocr_suggestion_job on public.ocr_mark_suggestion (job_id, enrolment_id);

create trigger ocr_mark_suggestion_audit after insert or update or delete on public.ocr_mark_suggestion
  for each row execute function app.tg_audit_row();

comment on column public.ocr_mark_suggestion.confidence is
  'FR-I14: recorded, never load-bearing. A 0.999 suggestion needs the same human confirmation as a 0.4 one.';

-- The FR's ocr_review_action, with the FR's columns. This is the affirmation
-- itself — the row whose existence is the difference between a number a machine
-- produced and a mark a school stands behind.
--
-- No unique constraint on (job_id, enrolment_id, question_no) on purpose: a
-- teacher who confirms 52, then looks again and amends to 55 before promotion
-- has done two reviewable things, and an append-only log that keeps both is the
-- honest record. Promotion reads the latest per key.
create table public.ocr_review_action (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  job_id        uuid not null references public.ocr_mark_job(id) on delete cascade,
  enrolment_id  uuid not null references public.enrolment(id) on delete cascade,
  question_no   integer not null,
  -- Copied from the suggestion by fn_record_ocr_review(), never taken from the
  -- client: a caller that could name the machine's value could also misreport
  -- it, and then "the teacher changed it" would be unfalsifiable.
  ocr_value     numeric(6,2) not null,
  final_value   numeric(6,2) not null,
  actor_id      uuid references public.app_user(user_id),
  acted_at      timestamptz not null default clock_timestamp(),
  constraint chk_ocr_review_final_nonneg check (final_value >= 0)
);

-- The FR's index, spelled as the FR spells it.
create index idx_ocr_review on public.ocr_review_action (job_id, enrolment_id);
create index idx_ocr_review_actor on public.ocr_review_action (actor_id, acted_at desc);

create trigger ocr_review_action_audit after insert or update or delete on public.ocr_review_action
  for each row execute function app.tg_audit_row();

comment on table public.ocr_review_action is
  'FR-I14: one row per script per question per human action. AC3 — a bulk accept of ten scripts writes TEN rows with ten actors and ten timestamps, because "I accepted a page" is not what a parent disputing one mark needs to read.';

-- ── mark_entry's provenance ───────────────────────────────────────────

alter table public.mark_entry add column source public.mark_source not null default 'manual';
alter table public.mark_entry add column ocr_job_id uuid references public.ocr_mark_job(id);

-- Inseparable. A row cannot claim machine provenance without naming the batch,
-- and cannot claim to be hand-entered while pointing at one.
alter table public.mark_entry add constraint chk_mark_entry_source_job check (
  (source = 'manual' and ocr_job_id is null)
  or (source in ('ocr_confirmed', 'ocr_overridden') and ocr_job_id is not null)
);

create index idx_mark_entry_ocr_job on public.mark_entry (ocr_job_id) where ocr_job_id is not null;

comment on column public.mark_entry.source is
  'FR-I14: who produced this number. Only fn_promote_ocr_marks() can set either OCR value — trg_mark_entry_source_guard refuses it from every other stack, service_role and the table owner included.';

-- ═══════════════════════════════════════════════════════════════════════
-- The guard that makes provenance structural rather than conventional
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY INVOKER on purpose, as FR-I16's and FR-I17's guards: current_user
-- must still report the executing context, so "the caller is the table owner"
-- means "we are inside a SECURITY DEFINER function running as the owner" and
-- not "somebody logged in as postgres".
create or replace function app.tg_mark_entry_source_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_stack text;
  v_owner text;
begin
  -- Losing OCR provenance is always allowed; acquiring it never is, except
  -- through the one promotion function. See the header.
  if new.source = 'manual' then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and new.source is not distinct from old.source
     and new.ocr_job_id is not distinct from old.ocr_job_id then
    return new;
  end if;

  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner
    from pg_catalog.pg_class c where c.oid = tg_relid;
  get diagnostics v_stack = pg_context;

  if current_user = v_owner and v_stack ~ 'function public\.fn_promote_ocr_marks\(' then
    return new;
  end if;

  raise exception 'a machine mark needs a named teacher'
    using errcode = '42501',
          detail = format('%s on mark_entry claiming source=%s (enrolment %s, component %s) by %s',
                          tg_op, new.source, new.enrolment_id, new.component_code, current_user),
          hint = 'OCR marks reach mark_entry only through fn_promote_ocr_marks(), which refuses until every script has been reviewed.';
end;
$$;

-- Fires after trg_mark_entry_block_when_locked and trg_mark_entry_frozen
-- (BEFORE row triggers fire in name order), so a locked set still answers
-- 'marks_locked' first — that is the truthful refusal, and the way through it
-- is FR-I17's, not this one's.
create trigger trg_mark_entry_source_guard
  before insert or update on public.mark_entry
  for each row execute function app.tg_mark_entry_source_guard();

-- ═══════════════════════════════════════════════════════════════════════
-- Visibility helpers
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY DEFINER owned by postgres bypasses RLS entirely (FR-K24's finding),
-- which is exactly what a policy on ocr_mark_suggestion needs: it must ask "may
-- this caller see the paper this job is for" without the job's own policy
-- deciding the answer first.
create or replace function app.fn_can_read_ocr_job(p_job_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select app.fn_can_enter_marks(j.exam_subject_id, j.section_id)
       from public.ocr_mark_job j where j.id = p_job_id),
    false
  );
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- The seam: what FR-I13 calls, and the only thing it calls
-- ═══════════════════════════════════════════════════════════════════════

-- p_suggestions = [{"enrolment_id": uuid, "question_no": 1,
--                   "ocr_value": 52, "confidence": 0.97}, ...]
--
-- Granted to service_role as well as authenticated, because FR-I13's engine
-- runs as a job rather than as a person. That is safe precisely because this
-- function cannot write a mark: everything it produces is a SUGGESTION, and a
-- suggestion is inert until a human acts on it.
create or replace function public.fn_open_ocr_job(
  p_exam_subject_id uuid,
  p_section_id      uuid,
  p_component       public.mark_component_code,
  p_suggestions     jsonb,
  p_engine          text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_es      record;
  v_job_id  uuid;
  v_scripts integer;
  v_rows    integer;
begin
  if p_suggestions is null or jsonb_typeof(p_suggestions) <> 'array'
     or jsonb_array_length(p_suggestions) = 0 then
    raise exception 'OCR_SUGGESTIONS_REQUIRED' using errcode = '23514',
      detail = 'A job with nothing to review is not a job.';
  end if;

  select es.id, es.tenant_id, es.campus_id, es.exam_term_id
    into v_es
    from public.exam_subject es
   where es.id = p_exam_subject_id;
  if v_es.id is null then
    raise exception 'EXAM_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_tenant_id() is not null and v_es.tenant_id <> app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not app.fn_can_enter_marks(p_exam_subject_id, p_section_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- The section must actually sit this paper, asked of FR-I16's fan-out so the
  -- job and the approval can never disagree about which sections a paper covers.
  if not exists (
    select 1 from public.v_exam_subject_section vs
     where vs.exam_subject_id = p_exam_subject_id and vs.section_id = p_section_id
  ) then
    raise exception 'SECTION_NOT_IN_EXAM_SUBJECT' using errcode = '23514',
      detail = 'That section does not sit this paper — check the class and stream.';
  end if;

  if not exists (
    select 1 from public.exam_subject_component c
     where c.exam_subject_id = p_exam_subject_id and c.component = p_component
  ) then
    raise exception 'MARK_COMPONENT_NOT_CONFIGURED' using errcode = '23514',
      detail = format('%s is not a configured component of this exam subject.', p_component);
  end if;

  -- A signed-off set gets no new machine opinion. FR-I17's window is the way
  -- back in, and re-running OCR is not a correction to one script.
  if app.fn_marks_locked(p_exam_subject_id, p_section_id) then
    raise exception 'marks_locked' using errcode = '42501',
      hint = 'These marks were approved and signed off. A correction needs a break-glass unlock.';
  end if;

  if exists (
    select 1 from public.ocr_mark_job j
     where j.exam_subject_id = p_exam_subject_id
       and j.section_id = p_section_id
       and j.component_code = p_component
       and j.status in ('pending', 'ready')
  ) then
    raise exception 'OCR_JOB_ALREADY_OPEN' using errcode = '23505',
      detail = 'This paper already has a batch waiting for review.',
      hint = 'Promote it or cancel it before scanning again.';
  end if;

  insert into public.ocr_mark_job (
    tenant_id, campus_id, exam_term_id, exam_subject_id, section_id,
    component_code, status, engine, created_by
  ) values (
    v_es.tenant_id, v_es.campus_id, v_es.exam_term_id, p_exam_subject_id, p_section_id,
    p_component, 'ready', p_engine, (select auth.uid())
  )
  returning id into v_job_id;

  -- Every suggestion must name a live candidate of THIS section. A machine that
  -- read a roll number off the wrong pile does not get to create a mark for
  -- somebody in another class.
  if exists (
    select 1
      from jsonb_array_elements(p_suggestions) as s
      left join public.enrolment e
        on e.id = nullif(s ->> 'enrolment_id', '')::uuid
       and e.section_id = p_section_id
       and e.deleted_at is null
     where e.id is null
  ) then
    raise exception 'OCR_ENROLMENT_MISMATCH' using errcode = '23514',
      detail = 'Every suggestion must name a live candidate of the section this job is for.';
  end if;

  insert into public.ocr_mark_suggestion (
    tenant_id, campus_id, job_id, enrolment_id, question_no, ocr_value, confidence
  )
  select v_es.tenant_id, v_es.campus_id, v_job_id,
         (s ->> 'enrolment_id')::uuid,
         (s ->> 'question_no')::integer,
         (s ->> 'ocr_value')::numeric,
         nullif(s ->> 'confidence', '')::numeric
    from jsonb_array_elements(p_suggestions) as s;
  get diagnostics v_rows = row_count;

  select count(distinct enrolment_id)::int into v_scripts
    from public.ocr_mark_suggestion where job_id = v_job_id;

  return jsonb_build_object(
    'job_id',           v_job_id,
    'exam_subject_id',  p_exam_subject_id,
    'section_id',       p_section_id,
    'component',        p_component,
    'script_count',     v_scripts,
    'suggestion_count', v_rows
  );
end;
$$;

revoke execute on function public.fn_open_ocr_job(uuid, uuid, public.mark_component_code, jsonb, text)
  from public, anon;
grant execute on function public.fn_open_ocr_job(uuid, uuid, public.mark_component_code, jsonb, text)
  to authenticated, service_role;

comment on function public.fn_open_ocr_job(uuid, uuid, public.mark_component_code, jsonb, text) is
  'FR-I14: the seam FR-I13 fills. Hands a batch of machine-read values over for human review. It cannot write a mark — nothing here can except fn_promote_ocr_marks(), and that refuses until every script is confirmed.';

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: how many scripts have actually been looked at
-- ═══════════════════════════════════════════════════════════════════════

-- A script counts as reviewed when EVERY question on it has a review action.
-- Nine of ten questions confirmed is a script nobody has finished, and the mark
-- it would promote to is a sum with a hole in it.
create or replace function app.fn_ocr_review_progress(p_job_id uuid)
returns table (total integer, reviewed integer)
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select count(distinct s.enrolment_id)::int
       from public.ocr_mark_suggestion s where s.job_id = p_job_id),
    (select count(distinct s.enrolment_id)::int
       from public.ocr_mark_suggestion s
      where s.job_id = p_job_id
        and not exists (
          select 1 from public.ocr_mark_suggestion s2
           where s2.job_id = s.job_id
             and s2.enrolment_id = s.enrolment_id
             and not exists (
               select 1 from public.ocr_review_action r
                where r.job_id = s2.job_id
                  and r.enrolment_id = s2.enrolment_id
                  and r.question_no = s2.question_no)));
$$;

-- The latest word on every question of a job. Append-only means a teacher may
-- confirm and then amend before promoting; the last action is the one that
-- counts, and every earlier one stays on the record.
create or replace function app.fn_ocr_final_values(p_job_id uuid)
returns table (enrolment_id uuid, question_no integer, ocr_value numeric, final_value numeric)
language sql
stable
security definer
set search_path = ''
as $$
  select distinct on (r.enrolment_id, r.question_no)
         r.enrolment_id, r.question_no, r.ocr_value, r.final_value
    from public.ocr_review_action r
   where r.job_id = p_job_id
   order by r.enrolment_id, r.question_no, r.acted_at desc, r.id desc;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the affirmation, one row per script per question
-- ═══════════════════════════════════════════════════════════════════════

-- p_reviews = [{"enrolment_id": uuid, "question_no": 1, "final_value": 55}, ...]
--
-- AC3 is "the teacher uses bulk-accept on a page of 10 scripts... 10 individual
-- review rows are written with actor and timestamp, not one row for the page".
-- That is not a rule this function enforces, it is a shape the table makes
-- unavoidable: ocr_review_action has enrolment_id and question_no NOT NULL, so
-- there is no row that can mean "a page". The bulk button sends ten entries and
-- ten rows land, each with its own actor and its own clock_timestamp().
--
-- final_value omitted means "accept what the machine said" — the ordinary case,
-- and the one the bulk button uses. ocr_value is never taken from the caller.
create or replace function public.fn_record_ocr_review(
  p_job_id   uuid,
  p_reviews  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job      record;
  v_written  integer;
  v_total    integer;
  v_reviewed integer;
begin
  if p_reviews is null or jsonb_typeof(p_reviews) <> 'array'
     or jsonb_array_length(p_reviews) = 0 then
    raise exception 'OCR_REVIEW_EMPTY' using errcode = '23514',
      detail = 'A review action with nothing in it confirms nothing.';
  end if;

  select j.* into v_job from public.ocr_mark_job j where j.id = p_job_id;
  if v_job.id is null then
    raise exception 'OCR_JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_tenant_id() is not null and v_job.tenant_id <> app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  -- The person confirming a machine mark is the person who could have entered
  -- it by hand. That is the whole content of "a named teacher".
  if not app.fn_can_enter_marks(v_job.exam_subject_id, v_job.section_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_job.status <> 'ready' then
    raise exception 'OCR_JOB_NOT_OPEN' using errcode = '23514',
      detail = format('status=%s', v_job.status),
      hint = 'A batch is reviewed before it is promoted, and a promoted or cancelled batch is history.';
  end if;

  -- Every entry must name a suggestion of THIS job: there is nothing to confirm
  -- about a question the machine never read.
  if exists (
    select 1
      from jsonb_array_elements(p_reviews) as v
      left join public.ocr_mark_suggestion s
        on s.job_id = p_job_id
       and s.enrolment_id = nullif(v ->> 'enrolment_id', '')::uuid
       and s.question_no = (v ->> 'question_no')::integer
     where s.id is null
  ) then
    raise exception 'OCR_SUGGESTION_NOT_FOUND' using errcode = 'P0002',
      detail = 'A review must answer a suggestion this batch actually made.';
  end if;

  insert into public.ocr_review_action (
    tenant_id, campus_id, job_id, enrolment_id, question_no, ocr_value, final_value, actor_id
  )
  select v_job.tenant_id, v_job.campus_id, p_job_id, s.enrolment_id, s.question_no,
         s.ocr_value,
         coalesce(nullif(v ->> 'final_value', '')::numeric, s.ocr_value),
         (select auth.uid())
    from jsonb_array_elements(p_reviews) as v
    join public.ocr_mark_suggestion s
      on s.job_id = p_job_id
     and s.enrolment_id = (v ->> 'enrolment_id')::uuid
     and s.question_no = (v ->> 'question_no')::integer;
  get diagnostics v_written = row_count;

  select t.total, t.reviewed into v_total, v_reviewed
    from app.fn_ocr_review_progress(p_job_id) t;

  return jsonb_build_object(
    'job_id',         p_job_id,
    'actions_written', v_written,
    'script_count',    v_total,
    'reviewed_count',  v_reviewed,
    'can_promote',     v_total > 0 and v_reviewed = v_total
  );
end;
$$;

revoke execute on function public.fn_record_ocr_review(uuid, jsonb) from public, anon;
grant execute on function public.fn_record_ocr_review(uuid, jsonb) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC1 / AC2: the promotion, and the refusal that is the whole requirement
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.fn_promote_ocr_marks(p_job_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job        record;
  v_total      integer;
  v_reviewed   integer;
  v_row        record;
  v_confirmed  integer := 0;
  v_overridden integer := 0;
begin
  select j.* into v_job from public.ocr_mark_job j where j.id = p_job_id;
  if v_job.id is null then
    raise exception 'OCR_JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_tenant_id() is not null and v_job.tenant_id <> app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not app.fn_can_enter_marks(v_job.exam_subject_id, v_job.section_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_job.status <> 'ready' then
    raise exception 'OCR_JOB_NOT_OPEN' using errcode = '23514',
      detail = format('status=%s', v_job.status),
      hint = 'A batch is promoted once.';
  end if;

  -- Raised ahead of trg_mark_entry_block_when_locked so the caller gets one
  -- refusal for the batch rather than one for the first script.
  if app.fn_marks_locked(v_job.exam_subject_id, v_job.section_id) then
    raise exception 'marks_locked' using errcode = '42501',
      hint = 'These marks were approved and signed off. A correction needs a break-glass unlock.';
  end if;

  select t.total, t.reviewed into v_total, v_reviewed
    from app.fn_ocr_review_progress(p_job_id) t;

  -- AC1, in the acceptance criteria's own words: "0 of 40 scripts reviewed".
  -- The FR's 'unreviewed_scripts' token rides in the detail — see the header
  -- for why the sentence is the message and not the other way round.
  if v_reviewed < v_total then
    raise exception '%', format('%s of %s scripts reviewed', v_reviewed, v_total)
      using errcode = '23514',
            detail = format('unreviewed_scripts: job %s, %s of %s scripts confirmed',
                            p_job_id, v_reviewed, v_total),
            hint = 'Every script needs a teacher''s confirm or amend before any of them counts.';
  end if;

  -- AC2. One mark_entry row per script: the component total is the sum of the
  -- FINAL values of its questions, and the row is 'ocr_overridden' when the
  -- teacher changed any of them and 'ocr_confirmed' when they changed none.
  for v_row in
    select f.enrolment_id,
           sum(f.final_value)                            as total_marks,
           bool_or(f.final_value <> f.ocr_value)         as overridden
      from app.fn_ocr_final_values(p_job_id) f
     group by f.enrolment_id
  loop
    insert into public.mark_entry as m (
      tenant_id, campus_id, exam_subject_id, enrolment_id, component_code,
      marks_obtained, entered_by, source, ocr_job_id
    ) values (
      v_job.tenant_id, v_job.campus_id, v_job.exam_subject_id, v_row.enrolment_id,
      v_job.component_code, v_row.total_marks, (select auth.uid()),
      case when v_row.overridden then 'ocr_overridden' else 'ocr_confirmed' end::public.mark_source,
      p_job_id
    )
    on conflict (tenant_id, exam_subject_id, enrolment_id, component_code) do update
      set marks_obtained = excluded.marks_obtained,
          entered_by     = excluded.entered_by,
          entered_at     = now(),
          source         = excluded.source,
          ocr_job_id     = excluded.ocr_job_id;

    if v_row.overridden then
      v_overridden := v_overridden + 1;
    else
      v_confirmed := v_confirmed + 1;
    end if;
  end loop;

  update public.ocr_mark_job
     set status = 'promoted', promoted_by = (select auth.uid()), promoted_at = clock_timestamp()
   where id = p_job_id;

  return jsonb_build_object(
    'job_id',           p_job_id,
    'exam_subject_id',  v_job.exam_subject_id,
    'section_id',       v_job.section_id,
    'component',        v_job.component_code,
    'script_count',     v_total,
    'confirmed_count',  v_confirmed,
    'overridden_count', v_overridden
  );
end;
$$;

revoke execute on function public.fn_promote_ocr_marks(uuid) from public, anon;
grant execute on function public.fn_promote_ocr_marks(uuid) to authenticated;

comment on function public.fn_promote_ocr_marks(uuid) is
  'FR-I14: the one path from a machine suggestion to a mark. Refuses with "<n> of <m> scripts reviewed" unless every script has a review action for every question — the FR''s Notes put this guard in the database precisely so no UI can be the only thing holding it.';

-- The door out of a bad scan. Without it an unpromotable batch would block its
-- section's approval for ever — see the header.
create or replace function public.fn_cancel_ocr_job(
  p_job_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job record;
begin
  select j.* into v_job from public.ocr_mark_job j where j.id = p_job_id;
  if v_job.id is null then
    raise exception 'OCR_JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_tenant_id() is not null and v_job.tenant_id <> app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not app.fn_can_enter_marks(v_job.exam_subject_id, v_job.section_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_job.status <> 'ready' then
    raise exception 'OCR_JOB_NOT_OPEN' using errcode = '23514',
      detail = format('status=%s', v_job.status);
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'OCR_CANCEL_REASON_REQUIRED' using errcode = '23514',
      detail = 'Abandoning a machine''s reading of forty scripts needs a written reason of at least 10 characters.';
  end if;

  update public.ocr_mark_job
     set status = 'cancelled',
         cancelled_by = (select auth.uid()),
         cancelled_at = clock_timestamp(),
         cancelled_reason = btrim(p_reason)
   where id = p_job_id;

  return jsonb_build_object('job_id', p_job_id, 'status', 'cancelled');
end;
$$;

revoke execute on function public.fn_cancel_ocr_job(uuid, text) from public, anon;
grant execute on function public.fn_cancel_ocr_job(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Append-only: the job's two named transitions
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY INVOKER, as FR-I16's and FR-I17's. Eleven frozen columns, checked
-- once rather than per transition, so a column added later is frozen by default
-- and has to be argued OUT of this list rather than into it.
create or replace function app.tg_ocr_mark_job_no_update()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_stack  text;
  v_owner  text;
  v_frozen boolean;
begin
  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner
    from pg_catalog.pg_class c where c.oid = tg_relid;

  get diagnostics v_stack = pg_context;

  v_frozen :=
        new.id              is not distinct from old.id
    and new.tenant_id       is not distinct from old.tenant_id
    and new.campus_id       is not distinct from old.campus_id
    and new.exam_term_id    is not distinct from old.exam_term_id
    and new.exam_subject_id is not distinct from old.exam_subject_id
    and new.section_id      is not distinct from old.section_id
    and new.component_code  is not distinct from old.component_code
    and new.engine          is not distinct from old.engine
    and new.created_by      is not distinct from old.created_by
    and new.created_at      is not distinct from old.created_at;

  if current_user = v_owner and v_frozen then
    -- A. PROMOTE. Write-once, and it is the only thing that ever names a
    -- promoter.
    if v_stack ~ 'function public\.fn_promote_ocr_marks\('
       and old.status = 'ready' and new.status = 'promoted'
       and old.promoted_at is null and new.promoted_at is not null
       and new.cancelled_at is null and new.cancelled_by is null
       and new.cancelled_reason is null
    then
      return new;
    end if;

    -- B. CANCEL. Likewise write-once, and it carries the reason it happened.
    if v_stack ~ 'function public\.fn_cancel_ocr_job\('
       and old.status = 'ready' and new.status = 'cancelled'
       and old.cancelled_at is null and new.cancelled_at is not null
       and new.cancelled_reason is not null
       and new.promoted_at is null and new.promoted_by is null
    then
      return new;
    end if;
  end if;

  raise exception 'an OCR batch is append-only'
    using errcode = '42501',
          detail = format('update of ocr_mark_job id=%s status=%s->%s by %s',
                          old.id, old.status, new.status, current_user),
          hint = 'A batch is promoted once or abandoned once, and either way the record of which stays.';
end;
$$;

create trigger trg_ocr_mark_job_no_update
  before update on public.ocr_mark_job
  for each row execute function app.tg_ocr_mark_job_no_update();

create or replace function app.tg_ocr_mark_job_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'an OCR batch is append-only'
    using errcode = '42501',
          detail = format('%s on ocr_mark_job by %s', tg_op, current_user),
          hint = 'Every batch this school ever ran stays on the record, promoted or not.';
end;
$$;

create trigger trg_ocr_mark_job_no_delete
  before delete on public.ocr_mark_job
  for each row execute function app.tg_ocr_mark_job_immutable();

-- TRUNCATE fires no row trigger and consults no RLS — FR-T08's finding, and a
-- real hole without its own statement-level trigger.
create trigger trg_ocr_mark_job_no_truncate
  before truncate on public.ocr_mark_job
  for each statement execute function app.tg_ocr_mark_job_immutable();

-- ═══════════════════════════════════════════════════════════════════════
-- Append-only: the suggestion and the review action have no legal UPDATE
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_ocr_suggestion_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'an OCR suggestion is append-only'
    using errcode = '42501',
          detail = format('%s on ocr_mark_suggestion by %s', tg_op, current_user),
          hint = 'What the machine read is the fixed half of "the teacher changed it". Rewriting it would make the override unfalsifiable.';
end;
$$;

create trigger trg_ocr_suggestion_no_update
  before update on public.ocr_mark_suggestion
  for each row execute function app.tg_ocr_suggestion_immutable();
create trigger trg_ocr_suggestion_no_delete
  before delete on public.ocr_mark_suggestion
  for each row execute function app.tg_ocr_suggestion_immutable();
create trigger trg_ocr_suggestion_no_truncate
  before truncate on public.ocr_mark_suggestion
  for each statement execute function app.tg_ocr_suggestion_immutable();

create or replace function app.tg_ocr_review_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'an OCR review action is append-only'
    using errcode = '42501',
          detail = format('%s on ocr_review_action by %s', tg_op, current_user),
          hint = 'This row is the named human a report card mark rests on. It is written once and it stays.';
end;
$$;

create trigger trg_ocr_review_no_update
  before update on public.ocr_review_action
  for each row execute function app.tg_ocr_review_immutable();
create trigger trg_ocr_review_no_delete
  before delete on public.ocr_review_action
  for each row execute function app.tg_ocr_review_immutable();
create trigger trg_ocr_review_no_truncate
  before truncate on public.ocr_review_action
  for each statement execute function app.tg_ocr_review_immutable();

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: the dispute, six months later
-- ═══════════════════════════════════════════════════════════════════════

-- "Given a parent disputes a mark 6 months later, when the audit is opened,
-- then the OCR value, the final value, the acting user and the timestamp are
-- all retrievable for that question."
--
-- One row per review action, per question, with the candidate named. Every
-- action is here, not merely the last one — a teacher who confirmed 52 and then
-- amended to 55 did two things and the record shows both.
--
-- security_invoker, so ocr_review_action_read is what decides who sees which
-- rows.
create view public.v_ocr_mark_audit
with (security_invoker = true) as
select r.id                       as review_action_id,
       r.tenant_id,
       r.campus_id,
       r.job_id,
       j.exam_term_id,
       j.exam_subject_id,
       j.section_id,
       j.component_code,
       j.status                   as job_status,
       j.engine,
       sub.name_en                as subject_name,
       cl.name_en                 as class_name,
       sec.name                   as section_name,
       r.enrolment_id,
       st.gr_number,
       st.name_en                 as student_name,
       e.roll_no,
       r.question_no,
       r.ocr_value,
       r.final_value,
       r.final_value <> r.ocr_value as was_overridden,
       s.confidence,
       r.actor_id,
       actor.full_name            as actor_name,
       r.acted_at
  from public.ocr_review_action r
  join public.ocr_mark_job j on j.id = r.job_id
  join public.exam_subject es on es.id = j.exam_subject_id
  join public.class_subject cs on cs.id = es.class_subject_id
  join public.subject sub on sub.id = cs.subject_id
  join public.class_level cl on cl.id = cs.class_level_id
  join public.class_section sec on sec.id = j.section_id
  join public.enrolment e on e.id = r.enrolment_id
  join public.student st on st.id = e.student_id
  left join public.ocr_mark_suggestion s
    on s.job_id = r.job_id and s.enrolment_id = r.enrolment_id and s.question_no = r.question_no
  left join public.app_user actor on actor.user_id = r.actor_id;

revoke all on public.v_ocr_mark_audit from public, anon;
grant select on public.v_ocr_mark_audit to authenticated;

comment on view public.v_ocr_mark_audit is
  'FR-I14 AC4: for any question of any script, what the machine read, what the school awarded, who decided and when.';

-- ═══════════════════════════════════════════════════════════════════════
-- FR-I16's completeness check, with a third refusal
-- ═══════════════════════════════════════════════════════════════════════

-- Same signature as FR-I16's, so this is a genuine replacement rather than a
-- second overload. Two additions and nothing else: ocr_unreviewed, and its
-- effect on `complete`. See the header for why an unreviewed batch belongs in
-- exactly this function rather than in a check of its own.
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
  v_ocr         jsonb;
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

  -- FR-I14. A candidate whose script the machine has read but no teacher has
  -- confirmed. A cancelled or promoted batch is not open and does not appear.
  select coalesce(
           jsonb_agg(jsonb_build_object('gr_number', x.gr_number, 'roll_no', x.roll_no,
                                        'student_name', x.name_en, 'job_id', x.job_id,
                                        'component', x.component_code)
                     order by x.roll_no nulls last, x.gr_number),
           '[]'::jsonb
         )
    into v_ocr
    from (
      select distinct st.gr_number, e.roll_no, st.name_en, j.id as job_id, j.component_code
        from public.ocr_mark_job j
        join public.ocr_mark_suggestion s on s.job_id = j.id
        join public.enrolment e on e.id = s.enrolment_id
        join public.student st on st.id = e.student_id
       where j.exam_subject_id = p_exam_subject_id
         and j.section_id = p_section_id
         and j.status in ('pending', 'ready')
         and e.deleted_at is null
         and st.deleted_at is null
         and not exists (
           select 1 from public.ocr_review_action r
            where r.job_id = s.job_id
              and r.enrolment_id = s.enrolment_id
              and r.question_no = s.question_no)
    ) x;

  return jsonb_build_object(
    'components',      to_jsonb(coalesce(v_components, '{}'::public.mark_component_code[])),
    'candidate_count', v_candidates,
    'mark_count',      v_marks,
    'not_started',     v_not_started,
    'partial',         v_partial,
    'ocr_unreviewed',  v_ocr,
    'complete',        jsonb_array_length(v_not_started) = 0
                       and jsonb_array_length(v_partial) = 0
                       and jsonb_array_length(v_ocr) = 0
                       and v_components is not null
  );
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- FR-I16's approval, refusing an unreviewed set first
-- ═══════════════════════════════════════════════════════════════════════

-- Same signature and the same body as FR-I16's, with ONE block added: the
-- ocr_unreviewed refusal, raised ahead of not_started. Built as a sentence with
-- the GR numbers in it, in the same shape and the same register as the two
-- beside it, because the criterion this serves is FR-I16's — the controller has
-- to be told which candidates, not handed a code.
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

  -- FR-I14. Raised BEFORE not_started: a script waiting for a human is a
  -- sharper diagnosis than "no mark and no status", and the case this ordering
  -- really exists for is the set that was keyed by hand while an unreviewed
  -- batch of the same scripts sat on file — where the other two lists are empty
  -- and the set would otherwise be signed off.
  if jsonb_array_length(v_check -> 'ocr_unreviewed') > 0 then
    select string_agg(c ->> 'gr_number', ', ' order by c ->> 'gr_number'), count(*)
      into v_names, v_count
      from jsonb_array_elements(v_check -> 'ocr_unreviewed') as c;
    raise exception '%',
      format('%s candidate%s %s an OCR mark no teacher has confirmed: %s',
             v_count, case when v_count = 1 then '' else 's' end,
             case when v_count = 1 then 'has' else 'have' end, v_names)
      using errcode = '23514',
            detail = format('exam_subject %s, section %s', p_exam_subject_id, p_section_id),
            hint = 'Confirm or amend every scanned script, then promote the batch — or cancel it and enter the marks by hand.';
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

-- ═══════════════════════════════════════════════════════════════════════
-- FR-I12's writer: the manual path says so
-- ═══════════════════════════════════════════════════════════════════════

-- FR-I17's body, re-emitted, with provenance made explicit. Two changes:
--
--   * an INSERT is 'manual' with no job, stated rather than left to the column
--     default, because this function IS the hand-entry path;
--   * an UPDATE that CHANGES the number resets a promoted row to 'manual'. The
--     number is now the teacher's, and a row that kept claiming OCR provenance
--     while carrying a hand-typed value would make source a lie. Nothing is
--     lost — the machine's reading, the confirmation and the actor all stay in
--     ocr_review_action, which is where AC4 looks.
--
-- Re-saving the SAME number changes nothing, so the grid's autosave cannot
-- quietly strip provenance off a set the teacher only scrolled past.
create or replace function public.fn_upsert_marks(
  p_payload         jsonb,
  p_client_batch_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_es_id     uuid;
  v_es        record;
  v_sections  uuid[];
  v_section   uuid;
  v_cell      record;
  v_saved     int := 0;
  v_response  jsonb;
  v_existing  jsonb;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'MARK_PAYLOAD_INVALID' using errcode = '23514';
  end if;

  v_es_id := nullif(p_payload ->> 'exam_subject_id', '')::uuid;
  if v_es_id is null then
    raise exception 'MARK_PAYLOAD_INVALID' using errcode = '23514',
      detail = 'The payload must name an exam_subject_id.';
  end if;
  if jsonb_typeof(p_payload -> 'marks') <> 'array' then
    raise exception 'MARK_PAYLOAD_INVALID' using errcode = '23514',
      detail = 'The payload must carry a marks array.';
  end if;

  select es.id, es.tenant_id, es.campus_id, es.exam_term_id
    into v_es
    from public.exam_subject es
   where es.id = v_es_id;
  if v_es.id is null then
    raise exception 'EXAM_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_tenant_id is not null and v_es.tenant_id <> v_tenant_id then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select array_agg(distinct e.section_id) into v_sections
    from jsonb_array_elements(p_payload -> 'marks') as c
    join public.enrolment e on e.id = (c ->> 'enrolment_id')::uuid
   where e.deleted_at is null;
  if v_sections is null or array_length(v_sections, 1) <> 1 then
    raise exception 'MARK_PAYLOAD_INVALID' using errcode = '23514',
      detail = 'One batch covers exactly one section of live enrolments.';
  end if;
  v_section := v_sections[1];

  if not app.fn_can_enter_marks(v_es_id, v_section) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- FR-I16's lock, raised ahead of trg_mark_entry_block_when_locked so the
  -- caller gets one refusal for the batch rather than one for the first cell.
  if app.fn_marks_locked(v_es_id, v_section) then
    raise exception 'marks_locked' using errcode = '42501',
      hint = 'These marks were approved and signed off. A correction needs a break-glass unlock.';
  end if;

  -- FR-I01's term freeze, which an open break-glass window is the one way past.
  if app.fn_exam_term_weight_frozen(v_es.exam_term_id)
     and not app.fn_break_glass_open(v_es_id, v_section) then
    raise exception 'marks are locked by approval — raise a result-recompute request'
      using errcode = '42501';
  end if;

  if p_client_batch_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('mark-batch:' || p_client_batch_id::text, 0));
    select response into v_existing
      from public.mark_entry_batch where client_batch_id = p_client_batch_id;
    if v_existing is not null then
      return v_existing || jsonb_build_object('replayed', true);
    end if;
  end if;

  for v_cell in
    select (c ->> 'enrolment_id')::uuid                     as enrolment_id,
           (c ->> 'component')::public.mark_component_code  as component,
           (c ->> 'marks_obtained')::numeric                as marks_obtained
      from jsonb_array_elements(p_payload -> 'marks') as c
  loop
    if v_cell.marks_obtained is null then
      delete from public.mark_entry
       where exam_subject_id = v_es_id
         and enrolment_id = v_cell.enrolment_id
         and component_code = v_cell.component;
      continue;
    end if;

    insert into public.mark_entry as m (
      tenant_id, campus_id, exam_subject_id, enrolment_id, component_code,
      marks_obtained, entered_by, client_batch_id, source, ocr_job_id
    ) values (
      v_es.tenant_id, v_es.campus_id, v_es_id, v_cell.enrolment_id, v_cell.component,
      v_cell.marks_obtained, (select auth.uid()), p_client_batch_id, 'manual', null
    )
    on conflict (tenant_id, exam_subject_id, enrolment_id, component_code) do update
      set marks_obtained  = excluded.marks_obtained,
          entered_by      = excluded.entered_by,
          entered_at      = now(),
          client_batch_id = excluded.client_batch_id,
          -- FR-I14: typing a DIFFERENT number over a promoted mark makes it
          -- hand-entered. Retyping the same one changes nothing.
          source          = case when m.marks_obtained is distinct from excluded.marks_obtained
                                 then 'manual'::public.mark_source else m.source end,
          ocr_job_id      = case when m.marks_obtained is distinct from excluded.marks_obtained
                                 then null else m.ocr_job_id end;

    v_saved := v_saved + 1;
  end loop;

  v_response := jsonb_build_object('saved', v_saved, 'replayed', false);

  if p_client_batch_id is not null then
    insert into public.mark_entry_batch (
      tenant_id, campus_id, exam_subject_id, client_batch_id, submitted_by, payload, response
    ) values (
      v_es.tenant_id, v_es.campus_id, v_es_id, p_client_batch_id, (select auth.uid()), p_payload, v_response
    );
  end if;

  return v_response;
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- The grid: an OCR mark is visibly not a typed one
-- ═══════════════════════════════════════════════════════════════════════

-- FR-I17's body with two additions and the same three-argument signature, so
-- this is a genuine replacement rather than a second overload:
--
--   'ocr'          — the open batch, if there is one, and how far through it
--                    the teacher is;
--   per student:   'mark_sources' (which of their marks a machine produced) and
--                  'ocr_questions' (what the machine read, what has been
--                  confirmed, and by whom).
--
-- Still one round trip, because the grid is still opened on a 2G phone.
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
  v_glass     jsonb;
  v_ocr       jsonb;
  -- Scalars rather than a record: the students query below reads the job id
  -- unconditionally, and an unassigned record would raise on a section with no
  -- exam subject at all.
  v_job_id    uuid;
  v_job_stat  public.ocr_job_status;
  v_job_comp  public.mark_component_code;
  v_job_eng   text;
  v_total     integer := 0;
  v_reviewed  integer := 0;
  v_has_lock  boolean := false;
  v_open      boolean := false;
begin
  v_readiness := public.fn_exam_entry_readiness(p_exam_term_id, p_section_id, p_subject_id);
  v_es_id := nullif(v_readiness ->> 'exam_subject_id', '')::uuid;

  select campus_id into v_campus_id from public.class_section where id = p_section_id;

  if v_es_id is not null then
    select jsonb_build_object(
             'locked_at',       l.locked_at,
             'locked_by',       l.locked_by,
             'locked_by_name',  u.full_name,
             'unlock_state',    l.unlock_state,
             'candidate_count', l.candidate_count,
             'mark_count',      l.mark_count,
             'result_stale_at', l.result_stale_at
           )
      into v_lock
      from public.mark_lock l
      left join public.app_user u on u.user_id = l.locked_by
     where l.exam_subject_id = v_es_id and l.section_id = p_section_id;
    v_has_lock := v_lock is not null;
    v_open := app.fn_break_glass_open(v_es_id, p_section_id);

    if v_open then
      select jsonb_build_object(
               'request_id',        r.id,
               'reason',            r.reason,
               'approved_at',       r.approved_at,
               'expires_at',        r.expires_at,
               'approved_by_name',  ap.full_name,
               'requested_by_name', rq.full_name
             )
        into v_glass
        from public.mark_unlock_request r
        left join public.app_user ap on ap.user_id = r.approved_by
        left join public.app_user rq on rq.user_id = r.requested_by
       where r.exam_subject_id = v_es_id
         and r.section_id = p_section_id
         and r.status = 'approved'
         and r.expires_at > clock_timestamp();
    end if;

    -- FR-I14. At most one, by uq_ocr_job_open — and only ever one component's
    -- worth, because a job is one pile of paper.
    select j.id, j.status, j.component_code, j.engine
      into v_job_id, v_job_stat, v_job_comp, v_job_eng
      from public.ocr_mark_job j
     where j.exam_subject_id = v_es_id
       and j.section_id = p_section_id
       and j.status in ('pending', 'ready')
     limit 1;

    if v_job_id is not null then
      select t.total, t.reviewed into v_total, v_reviewed
        from app.fn_ocr_review_progress(v_job_id) t;
      v_ocr := jsonb_build_object(
        'job_id',         v_job_id,
        'status',         v_job_stat,
        'component',      v_job_comp,
        'engine',         v_job_eng,
        'script_count',   v_total,
        'reviewed_count', v_reviewed,
        'can_promote',    v_total > 0 and v_reviewed = v_total
      );
    end if;
  end if;

  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'enrolment_id',      s.enrolment_id,
               'roll_no',           s.roll_no,
               'student_name',      s.student_name,
               'gr_number',         s.gr_number,
               'marks',             s.marks,
               'mark_sources',      s.mark_sources,
               'status',            s.mark_status,
               'attendance_status', s.attendance_status,
               'absence_reason',    s.absence_reason,
               'report_symbol',     s.report_symbol,
               'ocr_questions',     s.ocr_questions
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
             -- FR-I14: which of these numbers a machine produced, so the grid
             -- can say so in the cell rather than in a tooltip nobody opens.
             coalesce(
               (select jsonb_object_agg(m.component_code, m.source)
                  from public.mark_entry m
                 where m.exam_subject_id = v_es_id and m.enrolment_id = e.id),
               '{}'::jsonb
             )                   as mark_sources,
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
             end                                                            as report_symbol,
             coalesce(
               (select jsonb_agg(
                         jsonb_build_object(
                           'question_no', sg.question_no,
                           'ocr_value',   sg.ocr_value,
                           'confidence',  sg.confidence,
                           'final_value', lv.final_value,
                           'reviewed',    lv.final_value is not null,
                           'actor_name',  lv.actor_name,
                           'acted_at',    lv.acted_at
                         ) order by sg.question_no)
                  from public.ocr_mark_suggestion sg
                  left join lateral (
                    select r.final_value, r.acted_at, u.full_name as actor_name
                      from public.ocr_review_action r
                      left join public.app_user u on u.user_id = r.actor_id
                     where r.job_id = sg.job_id
                       and r.enrolment_id = sg.enrolment_id
                       and r.question_no = sg.question_no
                     order by r.acted_at desc, r.id desc
                     limit 1
                  ) lv on true
                 where sg.job_id = v_job_id and sg.enrolment_id = e.id),
               '[]'::jsonb
             )                   as ocr_questions
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
         'can_enter',      app.fn_can_enter_marks(v_es_id, p_section_id)
                             and (not v_has_lock or v_open),
         'mark_precision', app.fn_mark_precision(v_campus_id),
         'can_exempt',     app.auth_tenant_id() is null
                             or app.auth_role() in ('super_admin', 'owner', 'principal',
                                                    'vice_principal', 'exam_controller'),
         -- Still true during a window: the set IS signed off, it is simply
         -- open for the next few minutes and every keystroke is being recorded.
         'is_locked',      v_has_lock,
         'lock',           v_lock,
         'break_glass',    v_glass,
         'ocr',            v_ocr,
         'can_approve',    app.auth_tenant_id() is null
                             or app.auth_role() in ('super_admin', 'owner', 'principal', 'exam_controller'),
         'students',       v_students
       );
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.ocr_mark_job enable row level security;
alter table public.ocr_mark_suggestion enable row level security;
alter table public.ocr_review_action enable row level security;

-- Whoever may enter the marks may see the machine's attempt at them. Office
-- roles qualify through fn_can_enter_marks() exactly as they do on mark_entry,
-- so the approval board and the exceptions trail need no policy of their own.
create policy ocr_mark_job_read on public.ocr_mark_job
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or (campus_id = any(app.auth_campus_ids())
          and app.fn_can_enter_marks(exam_subject_id, section_id))
    )
  );

create policy ocr_mark_job_update_denied on public.ocr_mark_job
  for update to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  )
  with check (false);

create policy ocr_mark_job_delete_denied on public.ocr_mark_job
  for delete to authenticated
  using (false);

create policy ocr_mark_suggestion_read on public.ocr_mark_suggestion
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner')
         or (campus_id = any(app.auth_campus_ids()) and app.fn_can_read_ocr_job(job_id)))
  );

create policy ocr_mark_suggestion_update_denied on public.ocr_mark_suggestion
  for update to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  )
  with check (false);

create policy ocr_mark_suggestion_delete_denied on public.ocr_mark_suggestion
  for delete to authenticated
  using (false);

-- The FR's ocr_review_insert_only. INSERT gets no policy at all — RLS with no
-- INSERT policy denies it, and fn_record_ocr_review() is the only writer — and
-- UPDATE/DELETE are denied here AND by triggers that bind service_role and the
-- table owner too. See the header for why the trigger rather than the grant is
-- the load-bearing half.
create policy ocr_review_action_read on public.ocr_review_action
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner')
         or (campus_id = any(app.auth_campus_ids()) and app.fn_can_read_ocr_job(job_id)))
  );

create policy ocr_review_action_update_denied on public.ocr_review_action
  for update to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  )
  with check (false);

create policy ocr_review_action_delete_denied on public.ocr_review_action
  for delete to authenticated
  using (false);
