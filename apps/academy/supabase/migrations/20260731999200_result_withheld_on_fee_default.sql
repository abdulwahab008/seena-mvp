-- FR-J08: result withheld on fee default.
--
-- "As an Accountant, I want results withheld automatically for fee defaulters
-- and released the moment they pay, so that collection works without the
-- accounts office chasing report cards manually."
--
-- ── Withholding is a DISCLOSURE decision, not a computation one ────────
--
-- The FR's Notes are the whole design brief: "Withholding must block
-- disclosure, not computation — the school still needs the gazette and rank
-- list internally." So nothing in this migration touches
-- app.fn_compute_subject_result(), app.fn_compute_annual_result() or
-- app.fn_compute_positions(). A defaulter's marks are computed, aggregated
-- and ranked exactly as before, and AC4 — "when the exam office opens the
-- tabulation sheet, then their computed marks and grades are fully visible
-- internally" — is therefore true by not doing anything, which is the only
-- way it stays true as those engines change.
--
-- This is the sharp difference from FR-I11's DEBARMENT, and the two must not
-- be conflated even though FR-J05 spells its exclusion_reason 'withheld':
--
--   debarment    the candidate sat no valid paper. FR-J02 nulls pct,
--                grade_label and gpa_point; FR-J05 refuses to rank them.
--                There is no number to disclose.
--   fee default  the candidate has a complete, correct, ranked result. The
--                school is declining to HAND IT OVER until the dues are
--                settled. Every number still exists and staff still see it.
--
-- Which is why a fee withhold does not reach fn_compute_positions(). A
-- defaulter keeps their rank — removing them would renumber the classmates
-- above and below them and make the internal merit list a fiction, and it
-- would silently re-rank the whole class the day one parent paid. AC1's
-- "excluded from published rank lists" is delivered where publication
-- actually happens: the parent-facing RLS below drops the row, and the
-- report card gate refuses to print it. There is no cohort-wide list any
-- outsider can read in this schema, so nothing else needs excluding.
--
-- ── What counts as a default ──────────────────────────────────────────
--
-- The requirement is explicit and this migration adds nothing to it:
--
--     outstanding_balance_as_of(enrolment, cut-off) > threshold
--
-- FR-K24's outstanding_balance_as_of() is the single consolidated balance
-- function (student_balance() is a thin call into it) and it is used here
-- unchanged, so a soft-deleted challan cannot withhold a result — the bug
-- FR-K24's hardening fixed would otherwise have come back wearing this FR's
-- clothes. Money is paisa as bigint throughout.
--
-- Three consequences fall out rather than being coded:
--
--   * a CONCESSION or waiver clears a withhold with no special case at all.
--     generate_challans() posts concessions as credit ledger rows, so they
--     are already inside the balance; award one large enough and the next
--     sync releases the withhold as 'paid'.
--   * an ADVANCE payment likewise, for the same reason.
--   * the threshold is per campus (campus_setting, where FR-I12's
--     mark_precision and FR-J05's rank_policy already live — a second
--     settings table holding one key is a second place to look). It defaults
--     to 0, meaning any outstanding balance is a default. That default is
--     deliberately the strict one AND it is inert: nothing withholds anybody
--     until fn_sync_fee_withholds() is called for a term, which is an
--     explicit act by an accountant or a scheduled job.
--
-- The cut-off is a DATE, stored on the row, and the balance is measured to
-- the end of it. A parent asking "why" gets "as at 30 June you owed X",
-- which is answerable off the row a year later even though the ledger has
-- moved on since.
--
-- ── AC2 and AC3 are the same table and must not fight ─────────────────
--
-- AC2 clears the withhold when the money arrives. AC3 keeps the report card
-- available when the Principal grants hardship WHILE THE DUES REMAIN
-- OUTSTANDING. Both are a released row, so a released row has to say which
-- it was: release_kind 'paid' or 'hardship'. Without that distinction the
-- next sync — ten minutes later, dues still outstanding — would re-open the
-- withhold the Principal just lifted, and AC3 would survive for exactly one
-- cron tick. fn_sync_fee_withholds() therefore skips any candidate carrying
-- a hardship release for that term.
--
-- A hardship release is the override, and it is audited twice over: the
-- actor and the reason are columns on the row (released_by, release_reason,
-- both required by a CHECK for 'hardship' and refused to an empty string),
-- and app.tg_audit_row() puts the before/after on the tamper-evident audit
-- chain like every other register in this schema. It is Principal-and-above
-- only — the Accountant raises the debt and the Principal forgives its
-- consequence, and letting the same desk do both would remove the reason the
-- override is worth recording.
--
-- ── One open withhold per candidate per term ──────────────────────────
--
-- uq_withhold_open is the FR's index, spelled as the FR spells it: partial on
-- released_at IS NULL, and NOT partitioned by reason. So a candidate under a
-- discipline hold cannot simultaneously carry a fee hold. That is the right
-- shape — the outcome is identical (the result is not disclosed) and a
-- second row would only produce two rows to release. When the discipline
-- hold is lifted the next sync opens the fee one if the money is still
-- owed, so nothing is lost.
--
-- ── The gate is FR-J03's, extended, not a second one ──────────────────
--
-- FR-J03 built fn_assert_annual_result_publishable() precisely as "the gate
-- FR-J08/FR-J09 call before printing anything", already raising 23514 for
-- provisional and for stale. This migration adds two more refusals to THAT
-- function rather than standing a parallel gate beside it — a second gate is
-- a second thing a future printing path can forget to call:
--
--   * an open withhold on any term of the session, quoting the reason, and
--     for a fee default the amount, the cut-off and the threshold;
--   * debarment, which FR-J03 recorded on annual_result.is_blocked and
--     nothing ever refused to print. A debarred candidate's card would have
--     printed with empty grades.
--
-- Both read distinctly, because the recovery differs completely: one is
-- settled at the accounts counter, the other is an exam-committee decision.
-- Withhold is checked FIRST — it is the disclosure question, and telling a
-- parent at the counter that the term is "still being marked" when the real
-- answer is "you owe 12,000" would send them to the wrong desk.
--
-- fn_assert_result_disclosable() is the per-TERM sibling, for FR-J09's
-- per-term report card, and it is not a parallel implementation: both call
-- the same app.fn_open_withhold() and format through the same
-- app.fn_withhold_message(). One predicate, two arities.
--
-- ── Board registration ────────────────────────────────────────────────
--
-- The Notes require that a withhold "never propagate to board registration:
-- withholding a Class 10 candidate's school report is normal, withholding
-- their board admit card is not." Nothing in this schema registers a
-- candidate with a board yet. The property is preserved by construction: a
-- withhold is consulted at exactly two named gates and by three parent-facing
-- RLS policies, all listed below, and is not a column on the enrolment or a
-- flag any general-purpose query would pick up. A future board-registration
-- FR has to opt IN to it, which it must not.
--
-- ── The 10-minute job ─────────────────────────────────────────────────
--
-- AC2's "within 10 minutes". There is no pg_cron in this stack — the finding
-- FR-B16, FR-D12, FR-K13, FR-I16, FR-J03 and FR-J05 have each recorded — so
-- fn_sync_fee_withholds() is the callable a real 10-minute schedule invokes,
-- and the screen offers it as a button so the accounts office is never stuck
-- waiting for a scheduler that is not there.
--
-- It requires an authenticated tenant and says so loudly rather than
-- returning zero. FR-K24's outstanding_balance_as_of() filters on
-- app.auth_tenant_id(), so a null-tenant "System" caller would read every
-- balance as 0, release every open withhold and report success. That failure
-- mode is worse than a refusal.

-- ═══════════════════════════════════════════════════════════════════════
-- Schema
-- ═══════════════════════════════════════════════════════════════════════

-- The FR's enum, in the FR's order. Only 'fee_default' is opened by the sync;
-- the other two are the manual holds raise_result_withhold() exists for.
create type public.result_withhold_reason as enum ('fee_default', 'discipline', 'document_pending');

-- Why a row stopped being open, which is what keeps AC2 and AC3 from
-- overwriting each other on the next tick.
create type public.result_withhold_release as enum ('paid', 'hardship');

create table public.result_withhold (
  id                       uuid primary key default gen_random_uuid(),
  tenant_id                uuid not null references public.tenant(id) on delete cascade,
  campus_id                uuid not null references public.campus(id) on delete cascade,
  exam_term_id             uuid not null references public.exam_term(id) on delete cascade,
  enrolment_id             uuid not null references public.enrolment(id) on delete cascade,
  reason                   public.result_withhold_reason not null,
  -- Both stored, not just the balance: "you owed 12,000" is only an
  -- explanation next to "the threshold was 5,000".
  amount_outstanding_paisa bigint,
  threshold_paisa          bigint,
  cutoff_date              date not null,
  -- The words on a manual hold. A fee default needs none — the three numbers
  -- above say everything there is to say.
  note                     text,
  raised_by                uuid references public.app_user(user_id),
  raised_at                timestamptz not null default clock_timestamp(),
  released_by              uuid references public.app_user(user_id),
  released_at              timestamptz,
  release_kind             public.result_withhold_release,
  release_reason           text,
  constraint chk_withhold_fee_amounts
    check (reason <> 'fee_default'
           or (amount_outstanding_paisa is not null and threshold_paisa is not null)),
  -- AC3's audit trail, enforced rather than hoped for: a hardship release
  -- without an actor or with a blank reason is not an override, it is an
  -- unexplained disappearance.
  constraint chk_withhold_release
    check (
      (released_at is null and released_by is null and release_kind is null and release_reason is null)
      or (
        released_at is not null and release_kind is not null
        and (release_kind <> 'hardship'
             or (released_by is not null and coalesce(btrim(release_reason), '') <> ''))
      )
    )
);

-- The FR's index, spelled as the FR spells it. See the header: one open
-- withhold per candidate per term, whatever the reason.
create unique index uq_withhold_open
  on public.result_withhold (enrolment_id, exam_term_id)
  where released_at is null;

create index idx_withhold_term on public.result_withhold (exam_term_id, enrolment_id);
create index idx_withhold_enrolment on public.result_withhold (enrolment_id);
create index idx_withhold_scope on public.result_withhold (tenant_id, campus_id, raised_at desc);

create trigger result_withhold_audit after insert or update or delete on public.result_withhold
  for each row execute function app.tg_audit_row();

-- 20260731999100's idiom. result_withhold is NOT derived: the sync can
-- reconstruct today's open fee holds from the ledger, but it can reconstruct
-- neither the hardship releases (an actor's decision and their words) nor the
-- history of what was withheld as at which cut-off — which is the record a
-- school produces when a parent disputes why a card was not handed over.
select app.guard_table_truncate('result_withhold');

comment on table public.result_withhold is
  'FR-J08: disclosure of a candidate''s result for one term is withheld. Blocks the report card and the parent portal; never blocks computation, ranking or the internal tabulation sheet.';
comment on column public.result_withhold.release_kind is
  'FR-J08 AC2 vs AC3: ''paid'' is the sync clearing itself, ''hardship'' is the Principal''s override. The sync refuses to re-open a hardship-released term, which is the only thing that stops AC3 lasting one cron tick.';
comment on column public.result_withhold.cutoff_date is
  'FR-J08: the date the balance was measured to. Stored so "as at 30 June you owed X" is answerable off the row a year later.';

-- ═══════════════════════════════════════════════════════════════════════
-- The threshold
-- ═══════════════════════════════════════════════════════════════════════

-- FR-J05's rank_policy pattern exactly: a campus_setting key, read through a
-- function so the default lives in one place. 0 means any outstanding balance
-- is a default; see the header for why that is safe as a default.
create or replace function app.fn_withhold_threshold_paisa(p_campus_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select greatest((s.value #>> '{}')::bigint, 0)
       from public.campus_setting s
      where s.campus_id = p_campus_id and s.key = 'result_withhold_threshold_paisa'),
    0::bigint
  );
$$;

comment on function app.fn_withhold_threshold_paisa(uuid) is
  'FR-J08: the outstanding balance a candidate may carry without their result being withheld, in paisa. Defaults to 0 — any balance is a default.';

create or replace function public.set_result_withhold_threshold(
  p_campus_id uuid,
  p_paisa     bigint
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  -- The Accountant is in the list because collection policy is theirs; the
  -- same list fn_sync_fee_withholds() accepts, so a screen cannot offer the
  -- sync and refuse the number it syncs against.
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'accountant') then
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
  if p_paisa is null or p_paisa < 0 then
    raise exception 'WITHHOLD_THRESHOLD_INVALID' using errcode = '23514';
  end if;

  insert into public.campus_setting (campus_id, key, value)
  values (p_campus_id, 'result_withhold_threshold_paisa', to_jsonb(p_paisa))
  on conflict (campus_id, key) do update set value = excluded.value;
end;
$$;

revoke execute on function public.set_result_withhold_threshold(uuid, bigint) from public, anon;
grant execute on function public.set_result_withhold_threshold(uuid, bigint) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The predicate, once
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY DEFINER and deliberately outside RLS — FR-K24's finding used on
-- purpose rather than tripped over. Every caller below is either a gate that
-- must see a withhold the caller cannot read, or a parent-facing RLS policy
-- that is asking about its own child's row. It returns the row, not a
-- boolean, because the callers that refuse need the reason and the numbers.
create or replace function app.fn_open_withhold(
  p_enrolment_id uuid,
  p_exam_term_id uuid
)
returns public.result_withhold
language sql
stable
security definer
set search_path = ''
as $$
  select w.* from public.result_withhold w
   where w.enrolment_id = p_enrolment_id
     and w.exam_term_id = p_exam_term_id
     and w.released_at is null;
$$;

-- The boolean form, for RLS. Separate because a policy comparing a composite
-- against null is a subtlety no policy should carry.
create or replace function app.fn_result_withheld(
  p_enrolment_id uuid,
  p_exam_term_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.result_withhold w
     where w.enrolment_id = p_enrolment_id
       and w.exam_term_id = p_exam_term_id
       and w.released_at is null
  );
$$;

-- A year is withheld when any of its terms is, exactly as FR-J03 already
-- treats debarment ("debarred in any contributing term withholds the year").
-- Not restricted to counting terms: a non-counting term still has a report
-- card, and its disclosure is still the thing being withheld.
create or replace function app.fn_session_withheld(
  p_session_id   uuid,
  p_enrolment_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.result_withhold w
      join public.exam_term t on t.id = w.exam_term_id
     where w.enrolment_id = p_enrolment_id
       and t.session_id = p_session_id
       and w.released_at is null
  );
$$;

-- One sentence per reason, built in one place so the term gate, the annual
-- gate and the staff screen cannot drift into three wordings of one fact.
-- Money is formatted the way FR-C09's outstanding-balance message formats it.
create or replace function app.fn_withhold_message(
  p_withhold public.result_withhold,
  p_term_name text default null
)
-- STABLE, not IMMUTABLE: to_char() on a date reads lc_time.
returns text
language sql
stable
set search_path = ''
as $$
  select 'result withheld'
      || case when p_term_name is null then '' else ' for ' || p_term_name end
      || ' — '
      || case p_withhold.reason
           when 'fee_default' then
             'outstanding dues of PKR '
               || to_char(round(p_withhold.amount_outstanding_paisa / 100.0)::bigint, 'FM999,999,999')
               || ' as at ' || to_char(p_withhold.cutoff_date, 'DD Mon YYYY')
               || ' exceed the PKR '
               || to_char(round(p_withhold.threshold_paisa / 100.0)::bigint, 'FM999,999,999')
               || ' threshold'
           when 'discipline' then 'a discipline hold is open on this candidate'
           when 'document_pending' then 'a required document is still outstanding'
         end
      || coalesce(' (' || nullif(btrim(p_withhold.note), '') || ')', '');
$$;

comment on function app.fn_withhold_message(public.result_withhold, text) is
  'FR-J08: the one wording of a refusal, shared by the term gate, the annual gate and the staff screen.';

-- ═══════════════════════════════════════════════════════════════════════
-- AC1/AC2: the sync
-- ═══════════════════════════════════════════════════════════════════════

-- Opens what is owed and closes what is not, in one pass over one term. See
-- the header for the tenant requirement, the hardship skip, and why nothing
-- here touches a result.
create or replace function public.fn_sync_fee_withholds(
  p_exam_term_id uuid,
  p_as_of        date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_term      record;
  v_threshold bigint;
  v_cutoff    date;
  v_as_of_ts  timestamptz;
  v_row       record;
  v_balance   bigint;
  v_opened    integer := 0;
  v_updated   integer := 0;
  v_released  integer := 0;
begin
  -- Not a soft failure: outstanding_balance_as_of() reads 0 for every
  -- enrolment without a tenant claim, which would release every open
  -- withhold in the term and report success.
  if v_tenant_id is null then
    raise exception '%',
      'fee withholds can only be synced by a signed-in user — the balance function is tenant-scoped'
      using errcode = '42501',
            hint = 'Run this from the results screen or from a job that authenticates as a tenant user.';
  end if;
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select t.id, t.tenant_id, t.campus_id, t.session_id, t.name into v_term
    from public.exam_term t where t.id = p_exam_term_id;
  if v_term.id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_term.tenant_id <> v_tenant_id then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner')
     and not (v_term.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  v_threshold := app.fn_withhold_threshold_paisa(v_term.campus_id);
  v_cutoff := coalesce(p_as_of, current_date);
  -- Everything posted on or before the cut-off DAY, so a payment made that
  -- morning counts against that day's cut-off.
  v_as_of_ts := (v_cutoff + 1)::timestamptz;

  for v_row in
    select e.id as enrolment_id
      from public.enrolment e
     where e.tenant_id = v_tenant_id
       and e.campus_id = v_term.campus_id
       and e.session_id = v_term.session_id
       and e.status = 'active'
       and e.deleted_at is null
  loop
    v_balance := greatest(coalesce(public.outstanding_balance_as_of(v_row.enrolment_id, v_as_of_ts), 0), 0);

    if v_balance > v_threshold then
      -- AC3: a hardship release is the Principal's decision and the sync does
      -- not get to overrule it while the dues stand.
      if exists (
        select 1 from public.result_withhold w
         where w.enrolment_id = v_row.enrolment_id
           and w.exam_term_id = p_exam_term_id
           and w.release_kind = 'hardship'
      ) then
        continue;
      end if;

      update public.result_withhold w
         set amount_outstanding_paisa = v_balance,
             threshold_paisa          = v_threshold,
             cutoff_date              = v_cutoff
       where w.enrolment_id = v_row.enrolment_id
         and w.exam_term_id = p_exam_term_id
         and w.released_at is null
         and w.reason = 'fee_default';
      if found then
        v_updated := v_updated + 1;
        continue;
      end if;

      -- A discipline or document hold already covers this candidate; see the
      -- header on uq_withhold_open. Nothing to add.
      if exists (
        select 1 from public.result_withhold w
         where w.enrolment_id = v_row.enrolment_id
           and w.exam_term_id = p_exam_term_id
           and w.released_at is null
      ) then
        continue;
      end if;

      insert into public.result_withhold (
        tenant_id, campus_id, exam_term_id, enrolment_id, reason,
        amount_outstanding_paisa, threshold_paisa, cutoff_date, raised_by
      )
      values (
        v_tenant_id, v_term.campus_id, p_exam_term_id, v_row.enrolment_id, 'fee_default',
        v_balance, v_threshold, v_cutoff, (select auth.uid())
      );
      v_opened := v_opened + 1;
    else
      -- AC2. Only the sync's own holds clear themselves; a discipline hold is
      -- not settled by paying a fee bill.
      update public.result_withhold w
         set released_at              = clock_timestamp(),
             release_kind             = 'paid',
             amount_outstanding_paisa = v_balance,
             cutoff_date              = v_cutoff
       where w.enrolment_id = v_row.enrolment_id
         and w.exam_term_id = p_exam_term_id
         and w.released_at is null
         and w.reason = 'fee_default';
      if found then
        v_released := v_released + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'exam_term_id',    p_exam_term_id,
    'exam_term_name',  v_term.name,
    'cutoff_date',     v_cutoff,
    'threshold_paisa', v_threshold,
    'opened',          v_opened,
    'refreshed',       v_updated,
    'released',        v_released
  );
end;
$$;

revoke execute on function public.fn_sync_fee_withholds(uuid, date) from public, anon;
grant execute on function public.fn_sync_fee_withholds(uuid, date) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The manual holds, and AC3's release
-- ═══════════════════════════════════════════════════════════════════════

-- 'discipline' and 'document_pending' exist in the FR's enum and have no sync
-- to open them, so this is what makes those two values reachable. Same gate,
-- same parent-facing consequence; only the sentence differs.
create or replace function public.raise_result_withhold(
  p_enrolment_id uuid,
  p_exam_term_id uuid,
  p_reason       public.result_withhold_reason,
  p_note         text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_term      record;
  v_enrol     record;
  v_id        uuid;
begin
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  -- The sync owns 'fee_default'. Letting it be typed in by hand would create
  -- a hold the next sync releases, which reads as the system losing it.
  if p_reason = 'fee_default' then
    raise exception '%',
      'a fee-default withhold is opened by the sync, not by hand'
      using errcode = '23514',
            hint = 'Adjust the withhold threshold, or record the payment, and run the sync.';
  end if;

  select t.id, t.tenant_id, t.campus_id, t.session_id into v_term
    from public.exam_term t where t.id = p_exam_term_id;
  if v_term.id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  select e.id, e.tenant_id, e.campus_id, e.session_id into v_enrol
    from public.enrolment e where e.id = p_enrolment_id and e.deleted_at is null;
  if v_enrol.id is null then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_term.tenant_id <> v_tenant_id or v_enrol.tenant_id <> v_tenant_id
     or v_enrol.session_id <> v_term.session_id or v_enrol.campus_id <> v_term.campus_id then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner')
     and not (v_term.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'WITHHOLD_NOTE_REQUIRED' using errcode = '23514';
  end if;

  insert into public.result_withhold (
    tenant_id, campus_id, exam_term_id, enrolment_id, reason, cutoff_date, note, raised_by
  )
  values (
    v_tenant_id, v_term.campus_id, p_exam_term_id, p_enrolment_id, p_reason,
    current_date, btrim(p_note), (select auth.uid())
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.raise_result_withhold(uuid, uuid, public.result_withhold_reason, text) from public, anon;
grant execute on function public.raise_result_withhold(uuid, uuid, public.result_withhold_reason, text) to authenticated;

-- AC3. The override, and the whole of its audit trail: actor and reason onto
-- the row, plus the audit chain the row's trigger writes. Principal and
-- above; see the header on why the Accountant is not in this list.
create or replace function public.release_result_withhold(
  p_withhold_id uuid,
  p_reason      text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_row       public.result_withhold%rowtype;
begin
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_row from public.result_withhold where id = p_withhold_id;
  if v_row.id is null then
    raise exception 'WITHHOLD_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_row.tenant_id <> v_tenant_id then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner')
     and not (v_row.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_row.released_at is not null then
    raise exception 'WITHHOLD_ALREADY_RELEASED' using errcode = '23514';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception '%',
      'a hardship release needs a reason'
      using errcode = '23514',
            hint = 'The reason is what a later audit reads to understand why the dues were set aside.';
  end if;

  update public.result_withhold
     set released_at    = clock_timestamp(),
         released_by    = (select auth.uid()),
         release_kind   = 'hardship',
         release_reason = btrim(p_reason)
   where id = p_withhold_id;
end;
$$;

revoke execute on function public.release_result_withhold(uuid, text) from public, anon;
grant execute on function public.release_result_withhold(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The gates
-- ═══════════════════════════════════════════════════════════════════════

-- FR-J09's per-term gate. Withhold first, then debarment; both 23514 so
-- PostgREST hands the sentence to the browser intact rather than replacing
-- it with a generic 500 the way it does for SQLSTATE class 55.
create or replace function public.fn_assert_result_disclosable(
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
  v_enr      record;
  v_withhold public.result_withhold;
begin
  select e.id, e.tenant_id, e.campus_id into v_enr
    from public.enrolment e where e.id = p_enrolment_id;
  if v_enr.id is null then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_tenant_id() is not null then
    if v_enr.tenant_id <> app.auth_tenant_id() then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if app.auth_role() not in ('super_admin', 'owner', 'parent')
       and not (v_enr.campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  v_withhold := app.fn_open_withhold(p_enrolment_id, p_exam_term_id);
  if v_withhold.id is not null then
    raise exception '%', app.fn_withhold_message(v_withhold)
      using errcode = '23514',
            hint = 'Settle the dues, or record a hardship release, then print again.';
  end if;

  if exists (
    select 1 from public.subject_result sr
     where sr.enrolment_id = p_enrolment_id
       and sr.exam_term_id = p_exam_term_id
       and sr.is_blocked
  ) then
    raise exception '%',
      'result withheld — the candidate is debarred in this term'
      using errcode = '23514',
            hint = 'Debarment is an exam-committee decision; it is not settled at the accounts counter.';
  end if;
end;
$$;

revoke execute on function public.fn_assert_result_disclosable(uuid, uuid) from public, anon;
grant execute on function public.fn_assert_result_disclosable(uuid, uuid) to authenticated;

-- FR-J03's gate, extended. Everything from 'provisional' downwards is
-- FR-J03's, verbatim; the two refusals above it are this FR's. Same
-- signature, so this is a genuine replacement rather than a second overload —
-- the defaulted-argument ambiguity this codebase has been bitten by does not
-- arise, and every existing caller inherits the new refusals.
create or replace function public.fn_assert_annual_result_publishable(
  p_session_id   uuid,
  p_enrolment_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_enr         record;
  v_provisional integer;
  v_stale       integer;
  v_withhold    public.result_withhold;
  v_term_name   text;
begin
  select e.id, e.tenant_id, e.campus_id into v_enr
    from public.enrolment e where e.id = p_enrolment_id;
  if v_enr.id is null then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_tenant_id() is not null then
    if v_enr.tenant_id <> app.auth_tenant_id() then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if app.auth_role() not in ('super_admin', 'owner', 'parent')
       and not (v_enr.campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  -- FR-J08, checked first: a parent told the term is "still being marked"
  -- when the answer is "you owe 12,000" goes to the wrong desk.
  --
  -- A row variable has to be the sole INTO target — plpgsql gives it every
  -- column of the query — so the term's name is fetched separately rather
  -- than joined into this one.
  select w.* into v_withhold
    from public.result_withhold w
    join public.exam_term t on t.id = w.exam_term_id
   where w.enrolment_id = p_enrolment_id
     and t.session_id = p_session_id
     and w.released_at is null
   order by t.sequence
   limit 1;
  if v_withhold.id is not null then
    select t.name into v_term_name
      from public.exam_term t where t.id = v_withhold.exam_term_id;
    raise exception '%', app.fn_withhold_message(v_withhold, v_term_name)
      using errcode = '23514',
            hint = 'Settle the dues, or record a hardship release, then print again.';
  end if;

  -- FR-J08: FR-J03 recorded debarment on annual_result.is_blocked and nothing
  -- ever refused to print it, so a debarred candidate's card would have gone
  -- out with empty grades on it.
  if exists (
    select 1 from public.annual_result ar
     where ar.session_id = p_session_id
       and ar.enrolment_id = p_enrolment_id
       and ar.is_blocked
  ) then
    raise exception '%',
      'result withheld — the candidate is debarred in this session'
      using errcode = '23514',
            hint = 'Debarment is an exam-committee decision; it is not settled at the accounts counter.';
  end if;

  select count(*) filter (where ar.status = 'provisional')::int,
         count(*) filter (where app.fn_annual_result_stale(
                                  p_session_id, ar.enrolment_id, ar.subject_id, ar.computed_at))::int
    into v_provisional, v_stale
    from public.annual_result ar
   where ar.session_id = p_session_id
     and ar.enrolment_id = p_enrolment_id;

  if coalesce(v_provisional, 0) > 0 then
    raise exception '%',
      'annual result is provisional — a term is still being marked'
      using errcode = '23514',
            hint = 'Sign off every counting term for this section, then recompute.';
  end if;
  if coalesce(v_stale, 0) > 0 then
    raise exception '%',
      'annual result is stale — a mark changed after it was computed'
      using errcode = '23514',
            hint = 'Recompute the term results, then the annual result.';
  end if;
end;
$$;

revoke execute on function public.fn_assert_annual_result_publishable(uuid, uuid) from public, anon;
grant execute on function public.fn_assert_annual_result_publishable(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC4 and AC1: what staff see, and what a parent sees
-- ═══════════════════════════════════════════════════════════════════════

-- The accounts office's working list for one class and term: every candidate,
-- what they owe as at today, and the state of their withhold. AC4 lives here
-- too — this is a staff surface and it shows a withheld candidate's numbers.
create or replace function public.fn_withhold_sheet(
  p_exam_term_id uuid,
  p_class_id     uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_term      record;
  v_role      text := app.auth_role();
  v_threshold bigint;
  v_rows      jsonb;
begin
  select t.id, t.tenant_id, t.campus_id, t.session_id, t.name into v_term
    from public.exam_term t where t.id = p_exam_term_id;
  if v_term.id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_tenant_id() is not null then
    if v_term.tenant_id <> app.auth_tenant_id() then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if v_role not in ('super_admin', 'owner')
       and not (v_term.campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  v_threshold := app.fn_withhold_threshold_paisa(v_term.campus_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'enrolment_id',   c.enrolment_id,
           'student_name',   c.student_name,
           'gr_number',      c.gr_number,
           'roll_no',        c.roll_no,
           'section_name',   c.section_name,
           'balance_paisa',  c.balance_paisa,
           'is_withheld',    c.withhold_id is not null,
           'withhold_id',    c.withhold_id,
           'reason',         c.reason,
           'cutoff_date',    c.cutoff_date,
           'amount_outstanding_paisa', c.amount_outstanding_paisa,
           'threshold_paisa',          c.threshold_paisa,
           'message',        c.message,
           'is_debarred',    c.is_debarred,
           'last_release_kind',   c.last_release_kind,
           'last_release_reason', c.last_release_reason
         ) order by c.section_name, c.roll_no nulls last, c.student_name), '[]'::jsonb)
    into v_rows
    from (
      select e.id as enrolment_id,
             st.name_en as student_name,
             st.gr_number,
             e.roll_no,
             sec.name as section_name,
             greatest(coalesce(public.outstanding_balance_as_of(e.id, clock_timestamp()), 0), 0) as balance_paisa,
             w.id as withhold_id,
             w.reason,
             w.cutoff_date,
             w.amount_outstanding_paisa,
             w.threshold_paisa,
             case when w.id is not null then app.fn_withhold_message(w) end as message,
             exists (
               select 1 from public.subject_result sr
                where sr.enrolment_id = e.id and sr.exam_term_id = p_exam_term_id and sr.is_blocked
             ) as is_debarred,
             rel.release_kind as last_release_kind,
             rel.release_reason as last_release_reason
        from public.enrolment e
        join public.student st on st.id = e.student_id
        join public.class_section sec on sec.id = e.section_id
        left join lateral (
          select * from app.fn_open_withhold(e.id, p_exam_term_id)
        ) w on true
        left join lateral (
          select r.release_kind, r.release_reason
            from public.result_withhold r
           where r.enrolment_id = e.id and r.exam_term_id = p_exam_term_id
             and r.released_at is not null
           order by r.released_at desc
           limit 1
        ) rel on true
       where e.session_id = v_term.session_id
         and e.campus_id = v_term.campus_id
         and e.class_level_id = p_class_id
         and e.status = 'active'
         and e.deleted_at is null
    ) c;

  return jsonb_build_object(
    'exam_term_id',    p_exam_term_id,
    'exam_term_name',  v_term.name,
    'class_level_id',  p_class_id,
    'threshold_paisa', v_threshold,
    'can_sync',        v_role in ('super_admin', 'owner', 'principal', 'vice_principal', 'accountant'),
    'can_release',     v_role in ('super_admin', 'owner', 'principal', 'vice_principal'),
    'candidates',      v_rows
  );
end;
$$;

revoke execute on function public.fn_withhold_sheet(uuid, uuid) from public, anon;
grant execute on function public.fn_withhold_sheet(uuid, uuid) to authenticated;

-- AC1's parent-facing half. The sentence is the FR's, word for word, and it
-- deliberately quotes NO figure: the amount, the cut-off and the threshold
-- are an accounts-office conversation, and putting them on a portal page
-- would publish one child's family finances to whoever borrows the phone.
-- The term list comes back with the result rather than being queried
-- separately, because exam_term has no parent-facing RLS policy and should
-- not grow one: which exams a school is running is a staff fact, and a
-- guardian needs exactly the terms their own child sat. p_exam_term_id null
-- means "the latest", so the portal renders without a round trip to choose.
create or replace function public.fn_portal_term_result(
  p_enrolment_id uuid,
  p_exam_term_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_enr     record;
  v_term    record;
  v_terms   jsonb;
  v_rows    jsonb;
begin
  select e.id, e.tenant_id, e.campus_id, e.session_id, e.student_id into v_enr
    from public.enrolment e where e.id = p_enrolment_id and e.deleted_at is null;
  if v_enr.id is null then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  -- A guardian may ask about their own children and nobody else's.
  -- app.auth_guardian_student_ids() is FR-C11's, unchanged.
  if app.auth_tenant_id() is null or v_enr.tenant_id <> app.auth_tenant_id()
     or not (v_enr.student_id = any(app.auth_guardian_student_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('exam_term_id', t.id, 'name', t.name)
                            order by t.sequence), '[]'::jsonb)
    into v_terms
    from public.exam_term t
   where t.session_id = v_enr.session_id
     and t.campus_id = v_enr.campus_id
     and t.status <> 'draft';

  if p_exam_term_id is null then
    select t.id, t.name into v_term
      from public.exam_term t
     where t.session_id = v_enr.session_id
       and t.campus_id = v_enr.campus_id
       and t.status <> 'draft'
     order by t.sequence desc
     limit 1;
  else
    select t.id, t.name into v_term
      from public.exam_term t
     where t.id = p_exam_term_id
       and t.session_id = v_enr.session_id
       and t.campus_id = v_enr.campus_id;
  end if;
  if v_term.id is null then
    return jsonb_build_object('terms', v_terms, 'exam_term_id', null, 'exam_term_name', null,
                              'is_withheld', false, 'message', null, 'subjects', '[]'::jsonb);
  end if;

  if app.fn_result_withheld(p_enrolment_id, v_term.id) then
    return jsonb_build_object(
      'terms',          v_terms,
      'exam_term_id',   v_term.id,
      'exam_term_name', v_term.name,
      'is_withheld',    true,
      'message',        'Result withheld — please contact the accounts office',
      'subjects',       '[]'::jsonb
    );
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'subject_name', sub.name_en,
           'obtained',     sr.obtained,
           'max_marks',    sr.max_marks,
           'pct',          sr.pct,
           'grade_label',  sr.grade_label,
           'is_pass',      sr.is_pass,
           'is_blocked',   sr.is_blocked
         ) order by sub.name_en), '[]'::jsonb)
    into v_rows
    from public.subject_result sr
    join public.subject sub on sub.id = sr.subject_id
   where sr.enrolment_id = p_enrolment_id
     and sr.exam_term_id = v_term.id;

  return jsonb_build_object(
    'terms',          v_terms,
    'exam_term_id',   v_term.id,
    'exam_term_name', v_term.name,
    'is_withheld',    false,
    'message',        null,
    'subjects',       v_rows
  );
end;
$$;

revoke execute on function public.fn_portal_term_result(uuid, uuid) from public, anon;
grant execute on function public.fn_portal_term_result(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.result_withhold enable row level security;

-- Staff, campus-scoped. Parents are NOT given a policy here at all: AC1's
-- sentence is the whole of what a parent is told, and a row carrying the
-- amount outstanding is not it.
create policy withhold_campus_scope on public.result_withhold
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() <> 'parent'
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- No INSERT, UPDATE or DELETE policy: every write goes through the SECURITY
-- DEFINER functions above, which is what makes the release audit trail
-- unavoidable rather than conventional.
create policy withhold_no_direct_dml on public.result_withhold
  for update to authenticated
  using (false)
  with check (false);

-- The FR's report_card_hide_when_withheld, applied to the three parent-facing
-- result surfaces that exist today. Each is FR-J02/J03/J05's own policy with
-- one conjunct added; the staff policies beside them are untouched, which is
-- AC4. Drop-and-recreate because a policy's USING clause cannot be amended.
drop policy subject_result_parent_own_child on public.subject_result;
create policy subject_result_parent_own_child on public.subject_result
  for select to authenticated
  using (
    enrolment_id in (
      select id from public.enrolment where student_id = any(app.auth_guardian_student_ids())
    )
    and not app.fn_result_withheld(enrolment_id, exam_term_id)
  );

drop policy annual_result_parent_own_child on public.annual_result;
create policy annual_result_parent_own_child on public.annual_result
  for select to authenticated
  using (
    enrolment_id in (
      select id from public.enrolment where student_id = any(app.auth_guardian_student_ids())
    )
    and not app.fn_session_withheld(session_id, enrolment_id)
  );

-- AC1's "excluded from published rank lists". The row still exists and staff
-- still read it; the parent simply does not see a position for a result they
-- are not being given.
drop policy position_parent_own_child on public.result_position;
create policy position_parent_own_child on public.result_position
  for select to authenticated
  using (
    enrolment_id in (
      select id from public.enrolment where student_id = any(app.auth_guardian_student_ids())
    )
    and not app.fn_result_withheld(enrolment_id, exam_term_id)
  );
