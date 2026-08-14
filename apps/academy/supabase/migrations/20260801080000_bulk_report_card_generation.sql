-- FR-J12: bulk report card generation.
--
-- "As a Principal, I want to generate and print report cards for a whole class
-- in one action, so that results day does not consume three staff for two
-- days."
--
-- ── This FR is a DRIVER, not a second renderer ────────────────────────
--
-- FR-J09 already produces a report card: fn_assert_report_card_printable()
-- gates it, app.fn_build_report_card_payload() freezes it, begin_report_card()
-- reserves the revision and the path, and lib/report-cards/render.ts renders
-- and seals the bytes. Every one of those is reused here verbatim. Nothing in
-- this migration computes a mark, resolves a template, re-reads branding or
-- decides what a card says. What it adds is the three things a batch needs and
-- a single card does not:
--
--   * an enumeration of who is in scope, frozen in print order;
--   * a per-candidate outcome that survives the batch continuing past it;
--   * a merged print-ready PDF over the ones that succeeded.
--
-- begin_report_card() is refactored (not forked) into
-- app.fn_reserve_report_card(), which is the same body with the caller's
-- authorisation lifted out, so the batch and the single-card button reserve
-- revisions through one implementation. begin_report_card() keeps its
-- signature and its behaviour exactly.
--
-- ── AC2 is the whole design: partial success, never wholesale refusal ─
--
-- "Given 4 withheld results and 2 missing remarks, when the batch completes,
-- then 114 cards are produced and the result lists the 6 skipped candidates
-- with their reason codes."
--
-- 120 - 4 - 2 = 114. The batch does NOT abort on a candidate it cannot print,
-- and it does not silently omit one either: every enumerated candidate has a
-- report_card_batch_item row, and that row ends in exactly one of
--
--   succeeded  a card was issued (report_card_id is on the row);
--   skipped    the SCHOOL has something to fix — the result is withheld, the
--              term is still provisional, a mark has moved under it, or there
--              is no class teacher's remark to print. error_code says which;
--   failed     the SYSTEM has something to fix — no renderer, the upload was
--              refused, the digest would not seal.
--
-- skipped and failed are kept apart deliberately although they retry
-- identically: telling a Principal to go and collect a fee when the real
-- problem is that Chromium is missing from the server is how a results-day
-- afternoon gets wasted.
--
-- ── Why a missing remark is a skip, and why it is a batch-level rule ──
--
-- AC2 counts "2 missing remarks" among the six skipped, so a batch must
-- refuse a card whose remark box would print empty. FR-J09 does NOT refuse
-- that — a class teacher who presses Produce with the remark blank has made a
-- decision about one child in front of them, and there is nothing to second-
-- guess. Nobody makes that decision 120 times, so the rule belongs to the
-- batch and lives here rather than in the shared gate.
--
-- The remark itself has no table anywhere in this module: FR-J09 takes it as
-- an argument and freezes it into the snapshot. So a batch carries the same
-- thing — the screen's per-candidate remarks are passed to
-- start_report_card_batch() as a jsonb map and copied onto the item rows at
-- enumeration, which is also what makes them survive a resume. A candidate
-- with no supplied remark falls back to the remark on their last issued
-- revision (FR-J09's own rule, so a re-run after a marks correction does not
-- drop the teacher's words), and only then is skipped as 'remark_missing'.
--
-- require_remark is on the batch rather than assumed, because a first-ever
-- batch at a school that does not write remarks would otherwise skip every
-- child in it.
--
-- ── Resumability: a real function a driver calls repeatedly ───────────
--
-- There is no pg_cron and no worker process in this stack, and the FR's Notes
-- are right that 120 renders will not fit in one request. Rather than pretend
-- otherwise, the batch is built the way FR-A06's rollover and FR-T14's export
-- are: real functions, granted to service_role as well as authenticated, that
-- a driver calls repeatedly and that checkpoint after every item.
--
--   start_report_card_batch()          enumerates and returns immediately.
--                                      This is AC1's "a progress row appears
--                                      immediately" — it renders nothing.
--   claim_report_card_batch_item()     takes ONE pending item under
--                                      FOR UPDATE SKIP LOCKED, applies the
--                                      gate, and either records the skip or
--                                      reserves the revision.
--   finish_report_card_batch_item()    records the outcome of the bytes.
--   complete_report_card_batch()       seals the merged document.
--
-- Every one of those commits on its own, so a driver that dies mid-batch loses
-- at most one card, and calling the sequence again picks up exactly where it
-- stopped. An item left 'rendering' by a driver that never came back is
-- reclaimed after fifteen minutes, and its reserved-but-never-rendered
-- revision is VOIDED rather than reused — FR-T02's rule, which FR-J09 already
-- follows on its own failure path.
--
-- What is deliberately not claimed: no timing. AC1's "within 5 minutes" is a
-- property of the machine the driver runs on, not of this schema, and nothing
-- here asserts it.
--
-- ── AC4: re-run renders only what was skipped, merge is rebuilt in full ─
--
-- retry_report_card_batch() returns the skipped and failed items to 'pending'
-- and clears the merged document. The succeeded ones are untouched — they keep
-- their report_card_id and their page count — so the next pass renders only
-- the candidates that were fixed, exactly as AC4 requires, while the merged
-- PDF is rebuilt over ALL succeeded items from their frozen snapshots. That
-- rebuild costs nothing extra in correctness: FR-J09's payload_snapshot is the
-- card, so re-reading it produces the same page it produced the first time.
--
-- ── AC3: one merged PDF, and why "a new sheet" is not "a new page" ────
--
-- "cards are ordered by section then roll number and each card begins on a new
-- sheet so duplex printing does not mix students."
--
-- The order is frozen at enumeration into item.seq rather than recomputed at
-- merge time, so a section renamed halfway through results day cannot reorder
-- a document that is already half printed.
--
-- A SHEET is not a page. A one-page card followed by `break-after: page`
-- starts the next card on side 2 of the same sheet, which under duplex is
-- precisely the mixing the AC names. CSS has no portable `recto` break in
-- Chromium, so the padding is done with a fact the batch already owns: every
-- individual card was rendered on its own first, so its real page count is
-- known and stored on the item row, and the merged document inserts one blank
-- page after any card that ended on an odd page. That is measured, not
-- assumed.
--
-- The merged file does not replace the individual ones. The requirement asks
-- for both and a school uses both: the merged PDF is what a Principal sends to
-- the printer for a whole section, and the individual object behind FR-J09's
-- verifying download route is what a parent is handed when they come to the
-- office in August. One artifact could not do both — a parent cannot be given
-- 120 children's marks.
--
-- ── Errcodes and RLS ──────────────────────────────────────────────────
--
-- 23514 and 42501 throughout, never SQLSTATE class 55: PostgREST maps class 55
-- to HTTP 500 and replaces the body. Every function here is SECURITY DEFINER
-- and therefore bypasses RLS, so the campus guard, the tenant guard and the
-- soft-delete filters are written out explicitly in each one; the batch's
-- campus is taken from the exam term (exam_term.campus_id is NOT NULL), which
-- is what stops a 'class' scope — class_level is tenant-wide, not campus-wide
-- — from reaching into another campus's sections.

-- ═══════════════════════════════════════════════════════════════════════
-- Schema
-- ═══════════════════════════════════════════════════════════════════════

create type public.report_card_batch_scope as enum ('section', 'class', 'campus');
create type public.report_card_batch_status as enum ('queued', 'running', 'completed', 'failed');
create type public.report_card_batch_item_status as enum ('pending', 'rendering', 'succeeded', 'skipped', 'failed');

create table public.report_card_batch (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  exam_term_id   uuid not null references public.exam_term(id) on delete cascade,
  scope          public.report_card_batch_scope not null,
  target_id      uuid not null,
  -- See the header: AC2 counts a missing remark as a skip, and a school that
  -- does not write remarks would otherwise be unable to bulk print at all.
  require_remark boolean not null default true,
  status         public.report_card_batch_status not null default 'queued',
  total          integer not null default 0,
  succeeded      integer not null default 0,
  skipped        integer not null default 0,
  failed         integer not null default 0,
  -- The FR's path, reserved at enumeration so the bucket policy has a row to
  -- check against before any bytes are offered to it.
  file_path      text,
  checksum       text,
  page_count     integer,
  error          text,
  requested_by   uuid references public.app_user(user_id),
  requested_at   timestamptz not null default clock_timestamp(),
  started_at     timestamptz,
  completed_at   timestamptz,
  constraint chk_report_card_batch_checksum
    check (checksum is null or checksum ~ '^[0-9a-f]{64}$'),
  constraint chk_report_card_batch_counts
    check (total >= 0 and succeeded >= 0 and skipped >= 0 and failed >= 0)
);

create unique index uq_report_card_batch_file on public.report_card_batch (file_path);
create index idx_report_card_batch_scope on public.report_card_batch (tenant_id, campus_id, requested_at desc);
create index idx_report_card_batch_target on public.report_card_batch (exam_term_id, scope, target_id, requested_at desc);

create table public.report_card_batch_item (
  id             uuid primary key default gen_random_uuid(),
  batch_id       uuid not null references public.report_card_batch(id) on delete cascade,
  enrolment_id   uuid not null references public.enrolment(id) on delete cascade,
  section_id     uuid not null references public.class_section(id) on delete cascade,
  roll_no        integer,
  -- AC3's print order, frozen at enumeration. See the header.
  seq            integer not null,
  remark         text,
  status         public.report_card_batch_item_status not null default 'pending',
  report_card_id uuid references public.report_card(id),
  -- Read off the individual PDF's own bytes. The merged document pads to an
  -- even count from this, so "a new sheet" is measured rather than hoped for.
  page_count     integer,
  error_code     text,
  error_detail   text,
  attempts       integer not null default 0,
  claimed_at     timestamptz,
  resolved_at    timestamptz,
  constraint uq_report_card_batch_item unique (batch_id, enrolment_id),
  constraint chk_report_card_batch_item_seq check (seq >= 1)
);

-- The FR's index, spelled as the FR spells it: the driver's only hot query is
-- "the next pending item of this batch".
create index idx_batch_item on public.report_card_batch_item (batch_id, status);
create index idx_batch_item_card on public.report_card_batch_item (report_card_id);

-- Who bulk-printed a whole campus, when, and at what scope is an auditable
-- act, exactly as FR-F15's timetable_export_job is. The ITEMS are not audited:
-- 120 rows each transitioning twice would put 240 audit rows behind one
-- button press to record what the batch row already says in four counters,
-- and the per-candidate outcome is itself a permanent row here.
create trigger report_card_batch_audit after insert or update or delete on public.report_card_batch
  for each row execute function app.tg_audit_row();

select app.guard_table_truncate('report_card_batch');
select app.guard_table_truncate('report_card_batch_item');

comment on table public.report_card_batch is
  'FR-J12: one bulk report card run. The counters are derived from its items, never incremented blindly, so a resumed batch cannot drift.';
comment on table public.report_card_batch_item is
  'FR-J12: one enumerated candidate. Every candidate in scope has a row and ends in exactly one outcome — a batch never silently omits a child.';
comment on column public.report_card_batch_item.page_count is
  'FR-J12 AC3: the individual card''s real page count, read off its bytes, so the merged document can pad each card to a whole sheet for duplex printing.';

-- ═══════════════════════════════════════════════════════════════════════
-- FR-J09's gate, asked for a machine-readable reason
-- ═══════════════════════════════════════════════════════════════════════

-- The gate is unchanged in what it refuses and in the sentences it raises;
-- each refusal now also carries a code as its DETAIL, the way FR-J09 already
-- hands 'result_withheld' to its caller. AC2's "reason codes" are these, and
-- taking them from the raise itself is what stops a second list of reasons
-- existing somewhere that could disagree with the gate.
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
  begin
    perform public.fn_assert_result_disclosable(p_enrolment_id, p_exam_term_id);
  exception when check_violation then
    raise exception '%', sqlerrm using errcode = '23514', detail = 'result_withheld';
  end;

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
            detail = 'term_provisional',
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
            detail = 'result_not_computed',
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
            detail = 'result_stale',
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
            detail = 'position_stale',
            hint = 'Recompute the term results, then re-rank the class, then print again.';
  end if;
end;
$$;

revoke execute on function public.fn_assert_report_card_printable(uuid, uuid) from public, anon;
grant execute on function public.fn_assert_report_card_printable(uuid, uuid) to authenticated, service_role;

-- The gate as a question, now answering with the code as well as the
-- sentence. FR-J09's fn_report_card_block_reason() becomes a projection of
-- this rather than a second implementation, so the print list, the disabled
-- button and the batch's skip rows all quote one refusal.
create or replace function app.fn_report_card_block(
  p_enrolment_id uuid,
  p_exam_term_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_detail text;
begin
  perform public.fn_assert_report_card_printable(p_enrolment_id, p_exam_term_id);
  return null;
exception when check_violation then
  get stacked diagnostics v_detail = pg_exception_detail;
  return jsonb_build_object('code', coalesce(nullif(v_detail, ''), 'not_printable'), 'message', sqlerrm);
end;
$$;

create or replace function app.fn_report_card_block_reason(
  p_enrolment_id uuid,
  p_exam_term_id uuid
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select app.fn_report_card_block(p_enrolment_id, p_exam_term_id) ->> 'message';
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- FR-J09's reservation, with the caller's authorisation lifted out
-- ═══════════════════════════════════════════════════════════════════════

-- Byte-for-byte FR-J09's begin_report_card() body from the gate downwards.
-- The only change is that the tenant and the actor are arguments rather than
-- claims, because a batch driver may legitimately run as service_role where
-- there is no auth.uid() to read. Every authorisation decision stays with the
-- caller: public.begin_report_card() below, and claim_report_card_batch_item().
create or replace function app.fn_reserve_report_card(
  p_enrolment_id uuid,
  p_exam_term_id uuid,
  p_remark       text,
  p_tenant_id    uuid,
  p_actor        uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enr      record;
  v_prev     record;
  v_revision integer;
  v_remark   text;
  v_payload  jsonb;
  v_path     text;
  v_id       uuid;
  v_at       timestamptz;
begin
  select e.id, e.tenant_id, e.campus_id, e.section_id, e.session_id into v_enr
    from public.enrolment e where e.id = p_enrolment_id and e.deleted_at is null;
  if v_enr.id is null then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_enr.tenant_id <> p_tenant_id then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- AC3 of FR-J09, and it is the FIRST thing that happens: refusing before a
  -- revision is reserved is what makes "no file is written" true with nothing
  -- to clean up afterwards. The gate hands 'result_withheld' out as the
  -- machine-readable DETAIL while the sentence — which names the amount, the
  -- cut-off and the threshold — reaches the screen intact.
  perform public.fn_assert_report_card_printable(p_enrolment_id, p_exam_term_id);

  -- FR-J09 AC4. A correction is a new revision, never an edit: the old
  -- document is in a parent's hands and the register has to account for it.
  --
  -- The next number counts EVERY row including voided ones — FR-T02's rule
  -- that a number which has been handed out is never reissued — while the
  -- revision this one SUPERSEDES is the last one that actually became a
  -- document.
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
         'rendered_at',         v_at
       );

  v_path := p_tenant_id || '/' || v_enr.campus_id || '/' || p_exam_term_id || '/'
            || p_enrolment_id || '-r' || v_revision || '.pdf';

  insert into public.report_card (
    tenant_id, campus_id, exam_term_id, section_id, enrolment_id,
    revision_no, supersedes_revision, storage_path, status, payload_snapshot,
    rendered_at, rendered_by
  )
  values (
    p_tenant_id, v_enr.campus_id, p_exam_term_id, v_enr.section_id, p_enrolment_id,
    v_revision, v_prev.revision_no, v_path, 'pending', v_payload,
    v_at, p_actor
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

-- Unchanged in signature and in behaviour: the authorisation is still here,
-- and the reservation it used to inline is now the function above.
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
begin
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal',
                                'exam_controller', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select e.id, e.tenant_id, e.campus_id into v_enr
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

  return app.fn_reserve_report_card(
    p_enrolment_id, p_exam_term_id, p_remark, v_tenant_id, (select auth.uid())
  );
end;
$$;

revoke execute on function public.begin_report_card(uuid, uuid, text) from public, anon;
grant execute on function public.begin_report_card(uuid, uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The batch
-- ═══════════════════════════════════════════════════════════════════════

-- Derived, never incremented. A batch that is resumed, retried or driven by
-- two callers at once still reports what its items actually say.
create or replace function app.fn_refresh_report_card_batch_counters(p_batch_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.report_card_batch b
     set total     = c.total,
         succeeded = c.succeeded,
         skipped   = c.skipped,
         failed    = c.failed
    from (
      select count(*)::int                                          as total,
             count(*) filter (where i.status = 'succeeded')::int    as succeeded,
             count(*) filter (where i.status = 'skipped')::int       as skipped,
             count(*) filter (where i.status = 'failed')::int        as failed
        from public.report_card_batch_item i
       where i.batch_id = p_batch_id
    ) c
   where b.id = p_batch_id;
$$;

-- Who may drive a batch. Written once because start, claim, finish, complete,
-- fail and retry all need exactly the same answer, and a batch whose start is
-- guarded more tightly than its driver is not guarded at all.
--
-- service_role (app.auth_tenant_id() is null) is the un-authenticated worker
-- case and is trusted, the same way FR-J09's fn_report_card_sheet() trusts it:
-- there is no JWT to read, and the batch row itself carries the tenant and the
-- campus every statement below is scoped by.
create or replace function app.fn_assert_report_card_batch_access(
  p_tenant_id uuid,
  p_campus_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_role   text := app.auth_role();
begin
  if v_tenant is null then
    return;
  end if;
  if v_tenant <> p_tenant_id
     or v_role not in ('super_admin', 'owner', 'principal', 'vice_principal',
                       'exam_controller', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  -- The empty-claim case is a refusal, not a pass: `p_campus_id = any('{}')`
  -- is false, so a staff account with no campus assigned prints nothing.
  if v_role not in ('super_admin', 'owner')
     and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end;
$$;

-- AC1's first half: enumerate, and return. Nothing is rendered here, which is
-- what lets the progress row appear immediately for a campus of 900.
--
-- An unfinished batch for the same (term, scope, target) is RESUMED rather
-- than duplicated. Pressing the button twice — or reloading the page after the
-- browser was closed — must not start a second run that reserves a second
-- revision for every child.
create or replace function public.start_report_card_batch(
  p_exam_term_id   uuid,
  p_scope          public.report_card_batch_scope,
  p_target_id      uuid,
  p_remarks        jsonb default '{}'::jsonb,
  p_require_remark boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_term     record;
  v_batch_id uuid;
  v_existing uuid;
begin
  select t.id, t.tenant_id, t.campus_id, t.session_id into v_term
    from public.exam_term t where t.id = p_exam_term_id;
  if v_term.id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform app.fn_assert_report_card_batch_access(v_term.tenant_id, v_term.campus_id);

  -- The scope target has to be INSIDE the term's campus. class_level is
  -- tenant-wide rather than campus-wide, so a 'class' scope that trusted its
  -- target alone would sweep up another campus's sections; it is the
  -- enumeration below, not the target, that is campus-bound.
  if p_scope = 'section' then
    if not exists (
      select 1 from public.class_section cs
       where cs.id = p_target_id and cs.campus_id = v_term.campus_id and cs.session_id = v_term.session_id
    ) then
      raise exception '%', 'that section is not in this term''s campus and session'
        using errcode = '23514', detail = 'scope_out_of_campus';
    end if;
  elsif p_scope = 'class' then
    if not exists (
      select 1 from public.class_level cl where cl.id = p_target_id and cl.tenant_id = v_term.tenant_id
    ) then
      raise exception 'CLASS_NOT_FOUND' using errcode = 'P0002';
    end if;
  else
    if p_target_id <> v_term.campus_id then
      raise exception '%', 'that campus is not this term''s campus'
        using errcode = '23514', detail = 'scope_out_of_campus';
    end if;
  end if;

  select b.id into v_existing
    from public.report_card_batch b
   where b.exam_term_id = p_exam_term_id
     and b.scope = p_scope
     and b.target_id = p_target_id
     and b.status in ('queued', 'running')
   order by b.requested_at desc
   limit 1;
  if v_existing is not null then
    return public.fn_report_card_batch_status(v_existing) || jsonb_build_object('resumed', true);
  end if;

  insert into public.report_card_batch (
    tenant_id, campus_id, exam_term_id, scope, target_id, require_remark, requested_by
  )
  values (
    v_term.tenant_id, v_term.campus_id, p_exam_term_id, p_scope, p_target_id,
    coalesce(p_require_remark, true), (select auth.uid())
  )
  returning id into v_batch_id;

  -- The FR's path, reserved now so the bucket's own policy has a row to check
  -- before the merged bytes are ever offered to it.
  update public.report_card_batch
     set file_path = v_term.tenant_id || '/' || v_term.campus_id || '/' || p_exam_term_id
                     || '/batch-' || v_batch_id || '.pdf'
   where id = v_batch_id;

  -- AC3's order, frozen. Soft-deleted and non-active enrolments are excluded
  -- explicitly: this function is SECURITY DEFINER and RLS is not filtering it.
  insert into public.report_card_batch_item (batch_id, enrolment_id, section_id, roll_no, seq, remark)
  select v_batch_id,
         c.enrolment_id,
         c.section_id,
         c.roll_no,
         row_number() over (order by c.section_name, c.roll_no nulls last, c.student_name, c.enrolment_id),
         nullif(btrim(coalesce(p_remarks ->> c.enrolment_id::text, '')), '')
    from (
      select e.id as enrolment_id, e.section_id, e.roll_no,
             cs.name as section_name, st.name_en as student_name
        from public.enrolment e
        join public.class_section cs on cs.id = e.section_id
        join public.student st on st.id = e.student_id
       where e.session_id = v_term.session_id
         and e.campus_id = v_term.campus_id
         and e.status = 'active'
         and e.deleted_at is null
         and st.deleted_at is null
         and cs.campus_id = v_term.campus_id
         and (
           (p_scope = 'section' and e.section_id = p_target_id)
           or (p_scope = 'class' and e.class_level_id = p_target_id)
           or (p_scope = 'campus')
         )
    ) c;

  perform app.fn_refresh_report_card_batch_counters(v_batch_id);
  return public.fn_report_card_batch_status(v_batch_id) || jsonb_build_object('resumed', false);
end;
$$;

revoke execute on function public.start_report_card_batch(uuid, public.report_card_batch_scope, uuid, jsonb, boolean)
  from public, anon;
grant execute on function public.start_report_card_batch(uuid, public.report_card_batch_scope, uuid, jsonb, boolean)
  to authenticated, service_role;

-- One item, one commit. This is the per-item checkpoint the FR's Notes ask
-- for: it either records why a candidate was skipped or reserves their
-- revision, and either way the batch can stop here and resume later.
create or replace function public.claim_report_card_batch_item(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch  public.report_card_batch%rowtype;
  v_item   public.report_card_batch_item%rowtype;
  v_block  jsonb;
  v_remark text;
  v_res    jsonb;
begin
  select * into v_batch from public.report_card_batch where id = p_batch_id for update;
  if v_batch.id is null then
    raise exception 'REPORT_CARD_BATCH_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_report_card_batch_access(v_batch.tenant_id, v_batch.campus_id);

  -- A finished batch answers "nothing left" rather than raising: a driver that
  -- calls once more than it needed to — the last round of a polling screen,
  -- or a second driver arriving late — has not done anything wrong.
  if v_batch.status in ('completed', 'failed') then
    return jsonb_build_object('done', true, 'batch', public.fn_report_card_batch_status(p_batch_id));
  end if;

  -- A driver that died mid-item. Its reserved revision is VOIDED rather than
  -- reused (FR-T02, and FR-J09's own failure path), and the candidate goes
  -- back in the queue.
  update public.report_card rc
     set status = 'void', void_reason = 'BATCH_DRIVER_LOST'
    from public.report_card_batch_item i
   where i.batch_id = p_batch_id
     and i.status = 'rendering'
     and i.claimed_at < clock_timestamp() - interval '15 minutes'
     and rc.id = i.report_card_id
     and rc.status = 'pending';
  update public.report_card_batch_item i
     set status = 'pending', claimed_at = null, report_card_id = null
   where i.batch_id = p_batch_id
     and i.status = 'rendering'
     and i.claimed_at < clock_timestamp() - interval '15 minutes';

  if v_batch.status = 'queued' then
    update public.report_card_batch
       set status = 'running', started_at = coalesce(started_at, clock_timestamp())
     where id = p_batch_id;
  end if;

  select * into v_item
    from public.report_card_batch_item
   where batch_id = p_batch_id and status = 'pending'
   order by seq
   limit 1
   for update skip locked;

  if v_item.id is null then
    perform app.fn_refresh_report_card_batch_counters(p_batch_id);
    return jsonb_build_object(
      'done', not exists (
        select 1 from public.report_card_batch_item
         where batch_id = p_batch_id and status in ('pending', 'rendering')
      ),
      'batch', public.fn_report_card_batch_status(p_batch_id)
    );
  end if;

  -- FR-J09's own fallback first — a re-run after a marks correction keeps the
  -- teacher's words — and only then AC2's skip.
  select rc.payload_snapshot ->> 'remark' into v_remark
    from public.report_card rc
   where rc.enrolment_id = v_item.enrolment_id
     and rc.exam_term_id = v_batch.exam_term_id
     and rc.status in ('issued', 'superseded')
   order by rc.revision_no desc
   limit 1;
  v_remark := coalesce(v_item.remark, v_remark);

  -- The gate, unchanged, quoted rather than reimplemented — and asked BEFORE
  -- the remark. A withheld candidate whose remark is also missing is skipped
  -- for the withhold: that is the fact somebody has to act on, and typing a
  -- remark for them would not produce a card.
  v_block := app.fn_report_card_block(v_item.enrolment_id, v_batch.exam_term_id);
  if v_block is not null then
    update public.report_card_batch_item
       set status = 'skipped',
           error_code = v_block ->> 'code',
           error_detail = v_block ->> 'message',
           resolved_at = clock_timestamp()
     where id = v_item.id;
    perform app.fn_refresh_report_card_batch_counters(p_batch_id);
    return jsonb_build_object('item_id', v_item.id, 'status', 'skipped', 'error_code', v_block ->> 'code');
  end if;

  if v_batch.require_remark and nullif(btrim(coalesce(v_remark, '')), '') is null then
    update public.report_card_batch_item
       set status = 'skipped',
           error_code = 'remark_missing',
           error_detail = 'no class teacher''s remark has been written for this candidate',
           resolved_at = clock_timestamp()
     where id = v_item.id;
    perform app.fn_refresh_report_card_batch_counters(p_batch_id);
    return jsonb_build_object('item_id', v_item.id, 'status', 'skipped', 'error_code', 'remark_missing');
  end if;

  v_res := app.fn_reserve_report_card(
    v_item.enrolment_id, v_batch.exam_term_id, v_remark, v_batch.tenant_id, v_batch.requested_by
  );

  update public.report_card_batch_item
     set status = 'rendering',
         report_card_id = (v_res ->> 'report_card_id')::uuid,
         claimed_at = clock_timestamp(),
         attempts = attempts + 1,
         error_code = null,
         error_detail = null
   where id = v_item.id;

  return jsonb_build_object('item_id', v_item.id, 'status', 'rendering', 'reserved', v_res);
end;
$$;

revoke execute on function public.claim_report_card_batch_item(uuid) from public, anon;
grant execute on function public.claim_report_card_batch_item(uuid) to authenticated, service_role;

-- The other half of the checkpoint: what the bytes did. A failure here is
-- 'failed' rather than 'skipped' — see the header on why the two are kept
-- apart — and the reserved revision has already been voided by FR-J09's own
-- render path before this is called.
create or replace function public.finish_report_card_batch_item(
  p_item_id    uuid,
  p_ok         boolean,
  p_error_code text default null,
  p_page_count integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item  public.report_card_batch_item%rowtype;
  v_batch public.report_card_batch%rowtype;
begin
  select * into v_item from public.report_card_batch_item where id = p_item_id for update;
  if v_item.id is null then
    raise exception 'REPORT_CARD_BATCH_ITEM_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into v_batch from public.report_card_batch where id = v_item.batch_id;
  perform app.fn_assert_report_card_batch_access(v_batch.tenant_id, v_batch.campus_id);

  if v_item.status <> 'rendering' then
    raise exception 'REPORT_CARD_BATCH_ITEM_NOT_CLAIMED' using errcode = '23514';
  end if;

  if p_ok then
    -- A card is only 'succeeded' if the register agrees it became a document.
    if not exists (
      select 1 from public.report_card rc where rc.id = v_item.report_card_id and rc.status = 'issued'
    ) then
      raise exception 'REPORT_CARD_NOT_ISSUED' using errcode = '23514';
    end if;
    update public.report_card_batch_item
       set status = 'succeeded',
           page_count = greatest(coalesce(p_page_count, 1), 1),
           error_code = null,
           error_detail = null,
           resolved_at = clock_timestamp()
     where id = p_item_id;
  else
    update public.report_card_batch_item
       set status = 'failed',
           error_code = coalesce(nullif(btrim(coalesce(p_error_code, '')), ''), 'render_failed'),
           report_card_id = null,
           resolved_at = clock_timestamp()
     where id = p_item_id;
  end if;

  perform app.fn_refresh_report_card_batch_counters(v_item.batch_id);
  return public.fn_report_card_batch_status(v_item.batch_id);
end;
$$;

revoke execute on function public.finish_report_card_batch_item(uuid, boolean, text, integer) from public, anon;
grant execute on function public.finish_report_card_batch_item(uuid, boolean, text, integer) to authenticated, service_role;

-- What the merged document is made of: every succeeded card's FROZEN snapshot,
-- in AC3's order, with the page count that decides whether a blank sheet-filler
-- follows it. Rebuilding the merge therefore never re-renders and never
-- re-reads today's marks.
create or replace function public.fn_report_card_batch_manifest(p_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_batch public.report_card_batch%rowtype;
begin
  select * into v_batch from public.report_card_batch where id = p_batch_id;
  if v_batch.id is null then
    raise exception 'REPORT_CARD_BATCH_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_report_card_batch_access(v_batch.tenant_id, v_batch.campus_id);

  return jsonb_build_object(
    'batch_id',   v_batch.id,
    'file_path',  v_batch.file_path,
    'cards', coalesce((
      select jsonb_agg(jsonb_build_object(
               'enrolment_id', i.enrolment_id,
               'seq',          i.seq,
               'page_count',   coalesce(i.page_count, 1),
               'snapshot',     rc.payload_snapshot
             ) order by i.seq)
        from public.report_card_batch_item i
        join public.report_card rc on rc.id = i.report_card_id and rc.status = 'issued'
       where i.batch_id = p_batch_id and i.status = 'succeeded'
    ), '[]'::jsonb)
  );
end;
$$;

revoke execute on function public.fn_report_card_batch_manifest(uuid) from public, anon;
grant execute on function public.fn_report_card_batch_manifest(uuid) to authenticated, service_role;

-- The merged document, sealed. p_sha256 null means there was nothing to merge
-- — every candidate was skipped or failed — and the reserved path is released
-- rather than left pointing at a file that does not exist.
create or replace function public.complete_report_card_batch(
  p_batch_id   uuid,
  p_sha256     text default null,
  p_page_count integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch public.report_card_batch%rowtype;
begin
  select * into v_batch from public.report_card_batch where id = p_batch_id for update;
  if v_batch.id is null then
    raise exception 'REPORT_CARD_BATCH_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_report_card_batch_access(v_batch.tenant_id, v_batch.campus_id);

  if exists (
    select 1 from public.report_card_batch_item
     where batch_id = p_batch_id and status in ('pending', 'rendering')
  ) then
    raise exception 'REPORT_CARD_BATCH_UNFINISHED' using errcode = '23514';
  end if;
  if p_sha256 is not null and p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'REPORT_CARD_BATCH_DIGEST_INVALID' using errcode = '23514';
  end if;

  update public.report_card_batch
     set status = 'completed',
         checksum = p_sha256,
         page_count = case when p_sha256 is null then null else p_page_count end,
         error = null,
         completed_at = clock_timestamp()
   where id = p_batch_id;

  perform app.fn_refresh_report_card_batch_counters(p_batch_id);
  return public.fn_report_card_batch_status(p_batch_id);
end;
$$;

revoke execute on function public.complete_report_card_batch(uuid, text, integer) from public, anon;
grant execute on function public.complete_report_card_batch(uuid, text, integer) to authenticated, service_role;

-- The merge itself failing is a batch-level failure, not a candidate's: the
-- 114 individual cards are issued and downloadable, and only the print-ready
-- collation is missing. Retrying rebuilds it without touching them.
create or replace function public.fail_report_card_batch(p_batch_id uuid, p_error text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch public.report_card_batch%rowtype;
begin
  select * into v_batch from public.report_card_batch where id = p_batch_id for update;
  if v_batch.id is null then
    raise exception 'REPORT_CARD_BATCH_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_report_card_batch_access(v_batch.tenant_id, v_batch.campus_id);

  update public.report_card_batch
     set status = 'failed',
         error = coalesce(nullif(btrim(coalesce(p_error, '')), ''), 'UNKNOWN'),
         completed_at = clock_timestamp()
   where id = p_batch_id;

  perform app.fn_refresh_report_card_batch_counters(p_batch_id);
  return public.fn_report_card_batch_status(p_batch_id);
end;
$$;

revoke execute on function public.fail_report_card_batch(uuid, text) from public, anon;
grant execute on function public.fail_report_card_batch(uuid, text) to authenticated, service_role;

-- AC4. The six that were skipped go back in the queue; the 114 that succeeded
-- are untouched and are NOT re-rendered. The merged document is cleared so the
-- next pass rebuilds it in full over all of them.
create or replace function public.retry_report_card_batch(
  p_batch_id uuid,
  p_remarks  jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch public.report_card_batch%rowtype;
begin
  select * into v_batch from public.report_card_batch where id = p_batch_id for update;
  if v_batch.id is null then
    raise exception 'REPORT_CARD_BATCH_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_report_card_batch_access(v_batch.tenant_id, v_batch.campus_id);
  if v_batch.status not in ('completed', 'failed') then
    raise exception 'REPORT_CARD_BATCH_NOT_RUNNING' using errcode = '23514';
  end if;

  update public.report_card_batch_item i
     set status = 'pending',
         remark = coalesce(nullif(btrim(coalesce(p_remarks ->> i.enrolment_id::text, '')), ''), i.remark),
         error_code = null,
         error_detail = null,
         report_card_id = null,
         claimed_at = null,
         resolved_at = null
   where i.batch_id = p_batch_id
     and i.status in ('skipped', 'failed');

  update public.report_card_batch
     set status = 'queued',
         checksum = null,
         page_count = null,
         error = null,
         completed_at = null
   where id = p_batch_id;

  perform app.fn_refresh_report_card_batch_counters(p_batch_id);
  return public.fn_report_card_batch_status(p_batch_id);
end;
$$;

revoke execute on function public.retry_report_card_batch(uuid, jsonb) from public, anon;
grant execute on function public.retry_report_card_batch(uuid, jsonb) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- What a screen reads
-- ═══════════════════════════════════════════════════════════════════════

-- AC2's "the result lists the 6 skipped candidates with their reason codes".
-- Every enumerated candidate is here, named, in print order, with the code and
-- the gate's own sentence — which is the same sentence FR-J09's print list
-- shows and the same one the refusal would have raised.
create or replace function public.fn_report_card_batch_status(p_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_batch public.report_card_batch%rowtype;
  v_term  record;
begin
  select * into v_batch from public.report_card_batch where id = p_batch_id;
  if v_batch.id is null then
    raise exception 'REPORT_CARD_BATCH_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_report_card_batch_access(v_batch.tenant_id, v_batch.campus_id);

  select t.name into v_term from public.exam_term t where t.id = v_batch.exam_term_id;

  return jsonb_build_object(
    'batch_id',       v_batch.id,
    'exam_term_id',   v_batch.exam_term_id,
    'exam_term_name', v_term.name,
    'scope',          v_batch.scope,
    'target_id',      v_batch.target_id,
    'status',         v_batch.status,
    'require_remark', v_batch.require_remark,
    'total',          v_batch.total,
    'succeeded',      v_batch.succeeded,
    'skipped',        v_batch.skipped,
    'failed',         v_batch.failed,
    'pending', (
      select count(*)::int from public.report_card_batch_item
       where batch_id = p_batch_id and status in ('pending', 'rendering')
    ),
    'file_path',      case when v_batch.checksum is null then null else v_batch.file_path end,
    'checksum',       v_batch.checksum,
    'page_count',     v_batch.page_count,
    'error',          v_batch.error,
    'requested_at',   v_batch.requested_at,
    'completed_at',   v_batch.completed_at,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'item_id',        i.id,
               'enrolment_id',   i.enrolment_id,
               'student_name',   st.name_en,
               'gr_number',      st.gr_number,
               'section_name',   cs.name,
               'roll_no',        i.roll_no,
               'seq',            i.seq,
               'status',         i.status,
               'report_card_id', i.report_card_id,
               'revision_no',    rc.revision_no,
               'page_count',     i.page_count,
               'error_code',     i.error_code,
               'error_detail',   i.error_detail
             ) order by i.seq)
        from public.report_card_batch_item i
        join public.enrolment e on e.id = i.enrolment_id
        join public.student st on st.id = e.student_id
        join public.class_section cs on cs.id = i.section_id
        left join public.report_card rc on rc.id = i.report_card_id
       where i.batch_id = p_batch_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke execute on function public.fn_report_card_batch_status(uuid) from public, anon;
grant execute on function public.fn_report_card_batch_status(uuid) to authenticated, service_role;

-- A five-minute job outlives the tab it was started from. This is how the
-- screen finds the run again after a reload rather than starting a second one.
create or replace function public.fn_latest_report_card_batch(
  p_exam_term_id uuid,
  p_scope        public.report_card_batch_scope,
  p_target_id    uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select b.id into v_id
    from public.report_card_batch b
   where b.exam_term_id = p_exam_term_id
     and b.scope = p_scope
     and b.target_id = p_target_id
   order by b.requested_at desc
   limit 1;
  if v_id is null then
    return null;
  end if;
  return public.fn_report_card_batch_status(v_id);
end;
$$;

revoke execute on function public.fn_latest_report_card_batch(uuid, public.report_card_batch_scope, uuid)
  from public, anon;
grant execute on function public.fn_latest_report_card_batch(uuid, public.report_card_batch_scope, uuid)
  to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.report_card_batch enable row level security;
alter table public.report_card_batch_item enable row level security;

-- The FR's batch_campus_scope. A batch is a staff artifact — a parent has no
-- business seeing that 6 of their child's classmates were skipped, and 'parent'
-- is refused here rather than merely omitted.
create policy batch_campus_scope on public.report_card_batch
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() <> 'parent'
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy report_card_batch_item_scope on public.report_card_batch_item
  for select to authenticated
  using (exists (select 1 from public.report_card_batch b where b.id = batch_id));

-- Every write goes through the SECURITY DEFINER functions above; this states
-- the property rather than leaving it to be inferred from an absence.
revoke insert, update, delete on public.report_card_batch from authenticated, anon;
revoke insert, update, delete on public.report_card_batch_item from authenticated, anon;

-- ═══════════════════════════════════════════════════════════════════════
-- Storage: the merged document lives in FR-J09's bucket
-- ═══════════════════════════════════════════════════════════════════════

-- A merged section is 30-40 pages and a merged campus can be 900. FR-J09's
-- 10 MB ceiling was sized for one A4 card; the merged document is the same
-- pages plus one shared embedded font subset, and would hit it at roughly a
-- hundred children.
update storage.buckets set file_size_limit = 104857600 where id = 'report-cards';

create policy report_cards_insert_batch on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'report-cards'
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal',
                            'exam_controller', 'class_teacher')
    and exists (
      select 1 from public.report_card_batch b
       where b.file_path = objects.name and b.tenant_id = app.auth_tenant_id()
    )
  );

-- The one object in this bucket that is deliberately overwritable. AC4 says
-- the merged PDF is "rebuilt in full" on a re-run, and it is a collation of
-- documents that are each individually sealed and individually verifiable —
-- there is nothing here that the individual cards do not already attest to.
create policy report_cards_update_batch on storage.objects
  for update to authenticated
  using (
    bucket_id = 'report-cards'
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal',
                            'exam_controller', 'class_teacher')
    and exists (
      select 1 from public.report_card_batch b
       where b.file_path = objects.name and b.tenant_id = app.auth_tenant_id()
    )
  )
  with check (
    bucket_id = 'report-cards'
    and exists (
      select 1 from public.report_card_batch b
       where b.file_path = objects.name and b.tenant_id = app.auth_tenant_id()
    )
  );

-- Read follows the batch register's own visibility, and the subquery is
-- subject to report_card_batch's RLS as well, so the two cannot drift apart.
create policy report_cards_read_batch on storage.objects
  for select to authenticated
  using (
    bucket_id = 'report-cards'
    and exists (select 1 from public.report_card_batch b where b.file_path = objects.name)
  );
