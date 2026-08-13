-- FR-I17: break-glass mark unlock.
--
-- "As a Principal, I want a controlled way to reopen locked marks for a
-- genuine correction, so that errors can be fixed without the lock becoming
-- meaningless."
--
-- FR-I16 (20260731990000) made an approved mark set unwritable by every role,
-- including the table owner. That is the right default and it is also, on its
-- own, unusable: a Q5 total mis-added on six scripts has to be fixable. This
-- migration is the ONE way through, and every property below exists to keep it
-- from becoming an ordinary unlock button.
--
-- ── What the guard actually permits, and who can open it ──────────────
--
--   1. Two people. request_mark_unlock() is the Exam Controller's (or a
--      Principal's, a Vice Principal's, an Owner's). fn_break_glass_unlock()
--      is a Principal's, an Owner's or a Super Admin's — an Exam Controller
--      cannot approve, including their own request, because the whole point is
--      that the person who wants the marks open is not the person who opens
--      them.
--   2. Never yourself. chk_unlock_no_self_approve is a table CHECK, not a
--      policy and not a function branch: `approved_by is null or approved_by
--      <> requested_by` holds for service_role, for the table owner and for
--      any future writer, and it holds for a rejection too — a decision on a
--      break-glass request is always somebody else's, whichever way it goes.
--   3. A reason, in words. At least ten characters, and it is frozen the
--      moment the row is written. AC4's exceptions report is only worth
--      opening if the reasons in it are the ones that were actually given.
--   4. A bounded window. Default 60 minutes, 1 to 240, and it is a wall-clock
--      deadline rather than a session: app.fn_break_glass_open() compares
--      expires_at against clock_timestamp() on every single write, so the
--      moment the clock passes the deadline the marks are shut again whether
--      or not the sweep has run and whether or not the tab is still open.
--   5. One window at a time. uq_mark_unlock_open is a partial unique index on
--      (exam_subject_id, section_id) over the open statuses, so a set cannot
--      have two live justifications.
--   6. Marks only. exam_attendance stays frozen (FR-I11's
--      trg_exam_attendance_frozen is untouched): changing a candidate from
--      Present to Exempt changes the DENOMINATOR every other candidate's
--      percentage was computed against, which is a re-marking of the paper,
--      not a correction to one script. That needs the result-recompute path
--      FR-I11 already points at.
--
-- ── AC2: the window is closed by the clock, not by the UI ─────────────
--
-- The FR's Notes are the requirement: "The window has to be closed by pg_cron,
-- not by the UI. Tabs get closed and laptops sleep." Both halves are built,
-- and they are independent on purpose:
--
--   * The PREDICATE is what actually refuses a write, and it is time-based.
--     At 15:00:01 the edit fails, with no job having run. Nothing about the
--     lock depends on a sweep being punctual.
--   * fn_relock_expired_unlocks() is the sweep that makes the state durable
--     and visible: status 'approved' -> 'expired' and mark_lock.unlock_state
--     back to 'locked', so the queue, the grid and the exceptions report all
--     read a closed window rather than an open one with a past deadline.
--
-- There is no pg_cron in this stack, so this follows the same posture as every
-- other scheduled function in this schema (FR-B16, FR-K13, FR-D12, FR-B05,
-- FR-G11's sweep_attendance_locks): a plain, correct, tested function that a
-- real `cron.schedule('relock-expired-unlocks', '*/5 * * * *', ...)` calls.
--
-- fn_relock_expired_unlocks() takes p_as_of, defaulting to clock_timestamp().
-- That is not a test backdoor and it cannot widen anything: the sweep only
-- ever moves a window from open to closed, so passing a later timestamp closes
-- windows sooner and passing an earlier one closes fewer. It exists because
-- "the clock passes 15:00" is a thing a test has to be able to say, and
-- because an operator re-running a missed sweep should be able to name the
-- moment it should have run.
--
-- ── AC3: the before/after trail, and why mark_entry_audit exists now ──
--
-- FR-I12 explicitly declined to build mark_entry_audit: "public.audit_log +
-- app.tg_audit_row() already records before/after/changed_columns/actor for
-- every table here, and a second, narrower trail is a place for the two to
-- disagree." That reasoning was right and it is still right — and AC3 asks for
-- something audit_log structurally cannot give:
--
--   "an audit row captures old value, new value, actor AND UNLOCK REQUEST ID"
--
-- audit_log has no column for the authorisation a change was made under, and
-- adding one would mean adding it for every table in the schema to serve one.
-- So mark_entry_audit is not a second copy of the mark history: it is the
-- record of the changes made INSIDE a break-glass window, keyed to the window
-- that permitted them. app.tg_mark_entry_break_glass_audit() writes a row only
-- when a window is open, so an ordinary draft edit still leaves exactly one
-- trail (audit_log's) and there is nothing for the two to disagree about.
--
-- "every affected report card is marked stale": there is no report_card table
-- in this schema — FR-J is a later module — and inventing one to set a flag on
-- would be a table with no reader. What exists is FR-I16's readiness gate, and
-- that is where staleness belongs: mark_lock gains result_stale_at and
-- result_stale_request_id, stamped by the same trigger, and
-- fn_term_result_ready() reports the section as stale with the subjects that
-- changed. The result engine FR-J02 builds asks that function before computing
-- anyway; a stale answer is the signal it needs, and it cannot go out of date
-- because it is not cached anywhere.
--
-- ── Where a break-glass event is audited, and why there ───────────────
--
-- Three places, and each is answering a different question:
--
--   1. audit_log, via app.tg_audit_row() on mark_unlock_request,
--      mark_entry_audit and mark_lock. This is the AUTHORITATIVE record and it
--      is where FR-T09's rule puts it: an exclusion IS a row change, a failed
--      digest check is NOT. A request, its approval, its expiry and every mark
--      touched are all row changes, hash-chained and verified by FR-T14's
--      run_audit_chain_verification().
--   2. security_event, one 'mark_break_glass_unlock' row of severity 'alert'
--      at the moment the window opens. This is NOT a second record and it does
--      not contradict FR-T09's rule — that rule says where the EVIDENCE goes,
--      not that a row change may never also raise an alarm. audit_log is a
--      per-row change log nobody reads unprompted; security_event is the table
--      this schema built for "something a Principal should act on", it is read
--      by exactly super_admin/owner/principal, and it is itself covered by the
--      audit chain. A privilege grant that makes a signed-off result editable
--      is the single highest-value alert this module can raise, and burying it
--      as one of ten thousand audit_log rows would be the same as not raising
--      it.
--   3. mark_entry_audit, the before/after trail AC3 names, carrying the one
--      fact the other two cannot: which unlock request authorised the change.
--
-- ── Append-only, extended rather than relaxed ─────────────────────────
--
-- FR-I16 shipped mark_lock with an EMPTY update allow-list and said: "When
-- break-glass arrives it must add NAMED transitions with their own stack
-- frames — FR-T09's precedent — not soften this guard." That is what happens
-- below. app.tg_mark_lock_no_update() is re-emitted with the same frozen
-- column set and exactly three transitions:
--
--   A. UNLOCK — frame public.fn_break_glass_unlock(. unlock_state
--      'locked' -> 'unlocked', staleness untouched.
--   B. RELOCK — frame public.fn_relock_expired_unlocks(. unlock_state
--      'unlocked' -> 'locked', staleness untouched.
--   C. STALE  — frame app.tg_mark_entry_break_glass_audit(. unlock_state
--      unchanged, result_stale_at moves FORWARD only and
--      result_stale_request_id becomes non-null.
--
-- Anything else — including 'unlocked' -> 'unlocked', rewinding staleness, or
-- the owner editing locked_by by hand — still raises 'mark approval is
-- append-only'.
--
-- mark_unlock_request gets the same treatment, because a reason that could be
-- rewritten after the fact is not evidence:
--
--   * BORN PENDING. trg_mark_unlock_request_born_pending refuses any INSERT
--     that is not status='pending' with no decision on it. Without it,
--     service_role could insert a pre-approved request and walk straight
--     through the lock — an INSERT reaches no UPDATE guard.
--   * APPROVE / REJECT / EXPIRE are the three named transitions, each with its
--     own frame, each write-once from 'pending' (or, for EXPIRE, from
--     'approved'). requested_by, reason and requested_at are frozen in all
--     three.
--   * No DELETE, no TRUNCATE.
--
-- mark_entry_audit has no legal UPDATE at all, no DELETE and a TRUNCATE guard.
-- TRUNCATE fires no row trigger and consults no RLS (FR-T08's finding), and an
-- evidence table that can be emptied in one statement is not evidence.
--
-- ── The FR's suggested RLS policies ──────────────────────────────────
--
-- unlock_no_self_approve and unlock_approve_principal_only are built, but as a
-- CHECK CONSTRAINT and a function role gate rather than as RLS. Both are
-- stronger there: a policy binds only the roles it names, so service_role, the
-- table owner and any future SECURITY DEFINER function would walk past both —
-- and "you may not approve your own break-glass request" is exactly the rule
-- that has to hold for every caller. This is the same call FR-I01, FR-I11,
-- FR-I12 and FR-I16 each made about their own writes, and the same argument
-- FR-I16's own Notes make about the lock.

-- ═══════════════════════════════════════════════════════════════════════
-- Schema
-- ═══════════════════════════════════════════════════════════════════════

create type public.mark_unlock_status as enum ('pending', 'approved', 'expired', 'rejected');

create table public.mark_unlock_request (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  exam_term_id    uuid not null references public.exam_term(id) on delete cascade,
  exam_subject_id uuid not null references public.exam_subject(id) on delete cascade,
  section_id      uuid not null references public.class_section(id) on delete cascade,
  requested_by    uuid references public.app_user(user_id),
  requested_at    timestamptz not null default clock_timestamp(),
  -- AC1's "Q5 total mis-added on 6 scripts". Frozen once written.
  reason          text not null,
  -- The DECIDER and the moment of decision, whichever way it went. A rejection
  -- fills these too, which is why chk_unlock_no_self_approve covers both.
  approved_by     uuid references public.app_user(user_id),
  approved_at     timestamptz,
  decision_note   text,
  expires_at      timestamptz,
  relocked_at     timestamptz,
  status          public.mark_unlock_status not null default 'pending',
  created_at      timestamptz not null default now(),
  constraint chk_unlock_reason check (length(btrim(reason)) >= 10),
  -- The FR's unlock_no_self_approve, as a constraint rather than a policy: a
  -- policy binds only the roles it names.
  constraint chk_unlock_no_self_approve check (approved_by is null or approved_by <> requested_by),
  constraint chk_unlock_window check (expires_at is null or (approved_at is not null and expires_at > approved_at)),
  constraint chk_unlock_approved_shape check (
    (status = 'pending'  and approved_by is null and approved_at is null and expires_at is null)
    or (status = 'rejected' and approved_by is not null and approved_at is not null and expires_at is null)
    or (status in ('approved', 'expired') and approved_by is not null and approved_at is not null and expires_at is not null)
  )
);

-- One live justification per set. AC4's three unlocks are three SEQUENTIAL
-- windows, which is exactly the pattern the exceptions report is looking for.
create unique index uq_mark_unlock_open on public.mark_unlock_request (exam_subject_id, section_id)
  where status in ('pending', 'approved');
-- The FR's idx_unlock_expiry: the only index the five-minute sweep needs.
create index idx_unlock_expiry on public.mark_unlock_request (status, expires_at);
create index idx_mark_unlock_term on public.mark_unlock_request (exam_term_id, exam_subject_id);
create index idx_mark_unlock_campus on public.mark_unlock_request (tenant_id, campus_id, requested_at desc);

create trigger mark_unlock_request_audit after insert or update or delete on public.mark_unlock_request
  for each row execute function app.tg_audit_row();

comment on table public.mark_unlock_request is
  'FR-I17: the only way past FR-I16''s lock. Two people, a written reason, a wall-clock deadline, and an append-only record of all three.';
comment on column public.mark_unlock_request.expires_at is
  'The deadline the WRITE PATH compares against on every edit — not a hint for a job. The sweep only makes the closed state durable.';

-- AC3's staleness signal, on the lock row rather than on a report_card table
-- this schema does not have. See the header.
alter table public.mark_lock add column result_stale_at timestamptz;
alter table public.mark_lock add column result_stale_request_id uuid references public.mark_unlock_request(id);

comment on column public.mark_lock.result_stale_at is
  'FR-I17 AC3: a mark changed inside a break-glass window since this set was signed off. fn_term_result_ready() surfaces it; FR-J02 recomputes on it.';

-- AC3's trail. Written ONLY for changes made inside an open window — an
-- ordinary draft edit still leaves exactly one trail, audit_log's.
create table public.mark_entry_audit (
  id                     uuid primary key default gen_random_uuid(),
  tenant_id              uuid not null references public.tenant(id) on delete cascade,
  campus_id              uuid not null references public.campus(id) on delete cascade,
  mark_unlock_request_id uuid not null references public.mark_unlock_request(id) on delete cascade,
  mark_entry_id          uuid not null,
  exam_subject_id        uuid not null references public.exam_subject(id) on delete cascade,
  section_id             uuid not null references public.class_section(id) on delete cascade,
  enrolment_id           uuid not null references public.enrolment(id) on delete cascade,
  component_code         public.mark_component_code not null,
  action                 text not null,
  -- The two AC3 names. Null on the side that did not exist.
  old_marks              numeric(6,2),
  new_marks              numeric(6,2),
  actor_user_id          uuid references public.app_user(user_id),
  changed_at             timestamptz not null default clock_timestamp(),
  constraint chk_mark_entry_audit_action check (action in ('insert', 'update', 'delete'))
);

-- mark_entry_id is deliberately NOT a foreign key: the row it names may be
-- deleted inside the window (clearing a cell is a delete, FR-I12), and the
-- record of that deletion has to outlive it.
create index idx_mark_entry_audit_request on public.mark_entry_audit (mark_unlock_request_id, changed_at);
create index idx_mark_entry_audit_subject on public.mark_entry_audit (exam_subject_id, section_id, changed_at desc);
create index idx_mark_entry_audit_campus on public.mark_entry_audit (tenant_id, campus_id, changed_at desc);

create trigger mark_entry_audit_audit after insert or update or delete on public.mark_entry_audit
  for each row execute function app.tg_audit_row();

comment on table public.mark_entry_audit is
  'FR-I17 AC3: old value, new value, actor and UNLOCK REQUEST ID for every mark changed inside a break-glass window. The last of those is the fact audit_log structurally cannot carry.';

-- ═══════════════════════════════════════════════════════════════════════
-- The predicate every write path asks
-- ═══════════════════════════════════════════════════════════════════════

-- True while a window is genuinely open. Compared against clock_timestamp()
-- rather than now(): a long-running transaction must not be able to hold a
-- window open past its deadline by having started before it.
create or replace function app.fn_break_glass_open(
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
    select 1 from public.mark_unlock_request r
     where r.exam_subject_id = p_exam_subject_id
       and r.section_id = p_section_id
       and r.status = 'approved'
       and r.expires_at > clock_timestamp()
  );
$$;

create or replace function app.fn_open_unlock_request(
  p_exam_subject_id uuid,
  p_section_id      uuid
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select r.id from public.mark_unlock_request r
   where r.exam_subject_id = p_exam_subject_id
     and r.section_id = p_section_id
     and r.status = 'approved'
     and r.expires_at > clock_timestamp()
   limit 1;
$$;

-- FR-I16's predicate, minus an open window. Every caller of the lock asks this
-- one function, which is why break-glass is a change to one body rather than a
-- change to every call site.
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
  )
  and not app.fn_break_glass_open(p_exam_subject_id, p_section_id);
$$;

-- FR-I12's freeze, likewise. The open window subtracts BOTH conditions — the
-- per-row 'approved'/'locked' status and FR-I01's term-wide freeze — because
-- FR-I16 locks the term as soon as its last set is approved, so a window that
-- could not get past the term freeze would be useless in exactly the ordinary
-- case.
create or replace function app.fn_mark_entry_frozen(p_mark_entry_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.mark_entry m
      join public.exam_subject es on es.id = m.exam_subject_id
      join public.enrolment e on e.id = m.enrolment_id
     where m.id = p_mark_entry_id
       and (m.status in ('approved', 'locked')
            or app.fn_exam_term_weight_frozen(es.exam_term_id))
       and not app.fn_break_glass_open(m.exam_subject_id, e.section_id)
  );
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the trail, and the staleness stamp
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_mark_entry_break_glass_audit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row     record;
  v_section uuid;
  v_request uuid;
begin
  v_row := case when tg_op = 'DELETE' then old else new end;

  select e.section_id into v_section
    from public.enrolment e where e.id = v_row.enrolment_id;
  if v_section is null then
    return null;
  end if;

  v_request := app.fn_open_unlock_request(v_row.exam_subject_id, v_section);
  if v_request is null then
    return null;
  end if;

  insert into public.mark_entry_audit (
    tenant_id, campus_id, mark_unlock_request_id, mark_entry_id, exam_subject_id,
    section_id, enrolment_id, component_code, action, old_marks, new_marks, actor_user_id
  ) values (
    v_row.tenant_id, v_row.campus_id, v_request, v_row.id, v_row.exam_subject_id,
    v_section, v_row.enrolment_id, v_row.component_code, lower(tg_op),
    case when tg_op = 'INSERT' then null else old.marks_obtained end,
    case when tg_op = 'DELETE' then null else new.marks_obtained end,
    (select auth.uid())
  );

  -- Stamped once per window rather than once per cell, so result_stale_at is
  -- the moment this window first touched the set — the useful timestamp — and
  -- a forty-cell correction is one lock update, not forty.
  update public.mark_lock
     set result_stale_at = clock_timestamp(),
         result_stale_request_id = v_request
   where exam_subject_id = v_row.exam_subject_id
     and section_id = v_section
     and result_stale_request_id is distinct from v_request;

  return null;
end;
$$;

create trigger trg_mark_entry_break_glass_audit
  after insert or update or delete on public.mark_entry
  for each row execute function app.tg_mark_entry_break_glass_audit();

-- ═══════════════════════════════════════════════════════════════════════
-- mark_lock's guard, extended with three named transitions
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY INVOKER on purpose, as FR-I16's and FR-T02's: current_user must
-- still report the executing context, so "the caller is the table owner" means
-- "we are inside a SECURITY DEFINER function running as the owner".
create or replace function app.tg_mark_lock_no_update()
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

  -- Eleven columns no transition may touch. Checked once rather than repeated
  -- per transition, so a column added later is frozen by default and has to be
  -- argued out of this list rather than into it.
  v_frozen :=
        new.id              is not distinct from old.id
    and new.tenant_id       is not distinct from old.tenant_id
    and new.campus_id       is not distinct from old.campus_id
    and new.exam_term_id    is not distinct from old.exam_term_id
    and new.exam_subject_id is not distinct from old.exam_subject_id
    and new.section_id      is not distinct from old.section_id
    and new.locked_by       is not distinct from old.locked_by
    and new.locked_at       is not distinct from old.locked_at
    and new.candidate_count is not distinct from old.candidate_count
    and new.mark_count      is not distinct from old.mark_count
    and new.created_at      is not distinct from old.created_at;

  if current_user = v_owner and v_frozen then
    -- A. The window opens.
    if v_stack ~ 'function public\.fn_break_glass_unlock\('
       and old.unlock_state = 'locked' and new.unlock_state = 'unlocked'
       and new.result_stale_at is not distinct from old.result_stale_at
       and new.result_stale_request_id is not distinct from old.result_stale_request_id
    then
      return new;
    end if;

    -- B. The window closes. Only the sweep does this, and only in this
    -- direction.
    if v_stack ~ 'function public\.fn_relock_expired_unlocks\('
       and old.unlock_state = 'unlocked' and new.unlock_state = 'locked'
       and new.result_stale_at is not distinct from old.result_stale_at
       and new.result_stale_request_id is not distinct from old.result_stale_request_id
    then
      return new;
    end if;

    -- C. A mark changed inside the window, so the result is stale. Forward
    -- only: staleness is never rewound, and a later window overwrites an
    -- earlier one's stamp rather than clearing it.
    if v_stack ~ 'function app\.tg_mark_entry_break_glass_audit\('
       and new.unlock_state is not distinct from old.unlock_state
       and new.result_stale_request_id is not null
       and new.result_stale_at is not null
       and (old.result_stale_at is null or new.result_stale_at >= old.result_stale_at)
    then
      return new;
    end if;
  end if;

  raise exception 'mark approval is append-only'
    using errcode = '42501',
          detail = format('update of mark_lock id=%s exam_subject=%s section=%s unlock_state=%s->%s by %s',
                          old.id, old.exam_subject_id, old.section_id,
                          old.unlock_state, new.unlock_state, current_user),
          hint = 'An approval is a signature, not a setting. Reopening a locked set is a break-glass unlock.';
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- mark_unlock_request is append-only too
-- ═══════════════════════════════════════════════════════════════════════

-- Without this, an INSERT would reach no guard at all: service_role could
-- write a row that is already approved with a deadline an hour out and walk
-- straight through FR-I16's lock. A request is born pending.
create or replace function app.tg_mark_unlock_request_born_pending()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status <> 'pending'
     or new.approved_by is not null
     or new.approved_at is not null
     or new.expires_at is not null
     or new.relocked_at is not null then
    raise exception 'a break-glass request is born pending'
      using errcode = '42501',
            detail = format('insert of mark_unlock_request status=%s expires_at=%s by %s',
                            new.status, new.expires_at, current_user),
            hint = 'An unlock is granted by fn_break_glass_unlock(), by someone other than the requester.';
  end if;
  return new;
end;
$$;

create trigger trg_mark_unlock_request_born_pending
  before insert on public.mark_unlock_request
  for each row execute function app.tg_mark_unlock_request_born_pending();

create or replace function app.tg_mark_unlock_request_no_update()
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

  -- What was asked for, by whom and why is never editable. Those three are
  -- the whole evidentiary value of the row.
  v_frozen :=
        new.id              is not distinct from old.id
    and new.tenant_id       is not distinct from old.tenant_id
    and new.campus_id       is not distinct from old.campus_id
    and new.exam_term_id    is not distinct from old.exam_term_id
    and new.exam_subject_id is not distinct from old.exam_subject_id
    and new.section_id      is not distinct from old.section_id
    and new.requested_by    is not distinct from old.requested_by
    and new.requested_at    is not distinct from old.requested_at
    and new.reason          is not distinct from old.reason
    and new.created_at      is not distinct from old.created_at;

  if current_user = v_owner and v_frozen then
    -- APPROVE: pending -> approved, write-once, with a deadline.
    if v_stack ~ 'function public\.fn_break_glass_unlock\('
       and old.status = 'pending' and new.status = 'approved'
       and old.approved_by is null and new.approved_by is not null
       and new.approved_at is not null and new.expires_at is not null
       and new.relocked_at is null
    then
      return new;
    end if;

    -- REJECT: pending -> rejected, and no window is ever opened.
    if v_stack ~ 'function public\.reject_mark_unlock\('
       and old.status = 'pending' and new.status = 'rejected'
       and old.approved_by is null and new.approved_by is not null
       and new.approved_at is not null and new.expires_at is null
       and new.relocked_at is null
    then
      return new;
    end if;

    -- EXPIRE: approved -> expired, by the sweep, leaving the decision intact.
    if v_stack ~ 'function public\.fn_relock_expired_unlocks\('
       and old.status = 'approved' and new.status = 'expired'
       and new.approved_by is not distinct from old.approved_by
       and new.approved_at is not distinct from old.approved_at
       and new.expires_at  is not distinct from old.expires_at
       and old.relocked_at is null and new.relocked_at is not null
    then
      return new;
    end if;
  end if;

  raise exception 'break-glass request is append-only'
    using errcode = '42501',
          detail = format('update of mark_unlock_request id=%s status=%s->%s by %s',
                          old.id, old.status, new.status, current_user),
          hint = 'A break-glass request records what was asked, by whom and why. None of those is editable afterwards.';
end;
$$;

create trigger trg_mark_unlock_request_no_update
  before update on public.mark_unlock_request
  for each row execute function app.tg_mark_unlock_request_no_update();

create or replace function app.tg_mark_unlock_request_no_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'break-glass request is append-only'
    using errcode = '42501',
          detail = format('delete of mark_unlock_request id=%s status=%s by %s', old.id, old.status, current_user),
          hint = 'Every time this school reopened a signed-off result stays on the record.';
end;
$$;

create trigger trg_mark_unlock_request_no_delete
  before delete on public.mark_unlock_request
  for each row execute function app.tg_mark_unlock_request_no_delete();

create or replace function app.tg_mark_unlock_request_no_truncate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'break-glass request is append-only'
    using errcode = '42501',
          detail = format('truncate of mark_unlock_request by %s', current_user);
end;
$$;

create trigger trg_mark_unlock_request_no_truncate
  before truncate on public.mark_unlock_request
  for each statement execute function app.tg_mark_unlock_request_no_truncate();

-- ═══════════════════════════════════════════════════════════════════════
-- mark_entry_audit: written once, never touched again
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_mark_entry_audit_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'break-glass mark trail is append-only'
    using errcode = '42501',
          detail = format('%s on mark_entry_audit by %s', tg_op, current_user),
          hint = 'The record of what a break-glass window changed is the reason the window is allowed to exist.';
end;
$$;

create trigger trg_mark_entry_audit_no_update
  before update on public.mark_entry_audit
  for each row execute function app.tg_mark_entry_audit_immutable();

create trigger trg_mark_entry_audit_no_delete
  before delete on public.mark_entry_audit
  for each row execute function app.tg_mark_entry_audit_immutable();

create trigger trg_mark_entry_audit_no_truncate
  before truncate on public.mark_entry_audit
  for each statement execute function app.tg_mark_entry_audit_immutable();

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: the request, and the approval that is never the requester's
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.request_mark_unlock(
  p_exam_subject_id uuid,
  p_section_id      uuid,
  p_reason          text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_lock      record;
  v_id        uuid;
begin
  if v_tenant_id is null
     or v_role not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'UNLOCK_REASON_REQUIRED' using errcode = '23514',
      detail = 'A break-glass unlock needs a written reason of at least 10 characters.',
      hint = 'It is what the Owner reads in the exceptions report six months from now.';
  end if;

  -- SECURITY DEFINER bypasses RLS, so the tenant predicate is written out and
  -- the campus scope is checked explicitly (b16ba25's convention).
  select l.id, l.tenant_id, l.campus_id, l.exam_term_id
    into v_lock
    from public.mark_lock l
   where l.exam_subject_id = p_exam_subject_id
     and l.section_id = p_section_id
     and l.tenant_id = v_tenant_id;
  if v_lock.id is null then
    raise exception 'MARKS_NOT_LOCKED' using errcode = '23514',
      detail = 'These marks were never signed off, so there is nothing to break the glass on.';
  end if;
  if v_role not in ('super_admin', 'owner')
     and not (v_lock.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.mark_unlock_request r
     where r.exam_subject_id = p_exam_subject_id
       and r.section_id = p_section_id
       and r.status in ('pending', 'approved')
  ) then
    raise exception 'UNLOCK_ALREADY_OPEN' using errcode = '23505',
      detail = 'This set already has a break-glass request awaiting a decision or a window still open.';
  end if;

  insert into public.mark_unlock_request (
    tenant_id, campus_id, exam_term_id, exam_subject_id, section_id, requested_by, reason
  ) values (
    v_lock.tenant_id, v_lock.campus_id, v_lock.exam_term_id, p_exam_subject_id, p_section_id,
    (select auth.uid()), btrim(p_reason)
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.request_mark_unlock(uuid, uuid, text) from public, anon;
grant execute on function public.request_mark_unlock(uuid, uuid, text) to authenticated;

-- The approval. Principal and above only — an Exam Controller who could
-- approve their own request would make the whole thing a button.
create or replace function public.fn_break_glass_unlock(
  p_request_id      uuid,
  p_window_minutes  integer default 60
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_uid       uuid := (select auth.uid());
  v_req       public.mark_unlock_request%rowtype;
  v_expires   timestamptz;
  v_now       timestamptz := clock_timestamp();
begin
  if v_tenant_id is null or v_role not in ('super_admin', 'owner', 'principal') then
    raise exception 'UNLOCK_APPROVER_ONLY' using errcode = '42501',
      detail = 'Only a Principal, Owner or Super Admin can grant a break-glass unlock.',
      hint = 'The person who wants the marks open is not the person who opens them.';
  end if;

  if p_window_minutes is null or p_window_minutes < 1 or p_window_minutes > 240 then
    raise exception 'UNLOCK_WINDOW_OUT_OF_RANGE' using errcode = '23514',
      detail = 'A break-glass window is between 1 and 240 minutes.';
  end if;

  select * into v_req from public.mark_unlock_request
   where id = p_request_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'UNLOCK_REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner')
     and not (v_req.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'UNLOCK_NOT_PENDING' using errcode = '23514',
      detail = format('status=%s', v_req.status),
      hint = 'A break-glass request is decided once.';
  end if;

  -- AC1. Raised ahead of chk_unlock_no_self_approve so the caller gets a named
  -- refusal rather than a constraint violation — the constraint is still what
  -- makes it true for service_role and the table owner.
  if v_req.requested_by is not null and v_req.requested_by = v_uid then
    raise exception 'UNLOCK_SELF_APPROVAL' using errcode = '42501',
      detail = 'A break-glass request cannot be approved by the person who raised it.';
  end if;

  v_expires := v_now + make_interval(mins => p_window_minutes);

  update public.mark_unlock_request
     set status = 'approved',
         approved_by = v_uid,
         approved_at = v_now,
         expires_at = v_expires
   where id = p_request_id;

  update public.mark_lock
     set unlock_state = 'unlocked'
   where exam_subject_id = v_req.exam_subject_id
     and section_id = v_req.section_id;

  -- See the header for why this ALSO goes to security_event and not only to
  -- audit_log: audit_log is the evidence, security_event is the alarm.
  insert into public.security_event (
    tenant_id, campus_id, event_type, severity, subject_table, subject_id, actor_user_id, detail
  ) values (
    v_req.tenant_id, v_req.campus_id, 'mark_break_glass_unlock', 'alert',
    'mark_unlock_request', v_req.id, v_uid,
    jsonb_build_object(
      'exam_term_id',    v_req.exam_term_id,
      'exam_subject_id', v_req.exam_subject_id,
      'section_id',      v_req.section_id,
      'requested_by',    v_req.requested_by,
      'reason',          v_req.reason,
      'window_minutes',  p_window_minutes,
      'expires_at',      v_expires
    )
  );

  return jsonb_build_object(
    'request_id',      p_request_id,
    'exam_subject_id', v_req.exam_subject_id,
    'section_id',      v_req.section_id,
    'approved_at',     v_now,
    'expires_at',      v_expires,
    'window_minutes',  p_window_minutes
  );
end;
$$;

revoke execute on function public.fn_break_glass_unlock(uuid, integer) from public, anon;
grant execute on function public.fn_break_glass_unlock(uuid, integer) to authenticated;

create or replace function public.reject_mark_unlock(
  p_request_id uuid,
  p_note       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_uid       uuid := (select auth.uid());
  v_req       public.mark_unlock_request%rowtype;
begin
  if v_tenant_id is null or v_role not in ('super_admin', 'owner', 'principal') then
    raise exception 'UNLOCK_APPROVER_ONLY' using errcode = '42501';
  end if;

  select * into v_req from public.mark_unlock_request
   where id = p_request_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'UNLOCK_REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner')
     and not (v_req.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'UNLOCK_NOT_PENDING' using errcode = '23514',
      detail = format('status=%s', v_req.status);
  end if;
  -- Same rule as the approval, and for the same reason: the decision is
  -- somebody else's whichever way it goes.
  if v_req.requested_by is not null and v_req.requested_by = v_uid then
    raise exception 'UNLOCK_SELF_APPROVAL' using errcode = '42501',
      detail = 'A break-glass request cannot be decided by the person who raised it.';
  end if;

  update public.mark_unlock_request
     set status = 'rejected',
         approved_by = v_uid,
         approved_at = clock_timestamp(),
         decision_note = p_note
   where id = p_request_id;

  return jsonb_build_object('request_id', p_request_id, 'status', 'rejected');
end;
$$;

revoke execute on function public.reject_mark_unlock(uuid, text) from public, anon;
grant execute on function public.reject_mark_unlock(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: the sweep
-- ═══════════════════════════════════════════════════════════════════════

-- Not wired to a schedule (no pg_cron locally) — a real
-- cron.schedule('relock-expired-unlocks', '*/5 * * * *', ...) calls this, the
-- same posture as every other "cron" function in this schema. Tenant-wide for
-- service_role, own-tenant-only for an authenticated admin's "run now".
--
-- p_as_of can only ever CLOSE windows sooner; there is no argument to this
-- function that opens anything. See the header.
create or replace function public.fn_relock_expired_unlocks(
  p_as_of timestamptz default clock_timestamp()
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row   record;
  v_count integer := 0;
begin
  if app.auth_tenant_id() is not null
     and app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  for v_row in
    select r.id, r.exam_subject_id, r.section_id
      from public.mark_unlock_request r
     where r.status = 'approved'
       and r.expires_at <= coalesce(p_as_of, clock_timestamp())
       and (app.auth_tenant_id() is null or r.tenant_id = app.auth_tenant_id())
     order by r.expires_at
  loop
    update public.mark_unlock_request
       set status = 'expired', relocked_at = clock_timestamp()
     where id = v_row.id;

    update public.mark_lock
       set unlock_state = 'locked'
     where exam_subject_id = v_row.exam_subject_id
       and section_id = v_row.section_id
       and unlock_state = 'unlocked';

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.fn_relock_expired_unlocks(timestamptz) from public, anon;
grant execute on function public.fn_relock_expired_unlocks(timestamptz) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- The decision queue
-- ═══════════════════════════════════════════════════════════════════════

-- Every request with the four names a screen needs — paper, class, section and
-- the two people — plus how many marks the window actually changed. One view
-- rather than four embedded PostgREST joins, two of which would be to the same
-- table (requested_by and approved_by both point at app_user) and would need
-- disambiguating by constraint name.
--
-- security_invoker, so mark_unlock_request_read_office is what decides who
-- sees which rows.
create view public.v_mark_unlock_request
with (security_invoker = true) as
select r.id,
       r.tenant_id,
       r.campus_id,
       r.exam_term_id,
       r.exam_subject_id,
       r.section_id,
       sub.name_en        as subject_name,
       cl.name_en         as class_name,
       sec.name           as section_name,
       r.reason,
       r.status,
       r.requested_by,
       rq.full_name       as requested_by_name,
       r.requested_at,
       r.approved_by,
       ap.full_name       as approved_by_name,
       r.approved_at,
       r.expires_at,
       r.relocked_at,
       r.decision_note,
       (select count(*)::int from public.mark_entry_audit a where a.mark_unlock_request_id = r.id) as edit_count
  from public.mark_unlock_request r
  join public.exam_subject es on es.id = r.exam_subject_id
  join public.class_subject cs on cs.id = es.class_subject_id
  join public.subject sub on sub.id = cs.subject_id
  join public.class_level cl on cl.id = cs.class_level_id
  join public.class_section sec on sec.id = r.section_id
  left join public.app_user rq on rq.user_id = r.requested_by
  left join public.app_user ap on ap.user_id = r.approved_by;

revoke all on public.v_mark_unlock_request from public, anon;
grant select on public.v_mark_unlock_request to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: the exceptions report
-- ═══════════════════════════════════════════════════════════════════════

-- One row per (term, paper) that has been reopened at least once, with the
-- reasons and the approvers. A pending or rejected request is not an unlock
-- and does not appear: what the Owner is looking for is papers whose marks
-- were actually changed after sign-off.
--
-- security_invoker, so mark_unlock_request_read_office is in force and a
-- Principal reads their own campuses and nothing else.
create view public.v_mark_unlock_exception
with (security_invoker = true) as
select r.tenant_id,
       r.campus_id,
       r.exam_term_id,
       t.name                                              as exam_term_name,
       r.exam_subject_id,
       sub.name_en                                         as subject_name,
       cl.name_en                                          as class_name,
       count(*)::int                                       as unlock_count,
       min(r.approved_at)                                  as first_unlocked_at,
       max(r.approved_at)                                  as last_unlocked_at,
       array_agg(distinct sec.name)                        as sections,
       array_agg(r.reason order by r.approved_at)          as reasons,
       array_agg(distinct coalesce(ap.full_name, 'unknown')) as approvers,
       array_agg(distinct coalesce(rq.full_name, 'unknown')) as requesters,
       count(*) filter (
         where exists (select 1 from public.mark_entry_audit a where a.mark_unlock_request_id = r.id)
       )::int                                              as windows_with_edits
  from public.mark_unlock_request r
  join public.exam_subject es on es.id = r.exam_subject_id
  join public.class_subject cs on cs.id = es.class_subject_id
  join public.subject sub on sub.id = cs.subject_id
  join public.class_level cl on cl.id = cs.class_level_id
  join public.exam_term t on t.id = r.exam_term_id
  join public.class_section sec on sec.id = r.section_id
  left join public.app_user ap on ap.user_id = r.approved_by
  left join public.app_user rq on rq.user_id = r.requested_by
 where r.status in ('approved', 'expired')
 group by r.tenant_id, r.campus_id, r.exam_term_id, t.name, r.exam_subject_id, sub.name_en, cl.name_en;

revoke all on public.v_mark_unlock_exception from public, anon;
grant select on public.v_mark_unlock_exception to authenticated;

comment on view public.v_mark_unlock_exception is
  'FR-I17 AC4: papers reopened after sign-off, with how often, why and by whom. Three rows for one subject in one term is the pattern this exists to make visible.';

-- ═══════════════════════════════════════════════════════════════════════
-- The write path, and the two screens
-- ═══════════════════════════════════════════════════════════════════════

-- FR-I16's fan-out gains the staleness columns. create or replace on a view
-- may only APPEND columns, which is exactly what this does.
create or replace view public.v_exam_subject_section
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
       l.id is not null  as is_locked,
       l.result_stale_at,
       l.result_stale_request_id
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

-- FR-I12's writer, re-emitted for one line: the term-freeze pre-check now
-- yields to an open window. Without it a correction inside a live window would
-- be refused by FR-I01's term freeze — which FR-I16 sets on the last approval
-- of the term, i.e. in every case that matters. Same signature, so this is a
-- genuine replacement rather than a second overload.
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

    insert into public.mark_entry (
      tenant_id, campus_id, exam_subject_id, enrolment_id, component_code,
      marks_obtained, entered_by, client_batch_id
    ) values (
      v_es.tenant_id, v_es.campus_id, v_es_id, v_cell.enrolment_id, v_cell.component,
      v_cell.marks_obtained, (select auth.uid()), p_client_batch_id
    )
    on conflict (tenant_id, exam_subject_id, enrolment_id, component_code) do update
      set marks_obtained  = excluded.marks_obtained,
          entered_by      = excluded.entered_by,
          entered_at      = now(),
          client_batch_id = excluded.client_batch_id;

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

-- FR-I16's readiness gate, plus AC3's staleness. `ready` stays true when a set
-- is stale: the marks ARE all signed off, they have simply changed since the
-- last computation, and telling FR-J02 it may not compute would be the exact
-- opposite of what a stale flag is for.
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
  v_stale   jsonb;
  v_stale_at timestamptz;
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
         coalesce(jsonb_agg(sub.name_en order by sub.name_en) filter (where not vs.is_locked), '[]'::jsonb),
         coalesce(jsonb_agg(sub.name_en order by sub.name_en) filter (where vs.result_stale_at is not null), '[]'::jsonb),
         max(vs.result_stale_at)
    into v_total, v_locked, v_pending, v_stale, v_stale_at
    from public.v_exam_subject_section vs
    join public.subject sub on sub.id = vs.subject_id
   where vs.exam_term_id = p_exam_term_id
     and vs.section_id = p_section_id;

  return jsonb_build_object(
    'exam_term_id',     p_exam_term_id,
    'section_id',       p_section_id,
    'subject_count',    v_total,
    'locked_count',     v_locked,
    'pending_subjects', v_pending,
    'ready',            v_total > 0 and v_locked = v_total,
    -- FR-I17 AC3: "every affected report card is marked stale".
    'stale',            jsonb_array_length(v_stale) > 0,
    'stale_subjects',   v_stale,
    'stale_at',         v_stale_at
  );
end;
$$;

-- The grid. can_enter now yields to an open window, and break_glass carries
-- everything the banner needs to be loud about it.
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
         'can_approve',    app.auth_tenant_id() is null
                             or app.auth_role() in ('super_admin', 'owner', 'principal', 'exam_controller'),
         'students',       v_students
       );
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.mark_unlock_request enable row level security;
alter table public.mark_entry_audit enable row level security;

-- The FR's unlock_approve_principal_only lives in the two RPCs (see the
-- header). This is the read: the exam office sees its own campuses' requests,
-- which is what the queue and AC4's exceptions report are built on.
create policy mark_unlock_request_read_office on public.mark_unlock_request
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy mark_unlock_request_update_denied on public.mark_unlock_request
  for update to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  )
  with check (false);

create policy mark_unlock_request_delete_denied on public.mark_unlock_request
  for delete to authenticated
  using (false);

create policy mark_entry_audit_read_office on public.mark_entry_audit
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'exam_controller')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy mark_entry_audit_update_denied on public.mark_entry_audit
  for update to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'exam_controller')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  )
  with check (false);

create policy mark_entry_audit_delete_denied on public.mark_entry_audit
  for delete to authenticated
  using (false);
