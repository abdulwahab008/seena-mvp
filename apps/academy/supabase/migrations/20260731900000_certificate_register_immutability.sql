-- FR-T08: statutory certificate register with immutability.
--
-- "As a Principal, I want a permanent, tamper-evident register of every
-- certificate ever issued, so that when a district education officer
-- inspects the school I can produce the bound-register equivalent on
-- demand."
--
-- Fifth of module T's certificates cluster. FR-T01 (20260731860000)
-- authored the wording, FR-T02 (20260731870000) built the gapless
-- allocator and its three-layer append-only guard, FR-T03 (20260731880000)
-- created certificate_issue — explicitly naming it "the bound register" —
-- together with the 'cancelled' status value and replaced_by_issue_id this
-- migration finally uses, and FR-T05 (20260731890000) added the second
-- certificate type. Nothing below creates a second register: it makes the
-- one that already exists behave like a bound book.
--
-- ── What a bound register actually is ──────────────────────────────────
--
-- A page is written once. A withdrawn entry is STRUCK THROUGH IN PLACE,
-- annotated with who struck it, when and why, and cross-referenced to the
-- entry that replaced it. A page is never torn out and a number is never
-- re-used. Every design decision below follows from that and from nothing
-- else:
--
--   * UPDATE is refused except for the two annotations a bound register
--     permits (strike-through and cross-reference), and only from the
--     SECURITY DEFINER functions that own them.
--   * DELETE is refused outright, and the attempt is recorded.
--   * A cancelled row KEEPS its serial, its serial position and its place
--     in the printed run. Cancellation frees nothing; the replacement is a
--     NEW issuance with a NEW number, linked in both directions.
--
-- ── AC1: the append-only trigger's allow-list, in full ─────────────────
--
-- FR-T02's counter established the house pattern for "append-only against
-- a Super Admin who has SQL" and this migration follows it exactly, layer
-- for layer. The threat model is a role that reaches Postgres as
-- `authenticated` (every application role does, super_admin included), a
-- service_role key, and the table owner. Only a database superuser who
-- drops the trigger is out of scope, as it was for FR-T02.
--
--   1. RLS, and one deliberate change to it. FR-T03's
--      cert_issue_no_direct_dml was FOR UPDATE USING false, which meant an
--      authenticated caller's UPDATE qualified ZERO rows and therefore
--      never reached a trigger at all — the statement was refused, but
--      silently, as `UPDATE 0`. AC1 asks for the refusal to come from the
--      trigger "when ANY role attempts" it, so the policy is replaced by
--      cert_issue_update_denied, whose USING clause is a verbatim copy of
--      the table's own SELECT predicate (cert_issue_campus_scope) and
--      whose WITH CHECK is still false.
--
--      That is not a weakening, and the shape matters: USING only decides
--      which rows are OFFERED to the statement, and every row it offers is
--      one the same caller can already SELECT, so a refusal can never
--      confirm the existence of a row — in another tenant, or at another
--      campus — that the caller could not already read. Nothing new can
--      succeed either, for two independent reasons: the BEFORE trigger
--      raises before any row version is produced, and WITH CHECK (false)
--      would reject the row version even if the trigger were dropped. What
--      changes is only that a Super Admin poking at the register through
--      PostgREST is now TOLD the register is append-only instead of being
--      handed a silent no-op. The sanctioned functions are unaffected:
--      they run as the table owner and are not subject to RLS at all.
--
--      DELETE deliberately keeps USING false — see AC4 below, where the
--      silence is load-bearing.
--   2. trg_cert_issue_no_update fires BEFORE UPDATE FOR EACH ROW
--      regardless of caller, so service_role's BYPASSRLS buys nothing.
--   3. Its allow-list is narrow enough that even the table owner writing
--      the UPDATE by hand is refused — the plpgsql call stack must contain
--      a frame for the specific function that owns the transition, and
--      neither authenticated nor service_role holds CREATE on public or
--      app, so neither can plant a same-named function to forge one.
--
-- Eighteen columns are FROZEN in every legal transition and must be
-- byte-identical: id, tenant_id, campus_id, student_id, enrolment_id,
-- session_id, certificate_type, serial_no, serial_seq, template_id,
-- template_version, language, pdf_path, payload_snapshot, issued_by,
-- issued_at, original_issue_id, created_at. serial_no, student_id and
-- issued_at — the three the AC names — are simply three members of that
-- set; there is no reason for the other fifteen to be softer, and naming
-- only three would invite a later column to be added outside it.
--
-- Five columns may move, and only inside one of exactly three transitions:
--
--   A. VOID — frame public.void_certificate_issue(, FR-T03's failed-render
--      path. status 'issued' -> 'void', revoked_at null -> not null,
--      revoke_reason and revoked_by free, replaced_by_issue_id unchanged
--      (a document that never existed has nothing to replace it).
--   B. CANCEL — frame public.revoke_certificate(, this migration's.
--      status 'issued' -> 'cancelled', revoked_at null -> not null,
--      revoke_reason must become non-null (a strike-through with no reason
--      is not a register annotation), revoked_by and replaced_by_issue_id
--      free, and old.replaced_by_issue_id must have been null.
--   C. LINK — frame public.set_certificate_replacement(, the cross
--      reference written after the replacement has been issued. status
--      stays 'cancelled', revoked_at / revoke_reason / revoked_by all
--      unchanged, and replaced_by_issue_id goes null -> not null and never
--      any other way. Write-once, in the one direction a register allows.
--
-- Anything else — including 'cancelled' -> 'issued', a second cancellation,
-- re-pointing an existing cross-reference, or the owner editing a serial
-- by hand — raises 'certificate register is append-only'. The message is
-- one string for every refusal because the property being defended is one
-- property.
--
-- Transition C exists because of a real ordering constraint rather than
-- for symmetry. AC2's replacement (00212) is numbered AFTER the entry it
-- replaces (00147), so it cannot exist at the moment of cancellation — and
-- for a Transfer Certificate it CANNOT be issued first: uq_one_active_tc
-- forbids a second issued TC on the enrolment, and
-- issue_transfer_certificate() refuses a non-active enrolment. Cancelling
-- first is therefore the only possible order, and the forward link has to
-- be written afterwards. revoke_certificate() still accepts a replacement
-- inline for the case where one genuinely already exists (a character
-- certificate, which is not one-per-enrolment).
--
-- ── AC2: cancellation frees nothing ────────────────────────────────────
--
-- FR-T02's header is explicit: "FR-T08's cancellation must NEVER rewind
-- the counter. A cancelled certificate keeps its serial and stays in the
-- register with a cancelled status cross-referencing its replacement;
-- handing the number back is what would create the gap." So
-- revoke_certificate() touches the counter not at all, changes no serial,
-- and renumbers nothing. Serial 00147 stays exactly where it is in the
-- printed run with status CANCELLED, its reason, its cancelled_by and its
-- cancelled_at beside it, and a pointer to 00212. 00212 in turn shows what
-- it replaced, derived rather than stored — see the view.
--
-- The one thing cancellation DOES revert is the enrolment, and only for a
-- Transfer Certificate: issuing a TC is what sets the enrolment to
-- 'transferred' with a left_on (FR-T03's AC1), and a TC issued against the
-- wrong date of birth is a TC that should never have taken the child off
-- the roster. This is void_certificate_issue()'s existing branch, guarded
-- identically on certificate_type = 'transfer' and on the enrolment still
-- pointing at this issue, and it is also what makes the replacement
-- issuable at all. A character certificate changes no enrolment state, so
-- there is nothing to revert.
--
-- ── serial_seq: the register's ordinal, and where it comes from ────────
--
-- FR-T02 stores serials as FORMATTED TEXT ('TC-2026-000148') because that
-- is what gets printed. Text does not sort numerically once the width
-- changes, and "no missing numbers" is a statement about integers, so the
-- register needs the ordinal as an integer. certificate_issue had no such
-- column; one is added here rather than parsed back out of serial_no,
-- because prefix_pattern is free-form (it need only contain {SEQ}) and a
-- register that guesses its own numbering is not evidence.
--
-- trg_cert_issue_serial_seq derives it at INSERT from FR-T02's counter,
-- and — this is the load-bearing part — only when the row's serial_no is
-- EXACTLY what the counter's current state renders. Inside an issuing
-- transaction that is always true and exact: allocate_certificate_serial()
-- holds a transaction-scoped advisory lock on the series from before the
-- increment until COMMIT, so current_value cannot be anyone else's number
-- by the time the insert runs. A row written by hand, with a serial that
-- is not the number the counter just handed out, gets serial_seq NULL and
-- the register shows it as an unnumbered entry rather than silently
-- claiming a position in the run it never occupied. FR-T03 and FR-T05 need
-- no change for either behaviour.
--
-- ── AC3: what "no missing numbers" is checked against ──────────────────
--
-- certificate_register_continuity() reports, per series, the ordinals that
-- SHOULD be present and the ones that are. Its expected run is
-- greatest(max(serial_seq), counter.current_value) — the counter is FR-T02's
-- record of what was allocated and the register is the record of what was
-- written, and the whole point of a bound register is that an inspector can
-- see the two agree. A void or cancelled row counts as present, because it
-- is: the number is accounted for on the page.
--
-- ── AC4: rejected AND audited, and the honest limit of it ──────────────
--
-- A BEFORE DELETE trigger that RAISEs aborts the transaction, and an audit
-- row written in that same transaction dies with it. PostgreSQL has no
-- autonomous transaction, and the usual workaround — dblink writing on a
-- second connection — is not merely unavailable here but actively wrong:
-- app.tg_audit_row() serialises the hash chain on a per-tenant
-- pg_advisory_xact_lock which the aborting transaction is already holding,
-- so a second connection trying to append to the same chain would block on
-- it and deadlock. FR-C15 solved its own version of this with a
-- subtransaction and FR-G05 by returning instead of raising; neither makes
-- a write outlive a rollback, because nothing can.
--
-- So the paradox is dissolved by restructuring rather than by pretending,
-- and it is dissolved completely for the actor AC4 actually names — "ANY
-- authenticated role", which is every role this application authenticates
-- as, super_admin included:
--
--   1. cert_issue_delete_denied (FOR DELETE USING false) means RLS
--      qualifies ZERO rows for an authenticated caller. The row-level
--      trigger is therefore never reached, nothing raises, and the
--      statement is rejected in the only sense that matters — the register
--      row is still there afterwards and DELETE reports 0. This is exactly
--      the silence AC1's UPDATE policy was widened to avoid, and here it
--      is the point rather than a wart: a loud raise would take the audit
--      row with it, and a tamper attempt that is recorded is worth more
--      than a tamper attempt that is answered.
--   2. trg_cert_issue_delete_attempt fires BEFORE DELETE FOR EACH
--      STATEMENT, which fires once per statement regardless of how many
--      rows qualify — including none. It writes the attempt to audit_log,
--      chained with the same app.fn_audit_row_hash() the ordinary audit
--      trigger uses so run_audit_chain_verification() still verifies, and
--      raises a WARNING the caller can see. Because nothing in this path
--      raises an exception, THE AUDIT ROW COMMITS. AC4 holds end to end.
--   3. trg_cert_issue_no_delete fires BEFORE DELETE FOR EACH ROW and
--      raises 'certificate register is append-only' (and
--      trg_cert_issue_no_truncate does the same for TRUNCATE, which fires
--      no row trigger and is filtered by no RLS policy). It is reached only
--      when RLS did not filter — service_role, the table owner, a cascade
--      from campus or tenant — and it is what makes those fail loudly
--      instead of silently orphaning or skipping rows. In THAT path the
--      audit row from step 2 rolls back with the raise. That is stated
--      plainly rather than papered over: it is the price of a hard refusal,
--      it does not apply to the roles the AC names, and the alternative
--      (returning NULL for everyone) would let a cascading campus delete
--      quietly leave certificate rows behind a campus that no longer
--      exists.
--
-- The denial row is action='delete' on table_name='certificate_issue' with
-- `before` carrying {denied, reason, db_user, statement}. audit_action is
-- an enum of exactly ('insert','update','delete') and ALTER TYPE ... ADD
-- VALUE cannot share a migration with a statement that uses the new value
-- (the same constraint that made FR-T03 ship 'cancelled' early), so no new
-- label is invented for one row shape. It is unambiguous as it stands: no
-- delete of a certificate_issue row can ever succeed, so every 'delete'
-- audit row on that table is by construction a refused attempt.
--
-- ── Deliberate departures from the FR's suggested objects ──────────────
--
--   * NO certificate_revocation table. certificate_issue already carries
--     revoked_at, revoke_reason and replaced_by_issue_id (FR-T03); a side
--     table repeating them is the "competing register" FR-T02's header
--     warns about, and the two would eventually disagree about which
--     certificate was withdrawn. What was genuinely missing is WHO, so
--     revoked_by is added as a column beside the two that already exist.
--   * NO cert_register_read_admin policy. certificate_issue's SELECT is
--     already cert_issue_campus_scope, and RLS policies are OR'd — a
--     second SELECT policy could only ever WIDEN who reads the register.
--     The Principal/Owner/Super-Admin narrowing the FR asks for is applied
--     where narrowing is possible: the register page's own role gate.
--   * NO replaces_issue_id column. The backward half of AC2's
--     cross-reference is derived in the view from the forward half, so the
--     two cannot drift; a stored pair of mutually-pointing columns in an
--     append-only table would need two more sanctioned transitions to
--     maintain and could still end up inconsistent.
--
-- ── For FR-T09 (NOT built here) ────────────────────────────────────────
--
-- pdf_sha256 and signing_identity_id land on certificate_issue. Both are
-- written at INSERT by the issuing transaction, so both simply join the
-- frozen set above — a hash that could be updated after the fact is not a
-- tamper check. If a re-sign path is ever needed it must arrive as a
-- FOURTH named transition with its own frame in the allow-list, never as a
-- relaxation of the frozen set. v_certificate_register is the natural
-- place for its verification status to surface, beside the row it belongs
-- to.
--
-- Every function below has its full signature fixed. Adding a defaulted
-- argument with CREATE OR REPLACE creates a DISTINCT overload and makes
-- existing calls ambiguous (FR-G05 hit exactly this) — drop and recreate,
-- and re-issue the grants.

-- ═══════════════════════════════════════════════════════════════════════
-- The register's own columns
-- ═══════════════════════════════════════════════════════════════════════

-- AC2 asks the printed register for `cancelled_by` beside the reason and
-- the timestamp FR-T03 already stores. One column, beside the other two,
-- rather than a parallel revocation table that would have to be kept in
-- step with them.
alter table public.certificate_issue
  add column revoked_by uuid references public.app_user(user_id);

-- The ordinal of serial_no within its (campus, type, session) series. NULL
-- means "this row's serial was not the number the counter handed out" —
-- see the header; the register displays those as unnumbered rather than
-- letting them claim a position in the run.
alter table public.certificate_issue add column serial_seq bigint check (serial_seq > 0);

-- A strike-through with no reason is not a register annotation. The
-- backstop for every writer that does not come through
-- revoke_certificate(), same posture as FR-T05's chk_conduct_grade.
alter table public.certificate_issue
  add constraint chk_cert_issue_cancel_reason
    check (status <> 'cancelled' or revoke_reason is not null);

-- Only a withdrawn certificate names a successor, and never itself.
alter table public.certificate_issue
  add constraint chk_cert_issue_replacement
    check (replaced_by_issue_id is null or (status = 'cancelled' and replaced_by_issue_id <> id));

-- AC3's read: one campus's one series, in serial order. serial_seq rather
-- than serial_no because the run is an integer run — 000009 sorts after
-- 000010 as text the moment a series outgrows its width.
create index idx_cert_register on public.certificate_issue (campus_id, certificate_type, serial_seq);

-- The cross-reference lookup in the view, and the guard against two
-- cancelled certificates claiming the same replacement.
create unique index uq_cert_issue_replaced_by on public.certificate_issue (replaced_by_issue_id)
  where replaced_by_issue_id is not null;

-- ═══════════════════════════════════════════════════════════════════════
-- serial_seq at INSERT
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY DEFINER only so the counter read is not subject to
-- serial_counter_read, which deliberately excludes an Admissions Officer
-- (FR-T02) — an officer issuing a certificate must still get a numbered
-- register row. It decides nothing about authorisation.
create or replace function app.tg_cert_issue_serial_seq()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ctr record;
begin
  -- An explicit value is honoured: a school migrating a paper register on
  -- to this system has real ordinals that no counter here ever allocated.
  if new.serial_seq is not null then
    return new;
  end if;

  select ctr.current_value, ctr.prefix_pattern, ctr.academic_year, ctr.seq_width, c.code as campus_code
    into v_ctr
    from public.certificate_serial_counter ctr
    join public.campus c on c.id = ctr.campus_id
   where ctr.campus_id = new.campus_id
     and ctr.certificate_type = new.certificate_type
     and ctr.session_id = new.session_id;

  -- Only when this row's serial really IS the number the counter is
  -- standing on. allocate_certificate_serial() holds the series' advisory
  -- lock until COMMIT, so inside an issuing transaction that comparison is
  -- exact; outside one it is how a hand-written row is told apart.
  if found
     and new.serial_no = public.format_certificate_serial(
           v_ctr.prefix_pattern, v_ctr.academic_year, v_ctr.current_value, v_ctr.seq_width, v_ctr.campus_code)
  then
    new.serial_seq := v_ctr.current_value;
  end if;

  return new;
end;
$$;

create trigger trg_cert_issue_serial_seq
  before insert on public.certificate_issue
  for each row execute function app.tg_cert_issue_serial_seq();

-- Backfill for any register written before this migration. Runs before the
-- append-only trigger exists, which is the only moment it can.
update public.certificate_issue ci
   set serial_seq = ctr.current_value
  from public.certificate_serial_counter ctr
  join public.campus c on c.id = ctr.campus_id
 where ctr.campus_id = ci.campus_id
   and ctr.certificate_type = ci.certificate_type
   and ctr.session_id = ci.session_id
   and ci.serial_seq is null
   and ci.serial_no = public.format_certificate_serial(
         ctr.prefix_pattern, ctr.academic_year, ctr.current_value, ctr.seq_width, c.code);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: the register is append-only
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY INVOKER on purpose, exactly as FR-T02's counter trigger:
-- current_user must still report the executing context, so that "the
-- caller is the table owner" means "we are inside a SECURITY DEFINER
-- function running as the owner" and not "a logged-in role".
create or replace function app.tg_cert_issue_no_update()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_stack text;
  v_owner text;
  v_frozen boolean;
begin
  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner
    from pg_catalog.pg_class c
   where c.oid = tg_relid;

  get diagnostics v_stack = pg_context;

  -- Eighteen columns that no sanctioned transition may touch. Checked once
  -- rather than repeated per transition, so a column added later is frozen
  -- by default and has to be argued out of this list rather than into it.
  v_frozen :=
        new.id                is not distinct from old.id
    and new.tenant_id         is not distinct from old.tenant_id
    and new.campus_id         is not distinct from old.campus_id
    and new.student_id        is not distinct from old.student_id
    and new.enrolment_id      is not distinct from old.enrolment_id
    and new.session_id        is not distinct from old.session_id
    and new.certificate_type  is not distinct from old.certificate_type
    and new.serial_no         is not distinct from old.serial_no
    and new.serial_seq        is not distinct from old.serial_seq
    and new.template_id       is not distinct from old.template_id
    and new.template_version  is not distinct from old.template_version
    and new.language          is not distinct from old.language
    and new.pdf_path          is not distinct from old.pdf_path
    and new.payload_snapshot  is not distinct from old.payload_snapshot
    and new.issued_by         is not distinct from old.issued_by
    and new.issued_at         is not distinct from old.issued_at
    and new.original_issue_id is not distinct from old.original_issue_id
    and new.created_at        is not distinct from old.created_at;

  if current_user = v_owner and v_frozen then
    -- A. FR-T03's void: the document never came into existence.
    if v_stack ~ 'function public\.void_certificate_issue\('
       and old.status = 'issued' and new.status = 'void'
       and old.revoked_at is null and new.revoked_at is not null
       and new.replaced_by_issue_id is not distinct from old.replaced_by_issue_id
    then
      return new;
    end if;

    -- B. The strike-through itself.
    if v_stack ~ 'function public\.revoke_certificate\('
       and old.status = 'issued' and new.status = 'cancelled'
       and old.revoked_at is null and new.revoked_at is not null
       and new.revoke_reason is not null
       and old.replaced_by_issue_id is null
    then
      return new;
    end if;

    -- C. The cross-reference, written once, in one direction, after the
    -- replacement exists.
    if v_stack ~ 'function public\.set_certificate_replacement\('
       and old.status = 'cancelled' and new.status = 'cancelled'
       and new.revoked_at    is not distinct from old.revoked_at
       and new.revoke_reason is not distinct from old.revoke_reason
       and new.revoked_by    is not distinct from old.revoked_by
       and old.replaced_by_issue_id is null
       and new.replaced_by_issue_id is not null
    then
      return new;
    end if;
  end if;

  raise exception 'certificate register is append-only'
    using errcode = '42501',
          detail = format('update of certificate_issue id=%s serial_no=%s status=%s->%s by %s',
                          old.id, old.serial_no, old.status, new.status, current_user),
          hint = 'A register entry is written once. Withdraw it with revoke_certificate() and issue a replacement; the entry keeps its serial and stays in sequence.';
end;
$$;

create trigger trg_cert_issue_no_update
  before update on public.certificate_issue
  for each row execute function app.tg_cert_issue_no_update();

-- Replaces FR-T03's cert_issue_no_direct_dml. USING is cert_issue_campus_scope's
-- predicate verbatim, so the rows an authenticated caller's UPDATE can even
-- reach are exactly the rows it can already read — and reaching one is all
-- it buys, because the BEFORE trigger above answers first. WITH CHECK stays
-- false so "no authenticated write is ever committed" survives the trigger
-- being dropped. See the header for why DELETE is not treated the same way.
drop policy cert_issue_no_direct_dml on public.certificate_issue;

create policy cert_issue_update_denied on public.certificate_issue
  for update to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  )
  with check (false);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: no page is ever torn out, and the attempt is on the record
-- ═══════════════════════════════════════════════════════════════════════

-- Writes one hash-chained audit_log row for something that was REFUSED and
-- therefore has no row to audit through app.tg_audit_row(). It reproduces
-- that trigger's chaining deliberately and minimally — the same per-tenant
-- advisory lock, the same "previous row_hash by (occurred_at, id)", the
-- same app.fn_audit_row_hash() — so run_audit_chain_verification()
-- (FR-T14) verifies these rows exactly like every other one. Sharing the
-- hash function rather than copying it is what keeps the two from drifting.
create or replace function app.log_certificate_register_denial(p_detail jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid := app.auth_tenant_id();
  v_actor_role  public.app_role := nullif(app.auth_role(), 'none')::public.app_role;
  v_actor       uuid := (select auth.uid());
  v_occurred_at timestamptz;
  v_prev_hash   text;
  v_row_hash    text;
begin
  -- No JWT means no tenant to attribute the attempt to, and audit_log's
  -- tenant_id is NOT NULL. app.tg_audit_row() takes the same way out for
  -- the same reason. A caller with no claims is service_role or a superuser
  -- reaching the row trigger below, which refuses loudly regardless.
  if v_tenant_id is null then
    return;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('audit-chain:' || v_tenant_id::text, 0));

  v_occurred_at := clock_timestamp();

  select row_hash into v_prev_hash
    from public.audit_log
   where tenant_id = v_tenant_id
   order by occurred_at desc, id desc
   limit 1;

  v_row_hash := app.fn_audit_row_hash(
    v_prev_hash, v_tenant_id, null, v_occurred_at, v_actor, v_actor_role::text,
    'delete', 'certificate_issue', null, p_detail, null, null
  );

  insert into public.audit_log (
    tenant_id, campus_id, occurred_at, actor_user_id, actor_role, action, table_name, row_id,
    before, after, changed_columns, prev_hash, row_hash
  ) values (
    v_tenant_id, null, v_occurred_at, v_actor, v_actor_role,
    'delete', 'certificate_issue', null,
    p_detail, null, null, v_prev_hash, v_row_hash
  );
end;
$$;

revoke execute on function app.log_certificate_register_denial(jsonb) from public, anon, authenticated;

-- FOR EACH STATEMENT, which fires once per DELETE regardless of how many
-- rows qualify — including the zero that cert_issue_delete_denied leaves
-- for an authenticated caller, where the row trigger below never runs and
-- nothing raises, so this audit row COMMITS. See the header for the case
-- where it does not.
create or replace function app.tg_cert_issue_delete_attempt()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.log_certificate_register_denial(jsonb_build_object(
    'denied',    true,
    'reason',    'certificate register is append-only',
    'db_user',   current_user,
    'statement', left(coalesce(pg_catalog.current_query(), ''), 2000)
  ));

  -- A warning rather than an exception: an exception here would take the
  -- audit row down with it, which is the whole point of writing it from a
  -- statement trigger. The refusal itself is RLS's (zero rows qualify) and
  -- the row trigger's (for callers RLS does not reach).
  raise warning 'certificate register is append-only';

  return null;
end;
$$;

create trigger trg_cert_issue_delete_attempt
  before delete on public.certificate_issue
  for each statement execute function app.tg_cert_issue_delete_attempt();

create or replace function app.tg_cert_issue_no_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'certificate register is append-only'
    using errcode = '42501',
          detail = format('delete of certificate_issue id=%s serial_no=%s status=%s by %s',
                          old.id, old.serial_no, old.status, current_user),
          hint = 'A statutory register keeps every entry it ever held. Withdraw a certificate with revoke_certificate() instead.';
end;
$$;

create trigger trg_cert_issue_no_delete
  before delete on public.certificate_issue
  for each row execute function app.tg_cert_issue_no_delete();

-- TRUNCATE fires no row-level trigger at all and is not filtered by RLS, so
-- an append-only table that only guards DELETE can still be emptied in one
-- statement by anyone holding the table. It must be its own STATEMENT-level
-- trigger; there is no other place to catch it. (A bare TRUNCATE happens to
-- be refused already because enrolment references certificate_issue, but
-- TRUNCATE ... CASCADE is not, and relying on the FK graph staying shaped
-- the way it is today is not a control.)
create or replace function app.tg_cert_issue_no_truncate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'certificate register is append-only'
    using errcode = '42501',
          detail = format('truncate of certificate_issue by %s', current_user),
          hint = 'A statutory register keeps every entry it ever held.';
end;
$$;

create trigger trg_cert_issue_no_truncate
  before truncate on public.certificate_issue
  for each statement execute function app.tg_cert_issue_no_truncate();

-- The absence of a DELETE policy is already a denial; this states it, so a
-- reader does not have to infer a security property from an absence. Unlike
-- cert_issue_update_denied above it stays at USING false on purpose: that
-- is what makes the authenticated path in AC4 a zero-row statement rather
-- than an aborted one, and therefore what lets the audit row commit.
create policy cert_issue_delete_denied on public.certificate_issue
  for delete to authenticated
  using (false);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: the strike-through
-- ═══════════════════════════════════════════════════════════════════════

-- Withdrawing a certificate that is already in a family's hands is a
-- heavier act than voiding one whose PDF never rendered, so the role gate
-- is narrower than void_certificate_issue()'s: an Admissions Officer may
-- issue and may void a failed render, but only a Principal (or above)
-- strikes an entry out of the register.
create or replace function public.revoke_certificate(
  p_issue_id uuid,
  p_reason text,
  p_replacement_issue_id uuid default null
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
  v_issue       public.certificate_issue%rowtype;
  v_replacement public.certificate_issue%rowtype;
begin
  if v_role not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'REVOCATION_REASON_REQUIRED'
      using errcode = '23514',
            hint = 'A cancelled entry has to say why on the page beside it.';
  end if;

  -- SECURITY DEFINER bypasses RLS, so the tenant predicate is written out
  -- and the campus scope is checked explicitly (b16ba25's convention).
  select * into v_issue from public.certificate_issue
   where id = p_issue_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'CERTIFICATE_ISSUE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_issue.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_issue.status <> 'issued' then
    raise exception 'CERTIFICATE_NOT_ISSUED'
      using errcode = '55000',
            detail = format('status=%s', v_issue.status),
            hint = 'Only a live certificate can be withdrawn; a voided or already-cancelled entry stays as it is.';
  end if;

  if p_replacement_issue_id is not null then
    select * into v_replacement from public.certificate_issue
     where id = p_replacement_issue_id and tenant_id = v_tenant_id;
    if not found
       or v_replacement.id = v_issue.id
       or v_replacement.campus_id <> v_issue.campus_id
       or v_replacement.student_id <> v_issue.student_id
       or v_replacement.certificate_type <> v_issue.certificate_type
       or v_replacement.status <> 'issued'
    then
      raise exception 'REPLACEMENT_INVALID'
        using errcode = '23514',
              detail = format('replacement_issue_id=%s', p_replacement_issue_id),
              hint = 'A replacement must be a live certificate of the same type, for the same student, at the same campus.';
    end if;
  end if;

  -- The serial is NOT touched, the counter is NOT rewound and nothing is
  -- renumbered. The entry stays in the run with a line through it.
  update public.certificate_issue
     set status = 'cancelled',
         revoked_at = clock_timestamp(),
         revoke_reason = p_reason,
         revoked_by = v_uid,
         replaced_by_issue_id = p_replacement_issue_id
   where id = p_issue_id;

  -- Issuing a TC is what took the child off the roster (FR-T03's AC1); a
  -- TC that should never have been issued should never have done that, and
  -- the enrolment has to be active again for the corrected TC to be
  -- issuable at all. Same guard and same shape as void_certificate_issue().
  if v_issue.certificate_type = 'transfer' and v_issue.enrolment_id is not null then
    update public.enrolment
       set status = 'active',
           left_on = null,
           tc_issued_at = null,
           tc_certificate_issue_id = null
     where id = v_issue.enrolment_id
       and tc_certificate_issue_id = p_issue_id;
  end if;

  return jsonb_build_object(
    'issue_id',             p_issue_id,
    'serial_no',            v_issue.serial_no,
    'serial_seq',           v_issue.serial_seq,
    'status',               'cancelled',
    'reason',               p_reason,
    'replaced_by_issue_id', p_replacement_issue_id
  );
end;
$$;

revoke execute on function public.revoke_certificate(uuid, text, uuid) from public, anon;
grant execute on function public.revoke_certificate(uuid, text, uuid) to authenticated;

-- The cross-reference, once the replacement exists. Write-once: a register
-- entry that already names its successor is not re-pointed, it is read.
create or replace function public.set_certificate_replacement(
  p_cancelled_issue_id uuid,
  p_replacement_issue_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid := app.auth_tenant_id();
  v_role        text := app.auth_role();
  v_issue       public.certificate_issue%rowtype;
  v_replacement public.certificate_issue%rowtype;
begin
  if v_role not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_issue from public.certificate_issue
   where id = p_cancelled_issue_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'CERTIFICATE_ISSUE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_issue.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_issue.status <> 'cancelled' then
    raise exception 'CERTIFICATE_NOT_CANCELLED'
      using errcode = '55000',
            detail = format('status=%s', v_issue.status),
            hint = 'Only a withdrawn entry names a replacement.';
  end if;
  if v_issue.replaced_by_issue_id is not null then
    raise exception 'REPLACEMENT_ALREADY_SET'
      using errcode = '23505',
            detail = format('replaced_by_issue_id=%s', v_issue.replaced_by_issue_id),
            hint = 'A register cross-reference is written once.';
  end if;

  select * into v_replacement from public.certificate_issue
   where id = p_replacement_issue_id and tenant_id = v_tenant_id;
  if not found
     or v_replacement.id = v_issue.id
     or v_replacement.campus_id <> v_issue.campus_id
     or v_replacement.student_id <> v_issue.student_id
     or v_replacement.certificate_type <> v_issue.certificate_type
     or v_replacement.status <> 'issued'
  then
    raise exception 'REPLACEMENT_INVALID'
      using errcode = '23514',
            detail = format('replacement_issue_id=%s', p_replacement_issue_id),
            hint = 'A replacement must be a live certificate of the same type, for the same student, at the same campus.';
  end if;

  update public.certificate_issue
     set replaced_by_issue_id = p_replacement_issue_id
   where id = p_cancelled_issue_id;

  return jsonb_build_object(
    'issue_id',              p_cancelled_issue_id,
    'serial_no',             v_issue.serial_no,
    'replaced_by_issue_id',  p_replacement_issue_id,
    'replaced_by_serial_no', v_replacement.serial_no
  );
end;
$$;

revoke execute on function public.set_certificate_replacement(uuid, uuid) from public, anon;
grant execute on function public.set_certificate_replacement(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- FR-T03's void, re-emitted to record WHO
-- ═══════════════════════════════════════════════════════════════════════

-- Identical to 20260731880000's definition except for revoked_by. The
-- register prints one "withdrawn by" column and it must not be blank for
-- half the withdrawn rows purely because the two withdrawal paths were
-- written a migration apart. Nothing else about the void path changes: the
-- serial is still kept, the counter is still never rewound, and the
-- enrolment revert is still guarded to transfer certificates.
create or replace function public.void_certificate_issue(p_issue_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_issue     public.certificate_issue%rowtype;
begin
  if v_role not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_issue from public.certificate_issue
   where id = p_issue_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'CERTIFICATE_ISSUE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_issue.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_issue.status <> 'issued' then
    raise exception 'CERTIFICATE_NOT_ISSUED'
      using errcode = '55000', detail = format('status=%s', v_issue.status);
  end if;

  update public.certificate_issue
     set status = 'void',
         revoked_at = clock_timestamp(),
         revoke_reason = p_reason,
         revoked_by = (select auth.uid())
   where id = p_issue_id;

  if v_issue.certificate_type = 'transfer' and v_issue.enrolment_id is not null then
    update public.enrolment
       set status = 'active',
           left_on = null,
           tc_issued_at = null,
           tc_certificate_issue_id = null
     where id = v_issue.enrolment_id
       and tc_certificate_issue_id = p_issue_id;
  end if;

  return jsonb_build_object('issue_id', p_issue_id, 'serial_no', v_issue.serial_no, 'status', 'void');
end;
$$;

revoke execute on function public.void_certificate_issue(uuid, text) from public, anon;
grant execute on function public.void_certificate_issue(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The register itself
-- ═══════════════════════════════════════════════════════════════════════

-- security_invoker keeps cert_issue_campus_scope in force, so a Principal
-- reads their own campuses and nothing else — the same posture as FR-T02's
-- v_certificate_serial_register.
--
-- Student identity comes from payload_snapshot, not from a join to
-- student, and that is a decision rather than an optimisation. A register
-- records what the DOCUMENT says: a student later renamed, or soft-deleted
-- into FR-A15's recycle bin (whose RLS would drop the row from an inner
-- join entirely), must not change or erase a certificate the school has
-- already handed out. student_id is still carried for the cross-reference.
create or replace view public.v_certificate_register
with (security_invoker = true) as
select
  ci.id,
  ci.tenant_id,
  ci.campus_id,
  c.code as campus_code,
  c.name as campus_name,
  ci.certificate_type,
  ci.session_id,
  sess.name as session_name,
  extract(year from sess.starts_on)::int as academic_year,
  ci.serial_seq,
  ci.serial_no,
  ci.status,
  ci.issued_at,
  ci.issued_by,
  issuer.full_name as issued_by_name,
  ci.student_id,
  ci.payload_snapshot -> 'values' ->> 'student.gr_number'      as gr_number,
  ci.payload_snapshot -> 'values' ->> 'student.name_en'        as student_name,
  ci.payload_snapshot -> 'values' ->> 'student.father_name_en' as father_name,
  ci.payload_snapshot -> 'values' ->> 'enrolment.class_name'   as class_name,
  ci.payload_snapshot -> 'values' ->> 'enrolment.section_name' as section_name,
  ci.enrolment_id,
  ci.language,
  ci.template_id,
  ci.template_version,
  ci.pdf_path,
  -- AC2's annotation, under the names the printed register uses.
  ci.revoked_at    as cancelled_at,
  ci.revoke_reason as cancelled_reason,
  ci.revoked_by    as cancelled_by,
  canceller.full_name as cancelled_by_name,
  -- Forward: what replaced this entry. Backward: what this entry replaced,
  -- derived from the same column so the two cannot disagree.
  ci.replaced_by_issue_id,
  replacement.serial_no as replaced_by_serial_no,
  superseded.id         as replaces_issue_id,
  superseded.serial_no  as replaces_serial_no,
  ci.original_issue_id
from public.certificate_issue ci
join public.campus c on c.id = ci.campus_id
join public.academic_session sess on sess.id = ci.session_id
left join public.app_user issuer on issuer.user_id = ci.issued_by
left join public.app_user canceller on canceller.user_id = ci.revoked_by
left join public.certificate_issue replacement on replacement.id = ci.replaced_by_issue_id
left join public.certificate_issue superseded on superseded.replaced_by_issue_id = ci.id;

revoke all on public.v_certificate_register from public, anon;
grant select on public.v_certificate_register to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: "a continuous serial run with no missing numbers", proven
-- ═══════════════════════════════════════════════════════════════════════

-- One row per series (campus, certificate type, session) the caller can
-- see. expected_count is the longer of what the register holds and what
-- FR-T02's counter says it allocated, so a row deleted out from under the
-- register — which nothing above permits, which is the point — would show
-- up as a missing ordinal rather than as a shorter, still-continuous run.
create or replace function public.certificate_register_continuity(
  p_campus_id uuid default null,
  p_certificate_type public.certificate_type default null,
  p_academic_year int default null
)
returns table (
  campus_id        uuid,
  campus_code      text,
  certificate_type public.certificate_type,
  session_id       uuid,
  academic_year    int,
  expected_count   bigint,
  present_count    bigint,
  unnumbered_count bigint,
  counter_value    bigint,
  missing_seq      bigint[],
  first_serial     text,
  last_serial      text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
begin
  if v_role not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  return query
  with series as (
    select ci.campus_id, ci.certificate_type, ci.session_id,
           max(ci.serial_seq)                                  as max_seq,
           count(ci.serial_seq)                                as present,
           count(*) filter (where ci.serial_seq is null)       as unnumbered,
           min(ci.serial_no) filter (where ci.serial_seq is not null) as any_serial
      from public.certificate_issue ci
     where ci.tenant_id = v_tenant_id
       -- SECURITY DEFINER bypasses RLS, so the campus scope is checked out
       -- loud (b16ba25's convention).
       and (v_role in ('super_admin', 'owner') or ci.campus_id = any(app.auth_campus_ids()))
       and (p_campus_id is null or ci.campus_id = p_campus_id)
       and (p_certificate_type is null or ci.certificate_type = p_certificate_type)
     group by ci.campus_id, ci.certificate_type, ci.session_id
  )
  select
    s.campus_id,
    c.code,
    s.certificate_type,
    s.session_id,
    extract(year from sess.starts_on)::int,
    greatest(coalesce(s.max_seq, 0), coalesce(ctr.current_value, 0)),
    s.present,
    s.unnumbered,
    coalesce(ctr.current_value, 0),
    coalesce((
      select array_agg(g.n order by g.n)
        from generate_series(1, greatest(coalesce(s.max_seq, 0), coalesce(ctr.current_value, 0))::bigint) as g(n)
       where not exists (
         select 1 from public.certificate_issue m
          where m.campus_id = s.campus_id
            and m.certificate_type = s.certificate_type
            and m.session_id = s.session_id
            and m.serial_seq = g.n)
    ), array[]::bigint[]),
    (select f.serial_no from public.certificate_issue f
      where f.campus_id = s.campus_id and f.certificate_type = s.certificate_type
        and f.session_id = s.session_id and f.serial_seq is not null
      order by f.serial_seq limit 1),
    (select l.serial_no from public.certificate_issue l
      where l.campus_id = s.campus_id and l.certificate_type = s.certificate_type
        and l.session_id = s.session_id and l.serial_seq is not null
      order by l.serial_seq desc limit 1)
  from series s
  join public.campus c on c.id = s.campus_id
  join public.academic_session sess on sess.id = s.session_id
  left join public.certificate_serial_counter ctr
    on ctr.campus_id = s.campus_id
   and ctr.certificate_type = s.certificate_type
   and ctr.session_id = s.session_id
  where p_academic_year is null or extract(year from sess.starts_on)::int = p_academic_year
  order by c.code, s.certificate_type, extract(year from sess.starts_on)::int desc;
end;
$$;

revoke execute on function public.certificate_register_continuity(uuid, public.certificate_type, int) from public, anon;
grant execute on function public.certificate_register_continuity(uuid, public.certificate_type, int) to authenticated;
