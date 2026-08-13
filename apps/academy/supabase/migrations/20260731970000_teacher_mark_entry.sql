-- FR-I12: teacher mark entry with validation.
--
-- "As a teacher, I want to enter a whole section's marks quickly on my phone
-- without losing work when the connection drops, so that mark submission is
-- not an evening of re-typing."
--
-- The row this migration defines is the one every later FR in the assessment
-- chain reads: FR-J02 computes results from it, FR-I16 approves and locks it,
-- FR-I13/I15 move it through submission and moderation. So the shape matters
-- more than the screen.
--
-- Grepped for mark_entry / exam_mark / mark_status before writing: nothing
-- exists. FR-I01 (exam_term) and FR-I02 (exam_subject, exam_subject_component,
-- fn_exam_entry_readiness) are the whole of module I today.
--
-- ── marks_obtained is numeric, and it is NOT NULL ──────────────────────
--
-- Two decisions, and the second is the load-bearing one.
--
-- numeric(6,2) rather than the scaled-integer discipline money (paisa) and
-- weightage (basis points) use in this schema. Those two exist because a
-- percentage or a rupee arriving as a JSON float rounds on cast, and because
-- "the weights total 100.00%" has to be an exact integer equality. Neither
-- applies here: a mark is compared against and summed with exam_subject_
-- component.max_marks, which is already an int, jsonb stores numbers as
-- numeric (so (payload->>'marks_obtained')::numeric never passes through a
-- float), and numeric addition in Postgres is exact. A scaled integer would
-- buy nothing but a conversion at every boundary. How many decimals are
-- actually ALLOWED is not the column's business either — it is a per-campus
-- setting, checked below.
--
-- NOT NULL is the decision FR-I11 and FR-J02 depend on. There is deliberately
-- no way to store "no mark" as a value:
--
--   * a candidate with nothing entered yet has NO ROW, not a null one;
--   * a candidate who was absent, exempt or debarred also has no row — that
--     is FR-I11's exam_attendance, a different table with a different
--     vocabulary, and trg_block_marks_when_not_present refuses a mark_entry
--     for them outright.
--
-- So marks_obtained is always a number a computation may safely treat as a
-- number. There is no sentinel — no -1 for absent, no 0 that might mean
-- "zero marks" or might mean "did not sit". A result engine that reads this
-- column cannot silently average an absence into a percentage, because an
-- absence is not in this column at all.
--
-- ── Validation lives in a trigger, not only in the writer ──────────────
--
-- trg_mark_range_check fires BEFORE INSERT OR UPDATE for every caller —
-- fn_upsert_marks, a service_role INSERT, a future bulk importer. The three
-- rules the requirement names (negative, above the component maximum, more
-- decimals than the campus allows) are all enforced there, so no path can
-- write a mark the grid would have refused.
--
-- The two messages the acceptance criteria assert are built verbatim:
--
--   AC1  "max 65"           — format('max %s', component max_marks)
--   AC2  "whole numbers only" — when the campus mark_precision is 0
--
-- Both raise 23514 (check_violation), which PostgREST maps to HTTP 400 with
-- the message intact. Not 55000: SQLSTATE class 55 is replaced by PostgREST
-- with {"message":"Something went wrong"}, verified against this stack in
-- FR-I01's migration, and a message the acceptance criteria require the
-- teacher to READ in a cell cannot travel on a code that strips it.
--
-- ── mark_precision is a campus_setting, and 0 is the default ───────────
--
-- public.campus_setting (campus_id, key, value jsonb) has existed since the
-- foundation migration with an RLS policy and no rows: it is the designed
-- home for exactly this and nothing had needed it yet. key = 'mark_precision',
-- value = 0 | 1 | 2. Absent means 0 — whole numbers only — which is what a
-- Pakistani school board actually awards, and which makes AC2 the default
-- behaviour rather than something a campus has to opt into.
--
-- ── AC4: the batch, and why it is an idempotency ledger ────────────────
--
-- "queued values flush in one batch and produce exactly one row per
-- (exam_subject, enrolment, component) with no duplicates."
--
-- Two mechanisms, because the unique index alone answers a weaker question
-- than the AC asks. uq_mark_entry makes a duplicate ROW impossible. What it
-- does not do is make a REPLAY safe: a queue that re-sends a batch because
-- the ack was lost would re-run the upsert, overwrite marks a teacher has
-- since corrected on another device, and report a second success.
--
-- mark_entry_batch is therefore the same idempotency ledger FR-G05's
-- attendance_sync_log is, in the same shape and for the same reason: the
-- first call for a client_batch_id stores its own return value verbatim, and
-- every later call for that id returns the stored jsonb without re-executing
-- anything. pg_advisory_xact_lock serialises genuinely concurrent retries;
-- uq_mark_entry_batch is the hard backstop past the lock.
--
-- The FR's suggested mark_entry_audit table is NOT created, for the reason
-- FR-I01 gave for skipping exam_term_audit: public.audit_log +
-- app.tg_audit_row() already records before/after/changed_columns/actor for
-- every table here, and a second, narrower trail is a place for the two to
-- disagree. mark_entry gets that trigger. What AC4 genuinely needs and
-- audit_log cannot provide — replaying the ORIGINAL response for a repeated
-- batch id — is what mark_entry_batch does.
--
-- ── Teacher scoping is server-side, and it is not "in my campus" ───────
--
-- app.fn_can_enter_marks(exam_subject, section) is the single predicate, and
-- the RLS policy, the writer and the sheet function all call it rather than
-- restating it. A teacher qualifies through EITHER
--
--   (a) section_subject_teacher — the FR-E09 allocation, validity @>
--       current_date. This is the same boundary create_homework() uses, and
--       for the same reason: being the class teacher of 9-B does not qualify
--       anyone to enter its Chemistry marks.
--   (b) a PUBLISHED timetable_slot for that section+subject naming them as
--       staff — the FR's own "teacher assigned to section via timetable".
--       A draft version does not count; nothing is assigned until it is
--       published.
--
-- Office roles (owner, principal, vice_principal, exam_controller,
-- super_admin) qualify within their campus scope, because an Exam Controller
-- keying in a paper the teacher never submitted is the ordinary case, not an
-- exception.
--
-- SECURITY DEFINER owned by postgres bypasses RLS entirely (FR-K24's
-- finding), so every visibility filter below — tenant, campus, deleted_at —
-- is written out in SQL rather than left to a policy that will not run.
--
-- ── What is honestly stubbed ──────────────────────────────────────────
--
-- mark_status carries all five values the FR names, but only 'draft' is ever
-- written here. Moving a mark to 'submitted' is FR-I13, 'moderated' is
-- FR-I15, and 'approved'/'locked' is FR-I16. What IS real today is the
-- consequence: trg_mark_entry_frozen refuses any change to a row in
-- 'approved' or 'locked', and to every row of a term FR-I01's
-- app.fn_exam_term_weight_frozen() reports frozen — so the moment FR-I16
-- calls lock_exam_term(), marks stop being editable without that FR
-- changing anything here.
--
-- The read-only preview panel FR-I02 put on the exam-subject setup screen is
-- REMOVED by this migration's UI change, not left beside the real grid: it
-- existed to render fn_exam_entry_readiness() until there was somewhere real
-- to render it, and now there is.

-- ═══════════════════════════════════════════════════════════════════════
-- Schema
-- ═══════════════════════════════════════════════════════════════════════

create type public.mark_status as enum ('draft', 'submitted', 'moderated', 'approved', 'locked');

create table public.mark_entry (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  exam_subject_id uuid not null references public.exam_subject(id) on delete cascade,
  enrolment_id    uuid not null references public.enrolment(id) on delete cascade,
  component_code  public.mark_component_code not null,
  -- Always a number. See the header: absence is not stored here.
  marks_obtained  numeric(6,2) not null,
  status          public.mark_status not null default 'draft',
  entered_by      uuid references public.app_user(user_id),
  entered_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- The queue submission this value arrived in, null for an online save.
  client_batch_id uuid,
  constraint chk_mark_obtained_nonneg check (marks_obtained >= 0)
);

-- The FR's index, spelled as the FR spells it. exam_subject_id already
-- determines tenant_id, so the leading column is redundant for uniqueness —
-- it is kept because every RLS policy and every grid read filters on
-- tenant_id, and a unique index that also serves those reads is cheaper than
-- a second one.
create unique index uq_mark_entry on public.mark_entry (tenant_id, exam_subject_id, enrolment_id, component_code);
create index idx_mark_entry_grid on public.mark_entry (exam_subject_id, enrolment_id);
create index idx_mark_entry_enrolment on public.mark_entry (enrolment_id);

create trigger mark_entry_audit after insert or update or delete on public.mark_entry
  for each row execute function app.tg_audit_row();

comment on table public.mark_entry is
  'FR-I12: one obtained mark, per candidate, per component, per exam subject. A candidate who did not sit the paper has NO ROW here — see FR-I11 exam_attendance.';
comment on column public.mark_entry.marks_obtained is
  'Always a real number. Absent/exempt/debarred are never encoded as a value in this column.';

-- AC4's ledger. Named for what it is rather than for the FR's suggested
-- mark_entry_audit — see the header.
create table public.mark_entry_batch (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  exam_subject_id uuid not null references public.exam_subject(id) on delete cascade,
  client_batch_id uuid not null,
  submitted_by    uuid references public.app_user(user_id),
  payload         jsonb not null,
  response        jsonb not null,
  received_at     timestamptz not null default now()
);

create unique index uq_mark_entry_batch on public.mark_entry_batch (client_batch_id);
create index idx_mark_entry_batch_subject on public.mark_entry_batch (exam_subject_id, received_at desc);

create trigger mark_entry_batch_audit after insert or update or delete on public.mark_entry_batch
  for each row execute function app.tg_audit_row();

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: mark_precision
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.fn_mark_precision(p_campus_id uuid)
returns smallint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select (s.value #>> '{}')::smallint
       from public.campus_setting s
      where s.campus_id = p_campus_id and s.key = 'mark_precision'),
    0::smallint
  );
$$;

comment on function app.fn_mark_precision(uuid) is
  'FR-I12 AC2: decimal places a mark may carry on this campus. Absent means 0 — whole numbers only.';

create or replace function public.set_mark_precision(
  p_campus_id uuid,
  p_precision smallint
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
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
  -- Two decimals is the floor of a half mark and then some; beyond that the
  -- number stops being a mark and starts being a rounding argument.
  if p_precision is null or p_precision < 0 or p_precision > 2 then
    raise exception 'MARK_PRECISION_OUT_OF_RANGE' using errcode = '23514',
      detail = 'Mark precision must be 0, 1 or 2 decimal places.';
  end if;

  insert into public.campus_setting (campus_id, key, value)
  values (p_campus_id, 'mark_precision', to_jsonb(p_precision))
  on conflict (campus_id, key) do update set value = excluded.value;
end;
$$;

revoke execute on function public.set_mark_precision(uuid, smallint) from public, anon;
grant execute on function public.set_mark_precision(uuid, smallint) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC1 / AC2: trg_mark_range_check
-- ═══════════════════════════════════════════════════════════════════════

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

  -- The candidate has to actually be sitting this paper: same session and
  -- campus, and enrolled in a section of the class the configuration is for.
  -- A soft-deleted enrolment (FR-A15) is not a candidate.
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

  if new.marks_obtained < 0 then
    raise exception 'marks cannot be negative' using errcode = '23514';
  end if;

  -- AC1's message, in the acceptance criteria's own words. Physics theory
  -- with a maximum of 65, typed 70: "max 65".
  if new.marks_obtained > v_max then
    raise exception 'max %', v_max
      using errcode = '23514',
            detail = format('%s of a maximum of %s for %s',
                            new.marks_obtained, v_max, new.component_code);
  end if;

  -- AC2. Compared by VALUE, not by stored scale: 45.00 is a whole number
  -- whatever trailing zeros it was typed with, and 45.5 is not.
  v_precision := app.fn_mark_precision(v_es.campus_id);
  if new.marks_obtained <> round(new.marks_obtained, v_precision) then
    if v_precision = 0 then
      raise exception 'whole numbers only' using errcode = '23514';
    end if;
    raise exception '%',
      format('at most %s decimal place%s', v_precision, case v_precision when 1 then '' else 's' end)
      using errcode = '23514';
  end if;

  new.tenant_id := v_es.tenant_id;
  new.campus_id := v_es.campus_id;
  new.updated_at := now();
  return new;
end;
$$;

create trigger trg_mark_range_check
  before insert or update on public.mark_entry
  for each row execute function app.tg_mark_range_check();

-- ═══════════════════════════════════════════════════════════════════════
-- The freeze: FR-I16's seam, biting today
-- ═══════════════════════════════════════════════════════════════════════

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
     where m.id = p_mark_entry_id
       and (m.status in ('approved', 'locked')
            or app.fn_exam_term_weight_frozen(es.exam_term_id))
  );
$$;

create or replace function app.tg_mark_entry_frozen()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if app.fn_mark_entry_frozen(old.id) then
    raise exception 'marks are locked by approval — raise a result-recompute request'
      using errcode = '42501',
            detail = format('mark_entry %s (%s)', old.id, old.component_code),
            hint = 'Changing a mark a result was already computed from is a result correction, not an edit.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger trg_mark_entry_frozen
  before update or delete on public.mark_entry
  for each row execute function app.tg_mark_entry_frozen();

-- ═══════════════════════════════════════════════════════════════════════
-- Teacher scoping
-- ═══════════════════════════════════════════════════════════════════════

-- The single predicate. See the header for the two ways a teacher qualifies.
create or replace function app.fn_can_enter_marks(
  p_exam_subject_id uuid,
  p_section_id      uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_es      record;
  v_section record;
  v_uid     uuid := (select auth.uid());
begin
  select es.tenant_id, es.campus_id, cs.subject_id
    into v_es
    from public.exam_subject es
    join public.class_subject cs on cs.id = es.class_subject_id
   where es.id = p_exam_subject_id;
  if v_es.tenant_id is null then
    return false;
  end if;

  select id, tenant_id, campus_id into v_section
    from public.class_section where id = p_section_id;
  if v_section.id is null or v_section.tenant_id <> v_es.tenant_id then
    return false;
  end if;

  -- No JWT at all (pgTAP, or a trigger inside another definer function) is
  -- this schema's established "not an interactive caller" escape.
  if app.auth_tenant_id() is null then
    return true;
  end if;
  if app.auth_tenant_id() <> v_es.tenant_id then
    return false;
  end if;

  if app.auth_role() in ('super_admin', 'owner') then
    return true;
  end if;
  if not (v_section.campus_id = any(app.auth_campus_ids())) then
    return false;
  end if;
  if app.auth_role() in ('principal', 'vice_principal', 'exam_controller') then
    return true;
  end if;

  -- (a) the FR-E09 subject allocation, live today.
  if exists (
    select 1 from public.section_subject_teacher
     where section_id = p_section_id
       and subject_id = v_es.subject_id
       and staff_id = v_uid
       and validity @> current_date
  ) then
    return true;
  end if;

  -- (b) a PUBLISHED timetable slot naming them on this section+subject.
  return exists (
    select 1
      from public.timetable_slot sl
      join public.timetable_version v on v.id = sl.timetable_version_id
     where sl.section_id = p_section_id
       and sl.subject_id = v_es.subject_id
       and sl.staff_id = v_uid
       and v.status = 'PUBLISHED'
  );
end;
$$;

-- The same predicate reached the way an RLS policy on mark_entry can reach
-- it: from a row that carries the enrolment, not the section. Kept as its
-- own function because a policy on mark_entry that SELECTed from mark_entry
-- to find the section would recurse into itself.
create or replace function app.fn_can_read_mark(
  p_exam_subject_id uuid,
  p_enrolment_id    uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app.fn_can_enter_marks(
           p_exam_subject_id,
           (select e.section_id from public.enrolment e where e.id = p_enrolment_id)
         );
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- AC3 / AC4: fn_upsert_marks
-- ═══════════════════════════════════════════════════════════════════════

-- Saves a batch of cells in one round trip.
--
--   p_payload = {"exam_subject_id": uuid,
--                "marks": [{"enrolment_id": uuid,
--                           "component": "theory",
--                           "marks_obtained": 45}, ...]}
--
-- AC3's autosave sends one cell; AC4's flush sends forty. Both take exactly
-- this path, which is why the "batch" is the requirement rather than an
-- optimisation: a per-cell PATCH is a different code path that would have to
-- be validated, scoped and made idempotent all over again.
--
-- p_client_batch_id non-null means "this is a replayable queued submission".
-- Null is the ordinary online save and writes no ledger row.
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

  -- Every cell in one batch belongs to one section: the batch IS a grid, and
  -- a payload spanning sections would need a scope decision per row. Counted
  -- rather than `select distinct ... into`, which silently keeps the first
  -- row when there are two.
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

  -- The freeze, ahead of trg_mark_entry_frozen so the caller sees the
  -- sentence rather than a trigger-wrapped one on the first frozen cell.
  if app.fn_exam_term_weight_frozen(v_es.exam_term_id) then
    raise exception 'marks are locked by approval — raise a result-recompute request'
      using errcode = '42501';
  end if;

  -- AC4. Serialise genuinely concurrent retries of one batch, then replay the
  -- ORIGINAL response for any repeat — not merely "ignore the duplicate".
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
      -- Clearing a cell is deleting the row, never storing a null: see the
      -- header for why this column has no "no mark" value.
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

revoke execute on function public.fn_upsert_marks(jsonb, uuid) from public, anon;
grant execute on function public.fn_upsert_marks(jsonb, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The grid the teacher opens
-- ═══════════════════════════════════════════════════════════════════════

-- Everything one screen needs in one round trip — deliberately, because the
-- screen is opened on a 2G phone: FR-I02's readiness answer (is there a
-- denominator, and what columns), whether this caller may write, the campus
-- decimal rule, and the roster with whatever is already entered.
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
begin
  -- Does the tenant/campus guard, and raises SECTION_NOT_FOUND /
  -- EXAM_TERM_NOT_FOUND / FORBIDDEN on its own.
  v_readiness := public.fn_exam_entry_readiness(p_exam_term_id, p_section_id, p_subject_id);
  v_es_id := nullif(v_readiness ->> 'exam_subject_id', '')::uuid;

  select campus_id into v_campus_id from public.class_section where id = p_section_id;

  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'enrolment_id', s.enrolment_id,
               'roll_no',      s.roll_no,
               'student_name', s.student_name,
               'gr_number',    s.gr_number,
               'marks',        s.marks,
               'status',       s.mark_status
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
               where m.exam_subject_id = v_es_id and m.enrolment_id = e.id) as mark_status
        from public.enrolment e
        join public.student st on st.id = e.student_id
       where e.section_id = p_section_id
         and e.status = 'active'
         -- Explicit, because SECURITY DEFINER means FR-A15's RLS filter does
         -- not run here.
         and e.deleted_at is null
         and st.deleted_at is null
    ) s;

  return v_readiness
    || jsonb_build_object(
         'can_enter',      app.fn_can_enter_marks(v_es_id, p_section_id),
         'mark_precision', app.fn_mark_precision(v_campus_id),
         'students',       v_students
       );
end;
$$;

revoke execute on function public.fn_mark_entry_sheet(uuid, uuid, uuid) from public, anon;
grant execute on function public.fn_mark_entry_sheet(uuid, uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.mark_entry enable row level security;
alter table public.mark_entry_batch enable row level security;

-- The FR's marks_teacher_own_section. Writes get no policy at all: RLS with
-- no INSERT/UPDATE policy denies both by default, and fn_upsert_marks() is
-- the only writer.
--
-- The FR also suggests a marks_locked_readonly policy. It is deliberately a
-- TRIGGER here instead (trg_mark_entry_frozen): a policy binds only the
-- roles it names, so the table owner, service_role and any future definer
-- function would walk straight past it, and "this mark is approved" is
-- exactly the rule that must hold for every caller.
create policy marks_teacher_own_section on public.mark_entry
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or (
        campus_id = any(app.auth_campus_ids())
        and (
          app.auth_role() in ('principal', 'vice_principal', 'exam_controller')
          or app.fn_can_read_mark(exam_subject_id, enrolment_id)
        )
      )
    )
  );

create policy mark_entry_batch_campus_scope on public.mark_entry_batch
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
