-- FR-I01: exam term definition and weightage.
--
-- "As an Exam Controller, I want to define the exam terms for an academic
-- session with their weightage, so that every downstream mark, aggregate
-- and report card rolls up against one agreed structure."
--
-- First migration of module I (Examinations). Grepped every migration for
-- exam_term / exam_subject / mark before writing: nothing of module I
-- exists. What DOES exist, and had to be reconciled, is below.
--
-- ── Why this is not public.academic_term (FR-A05) ──────────────────────
--
-- 20260729155339_session_lifecycle_and_terms.sql already ships
-- academic_term: (session_id, name, starts_on, ends_on, weightage
-- numeric(5,2), sequence, is_locked), written and rewritten as a whole set
-- by set_academic_terms(p_session_id, p_terms jsonb). It is the academic
-- CALENDAR's term — the dated blocks a session divides into — and it is
-- currently referenced by nothing but its own audit trigger.
--
-- It was seriously considered as the home for this FR and rejected, because
-- every one of FR-I01's acceptance criteria contradicts a rule
-- academic_term already ships and already has passing pgTAP for:
--
--   * AC1 needs a 0% term (Pre-Board). academic_term has
--     `check (weightage > 0)`.
--   * AC4 needs terms EXCLUDED from the 100% total (weekly tests).
--     set_academic_terms() requires every row to be in the sum.
--   * AC4's weekly tests mean more than four terms. set_academic_terms()
--     raises TERM_COUNT_INVALID above 4.
--   * AC1/AC2 need an activation STATUS transition that can be refused
--     ("NO term changes status"). academic_term has no status; its writer
--     deletes and re-inserts the whole set on every edit, which cannot
--     preserve per-row status at all.
--   * AC3 needs per-row weightage immutability once marks are approved.
--     Delete-and-reinsert is the opposite of that.
--   * exam terms are per-campus (two campuses of one tenant can run
--     different exam structures against the same session). academic_term
--     has no campus_id, and adding one would change the meaning of
--     academic_term_sequence_uniq underneath FR-A05's tests.
--
-- Reusing it therefore means gutting a shipped, tested FR to fit a newer
-- one. exam_term is a separate table with the examinations module's
-- semantics, and academic_term keeps the calendar's. The overlap on the
-- word "term" is real and is flagged rather than hidden: if the two ever
-- need to be associated, the association is one nullable FK away, and that
-- FK is deliberately NOT added here because nothing consumes it yet.
--
-- ── Weightage is basis points, not a percentage float ──────────────────
--
-- weight_bp is an integer count of basis points: 1 bp = 0.01%, 100.00% =
-- 10000 bp. This follows the same discipline as money in this schema
-- (fee_ledger.amount_paisa, expense_voucher.amount_paisa — bigint paisa,
-- never a fractional rupee), for the same reason and with the same payoff:
--
--   * "the weights total 100%" becomes `sum(weight_bp) = 10000`, an integer
--     equality with no rounding mode, no epsilon and no scale coercion. A
--     numeric(5,2) column would also be exact in Postgres, but the sum
--     would still be compared against a literal whose scale has to be
--     reasoned about, and any future percentage arriving from JSON or a
--     form as a float would silently round on cast.
--   * two decimal places is exactly one basis point, which is precisely the
--     precision AC2's "90.00%" is written in. A weight of 33.333% is not
--     representable — deliberately: three "equal" terms that each round to
--     33.33% do not total 100.00%, and a school has to choose weights that
--     actually add up rather than discovering the shortfall in a report
--     card six months later.
--
-- weight_pct numeric(5,2) is a GENERATED column over weight_bp, so the
-- percentage the FR names is queryable and renderable without every caller
-- repeating the /100, and cannot drift from the stored truth because it is
-- not separately writable. AC3's "when a user edits weight_pct" is enforced
-- against weight_bp, the column that actually stores it — blocking edits to
-- a generated column would be a tautology, not a control.
--
-- ── AC2's message is asserted text, not an error code ──────────────────
--
-- Almost every error in this schema is a SCREAMING_SNAKE code that the UI
-- translates (FORBIDDEN, SESSION_NOT_FOUND, ...). AC2 asserts the wording
-- itself, including the two decimal places in "currently 90.00%", so this
-- one is a sentence built in SQL and passed through to the user verbatim —
-- the same exception this codebase already makes for 'certificate register
-- is append-only' (FR-T08). Formatting is to_char(..., 'FM999999990.00'),
-- which renders 9000 bp as "90.00" and 10000 bp as "100.00".
--
-- ── AC3: "a term with at least one APPROVED mark set" ──────────────────
--
-- There are no marks in this schema. FR-I12 (teacher mark entry) and
-- FR-I16 (mark approval and locking) are both later FRs, so the state AC3
-- keys off does not exist yet and this migration does not invent a mark
-- table to pretend otherwise.
--
-- What is built is the guard, against the approval-ish state that genuinely
-- exists today, shaped so FR-I16 changes nothing but one call site:
--
--   app.fn_exam_term_weight_frozen(p_exam_term_id) is the single predicate.
--   It is true when EITHER
--     (a) the term's status is 'locked' — set only by lock_exam_term(),
--         which is the seam FR-I16 calls the moment it approves a mark set
--         against the term; or
--     (b) the term's session has academic_session.result_locked_at set —
--         a real column shipped in the foundation migration, meaning this
--         session's results are closed.
--
--   trg_exam_term_weight_immutable (BEFORE UPDATE, every caller, including
--   the table owner and service_role) refuses any change to weight_bp or
--   counts_toward_annual while that predicate holds, and the message names
--   the result-recompute request AC3 says the user should be directed to.
--   set_exam_term_weight() raises the same message first so the UI gets it
--   without a constraint-violation wrapper.
--
-- counts_toward_annual is frozen alongside weight_bp on purpose: flipping a
-- term out of the annual aggregate changes the denominator every approved
-- mark was aggregated against just as surely as editing its weight does.
--
-- So: the mechanism is real, tested and enforced at the row level today via
-- both (a) and (b). What is NOT real is a marks table for (a) to be driven
-- by — lock_exam_term() is called by tests and by nothing else until
-- FR-I16 exists.
--
-- ── Why the freeze raises 42501 and not 55000 ──────────────────────────
--
-- 'object_not_in_prerequisite_state' (55000) is this schema's usual code
-- for a state refusal, and EXAM_TERM_NOT_DRAFT / EXAM_TERM_NOT_ACTIVE below
-- keep it. The AC3 freeze does not, because PostgREST maps SQLSTATE class
-- 55 to HTTP 500 and replaces the body with {"message":"Something went
-- wrong"} — verified against the running stack, not assumed. A message the
-- acceptance criteria require a user to READ cannot travel on a code that
-- strips it. 42501 (insufficient_privilege) maps to 403 with the message
-- intact, and is already what this schema uses for the equivalent
-- immutability refusal, 'certificate register is append-only' (FR-T08).
--
-- The two remaining 55000s are unreachable through this FR's own screen —
-- Remove renders only for a draft term and Lock only for an active one —
-- so their sanitized fallback is a cosmetic edge, not a broken control.
-- That PostgREST behaviour affects all 126 pre-existing 55000 raises in
-- this schema equally; it is noted here, not fixed here.
--
-- ── Where the 100% gate is, and deliberately is not ───────────────────
--
-- The total is validated at ACTIVATION (AC1/AC2) and frozen once results
-- ride on it (AC3). It is NOT re-validated on every weight edit in between,
-- and that is a decision rather than an oversight: rebalancing an activated
-- set from 25/15/60 to 30/15/55 necessarily passes through an invalid
-- intermediate, so a per-row re-check would make any two-term rebalance
-- impossible through a per-row API and would be trivially worked around by
-- deactivating first. The window is bounded on both sides — you cannot
-- activate an invalid set, and you cannot edit one that has approved marks
-- — and the FR-I01 screen renders the live total against 100.00% so a set
-- left mid-rebalance is visible rather than silent. If a school needs the
-- stricter rule, the place for it is a statement-level constraint trigger,
-- not a row-level one.
--
-- ── Roles, and the RLS shape ──────────────────────────────────────────
--
-- 'exam_controller' is a real public.app_role value (foundation migration,
-- and one of the 16 seeded system roles in FR-A10's catalogue), so the FR's
-- role gate needed no invention. It is spelled
-- ('super_admin', 'owner', 'principal', 'exam_controller') everywhere here,
-- adding owner/super_admin to the FR's ('exam_controller', 'principal')
-- the same way create_subject() and every other Module E writer does — an
-- Owner locked out of their own exam structure would be a bug, not a
-- control.
--
-- Reads get exam_term_campus_scope, copied in shape from
-- class_subject_campus_scope. Writes get NO policy: RLS with no INSERT or
-- UPDATE policy denies both by default, and every controlled write in this
-- schema goes through a SECURITY DEFINER function that gates its own role
-- and campus scope. The FR suggests an exam_term_write_controller policy;
-- adding one would split authorization across two mechanisms for no gain,
-- since PostgREST clients would still be writing through the RPCs.
--
-- Likewise the FR's suggested exam_term_audit table is not created:
-- public.audit_log + app.tg_audit_row() already records before/after/
-- changed_columns/actor for every table in this schema, and a second,
-- narrower audit trail is a place for the two to disagree.
--
-- ── Interaction with what already exists ───────────────────────────────
--
-- Session-scoped by construction (session_id FK, on delete cascade), so
-- FR-A06's rollover into a new session correctly starts with no exam terms
-- rather than inheriting last year's — rollover copies students and
-- structure, not assessment setup, and extending it is FR-A06's call, not
-- this migration's. No deleted_at column: FR-A15's soft delete covers
-- student/enrolment/fee_challan, and a draft term is removed outright by
-- delete_exam_term() while an activated one cannot be removed at all.

-- ═══════════════════════════════════════════════════════════════════════
-- Schema
-- ═══════════════════════════════════════════════════════════════════════

create type public.exam_term_status as enum ('draft', 'active', 'locked');

create table public.exam_term (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  session_id           uuid not null references public.academic_session(id) on delete cascade,
  code                 text not null,
  name                 text not null,
  name_ur              text,
  sequence             smallint not null,
  -- 1 bp = 0.01%. See the header: integer basis points, not a percentage.
  weight_bp            integer not null default 0,
  weight_pct           numeric(5,2) generated always as (weight_bp::numeric / 100) stored,
  counts_toward_annual boolean not null default true,
  status               public.exam_term_status not null default 'draft',
  activated_at         timestamptz,
  locked_at            timestamptz,
  created_at           timestamptz not null default now(),
  constraint chk_exam_term_weight_bp check (weight_bp between 0 and 10000),
  constraint chk_exam_term_sequence check (sequence between 1 and 40)
);

create unique index uq_exam_term_seq on public.exam_term (tenant_id, campus_id, session_id, sequence);
create unique index uq_exam_term_code on public.exam_term (tenant_id, campus_id, session_id, upper(code));
create index idx_exam_term_session_campus on public.exam_term (session_id, campus_id, sequence);
-- The weightage sum reads only the counting terms; index the predicate it
-- actually filters on.
create index idx_exam_term_counting on public.exam_term (session_id, campus_id)
  where counts_toward_annual;

create trigger exam_term_audit after insert or update or delete on public.exam_term
  for each row execute function app.tg_audit_row();

comment on column public.exam_term.weight_bp is
  'Weightage in basis points: 1 bp = 0.01%, 100.00% = 10000. Counting terms must total exactly 10000 to activate.';
comment on column public.exam_term.counts_toward_annual is
  'False for non-counting terms (weekly tests, mock/pre-board): excluded from the 100% validation, still rendered on the report card.';

-- ═══════════════════════════════════════════════════════════════════════
-- AC2 / AC4: the weightage total, and what is in it
-- ═══════════════════════════════════════════════════════════════════════

-- Raises when the counting terms of one session+campus do not total exactly
-- 100.00%. Returns void on success.
--
-- The FR suggests fn_validate_term_weightage(p_session_id). It takes the
-- campus too: exam terms are per-campus (uq_exam_term_seq is keyed on
-- campus_id), and a session shared by two campuses would otherwise have
-- both campuses' terms summed into one meaningless total that can never
-- reach 100 without them colluding.
--
-- SECURITY DEFINER because trg_exam_term_weightage_check must see every
-- sibling row regardless of the caller's RLS — and per the lesson recorded
-- in FR-K24, a SECURITY DEFINER function owned by postgres BYPASSES RLS, so
-- the tenant/campus scope it needs is written out explicitly below rather
-- than left to a policy that will not run.
create or replace function public.fn_validate_term_weightage(
  p_session_id uuid,
  p_campus_id  uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sum_bp integer;
begin
  -- Interactive callers are held to their own campus scope. The
  -- `auth_tenant_id() is null` escape is this schema's established
  -- convention for functions also reachable without a JWT (here: from a
  -- trigger fired inside another SECURITY DEFINER function, and from
  -- pgTAP).
  if app.auth_tenant_id() is not null then
    if not exists (
      select 1 from public.campus
       where id = p_campus_id and tenant_id = app.auth_tenant_id()
    ) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if app.auth_role() not in ('super_admin', 'owner')
       and not (p_campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  -- AC4: non-counting terms are excluded from the total outright. They are
  -- not "counted as zero" — a weekly-test term may legitimately carry its
  -- own display weight and must still never move this sum.
  select coalesce(sum(weight_bp), 0)
    into v_sum_bp
    from public.exam_term
   where session_id = p_session_id
     and campus_id = p_campus_id
     and counts_toward_annual;

  if v_sum_bp <> 10000 then
    -- AC2 asserts this sentence verbatim, including "currently 90.00%".
    -- Built with format() rather than RAISE's own %-substitution: RAISE
    -- scans "%%%" left to right as literal-percent-then-argument, so the
    -- trailing "90.00%" this message needs is not expressible there.
    raise exception '%',
      format('Term weightage must total 100.00%%, currently %s%%',
             to_char(v_sum_bp / 100.0, 'FM999999990.00'))
      using errcode = '22023',
            detail = format('session %s, campus %s, %s bp across counting terms',
                            p_session_id, p_campus_id, v_sum_bp);
  end if;
end;
$$;

revoke execute on function public.fn_validate_term_weightage(uuid, uuid) from public, anon;
grant execute on function public.fn_validate_term_weightage(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC1 / AC2: activation, and the trigger that refuses it
-- ═══════════════════════════════════════════════════════════════════════

-- Fires per row, but validates the SET — the sum is the same whichever row
-- of the set is being activated, and because the whole activation is one
-- UPDATE statement, a raise on any row aborts the statement and leaves
-- every term's status exactly as it was. That is AC2's "NO term changes
-- status", enforced by transaction semantics rather than by ordering.
create or replace function app.tg_exam_term_weightage_check()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'active' and old.status is distinct from 'active' then
    perform public.fn_validate_term_weightage(new.session_id, new.campus_id);
  end if;
  return new;
end;
$$;

create trigger trg_exam_term_weightage_check
  before update of status on public.exam_term
  for each row execute function app.tg_exam_term_weightage_check();

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the weightage freeze
-- ═══════════════════════════════════════════════════════════════════════

-- The single predicate for "this term's weightage has downstream results
-- riding on it". See the header for what is real today and what waits on
-- FR-I16.
create or replace function app.fn_exam_term_weight_frozen(p_exam_term_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.exam_term t
      join public.academic_session s on s.id = t.session_id
     where t.id = p_exam_term_id
       and (t.status = 'locked' or s.result_locked_at is not null)
  );
$$;

create or replace function app.tg_exam_term_weight_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.weight_bp is distinct from old.weight_bp
      or new.counts_toward_annual is distinct from old.counts_toward_annual)
     and app.fn_exam_term_weight_frozen(old.id) then
    raise exception 'exam term weightage is locked by approved marks — raise a result-recompute request'
      using errcode = '42501',
            detail = format('exam_term %s (%s)', old.id, old.name),
            hint = 'Recomputing an aggregate that marks were already approved against is a result correction, not an edit.';
  end if;
  return new;
end;
$$;

create trigger trg_exam_term_weight_immutable
  before update on public.exam_term
  for each row execute function app.tg_exam_term_weight_immutable();

-- ═══════════════════════════════════════════════════════════════════════
-- Writers
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.exam_term_weight_bp(p_weight_pct numeric)
returns integer
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_weight_pct is null or p_weight_pct < 0 or p_weight_pct > 100 then
    raise exception 'WEIGHT_OUT_OF_RANGE' using errcode = '23514';
  end if;
  -- The basis-point floor made explicit: 33.333% is refused here rather
  -- than silently rounded to 33.33% and quietly failing to total 100.
  if p_weight_pct * 100 <> round(p_weight_pct * 100) then
    raise exception 'WEIGHT_PRECISION' using errcode = '22023',
      detail = 'Weightage supports at most two decimal places.';
  end if;
  return round(p_weight_pct * 100)::integer;
end;
$$;

create or replace function public.upsert_exam_term(
  p_campus_id            uuid,
  p_session_id           uuid,
  p_code                 text,
  p_name                 text,
  p_sequence             smallint,
  p_weight_pct           numeric,
  p_counts_toward_annual boolean default true,
  p_name_ur              text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid;
  v_weight_bp integer := app.exam_term_weight_bp(p_weight_pct);
  v_existing  record;
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
    select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id
  ) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from public.academic_session
     where id = p_session_id
       and tenant_id = v_tenant_id
       and (campus_id is null or campus_id = p_campus_id)
  ) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_code is null or btrim(p_code) = '' or p_name is null or btrim(p_name) = '' then
    raise exception 'EXAM_TERM_NAME_REQUIRED' using errcode = '23514';
  end if;

  select id, weight_bp, counts_toward_annual into v_existing
    from public.exam_term
   where tenant_id = v_tenant_id
     and campus_id = p_campus_id
     and session_id = p_session_id
     and upper(code) = upper(btrim(p_code));

  if not found then
    insert into public.exam_term (
      tenant_id, campus_id, session_id, code, name, name_ur,
      sequence, weight_bp, counts_toward_annual
    ) values (
      v_tenant_id, p_campus_id, p_session_id, upper(btrim(p_code)), p_name, p_name_ur,
      p_sequence, v_weight_bp, p_counts_toward_annual
    )
    returning id into v_id;
    return v_id;
  end if;

  -- AC3's message, raised ahead of trg_exam_term_weight_immutable so the
  -- caller sees the sentence rather than a trigger-wrapped one. Renaming or
  -- resequencing a frozen term is still allowed — only the two columns the
  -- aggregate depends on are shut.
  if (v_weight_bp <> v_existing.weight_bp
      or p_counts_toward_annual <> v_existing.counts_toward_annual)
     and app.fn_exam_term_weight_frozen(v_existing.id) then
    raise exception 'exam term weightage is locked by approved marks — raise a result-recompute request'
      using errcode = '42501';
  end if;

  update public.exam_term
     set name                 = p_name,
         name_ur              = p_name_ur,
         sequence             = p_sequence,
         weight_bp            = v_weight_bp,
         counts_toward_annual = p_counts_toward_annual
   where id = v_existing.id;

  return v_existing.id;
end;
$$;

revoke execute on function public.upsert_exam_term(uuid, uuid, text, text, smallint, numeric, boolean, text)
  from public, anon;
grant execute on function public.upsert_exam_term(uuid, uuid, text, text, smallint, numeric, boolean, text)
  to authenticated;

-- AC1: activate the whole term set for one session+campus. One UPDATE, so
-- AC2's refusal leaves every row untouched.
create or replace function public.activate_exam_terms(
  p_session_id uuid,
  p_campus_id  uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_activated integer;
begin
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner')
     and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- Explicit, ahead of the trigger: the trigger only fires for rows that
  -- actually change status, so an already-activated (or empty) set would
  -- otherwise skip validation entirely and report success.
  perform public.fn_validate_term_weightage(p_session_id, p_campus_id);

  update public.exam_term
     set status = 'active',
         activated_at = now()
   where tenant_id = v_tenant_id
     and session_id = p_session_id
     and campus_id = p_campus_id
     and status = 'draft';

  get diagnostics v_activated = row_count;
  return v_activated;
end;
$$;

revoke execute on function public.activate_exam_terms(uuid, uuid) from public, anon;
grant execute on function public.activate_exam_terms(uuid, uuid) to authenticated;

create or replace function public.set_exam_term_weight(
  p_exam_term_id uuid,
  p_weight_pct   numeric
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_campus_id uuid;
begin
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select campus_id into v_campus_id
    from public.exam_term
   where id = p_exam_term_id and tenant_id = v_tenant_id;
  if v_campus_id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner')
     and not (v_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if app.fn_exam_term_weight_frozen(p_exam_term_id) then
    raise exception 'exam term weightage is locked by approved marks — raise a result-recompute request'
      using errcode = '42501';
  end if;

  update public.exam_term
     set weight_bp = app.exam_term_weight_bp(p_weight_pct)
   where id = p_exam_term_id;
end;
$$;

revoke execute on function public.set_exam_term_weight(uuid, numeric) from public, anon;
grant execute on function public.set_exam_term_weight(uuid, numeric) to authenticated;

-- The FR-I16 seam. Nothing but tests calls this until mark approval exists;
-- when it does, approving a mark set against a term calls exactly this and
-- the AC3 freeze starts biting for the real reason.
create or replace function public.lock_exam_term(p_exam_term_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_campus_id uuid;
  v_status    public.exam_term_status;
begin
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select campus_id, status into v_campus_id, v_status
    from public.exam_term
   where id = p_exam_term_id and tenant_id = v_tenant_id;
  if v_campus_id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner')
     and not (v_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_status <> 'active' then
    raise exception 'EXAM_TERM_NOT_ACTIVE' using errcode = '55000';
  end if;

  update public.exam_term
     set status = 'locked', locked_at = now()
   where id = p_exam_term_id;
end;
$$;

revoke execute on function public.lock_exam_term(uuid) from public, anon;
grant execute on function public.lock_exam_term(uuid) to authenticated;

-- Draft terms only: once a term is selectable in mark entry, removing it is
-- a result correction, not a setup edit.
create or replace function public.delete_exam_term(p_exam_term_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_campus_id uuid;
  v_status    public.exam_term_status;
begin
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select campus_id, status into v_campus_id, v_status
    from public.exam_term
   where id = p_exam_term_id and tenant_id = v_tenant_id;
  if v_campus_id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner')
     and not (v_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_status <> 'draft' then
    raise exception 'EXAM_TERM_NOT_DRAFT' using errcode = '55000';
  end if;

  delete from public.exam_term where id = p_exam_term_id;
end;
$$;

revoke execute on function public.delete_exam_term(uuid) from public, anon;
grant execute on function public.delete_exam_term(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: "all four terms become selectable in mark entry"
-- ═══════════════════════════════════════════════════════════════════════

-- Selectability is a property of the term, not of a screen: a term is
-- selectable once it is out of draft. Both 'active' and 'locked' qualify —
-- a locked term is still the thing an already-approved mark belongs to, it
-- simply cannot be re-weighted. Mark entry (FR-I12) reads this view; until
-- it exists, the FR-I01 UI does.
create view public.v_exam_term_selectable
with (security_invoker = true) as
select t.id,
       t.tenant_id,
       t.campus_id,
       t.session_id,
       t.code,
       t.name,
       t.name_ur,
       t.sequence,
       t.weight_pct,
       t.counts_toward_annual,
       t.status,
       t.status = 'locked' as is_locked
  from public.exam_term t
 where t.status in ('active', 'locked');

revoke all on public.v_exam_term_selectable from public, anon;
grant select on public.v_exam_term_selectable to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.exam_term enable row level security;

create policy exam_term_campus_scope on public.exam_term
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
