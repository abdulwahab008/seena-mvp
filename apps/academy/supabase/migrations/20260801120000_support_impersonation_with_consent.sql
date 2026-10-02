-- FR-A16: support impersonation with consent.
--
-- "As a support engineer, I want to view the product exactly as a specific
-- school user sees it after they approve it, so that I can diagnose their
-- problem without asking for their password."
--
-- 20260729135955_foundation.sql deliberately left a hole here: "The
-- custom_access_token_hook's break-glass/support-impersonation overlay
-- (rls.md §7) is intentionally omitted — no support tooling exists yet to
-- grant it, and shipping the overlay without the tooling that populates
-- platform.support_grant is dead code." This migration is that tooling and
-- that overlay, together.
--
-- Impersonation is the single most dangerous feature in a multi-tenant
-- product: done carelessly it is a permanent, unattributable backdoor into
-- every customer's data. Every property below exists to stop that, and the
-- shape is FR-I17's (break-glass mark unlock) because FR-I17 is the same
-- problem — a deliberate hole in a wall that must not become a door.
--
-- ── 1. sub is NEVER rewritten. This is the load-bearing decision ──────
--
-- The obvious implementation of "view the product exactly as the user sees
-- it" is to mint a token whose `sub` is the target user. That would be a
-- catastrophe, and it is refused here.
--
-- auth.uid() is the attribution primitive of this entire schema. It is what
-- app.tg_audit_row() writes into audit_log.actor_user_id, and it is what
-- ~70 tables' requested_by / approved_by / granted_by / issued_by / locked_by
-- columns are filled from. FR-I17's whole two-person control is the table
-- CHECK `approved_by <> requested_by` — which is worth exactly nothing if a
-- support engineer can make auth.uid() return whoever they like. Rewriting
-- `sub` does not "impersonate a user", it forges one, on every table at once,
-- with no way to tell the forgery from the real thing afterwards.
--
-- So: under impersonation the JWT's `sub` remains the SUPPORT ENGINEER'S OWN
-- auth user id. auth.uid() is the real human, always. What the overlay
-- changes is the AUTHORISATION claims — tenant_id, campus_ids, app_role,
-- role_id, cv — which are read off the TARGET user, so RLS shows the
-- engineer the target's role-and-campus view of the product. And it adds one
-- claim that a normally-issued token can never carry:
--
--     "imp": {"sid": <session id>, "sub": <target user>, "by": <engineer>,
--             "exp": <session deadline>}
--
-- An impersonated token is therefore trivially distinguishable from a real
-- one, in SQL (app.auth_impersonation()) and in the client, which is what
-- makes both the write block and the banner possible.
--
-- The honest cost, stated rather than hidden: policies keyed on
-- `user_id = auth.uid()` — "my own leave requests", "my own payslip" — still
-- resolve to the engineer, so the engineer sees the target's ROLE view, not
-- the target's PERSONAL rows. That is a fidelity gap in the user story and it
-- is the right trade: the alternative buys those few rows by making every
-- write in the product unattributable.
--
-- ── 2. Consent: whose, how, and revocable to the second ───────────────
--
-- The tenant's OWNER consents, nobody else — not the target user, not a
-- Principal, and emphatically not the support engineer. Consent is a row in
-- impersonation_consent, granted through grant_impersonation_consent(), and
-- it is time-boxed: 1 to 24 hours, capped by a table CHECK so the cap holds
-- for service_role and the table owner too.
--
-- `scope` (a column the FR names) is used honestly: 'user' consent names one
-- target; 'tenant' consent covers any eligible user in the school, for cases
-- where the school does not yet know which account is broken. Neither widens
-- the role ceiling, the 60-minute session cap or the write block.
--
-- The FR's Notes are the requirement: "Consent must be revocable instantly by
-- the Owner mid-session, which means the check cannot live only in the token
-- — a revocation epoch or a per-request consent lookup is required." Both
-- halves are built, and they are independent:
--
--   * revoke_impersonation_consent() ends every live session on that consent
--     in the same statement. That is the state change.
--   * app.assert_impersonation_live() is the PER-REQUEST lookup, and it is
--     what actually refuses. It re-reads the session AND the consent from
--     their tables on every single request and raises when either is over.
--     Nothing depends on the token being re-minted, on the sweep being
--     punctual, or on the tab being closed.
--
-- It is wired into app.auth_tenant_id() — exactly where FR-A13 put
-- app.assert_claims_fresh(), and for the same reason: `tenant_id =
-- app.auth_tenant_id()` is the leading conjunct of essentially every RLS
-- policy already shipped here, so one edit gives every already-shipped table
-- live impersonation enforcement without touching ~100 other migrations.
--
-- ── 3. Role ceiling: who may be impersonated, enforced as a CHECK ─────
--
-- chk_impersonation_role_ceiling refuses 'super_admin', 'owner', 'parent' and
-- 'student' as targets. It is a table CHECK, not a policy and not a function
-- branch, so it holds for service_role, for the table owner and for any
-- future writer:
--
--   * owner — the Owner is the CONSENT GRANTER. An engineer impersonating an
--     Owner could grant themselves consent, extend it, revoke the Owner's
--     ability to cut them off, and approve anything the product asks an Owner
--     to approve. Consent that can be self-granted is not consent. This is
--     FR-I17's "never yourself", one level up.
--   * super_admin — impersonating another platform admin is lateral movement
--     inside the support team with the customer's consent standing in for the
--     platform's.
--   * parent / student — the Owner cannot consent on a family's behalf to a
--     support engineer reading that family's private portal, and the data is
--     a minor's. (Guardians are structurally excluded anyway: they have no
--     app_user row, and impersonation_session.target_user_id references one.)
--
-- Plus chk_impersonation_not_self (an engineer may not impersonate
-- themselves — it would be an audit-laundering no-op) and
-- chk_impersonation_two_person (`consent_granted_by <> support_user_id`), the
-- FR-I17-shaped two-person control: the person who opens the door is never
-- the person who authorised it, for every writer including service_role.
--
-- ── 4. What an impersonator may NOT do, and why a trigger not a policy ─
--
-- The FR asks for `RLS: blocked_write_during_impersonation policy on
-- fee_payment, fee_waiver, result_publication using (auth.jwt()->>'imp') is
-- null`. Built — but as a BEFORE trigger, because as an RLS policy it would
-- not work at all in this codebase. Almost every write in this schema goes
-- through a SECURITY DEFINER RPC (record_payment, fn_publish_merit_list,
-- fn_compute_annual_result, …), and SECURITY DEFINER owned by postgres
-- BYPASSES RLS ENTIRELY. A policy would be a sign on a door nobody uses. A
-- BEFORE trigger fires for the RPC, for service_role, for the table owner and
-- for a direct PostgREST write alike.
--
-- The blocked set is the FR's three categories mapped onto the tables this
-- schema actually has (the FR's `fee_waiver`/`result_publication` do not
-- exist under those names):
--
--   money moved or forgiven  fee_payment, fee_payment_allocation, fee_receipt,
--                            fee_ledger, admission_fee_payment,
--                            admission_fee_waiver, concession_award,
--                            expense_voucher, expense_voucher_approval,
--                            fee_increase_approval
--   results made real        subject_result, annual_result, result_position,
--                            result_withhold
--
-- fee_challan generation is deliberately NOT blocked: issuing a challan
-- asserts an amount is owed and is reversible, and a support engineer
-- reproducing a broken challan run is a legitimate diagnosis. Marking one
-- PAID is not reversible in any way that matters, and that is fee_payment.
-- The FR's Notes make the argument: "if a support engineer can mark a challan
-- paid while impersonating an accountant, the audit trail becomes legally
-- worthless in a fee dispute."
--
-- ── 5. "and the attempt is audited" — an honest limitation ────────────
--
-- AC3 asks for the refused attempt to be audited. A BEFORE trigger that
-- RAISES aborts the transaction, and an INSERT written before the raise dies
-- with it — PostgreSQL has no autonomous transaction without an extension
-- (dblink/pg_background), and adding one to log a refusal is not a trade this
-- schema should make. So the two halves are separated and neither pretends to
-- be the other:
--
--   * The BLOCK is unconditional and depends on nothing. It raises 42501
--     IMPERSONATION_WRITE_BLOCKED with a DETAIL naming the session, the real
--     engineer, the target and the table — which lands in the Postgres server
--     log whatever the caller does next.
--   * The durable in-database record is written by
--     record_impersonation_block(), a separate transaction the support
--     console calls from its error path. It bumps
--     impersonation_session.blocked_write_count and raises a security_event.
--
-- A caller who bypasses the console and drives PostgREST directly is still
-- blocked, and still logged by Postgres; they just do not write their own
-- security_event. That is stated here rather than papered over.
--
-- ── 6. Where impersonation events are audited, and why there ──────────
--
-- Three places, following FR-T09's rule and FR-I17's application of it:
--
--   1. audit_log, via app.tg_audit_row() on both new tables. Every consent
--      grant, every revocation, every session start and end IS a row change,
--      so this is where the evidence goes: hash-chained, tamper-evident,
--      verified by run_audit_chain_verification().
--   2. security_event, three event types of severity 'alert'/'warning':
--      'impersonation_started', 'impersonation_write_blocked',
--      'impersonation_consent_revoked'. audit_log is a per-row change log
--      nobody reads unprompted; security_event is the table this schema built
--      for "something an Owner or Principal should act on", it is read by
--      exactly super_admin/owner/principal, and it is itself covered by the
--      audit chain. "A stranger is currently inside your school's account" is
--      the highest-value alert this product can raise.
--   3. impersonation_session itself, which is AC6's log surface: who, when,
--      until when, how it ended, and the read/write counts.
--
-- audit_log gains two columns for AC5 — effective_actor_user_id (the
-- impersonated user) and impersonation_session_id — because AC5 asks for a
-- fact audit_log structurally could not carry: "the audit row records
-- actor=support engineer and effective_actor=the impersonated user". actor
-- was already right and needed no change, precisely because `sub` is not
-- rewritten (§1). Both new columns are folded into the hash chain, so they
-- cannot be edited after the fact any more than actor_user_id can. The fold
-- is conditional (nothing is appended when both are null), so every audit row
-- written before this migration hashes to exactly the byte string it hashed
-- to before and the existing chain still verifies.
--
-- ── 7. Time bounds, and everything that ends a session ────────────────
--
--   * ends_at <= started_at + 60 minutes, as a table CHECK. The FR's cap is
--     structural, not a function argument that a service_role INSERT could
--     ignore.
--     The CHECK alone is not enough, because started_at is itself a supplied
--     column: a service_role INSERT dated 2030 satisfies "ends_at <=
--     started_at + 60 minutes" and is then live for four years. The born-live
--     trigger anchors both windows to clock_timestamp() so the cap means
--     sixty minutes from NOW for every writer. Same for the consent's 24.
--   * The deadline is WALL CLOCK, compared on every request by
--     assert_impersonation_live() (via auth_tenant_id, for everything RLS
--     mediates) and on every audited write by tg_audit_row() (for the
--     SECURITY DEFINER RPCs that bypass RLS). At minute 61 the next request
--     raises, with no job having run. This is FR-I17's finding, restated: the
--     predicate closes the window, the sweep only makes it visible.
--   * expire_impersonation_sessions() is the FR's five-minute cron. There is
--     no pg_cron in this stack, so it follows the same posture as every other
--     scheduled function here (FR-I17, FR-B16, FR-K13, FR-G11): a plain,
--     correct, tested function a real cron.schedule() calls. Its p_as_of
--     cannot widen anything — the sweep only ever moves a session from open
--     to closed.
--   * end_impersonation() — by the engineer (this is how you leave) or by any
--     Owner of the tenant (this is how you throw someone out).
--   * revoke_impersonation_consent() — kills every live session on it.
--   * Consent expiry passing mid-session.
--   * The engineer ceasing to be an active super_admin, or the target ceasing
--     to be active — both re-checked per request.
--   * A role or campus change on the TARGET bumps their claims_version, and
--     FR-A13's epoch check then raises TOKEN_EPOCH_STALE, because the overlay
--     stamps the target's cv (see assert_claims_fresh below).
--
-- ── 8. Append-only, the FR-T02/FR-T08/FR-I17 three-layer shape ────────
--
--   * BORN LIVE. A consent is born unrevoked and attributable to a real,
--     active Owner of the school it names. A session is born open, with zero
--     counters, only against a consent that is live RIGHT NOW and actually
--     covers the target. Without these, service_role could INSERT a
--     pre-authorised session with a far-future deadline and walk straight
--     past start_impersonation() — an INSERT reaches no UPDATE guard. This is
--     FR-I17's trg_mark_unlock_request_born_pending, one table over.
--   * NAMED TRANSITIONS. Consent: REVOKE only. Session: END, SHORTEN
--     (ends_at may only move EARLIER — narrowing is always safe, and it is
--     also how an Owner cuts a session short) and COUNT (counters may only
--     increase). Everything else raises.
--   * NO DELETE, NO TRUNCATE. TRUNCATE fires no row trigger and consults no
--     RLS (FR-T08's finding), and a consent record that can be emptied in one
--     statement is not a consent record.

-- ═══════════════════════════════════════════════════════════════════════
-- 1. Schema
-- ═══════════════════════════════════════════════════════════════════════

create table public.impersonation_consent (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  -- The Owner. Enforced as "an active owner of THIS tenant" by the born-live
  -- trigger, so it holds for every writer, not only for the RPC.
  granted_by     uuid not null references public.app_user(user_id),
  granted_at     timestamptz not null default clock_timestamp(),
  expires_at     timestamptz not null,
  revoked_at     timestamptz,
  revoked_by     uuid references public.app_user(user_id),
  -- 'user': this one account. 'tenant': any eligible account in the school,
  -- for when the school cannot yet say which login is broken.
  scope          text not null default 'user',
  target_user_id uuid references public.app_user(user_id),
  constraint chk_consent_scope check (
    (scope = 'user'   and target_user_id is not null)
    or (scope = 'tenant' and target_user_id is null)
  ),
  -- The FR's "24-hour consent", as a constraint rather than an argument
  -- check: a 30-day consent cannot be written by anyone, including a
  -- service_role key.
  constraint chk_consent_window check (
    expires_at > granted_at and expires_at <= granted_at + interval '24 hours'
  ),
  constraint chk_consent_revocation check (
    (revoked_at is null and revoked_by is null)
    or (revoked_at is not null and revoked_by is not null and revoked_at >= granted_at)
  )
);

create index idx_impersonation_consent_live
  on public.impersonation_consent (tenant_id, expires_at desc)
  where revoked_at is null;
create index idx_impersonation_consent_target on public.impersonation_consent (target_user_id);

comment on table public.impersonation_consent is
  'FR-A16: a school Owner''s time-boxed permission for platform support to act as one of their users. Append-only; revocable to the second by revoke_impersonation_consent().';
comment on column public.impersonation_consent.scope is
  '''user'' names one target; ''tenant'' covers any eligible user in the school. Neither widens the role ceiling, the 60-minute session cap or the write block.';

create table public.impersonation_session (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant(id) on delete cascade,
  consent_id         uuid not null references public.impersonation_consent(id),
  -- Denormalised from the consent so the two-person control can be a table
  -- CHECK: a CHECK cannot reach into another table, and FR-I17 established
  -- that this rule has to hold for every caller, not only for the ones a
  -- policy names. The born-live trigger keeps it honest.
  consent_granted_by uuid not null references public.app_user(user_id),
  support_user_id    uuid not null references public.app_user(user_id),
  target_user_id     uuid not null references public.app_user(user_id),
  -- Snapshot, so the log still says what was impersonated after the target is
  -- promoted, and so the ceiling is enforceable as a CHECK.
  target_role        public.app_role not null,
  started_at         timestamptz not null default clock_timestamp(),
  ends_at            timestamptz not null,
  ended_at           timestamptz,
  end_reason         text,
  read_count         bigint not null default 0,
  write_count        bigint not null default 0,
  blocked_write_count bigint not null default 0,
  constraint chk_impersonation_not_self check (support_user_id <> target_user_id),
  -- The two-person control. Whoever opened the door is never whoever
  -- authorised it — for service_role and the table owner too.
  constraint chk_impersonation_two_person check (consent_granted_by <> support_user_id),
  constraint chk_impersonation_role_ceiling check (
    target_role not in ('super_admin', 'owner', 'parent', 'student')
  ),
  -- The FR's 60-minute cap, structural.
  constraint chk_impersonation_window check (
    ends_at > started_at and ends_at <= started_at + interval '60 minutes'
  ),
  constraint chk_impersonation_ended check (
    (ended_at is null and end_reason is null)
    or (ended_at is not null and end_reason is not null and ended_at >= started_at)
  ),
  constraint chk_impersonation_end_reason check (
    end_reason is null or end_reason in (
      'ended_by_support', 'ended_by_owner', 'expired', 'consent_revoked', 'consent_expired'
    )
  ),
  constraint chk_impersonation_counts check (
    read_count >= 0 and write_count >= 0 and blocked_write_count >= 0
  )
);

-- One live session per engineer, and one per target. Two engineers inside the
-- same account at once makes "who did that" unanswerable from the session log.
create unique index uq_impersonation_live_support
  on public.impersonation_session (support_user_id) where ended_at is null;
create unique index uq_impersonation_live_target
  on public.impersonation_session (target_user_id) where ended_at is null;
create index idx_impersonation_session_sweep on public.impersonation_session (ends_at) where ended_at is null;
create index idx_impersonation_session_log on public.impersonation_session (tenant_id, started_at desc);
create index idx_impersonation_session_consent on public.impersonation_session (consent_id);

comment on table public.impersonation_session is
  'FR-A16 AC6: the impersonation log an Owner reads — who acted as whom, from when to when, how it ended, and what it touched.';
comment on column public.impersonation_session.write_count is
  'Exact. Incremented by app.tg_audit_row(), which already fires on every audited write in the schema.';
comment on column public.impersonation_session.read_count is
  'Incremented by public.impersonation_note_reads(), which the support console calls once per page view. PostgREST runs GET requests inside a READ ONLY transaction and an RLS SELECT policy cannot write, so a trigger cannot count rows read; this is the closest honest approximation, and unlike write_count it is app-reported rather than exact.';

create trigger impersonation_consent_audit after insert or update or delete on public.impersonation_consent
  for each row execute function app.tg_audit_row();
create trigger impersonation_session_audit after insert or update or delete on public.impersonation_session
  for each row execute function app.tg_audit_row();

-- ═══════════════════════════════════════════════════════════════════════
-- 2. Born live / append-only guards
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_impersonation_consent_born_live()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.revoked_at is not null or new.revoked_by is not null then
    raise exception 'a consent is born unrevoked'
      using errcode = '42501',
            detail = format('insert of impersonation_consent revoked_at=%s by %s', new.revoked_at, current_user);
  end if;

  -- chk_consent_window bounds expires_at against granted_at, but granted_at is
  -- itself a supplied column: a service_role INSERT dated a year ahead
  -- satisfies that CHECK and is still `expires_at > clock_timestamp()` — i.e.
  -- live — for the whole year. The 24-hour cap only means anything anchored to
  -- the wall clock, not to a neighbouring column.
  if new.granted_at > clock_timestamp()
     or new.expires_at > clock_timestamp() + interval '24 hours' then
    raise exception 'CONSENT_WINDOW_INVALID'
      using errcode = '23514',
            detail = format('consent window %s..%s does not start now (writer: %s)',
                            new.granted_at, new.expires_at, current_user),
            hint = 'Consent begins the moment it is granted and lasts at most 24 hours from that moment.';
  end if;

  if not exists (
    select 1 from public.app_user au
     where au.user_id = new.granted_by
       and au.tenant_id = new.tenant_id
       and au.app_role = 'owner'
       and au.status = 'active'
  ) then
    raise exception 'consent can only be granted by an active Owner of the school it names'
      using errcode = '42501',
            detail = format('granted_by %s is not an active owner of tenant %s (writer: %s)',
                            new.granted_by, new.tenant_id, current_user);
  end if;

  if new.target_user_id is not null and not exists (
    select 1 from public.app_user au
     where au.user_id = new.target_user_id
       and au.tenant_id = new.tenant_id
       and au.status = 'active'
       and au.app_role not in ('super_admin', 'owner', 'parent', 'student')
  ) then
    raise exception 'IMPERSONATION_ROLE_FORBIDDEN'
      using errcode = '42501',
            detail = format('target %s is not an impersonatable active user of tenant %s',
                            new.target_user_id, new.tenant_id);
  end if;

  return new;
end;
$$;

create trigger trg_impersonation_consent_born_live
  before insert on public.impersonation_consent
  for each row execute function app.tg_impersonation_consent_born_live();

create or replace function app.tg_impersonation_consent_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'impersonation consent is append-only'
      using errcode = '42501',
            detail = format('delete of impersonation_consent %s by %s', old.id, current_user),
            hint = 'Consent is withdrawn with revoke_impersonation_consent(), which leaves the record of it having been given.';
  end if;

  -- The one named transition: REVOKE.
  if old.revoked_at is null
     and new.revoked_at is not null
     and new.revoked_by is not null
     and new.id is not distinct from old.id
     and new.tenant_id is not distinct from old.tenant_id
     and new.granted_by is not distinct from old.granted_by
     and new.granted_at is not distinct from old.granted_at
     and new.expires_at is not distinct from old.expires_at
     and new.scope is not distinct from old.scope
     and new.target_user_id is not distinct from old.target_user_id then
    return new;
  end if;

  raise exception 'impersonation consent is append-only'
    using errcode = '42501',
          detail = format('update of impersonation_consent %s by %s', old.id, current_user),
          hint = 'The only legal change to a consent is revoking it once.';
end;
$$;

create trigger trg_impersonation_consent_append_only
  before update or delete on public.impersonation_consent
  for each row execute function app.tg_impersonation_consent_append_only();

create or replace function app.tg_impersonation_no_truncate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'impersonation records are append-only'
    using errcode = '42501',
          detail = format('truncate of %s by %s', tg_table_name, current_user),
          hint = 'TRUNCATE fires no row trigger and consults no RLS, so it is refused outright.';
end;
$$;

create trigger trg_impersonation_consent_no_truncate
  before truncate on public.impersonation_consent
  for each statement execute function app.tg_impersonation_no_truncate();
create trigger trg_impersonation_session_no_truncate
  before truncate on public.impersonation_session
  for each statement execute function app.tg_impersonation_no_truncate();

create or replace function app.tg_impersonation_session_born_live()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_consent public.impersonation_consent;
begin
  if new.ended_at is not null or new.end_reason is not null
     or new.read_count <> 0 or new.write_count <> 0 or new.blocked_write_count <> 0 then
    raise exception 'an impersonation session is born open'
      using errcode = '42501',
            detail = format('insert of impersonation_session ended_at=%s counts=%s/%s/%s by %s',
                            new.ended_at, new.read_count, new.write_count, new.blocked_write_count, current_user);
  end if;

  -- Same hole as the consent's, one table over and worse: chk_impersonation_window
  -- bounds ends_at against started_at, so a service_role INSERT with
  -- started_at = 2030 passes the CHECK and app.assert_impersonation_live()'s
  -- `ends_at > clock_timestamp()` is then true for four years. The 60-minute
  -- cap has to be measured from now.
  if new.started_at > clock_timestamp()
     or new.ends_at > clock_timestamp() + interval '60 minutes' then
    raise exception 'IMPERSONATION_WINDOW_INVALID'
      using errcode = '23514',
            detail = format('session window %s..%s does not start now (writer: %s)',
                            new.started_at, new.ends_at, current_user),
            hint = 'A session begins the moment it is opened and lasts at most 60 minutes from that moment.';
  end if;

  select * into v_consent from public.impersonation_consent where id = new.consent_id;
  if not found
     or v_consent.tenant_id <> new.tenant_id
     or v_consent.granted_by <> new.consent_granted_by
     or v_consent.revoked_at is not null
     or v_consent.expires_at <= clock_timestamp()
     or (v_consent.scope = 'user' and v_consent.target_user_id <> new.target_user_id) then
    raise exception 'IMPERSONATION_NOT_CONSENTED'
      using errcode = '42501',
            detail = format('no live consent %s covers target %s in tenant %s (writer: %s)',
                            new.consent_id, new.target_user_id, new.tenant_id, current_user),
            hint = 'A session may only be opened against a consent that is live at this moment and names this user.';
  end if;

  if not exists (
    select 1 from public.app_user au
     where au.user_id = new.support_user_id
       and au.tenant_id = new.tenant_id
       and au.app_role = 'super_admin'
       and au.status = 'active'
  ) then
    raise exception 'FORBIDDEN'
      using errcode = '42501',
            detail = format('support_user %s is not an active super_admin of tenant %s (writer: %s)',
                            new.support_user_id, new.tenant_id, current_user);
  end if;

  if not exists (
    select 1 from public.app_user au
     where au.user_id = new.target_user_id
       and au.tenant_id = new.tenant_id
       and au.status = 'active'
       and au.app_role = new.target_role
  ) then
    raise exception 'IMPERSONATION_TARGET_UNKNOWN'
      using errcode = '42501',
            detail = format('target %s is not an active %s in tenant %s (writer: %s)',
                            new.target_user_id, new.target_role, new.tenant_id, current_user);
  end if;

  return new;
end;
$$;

create trigger trg_impersonation_session_born_live
  before insert on public.impersonation_session
  for each row execute function app.tg_impersonation_session_born_live();

create or replace function app.tg_impersonation_session_transitions()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'impersonation session is append-only'
      using errcode = '42501',
            detail = format('delete of impersonation_session %s by %s', old.id, current_user),
            hint = 'A session that happened cannot be made not to have happened.';
  end if;

  if new.id is distinct from old.id
     or new.tenant_id is distinct from old.tenant_id
     or new.consent_id is distinct from old.consent_id
     or new.consent_granted_by is distinct from old.consent_granted_by
     or new.support_user_id is distinct from old.support_user_id
     or new.target_user_id is distinct from old.target_user_id
     or new.target_role is distinct from old.target_role
     or new.started_at is distinct from old.started_at then
    raise exception 'impersonation session is append-only'
      using errcode = '42501',
            detail = format('update of impersonation_session %s changed a frozen column (writer: %s)',
                            old.id, current_user);
  end if;

  -- SHORTEN: a deadline may only move earlier. Narrowing is always safe, and
  -- it is how an Owner cuts a live session short without ending it outright.
  if new.ends_at > old.ends_at then
    raise exception 'impersonation session is append-only'
      using errcode = '42501',
            detail = format('update of impersonation_session %s moved ends_at from %s to %s (writer: %s)',
                            old.id, old.ends_at, new.ends_at, current_user),
            hint = 'An impersonation window can be cut short but never extended. Start a new session.';
  end if;

  -- END: write-once.
  if old.ended_at is not null
     and (new.ended_at is distinct from old.ended_at or new.end_reason is distinct from old.end_reason) then
    raise exception 'impersonation session is append-only'
      using errcode = '42501',
            detail = format('update of impersonation_session %s re-decided how it ended (writer: %s)',
                            old.id, current_user);
  end if;

  -- COUNT: monotonic.
  if new.read_count < old.read_count
     or new.write_count < old.write_count
     or new.blocked_write_count < old.blocked_write_count then
    raise exception 'impersonation session is append-only'
      using errcode = '42501',
            detail = format('update of impersonation_session %s rewound a counter (writer: %s)',
                            old.id, current_user);
  end if;

  return new;
end;
$$;

create trigger trg_impersonation_session_transitions
  before update or delete on public.impersonation_session
  for each row execute function app.tg_impersonation_session_transitions();

-- ═══════════════════════════════════════════════════════════════════════
-- 3. Claim helpers and the per-request check
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY DEFINER, and this one is load-bearing rather than stylistic:
-- foundation.sql grants app.jwt() to `authenticated` ONLY. This reader is
-- reached from app.tg_block_impersonated_write(), an INVOKER-rights trigger
-- that has to fire for service_role, for anon and for the table owner too —
-- without it, every service_role write to a blocked table would die with
-- "permission denied for function jwt" instead of being evaluated, which
-- breaks ordinary backend writes to fee_payment and friends and makes the
-- block itself untestable for the writers it most needs to bind.
-- Nothing is exposed by the elevation: the imp claim is the caller's own
-- request-local GUC, not a row in anyone's table.
create or replace function app.auth_impersonation()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when jsonb_typeof(app.jwt() -> 'imp') = 'object' then app.jwt() -> 'imp' end;
$$;

comment on function app.auth_impersonation() is
  'FR-A16: the imp claim, or null. A normally-issued token never carries it, which is what makes an impersonated request distinguishable from a real one.';

-- SECURITY DEFINER for the same reason app.assert_claims_fresh() is: it is
-- reached from inside RLS policy evaluation (via app.auth_tenant_id()), and
-- an invoker-rights read of impersonation_session from there would recurse
-- into that table's own policy. Visibility is not at stake — every filter
-- below is explicit and pinned to the caller's own auth.uid().
create or replace function app.assert_impersonation_live()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_imp jsonb := app.auth_impersonation();
begin
  if v_imp is null then
    return true;
  end if;

  perform 1
     from public.impersonation_session s
     join public.impersonation_consent c on c.id = s.consent_id
     join public.app_user sup on sup.user_id = s.support_user_id
     join public.app_user tgt on tgt.user_id = s.target_user_id
    where s.id = nullif(v_imp ->> 'sid', '')::uuid
      -- The token names its own session AND its own holder: a leaked imp
      -- claim replayed by anyone else matches nothing.
      and s.support_user_id = (select auth.uid())
      and s.target_user_id = nullif(v_imp ->> 'sub', '')::uuid
      and s.ended_at is null
      and s.ends_at > clock_timestamp()
      and c.revoked_at is null
      and c.expires_at > clock_timestamp()
      and sup.status = 'active'
      and sup.app_role = 'super_admin'
      and tgt.status = 'active';

  if not found then
    -- PT401 rather than FR-A13's 28000: AC4 asks for 401 specifically, and
    -- PostgREST maps SQLSTATE class 28 to 403 while it maps the PTxyz range
    -- to the HTTP status xyz. A closed impersonation window is an
    -- authentication fact — this token is no longer good — not a permissions
    -- fact about the row being touched.
    raise exception 'IMPERSONATION_SESSION_ENDED'
      using errcode = 'PT401',
            hint = 'The consent was revoked or expired, the 60-minute window closed, or the session was ended. Sign in again as yourself.';
  end if;

  return true;
end;
$$;

revoke execute on function app.assert_impersonation_live() from public, anon;
grant execute on function app.assert_impersonation_live() to authenticated;

-- Rewritten from 20260731750000_jwt_claim_epoch_and_fail_closed.sql for one
-- reason: under impersonation the cv claim is the TARGET's epoch, because the
-- overlay reads every authorisation claim off the target. Comparing it to the
-- support engineer's live claims_version would raise TOKEN_EPOCH_STALE on
-- every single impersonated request. Comparing it to the target's is also
-- what makes a role or campus change on the target end the session, which is
-- the behaviour FR-A13 promised for an ordinary token and there is no reason
-- an impersonated one should be weaker.
create or replace function app.assert_claims_fresh()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_claim_cv int   := nullif(app.jwt() ->> 'cv', '')::int;
  v_imp      jsonb := app.auth_impersonation();
  v_uid      uuid  := coalesce(nullif(v_imp ->> 'sub', '')::uuid, (select auth.uid()));
  v_live_cv  int;
begin
  if v_claim_cv is null or v_uid is null then
    return true;
  end if;

  select claims_version into v_live_cv from public.app_user where user_id = v_uid;
  if not found then
    return true;
  end if;

  if v_claim_cv <> v_live_cv then
    raise exception 'TOKEN_EPOCH_STALE' using errcode = '28000';
  end if;

  return true;
end;
$$;

-- The one edit that gives every already-shipped RLS policy live impersonation
-- enforcement, exactly where FR-A13 put the epoch check.
create or replace function app.auth_tenant_id()
returns uuid
language sql
stable
as $$
  select nullif(app.jwt() ->> 'tenant_id', '')::uuid
   where app.assert_claims_fresh()
     and app.assert_impersonation_live();
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- 4. The token overlay
-- ═══════════════════════════════════════════════════════════════════════
--
-- Body below is the existing hook (20260801100000_custom_role_creation.sql)
-- with ONE branch added in front of the staff branch. Note what it does not
-- touch: event->>'user_id' and therefore the token's `sub`. auth.uid() is the
-- support engineer during impersonation, always. See §1 of this file's
-- header for why that is not negotiable.

create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  claims  jsonb := coalesce(event -> 'claims', '{}'::jsonb);
  imp     record;
  u       record;
  gu      record;
begin
  -- FR-A16: support impersonation overlay. Resolved before the ordinary
  -- staff branch so a live session wins over the engineer's own claims, and
  -- gated on the session, the consent, the engineer and the target all being
  -- live at issuance — the same predicate app.assert_impersonation_live()
  -- re-checks on every subsequent request.
  select s.id                as session_id,
         s.target_user_id,
         s.ends_at,
         t.tenant_id,
         t.app_role::text    as app_role,
         t.claims_version,
         coalesce(
           (select array_agg(uc.campus_id)
              from public.user_campus uc
             where uc.user_id = t.user_id and uc.is_active),
           '{}'::uuid[]
         ) as campus_ids,
         (select acs.id
            from public.academic_session acs
           where acs.tenant_id = t.tenant_id and acs.is_current
           limit 1) as academic_session_id,
         coalesce(
           (select cr.id from public.role cr where cr.id = t.custom_role_id and cr.deleted_at is null),
           (select r.id
              from public.role r
             where r.tenant_id = t.tenant_id and r.code = t.app_role::text and r.deleted_at is null
             limit 1)
         ) as role_id
    into imp
    from public.impersonation_session s
    join public.impersonation_consent c on c.id = s.consent_id
    join public.app_user sup on sup.user_id = s.support_user_id
    join public.app_user t   on t.user_id = s.target_user_id
   where s.support_user_id = (event ->> 'user_id')::uuid
     and s.ended_at is null
     and s.ends_at > clock_timestamp()
     and c.revoked_at is null
     and c.expires_at > clock_timestamp()
     and sup.status = 'active'
     and sup.app_role = 'super_admin'
     and t.status = 'active'
   limit 1;

  if found then
    claims := claims || jsonb_build_object(
      'tenant_id',           imp.tenant_id,
      'campus_ids',          to_jsonb(imp.campus_ids),
      'app_role',            imp.app_role,
      'academic_session_id', imp.academic_session_id,
      'role_id',             imp.role_id,
      'cv',                  imp.claims_version,
      'imp', jsonb_build_object(
        'sid', imp.session_id,
        'sub', imp.target_user_id,
        'by',  (event ->> 'user_id')::uuid,
        'exp', imp.ends_at
      )
    );
    return jsonb_set(event, '{claims}', claims);
  end if;

  select au.tenant_id,
         au.app_role::text as app_role,
         au.claims_version,
         coalesce(
           (select array_agg(uc.campus_id)
              from public.user_campus uc
             where uc.user_id = au.user_id and uc.is_active),
           '{}'::uuid[]
         ) as campus_ids,
         (select s.id
            from public.academic_session s
           where s.tenant_id = au.tenant_id and s.is_current
           limit 1) as academic_session_id,
         coalesce(
           (select cr.id
              from public.role cr
             where cr.id = au.custom_role_id and cr.deleted_at is null),
           (select r.id
              from public.role r
             where r.tenant_id = au.tenant_id and r.code = au.app_role::text and r.deleted_at is null
             limit 1)
         ) as role_id
    into u
    from public.app_user au
   where au.user_id = (event ->> 'user_id')::uuid
     and au.status = 'active';

  if found then
    claims := claims || jsonb_build_object(
      'tenant_id',           u.tenant_id,
      'campus_ids',          to_jsonb(u.campus_ids),
      'app_role',            u.app_role,
      'academic_session_id', u.academic_session_id,
      'role_id',             u.role_id,
      'cv',                  u.claims_version
    );
    return jsonb_set(event, '{claims}', claims);
  end if;

  select g.tenant_id,
         coalesce(
           (select array_agg(distinct e.campus_id)
              from public.student_guardian sg
              join public.enrolment e on e.student_id = sg.student_id and e.status = 'active'
             where sg.guardian_id = g.id and sg.to_date is null),
           '{}'::uuid[]
         ) as campus_ids
    into gu
    from public.guardian g
   where g.auth_user_id = (event ->> 'user_id')::uuid;

  if found then
    claims := claims || jsonb_build_object(
      'tenant_id',  gu.tenant_id,
      'campus_ids', to_jsonb(gu.campus_ids),
      'app_role',   'parent',
      'cv',         1
    );
    return jsonb_set(event, '{claims}', claims);
  end if;

  return jsonb_set(event, '{claims}',
    claims || jsonb_build_object('tenant_id', null, 'app_role', 'none', 'cv', 0));
exception
  when others then
    return jsonb_build_object(
      'error', jsonb_build_object(
        'http_code', 500,
        'message', 'AUTH_CLAIMS_UNAVAILABLE'
      )
    );
end;
$$;

grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;

-- ═══════════════════════════════════════════════════════════════════════
-- 5. Attribution: audit_log carries the real human AND the effective one
-- ═══════════════════════════════════════════════════════════════════════

alter table public.audit_log
  add column effective_actor_user_id uuid,
  add column impersonation_session_id uuid;

comment on column public.audit_log.actor_user_id is
  'The real human. Under impersonation this is the SUPPORT ENGINEER, because the token''s sub is never rewritten — see FR-A16 (20260801120000) §1.';
comment on column public.audit_log.effective_actor_user_id is
  'FR-A16 AC5: the impersonated user, when the write was made inside an impersonation session. Null for every ordinary write.';

-- The 12-argument form is kept as a thin wrapper so its other caller —
-- certificate_register_immutability.sql's own chain — is untouched and keeps
-- producing byte-identical digests. One definition, no drift, which is the
-- property 20260731790000's header set out to preserve.
create or replace function app.fn_audit_row_hash(
  p_prev_hash        text,
  p_tenant_id        uuid,
  p_campus_id        uuid,
  p_occurred_at      timestamptz,
  p_actor_user_id    uuid,
  p_actor_role       text,
  p_action           text,
  p_table_name       text,
  p_row_id           uuid,
  p_before           jsonb,
  p_after            jsonb,
  p_changed_columns  text[],
  p_effective_actor  uuid,
  p_session_id       uuid
)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(
    sha256(
      convert_to(
        coalesce(p_prev_hash, 'GENESIS') || '|' ||
        coalesce(p_tenant_id::text, '') || '|' ||
        coalesce(p_campus_id::text, '') || '|' ||
        p_occurred_at::text || '|' ||
        coalesce(p_actor_user_id::text, '') || '|' ||
        coalesce(p_actor_role, '') || '|' ||
        coalesce(p_action, '') || '|' ||
        coalesce(p_table_name, '') || '|' ||
        coalesce(p_row_id::text, '') || '|' ||
        coalesce(p_before::text, '') || '|' ||
        coalesce(p_after::text, '') || '|' ||
        coalesce(array_to_string(p_changed_columns, ','), '') ||
        -- Appended ONLY for an impersonated row, so every audit row written
        -- before FR-A16 hashes exactly the byte string it hashed before and
        -- the existing chain still verifies. An impersonated row's
        -- attribution is inside the digest and cannot be edited afterwards.
        case
          when p_effective_actor is null and p_session_id is null then ''
          else '|' || coalesce(p_effective_actor::text, '') || '|' || coalesce(p_session_id::text, '')
        end,
        'UTF8'
      )
    ),
    'hex'
  );
$$;

revoke execute on function app.fn_audit_row_hash(
  text, uuid, uuid, timestamptz, uuid, text, text, text, uuid, jsonb, jsonb, text[], uuid, uuid
) from public, anon, authenticated;

create or replace function app.fn_audit_row_hash(
  p_prev_hash       text,
  p_tenant_id       uuid,
  p_campus_id       uuid,
  p_occurred_at     timestamptz,
  p_actor_user_id   uuid,
  p_actor_role      text,
  p_action          text,
  p_table_name      text,
  p_row_id          uuid,
  p_before          jsonb,
  p_after           jsonb,
  p_changed_columns text[]
)
returns text
language sql
immutable
set search_path = ''
as $$
  select app.fn_audit_row_hash(
    p_prev_hash, p_tenant_id, p_campus_id, p_occurred_at, p_actor_user_id, p_actor_role,
    p_action, p_table_name, p_row_id, p_before, p_after, p_changed_columns, null::uuid, null::uuid
  );
$$;

-- Body below is 20260731790000's tg_audit_row() with the impersonation
-- attribution threaded through and one counter bump added.
create or replace function app.tg_audit_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid;
  v_campus_id   uuid;
  v_row_id      uuid;
  v_changed     text[];
  v_before      jsonb;
  v_after       jsonb;
  v_redacted    text[];
  v_actor_role  public.app_role;
  v_occurred_at timestamptz;
  v_prev_hash   text;
  v_row_hash    text;
  v_imp         jsonb;
  v_effective   uuid;
  v_session     uuid;
begin
  v_tenant_id := coalesce(
    (to_jsonb(new)->>'tenant_id')::uuid,
    (to_jsonb(old)->>'tenant_id')::uuid,
    case when tg_table_name = 'tenant' then coalesce((to_jsonb(new)->>'id')::uuid, (to_jsonb(old)->>'id')::uuid) end
  );

  if v_tenant_id is null and tg_table_name <> 'tenant' then
    return coalesce(new, old);
  end if;

  v_campus_id := coalesce(
    (to_jsonb(new)->>'campus_id')::uuid,
    (to_jsonb(old)->>'campus_id')::uuid,
    case when tg_table_name = 'campus' then coalesce((to_jsonb(new)->>'id')::uuid, (to_jsonb(old)->>'id')::uuid) end
  );
  v_row_id := coalesce(
    (to_jsonb(new)->>'id')::uuid, (to_jsonb(old)->>'id')::uuid,
    (to_jsonb(new)->>'user_id')::uuid, (to_jsonb(old)->>'user_id')::uuid
  );

  if tg_op = 'UPDATE' then
    select array_agg(key) into v_changed
      from jsonb_each(to_jsonb(new))
     where to_jsonb(new)->key is distinct from to_jsonb(old)->key;
  end if;

  select array_agg(column_name) into v_redacted
    from public.audit_redacted_column where table_name = tg_table_name;

  v_before := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end;
  v_after  := case when tg_op in ('UPDATE', 'INSERT') then to_jsonb(new) else null end;

  if v_redacted is not null then
    if v_before is not null then
      select jsonb_object_agg(t.k, case when t.k = any(v_redacted) then to_jsonb('[redacted]'::text) else t.v end)
        into v_before from jsonb_each(v_before) as t(k, v);
    end if;
    if v_after is not null then
      select jsonb_object_agg(t.k, case when t.k = any(v_redacted) then to_jsonb('[redacted]'::text) else t.v end)
        into v_after from jsonb_each(v_after) as t(k, v);
    end if;
  end if;

  v_actor_role := nullif(app.auth_role(), 'none')::public.app_role;

  -- FR-A16 AC5. actor_user_id is auth.uid() exactly as before and is the real
  -- support engineer, because the overlay never rewrites sub; the impersonated
  -- user is recorded alongside it, never instead of it.
  v_imp := app.auth_impersonation();
  if v_imp is not null then
    v_effective := nullif(v_imp ->> 'sub', '')::uuid;
    v_session   := nullif(v_imp ->> 'sid', '')::uuid;

    -- The wall-clock deadline, on the WRITE path. app.auth_tenant_id()
    -- re-checks it on every RLS-mediated request, but almost every write in
    -- this schema goes through a SECURITY DEFINER RPC, and SECURITY DEFINER
    -- owned by postgres bypasses RLS — the same reason §4 makes the write
    -- block a trigger rather than a policy. This trigger is already on every
    -- audited table, so it is the one place an expired or revoked session
    -- cannot get past, whatever the caller and whether or not the sweep has
    -- run. The two impersonation tables are exempt because ENDING a session is
    -- itself an UPDATE on one of them.
    if tg_table_name not in ('impersonation_session', 'impersonation_consent') then
      perform app.assert_impersonation_live();
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('audit-chain:' || coalesce(v_tenant_id::text, 'GLOBAL'), 0));

  v_occurred_at := clock_timestamp();

  select row_hash into v_prev_hash
    from public.audit_log
   where tenant_id = v_tenant_id
   order by occurred_at desc, id desc
   limit 1;

  v_row_hash := app.fn_audit_row_hash(
    v_prev_hash, v_tenant_id, v_campus_id, v_occurred_at,
    (select auth.uid()), v_actor_role::text, lower(tg_op), tg_table_name, v_row_id,
    v_before, v_after, v_changed, v_effective, v_session
  );

  insert into public.audit_log (
    tenant_id, campus_id, occurred_at, actor_user_id, actor_role, action, table_name, row_id,
    before, after, changed_columns, prev_hash, row_hash,
    effective_actor_user_id, impersonation_session_id
  ) values (
    v_tenant_id, v_campus_id, v_occurred_at, (select auth.uid()), v_actor_role,
    lower(tg_op)::public.audit_action, tg_table_name, v_row_id,
    v_before, v_after, v_changed, v_prev_hash, v_row_hash,
    v_effective, v_session
  );

  -- FR-A16 AC6's write count, taken here because this trigger is already on
  -- every audited table in the schema — one place instead of seventy. Skipped
  -- for impersonation_session itself: the bump is an UPDATE on that table,
  -- which re-enters this trigger, and without the guard that recurses.
  if v_session is not null and tg_table_name <> 'impersonation_session' then
    update public.impersonation_session
       set write_count = write_count + 1
     where id = v_session and ended_at is null;
  end if;

  return coalesce(new, old);
end;
$$;

create or replace function public.run_audit_chain_verification(p_tenant_id uuid default null)
returns setof public.audit_chain_verification
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller_tenant uuid := app.auth_tenant_id();
  v_tenant        record;
  v_row           record;
  v_prev_hash     text;
  v_expected_hash text;
  v_checked       bigint;
  v_broken        boolean;
  v_result        public.audit_chain_verification%rowtype;
begin
  if v_caller_tenant is not null then
    if app.auth_role() not in ('super_admin', 'owner') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    p_tenant_id := v_caller_tenant;
  end if;

  for v_tenant in
    select id from public.tenant where p_tenant_id is null or id = p_tenant_id order by id
  loop
    v_prev_hash := null;
    v_checked := 0;
    v_broken := false;

    for v_row in
      select id, campus_id, occurred_at, actor_user_id, actor_role, action, table_name, row_id,
             before, after, changed_columns, prev_hash, row_hash,
             effective_actor_user_id, impersonation_session_id
        from public.audit_log
       where tenant_id = v_tenant.id
       order by occurred_at, id
    loop
      v_expected_hash := app.fn_audit_row_hash(
        v_prev_hash, v_tenant.id, v_row.campus_id, v_row.occurred_at,
        v_row.actor_user_id, v_row.actor_role::text, v_row.action::text, v_row.table_name, v_row.row_id,
        v_row.before, v_row.after, v_row.changed_columns,
        v_row.effective_actor_user_id, v_row.impersonation_session_id
      );

      if v_row.prev_hash is distinct from v_prev_hash or v_row.row_hash is distinct from v_expected_hash then
        insert into public.audit_chain_verification (
          tenant_id, status, rows_checked, broken_audit_log_id, broken_occurred_at, broken_reason
        ) values (
          v_tenant.id, 'broken', v_checked + 1, v_row.id, v_row.occurred_at,
          case
            when v_row.prev_hash is distinct from v_prev_hash then 'prev_hash does not match the preceding row''s row_hash'
            else 'row_hash does not match this row''s own stored fields'
          end
        ) returning * into v_result;
        v_broken := true;
        return next v_result;
        exit;
      end if;

      v_prev_hash := v_row.row_hash;
      v_checked := v_checked + 1;
    end loop;

    if not v_broken then
      insert into public.audit_chain_verification (tenant_id, status, rows_checked)
      values (v_tenant.id, 'ok', v_checked)
      returning * into v_result;
      return next v_result;
    end if;
  end loop;

  return;
end;
$$;

revoke execute on function public.run_audit_chain_verification(uuid) from public, anon;
grant execute on function public.run_audit_chain_verification(uuid) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- 6. The write block
-- ═══════════════════════════════════════════════════════════════════════

-- Not SECURITY DEFINER: it reads the request's own claims and nothing else.
create or replace function app.tg_block_impersonated_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_imp jsonb := app.auth_impersonation();
begin
  if v_imp is null then
    return coalesce(new, old);
  end if;

  raise exception 'IMPERSONATION_WRITE_BLOCKED'
    using errcode = '42501',
          detail = format('%s on %s refused during impersonation session %s: %s acting as %s (writer: %s)',
                          tg_op, tg_table_name, v_imp ->> 'sid', v_imp ->> 'by', v_imp ->> 'sub', current_user),
          hint = 'Financial and result-publishing writes are never permitted while impersonating. End the session and make the change as yourself, or ask the school to make it.';
end;
$$;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    -- money moved or forgiven
    'fee_payment', 'fee_payment_allocation', 'fee_receipt', 'fee_ledger',
    'admission_fee_payment', 'admission_fee_waiver', 'concession_award',
    'expense_voucher', 'expense_voucher_approval', 'fee_increase_approval',
    -- results made real
    'subject_result', 'annual_result', 'result_position', 'result_withhold'
  ]
  loop
    execute format(
      'create trigger %I before insert or update or delete on public.%I
         for each row execute function app.tg_block_impersonated_write()',
      v_table || '_block_impersonated_write', v_table
    );
  end loop;
end;
$$;

-- Derived from pg_trigger rather than from a catalogue table, so it cannot
-- claim a table is protected that is not.
create or replace function public.impersonation_blocked_tables()
returns setof text
language sql
stable
set search_path = ''
as $$
  select c.relname::text
    from pg_catalog.pg_trigger t
    join pg_catalog.pg_class c on c.oid = t.tgrelid
    join pg_catalog.pg_proc p on p.oid = t.tgfoid
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app'
     and p.proname = 'tg_block_impersonated_write'
     and not t.tgisinternal
   order by 1;
$$;

revoke execute on function public.impersonation_blocked_tables() from public, anon;
grant execute on function public.impersonation_blocked_tables() to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- 7. RPCs
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.grant_impersonation_consent(
  p_target_user_id uuid default null,
  p_hours          integer default 24
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_uid    uuid := (select auth.uid());
  v_id     uuid;
  v_now    timestamptz := clock_timestamp();
begin
  if app.auth_impersonation() is not null then
    raise exception 'FORBIDDEN'
      using errcode = '42501', hint = 'Consent cannot be granted from inside an impersonation session.';
  end if;
  if v_tenant is null or app.auth_role() <> 'owner' then
    raise exception 'FORBIDDEN'
      using errcode = '42501', hint = 'Only the school''s Owner can let platform support act as one of their users.';
  end if;
  if p_hours is null or p_hours < 1 or p_hours > 24 then
    raise exception 'CONSENT_WINDOW_INVALID'
      using errcode = '23514', hint = 'Consent lasts between 1 and 24 hours.';
  end if;

  insert into public.impersonation_consent (
    tenant_id, granted_by, granted_at, expires_at, scope, target_user_id
  ) values (
    v_tenant, v_uid, v_now, v_now + make_interval(hours => p_hours),
    case when p_target_user_id is null then 'tenant' else 'user' end,
    p_target_user_id
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.grant_impersonation_consent(uuid, integer) from public, anon;
grant execute on function public.grant_impersonation_consent(uuid, integer) to authenticated;

create or replace function public.revoke_impersonation_consent(p_consent_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant  uuid := app.auth_tenant_id();
  v_uid     uuid := (select auth.uid());
  v_consent public.impersonation_consent;
  v_ended   integer := 0;
  v_row     record;
begin
  -- Authorisation before the lookup, so a non-Owner cannot use the
  -- CONSENT_NOT_FOUND / FORBIDDEN split to probe which consent ids exist.
  if app.auth_role() <> 'owner' or app.auth_impersonation() is not null then
    raise exception 'FORBIDDEN'
      using errcode = '42501', hint = 'Only the school''s Owner can withdraw consent.';
  end if;

  select * into v_consent from public.impersonation_consent where id = p_consent_id;
  if not found or v_consent.tenant_id is distinct from v_tenant then
    raise exception 'CONSENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_consent.revoked_at is null then
    update public.impersonation_consent
       set revoked_at = clock_timestamp(), revoked_by = v_uid
     where id = p_consent_id;
  end if;

  -- The state change. app.assert_impersonation_live() would refuse these
  -- sessions on their next request regardless of this loop — that is the
  -- point of a per-request lookup — but leaving them open in the log would
  -- make the Owner's own impersonation page lie about who is inside.
  for v_row in
    select id, tenant_id, support_user_id, target_user_id
      from public.impersonation_session
     where consent_id = p_consent_id and ended_at is null
  loop
    update public.impersonation_session
       set ended_at = clock_timestamp(), end_reason = 'consent_revoked'
     where id = v_row.id;
    v_ended := v_ended + 1;

    insert into public.security_event (
      tenant_id, event_type, severity, subject_table, subject_id, actor_user_id, detail
    ) values (
      v_row.tenant_id, 'impersonation_consent_revoked', 'warning',
      'impersonation_session', v_row.id, v_uid,
      jsonb_build_object(
        'consent_id', p_consent_id,
        'support_user_id', v_row.support_user_id,
        'target_user_id', v_row.target_user_id
      )
    );
  end loop;

  return v_ended;
end;
$$;

revoke execute on function public.revoke_impersonation_consent(uuid) from public, anon;
grant execute on function public.revoke_impersonation_consent(uuid) to authenticated;

create or replace function public.start_impersonation(
  p_target_user_id uuid,
  p_minutes        integer default 60
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant  uuid := app.auth_tenant_id();
  v_uid     uuid := (select auth.uid());
  v_target  public.app_user;
  v_consent public.impersonation_consent;
  v_now     timestamptz := clock_timestamp();
  v_ends    timestamptz;
  v_id      uuid;
begin
  if app.auth_impersonation() is not null then
    raise exception 'FORBIDDEN'
      using errcode = '42501', hint = 'An impersonation session cannot start another one.';
  end if;
  if v_tenant is null or app.auth_role() <> 'super_admin' then
    raise exception 'FORBIDDEN'
      using errcode = '42501', hint = 'Only platform support can impersonate.';
  end if;
  if p_minutes is null or p_minutes < 1 or p_minutes > 60 then
    raise exception 'IMPERSONATION_WINDOW_INVALID'
      using errcode = '23514', hint = 'An impersonation session lasts between 1 and 60 minutes.';
  end if;
  if p_target_user_id = v_uid then
    raise exception 'IMPERSONATION_SELF_FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_target
    from public.app_user
   where user_id = p_target_user_id and tenant_id = v_tenant and status = 'active';
  if not found then
    raise exception 'IMPERSONATION_TARGET_UNKNOWN' using errcode = 'P0002';
  end if;
  if v_target.app_role in ('super_admin', 'owner', 'parent', 'student') then
    raise exception 'IMPERSONATION_ROLE_FORBIDDEN'
      using errcode = '42501',
            hint = 'Owners, other platform admins, parents and students are never impersonatable — see FR-A16 §3.';
  end if;

  select * into v_consent
    from public.impersonation_consent c
   where c.tenant_id = v_tenant
     and c.revoked_at is null
     and c.expires_at > v_now
     and (c.scope = 'tenant' or c.target_user_id = p_target_user_id)
   order by c.expires_at desc
   limit 1;

  if not found then
    -- "They never agreed", "they agreed and withdrew it" and "they agreed and
    -- it ran out" are three different conversations to have with a school, so
    -- the refusal names which one it is. The verdict is read off the MOST
    -- RECENT relevant consent rather than off an exists() per branch: a school
    -- that revoked in March and granted a fresh window in August that has
    -- since lapsed is told CONSENT_EXPIRED, which is the true and useful
    -- answer, not CONSENT_REVOKED.
    select * into v_consent
      from public.impersonation_consent c
     where c.tenant_id = v_tenant
       and (c.scope = 'tenant' or c.target_user_id = p_target_user_id)
     order by c.granted_at desc
     limit 1;

    if not found then
      raise exception 'IMPERSONATION_NOT_CONSENTED'
        using errcode = '42501',
              hint = 'Ask the school''s Owner to grant consent from their Impersonation page.';
    elsif v_consent.revoked_at is not null then
      raise exception 'CONSENT_REVOKED' using errcode = '42501';
    else
      raise exception 'CONSENT_EXPIRED' using errcode = '42501';
    end if;
  end if;

  if v_consent.granted_by = v_uid then
    raise exception 'FORBIDDEN'
      using errcode = '42501', hint = 'The person who granted consent is never the person who uses it.';
  end if;

  if exists (select 1 from public.impersonation_session
              where ended_at is null and (support_user_id = v_uid or target_user_id = p_target_user_id)) then
    raise exception 'IMPERSONATION_ALREADY_ACTIVE'
      using errcode = '42501',
            hint = 'End the open session first. One engineer inside one account at a time.';
  end if;

  v_ends := v_now + make_interval(mins => p_minutes);

  insert into public.impersonation_session (
    tenant_id, consent_id, consent_granted_by, support_user_id, target_user_id,
    target_role, started_at, ends_at
  ) values (
    v_tenant, v_consent.id, v_consent.granted_by, v_uid, p_target_user_id,
    v_target.app_role, v_now, v_ends
  )
  returning id into v_id;

  insert into public.security_event (
    tenant_id, event_type, severity, subject_table, subject_id, actor_user_id, detail
  ) values (
    v_tenant, 'impersonation_started', 'alert', 'impersonation_session', v_id, v_uid,
    jsonb_build_object(
      'consent_id', v_consent.id,
      'granted_by', v_consent.granted_by,
      'target_user_id', p_target_user_id,
      'target_role', v_target.app_role,
      'ends_at', v_ends
    )
  );

  return jsonb_build_object(
    'session_id',     v_id,
    'target_user_id', p_target_user_id,
    'target_role',    v_target.app_role,
    'consent_id',     v_consent.id,
    'started_at',     v_now,
    'ends_at',        v_ends
  );
end;
$$;

revoke execute on function public.start_impersonation(uuid, integer) from public, anon;
grant execute on function public.start_impersonation(uuid, integer) to authenticated;

-- Deliberately does NOT call app.auth_tenant_id(): that would run
-- assert_impersonation_live(), so an engineer whose window had just closed
-- could not close their own session record. Identity is read straight off
-- app_user, which is also impersonation-proof — under impersonation the
-- app_role CLAIM is the target's, but auth.uid() is still the engineer.
create or replace function public.end_impersonation(p_session_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_session public.impersonation_session;
  v_reason  text;
begin
  if p_session_id is null then
    select * into v_session
      from public.impersonation_session
     where support_user_id = v_uid and ended_at is null
     order by started_at desc
     limit 1;
  else
    select * into v_session from public.impersonation_session where id = p_session_id;
  end if;

  if not found then
    raise exception 'IMPERSONATION_SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_session.support_user_id = v_uid then
    v_reason := 'ended_by_support';
  elsif exists (
    select 1 from public.app_user au
     where au.user_id = v_uid and au.tenant_id = v_session.tenant_id
       and au.app_role = 'owner' and au.status = 'active'
  ) then
    v_reason := 'ended_by_owner';
  else
    raise exception 'FORBIDDEN'
      using errcode = '42501',
            hint = 'Only the support engineer inside the session, or an Owner of the school, can end it.';
  end if;

  if v_session.ended_at is null then
    update public.impersonation_session
       set ended_at = clock_timestamp(), end_reason = v_reason
     where id = v_session.id;
  end if;

  return jsonb_build_object(
    'session_id', v_session.id,
    'end_reason', coalesce(v_session.end_reason, v_reason),
    'already_ended', v_session.ended_at is not null
  );
end;
$$;

revoke execute on function public.end_impersonation(uuid) from public, anon;
grant execute on function public.end_impersonation(uuid) to authenticated;

-- The FR's `cron: expire_impersonation_sessions every 5 minutes`. p_as_of
-- cannot widen anything: the sweep only ever moves a session from open to
-- closed, so a later timestamp closes more and an earlier one closes fewer.
create or replace function public.expire_impersonation_sessions(
  p_as_of timestamptz default clock_timestamp()
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
begin
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  with closed as (
    update public.impersonation_session s
       set ended_at = p_as_of,
           end_reason = case
             when s.ends_at <= p_as_of then 'expired'
             when c.revoked_at is not null then 'consent_revoked'
             else 'consent_expired'
           end
      from public.impersonation_consent c
     where c.id = s.consent_id
       and s.ended_at is null
       and (s.ends_at <= p_as_of or c.revoked_at is not null or c.expires_at <= p_as_of)
    returning s.id
  )
  select count(*) into v_count from closed;

  return v_count;
end;
$$;

revoke execute on function public.expire_impersonation_sessions(timestamptz) from public, anon;
grant execute on function public.expire_impersonation_sessions(timestamptz) to authenticated, service_role;

create or replace function public.impersonation_note_reads(p_rows integer default 1)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_imp   jsonb := app.auth_impersonation();
  v_total bigint;
begin
  if v_imp is null or p_rows is null or p_rows <= 0 then
    return 0;
  end if;

  update public.impersonation_session
     set read_count = read_count + p_rows
   where id = nullif(v_imp ->> 'sid', '')::uuid
     and support_user_id = (select auth.uid())
     and ended_at is null
  returning read_count into v_total;

  return coalesce(v_total, 0);
end;
$$;

revoke execute on function public.impersonation_note_reads(integer) from public, anon;
grant execute on function public.impersonation_note_reads(integer) to authenticated;

-- AC3's "and the attempt is audited", in the only shape Postgres allows
-- without an autonomous-transaction extension: a separate transaction, called
-- by the support console from its error path. See §5 of this file's header —
-- the BLOCK itself never depends on this being called.
create or replace function public.record_impersonation_block(
  p_table  text,
  p_action text default 'write'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_imp     jsonb := app.auth_impersonation();
  v_session public.impersonation_session;
  v_id      uuid;
begin
  if v_imp is null then
    raise exception 'FORBIDDEN'
      using errcode = '42501', hint = 'There is nothing to record outside an impersonation session.';
  end if;

  select * into v_session
    from public.impersonation_session
   where id = nullif(v_imp ->> 'sid', '')::uuid
     and support_user_id = (select auth.uid());
  if not found then
    raise exception 'IMPERSONATION_SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.impersonation_session
     set blocked_write_count = blocked_write_count + 1
   where id = v_session.id;

  insert into public.security_event (
    tenant_id, event_type, severity, subject_table, subject_id, actor_user_id, detail
  ) values (
    v_session.tenant_id, 'impersonation_write_blocked', 'alert',
    'impersonation_session', v_session.id, (select auth.uid()),
    jsonb_build_object(
      'blocked_table', p_table,
      'blocked_action', p_action,
      'target_user_id', v_session.target_user_id,
      'support_user_id', v_session.support_user_id
    )
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.record_impersonation_block(text, text) from public, anon;
grant execute on function public.record_impersonation_block(text, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 8. RLS
-- ═══════════════════════════════════════════════════════════════════════
--
-- No INSERT, UPDATE or DELETE policy on either table anywhere: the only
-- writers are the SECURITY DEFINER functions above, which run as the table
-- owner. The born-live and transition triggers are what constrain THEM, and
-- they constrain service_role identically.

alter table public.impersonation_consent enable row level security;
alter table public.impersonation_session enable row level security;

create policy impersonation_consent_read on public.impersonation_consent
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal')
  );

-- The extra `support_user_id = auth.uid()` disjunct is what lets the banner
-- read its own session: during impersonation app.auth_role() is the TARGET's
-- role, so the role list alone would hide from an engineer the very session
-- they are inside.
create policy impersonation_session_read on public.impersonation_session
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner', 'principal')
      or support_user_id = (select auth.uid())
    )
  );
