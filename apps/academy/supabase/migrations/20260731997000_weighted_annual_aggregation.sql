-- FR-J03: weighted aggregation across terms.
--
-- "As a Principal, I want the annual result computed from weighted term
-- results, so that the final report card reflects the whole year rather than
-- one paper."
--
-- ── What this aggregates, and what it refuses to re-derive ─────────────
--
-- FR-J02 stored subject_result precisely so this migration would have a
-- stable artifact to sum. Three of its columns are load-bearing here and
-- none of them is recomputed:
--
--   pct                 the term percentage, numeric(5,2), already rounded
--                       once off the number the report card prints;
--   grading_scheme_id   the scale that result was graded on, FROZEN. This
--                       migration reads it off the term results rather than
--                       re-resolving a scheme for today's date — re-resolving
--                       is exactly the re-grading FR-J01 AC4 exists to stop;
--   is_blocked          FR-I11's withhold signal, answered per term.
--
-- An exempt subject already left the denominator at the term level, so its
-- term percentage is NULL, so that term simply does not contribute — which is
-- the same code path as a term the candidate was not there for. No special
-- case, at either level.
--
-- ── The arithmetic, and where exactly it rounds ───────────────────────
--
-- FR-I01 chose integer basis points for weightage (100% = 10000) so that the
-- one place a weighted sum is taken would not have to argue about floating
-- point. This is that place, and it uses weight_bp — never the generated
-- weight_pct — for the arithmetic:
--
--     weighted_pct = round( sum(weight_bp * term_pct) / sum(weight_bp), 2 )
--
-- Both sums are exact: weight_bp is an integer and term_pct is numeric(5,2),
-- so every product is exact decimal and so is their total. There is exactly
-- ONE round(), at the very end, on a numeric — never on an intermediate, and
-- never in binary floating point. The result is therefore reproducible: the
-- same marks recomputed in 2030 give the same digits, and a boundary value
-- lands the same way every time (Postgres numeric rounds half away from zero,
-- so a total of exactly 65.005 is 65.01 today, tomorrow and on a replica).
--
-- AC1 is that formula with nothing else in it:
--   (2500*60.00 + 1500*70.00 + 6000*80.00) / 10000 = 735000/10000 = 73.50.
--
-- ── Pro-rating is the SAME formula, not a second one ──────────────────
--
-- AC3's mid-session admission has no First Term result. The naive fix is to
-- score the missing term zero, which is the failing report card the Notes
-- warn about. The other naive fix is a bespoke redistribution routine.
--
-- Neither is needed: dividing by the weight actually present IS pro rata
-- redistribution. With First Term (2500) missing and Mid 70.00 / Final 80.00:
--
--     (1500*70.00 + 6000*80.00) / 7500 = 585000/7500 = 78.00
--
-- and redistributing First's 25% across 15:60 by hand — Mid 20%, Final 80% —
-- gives 0.20*70 + 0.80*80 = 78.00, the same number. So the denominator is
-- sum(weight_bp) over the terms that CONTRIBUTED, and the arithmetic is the
-- whole of AC3. What is left is AC3's other half, which the Notes are equally
-- clear about: pro-rating must be PRINTED. terms_counted and terms_total are
-- stored and proration_note is generated from them, so the sentence
-- "pro-rated, 2 of 3 terms" cannot drift away from the arithmetic that earned
-- it.
--
-- ── A missing term versus a term nobody has computed yet ──────────────
--
-- Those look identical in the data and are completely different facts, and
-- AC2 and AC3 want opposite handling. The discriminator is FR-I16's
-- per-section readiness, not the candidate:
--
--   * a counting term that is NOT result-ready for this candidate's section
--     is a term the school has not finished marking. The aggregate is still
--     computed — a Principal wants to see where a class stands — but it is
--     stored 'provisional' and fn_assert_annual_result_publishable() refuses
--     to let it be printed. That is AC2.
--   * a counting term that IS ready, where this candidate has no result, is a
--     candidate who was not there. Pro rata, annotated, 'final'. That is AC3.
--
-- The same test therefore covers "a term not yet computed" without inventing
-- a third state for it.
--
-- ── Staleness is FR-I17's, inherited rather than re-invented ──────────
--
-- An annual aggregate is stale when ANY contributing term result is stale.
-- FR-I17's mark_lock.result_stale_at is still the only stamp; FR-J02 already
-- derives v_subject_result.is_stale from it, and this migration derives from
-- exactly the same place through app.fn_result_stale_at().
--
-- One disjunct is added, and it is cache coherence rather than a second
-- staleness concept: an annual result is also out of date when a contributing
-- subject_result was RECOMPUTED after it (sr.computed_at > ar.computed_at).
-- Both halves matter and neither can replace the other:
--
--   * without the inherited half, recomputing the annual after a break-glass
--     edit would clear the flag while still sitting on term results nobody
--     had recomputed;
--   * without the coherence half, correcting a term result would leave a
--     silently wrong annual figure behind it.
--
-- Because the inherited half is re-derived on every read, recomputing an
-- annual result CANNOT clear staleness the term result still has. Only
-- recomputing the term result can. That is the correct dependency direction
-- and it falls out of the definition rather than out of ordering.
--
-- ── Stored, for FR-J02's reason and one more ─────────────────────────
--
-- A view would re-resolve the grading scheme on read and silently re-grade
-- every transcript the day a new scale took effect — FR-J02's argument,
-- unchanged. And an aggregate additionally depends on which terms existed and
-- were ready at computation time, which is not recoverable from today's rows.
-- So annual_result stores, and like subject_result it has NO write policy: a
-- correction is a recompute of the marks it came from.
--
-- ── The 5-minute job ──────────────────────────────────────────────────
--
-- AC4 asks for a recompute within 5 minutes of a break-glass correction.
-- There is no pg_cron in this stack (the same finding FR-B16, FR-D12, FR-K13
-- and FR-I16 all recorded), so fn_recompute_stale_annual_results() is a
-- callable function a real schedule would invoke, and the ordinary path does
-- not wait for it at all: app.fn_compute_subject_result() now chains straight
-- into the aggregate, so recomputing a corrected term updates the annual in
-- the same transaction. The dependent report cards are marked stale
-- immediately either way, because staleness is derived.

-- ═══════════════════════════════════════════════════════════════════════
-- Schema
-- ═══════════════════════════════════════════════════════════════════════

-- AC2's 'provisional'. The other value is what it is not.
create type public.annual_result_status as enum ('provisional', 'final');

create table public.annual_result (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  session_id        uuid not null references public.academic_session(id) on delete cascade,
  class_level_id    uuid not null references public.class_level(id),
  section_id        uuid not null references public.class_section(id) on delete cascade,
  enrolment_id      uuid not null references public.enrolment(id) on delete cascade,
  subject_id        uuid not null references public.subject(id) on delete cascade,
  -- round(sum(weight_bp * term_pct) / sum(weight_bp), 2). Null when nothing
  -- contributed a percentage — every counting term exempt, or withheld.
  weighted_pct      numeric(5,2),
  -- Read off the contributing term results, never re-resolved (FR-J01 AC4).
  grading_scheme_id uuid references public.grading_scheme(id),
  grade_label       text,
  gpa_point         numeric(3,2),
  is_pass           boolean,
  status            public.annual_result_status not null,
  -- AC3's annotation, and the two numbers it is built from.
  terms_counted     integer not null,
  terms_total       integer not null,
  prorated_terms    integer not null,
  proration_note    text generated always as (
                      case when prorated_terms > 0
                           then 'pro-rated, ' || terms_counted || ' of ' || terms_total || ' terms'
                      end
                    ) stored,
  -- FR-I11 through FR-J02: debarred in any contributing term withholds the
  -- year, exactly as it withholds the term. Not a fail.
  is_blocked        boolean not null default false,
  computed_at       timestamptz not null default clock_timestamp(),
  computed_by       uuid references public.app_user(user_id),
  constraint chk_annual_result_terms
    check (terms_counted >= 0 and terms_total >= terms_counted
           and prorated_terms = terms_total - terms_counted)
);

-- The FR's index, spelled as the FR spells it.
create unique index uq_annual_result
  on public.annual_result (tenant_id, session_id, enrolment_id, subject_id);
create index idx_annual_result_section on public.annual_result (session_id, section_id);
create index idx_annual_result_class on public.annual_result (session_id, class_level_id);
create index idx_annual_result_enrolment on public.annual_result (enrolment_id);

create trigger annual_result_audit after insert or update or delete on public.annual_result
  for each row execute function app.tg_audit_row();

comment on table public.annual_result is
  'FR-J03: one weighted annual result per (candidate, subject, session). Aggregated from FR-J02''s subject_result using FR-I01''s integer basis points, rounded exactly once.';
comment on column public.annual_result.proration_note is
  'FR-J03 AC3: "pro-rated, 2 of 3 terms". Generated from terms_counted/terms_total so the sentence cannot drift from the arithmetic.';
comment on column public.annual_result.status is
  'FR-J03 AC2: ''provisional'' while any counting term is unfinished for this section. fn_assert_annual_result_publishable() is what refuses to print one.';

-- ═══════════════════════════════════════════════════════════════════════
-- Staleness
-- ═══════════════════════════════════════════════════════════════════════

-- See the header: FR-I17's stamp inherited, plus a coherence check against
-- the term result's own computed_at. SECURITY DEFINER because it reads
-- mark_lock through app.fn_result_stale_at(), and — per FR-K24's finding that
-- a definer function owned by postgres bypasses RLS — the tenant scope is
-- written out in SQL rather than left to a policy that will not run.
create or replace function app.fn_annual_result_stale(
  p_session_id   uuid,
  p_enrolment_id uuid,
  p_subject_id   uuid,
  p_computed_at  timestamptz
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.subject_result sr
      join public.exam_term t on t.id = sr.exam_term_id
     where t.session_id = p_session_id
       and t.counts_toward_annual
       and sr.enrolment_id = p_enrolment_id
       and sr.subject_id = p_subject_id
       and (app.auth_tenant_id() is null or sr.tenant_id = app.auth_tenant_id())
       and (
         -- Inherited from FR-I17: this term result is itself stale.
         coalesce(app.fn_result_stale_at(sr.exam_subject_id, sr.section_id) > sr.computed_at, false)
         -- Coherence: this term result moved after the aggregate was taken.
         or sr.computed_at > p_computed_at
       )
  );
$$;

comment on function app.fn_annual_result_stale(uuid, uuid, uuid, timestamptz) is
  'FR-J03: an annual result is stale when any contributing term result is stale (FR-I17''s stamp) or was recomputed after it. Recomputing the aggregate cannot clear the first half — only recomputing the term can.';

-- ═══════════════════════════════════════════════════════════════════════
-- The computation
-- ═══════════════════════════════════════════════════════════════════════

-- The engine. No authorisation of its own, the split FR-J02 established: the
-- public entry point below gates the Exam Controller, and the automatic path
-- runs off an approval that has already passed one.
--
-- p_section_id narrows the run to one section; null means the whole class,
-- which is what the FR's own signature asks for.
create or replace function app.fn_compute_annual_result(
  p_session_id     uuid,
  p_class_level_id uuid,
  p_section_id     uuid,
  p_actor          uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
begin
  -- FR-I16's readiness is answered once per (section, term), not once per
  -- candidate: it is a property of the section's papers, and asking it forty
  -- times over for forty classmates would be forty scans for one answer.
  with section_readiness as (
    select s.section_id,
           count(*)::int as terms_total,
           bool_and((public.fn_term_result_ready(t.id, s.section_id) ->> 'ready')::boolean) as all_ready
      from (
        select distinct e.section_id, e.campus_id
          from public.enrolment e
          join public.class_section sec on sec.id = e.section_id
         where e.session_id = p_session_id
           and e.class_level_id = p_class_level_id
           and e.status = 'active'
           and e.deleted_at is null
           and sec.is_active
           and (p_section_id is null or e.section_id = p_section_id)
      ) s
      join public.exam_term t
        on t.session_id = p_session_id
       and t.campus_id = s.campus_id
       and t.counts_toward_annual
     group by s.section_id
  )
  insert into public.annual_result (
    tenant_id, campus_id, session_id, class_level_id, section_id,
    enrolment_id, subject_id, weighted_pct, grading_scheme_id, grade_label,
    gpa_point, is_pass, status, terms_counted, terms_total, prorated_terms,
    is_blocked, computed_at, computed_by
  )
  select a.tenant_id,
         a.campus_id,
         p_session_id,
         p_class_level_id,
         a.section_id,
         a.enrolment_id,
         a.subject_id,
         -- A withheld year carries no number, exactly as a withheld term does.
         case when a.is_blocked then null else a.weighted_pct end,
         a.grading_scheme_id,
         case when a.is_blocked then null else g.grade_label end,
         case when a.is_blocked then null else g.gpa_point end,
         case when a.is_blocked or a.weighted_pct is null then null
              else coalesce(g.is_pass, false) end,
         case when a.all_ready then 'final' else 'provisional' end::public.annual_result_status,
         a.terms_counted,
         a.terms_total,
         a.terms_total - a.terms_counted,
         a.is_blocked,
         clock_timestamp(),
         p_actor
    from (
      select c.tenant_id,
             c.campus_id,
             c.section_id,
             c.enrolment_id,
             sr.subject_id,
             c.terms_total,
             c.all_ready,
             count(*) filter (where sr.pct is not null)::int              as terms_counted,
             bool_or(sr.is_blocked)                                       as is_blocked,
             -- The ONE round(), on exact decimals, at the very end. The
             -- denominator is the weight that actually contributed, which is
             -- AC3's pro rata redistribution written as arithmetic.
             case when coalesce(sum(t.weight_bp) filter (where sr.pct is not null), 0) > 0
                  then round(
                         sum(t.weight_bp * sr.pct) filter (where sr.pct is not null)
                           / sum(t.weight_bp) filter (where sr.pct is not null),
                         2)
             end                                                          as weighted_pct,
             -- FR-J01 AC4: the scale the candidate was actually graded on,
             -- taken from the LAST contributing term rather than re-resolved.
             -- Every term of one session resolves the same scheme today
             -- (FR-J02 resolves it from the session's start date), so this
             -- only ever has one answer — but it has to be read off the
             -- result, not looked up again.
             (array_agg(sr.grading_scheme_id order by t.sequence desc)
                filter (where sr.grading_scheme_id is not null))[1]        as grading_scheme_id
        from (
          select e.id as enrolment_id,
                 e.tenant_id,
                 e.campus_id,
                 e.section_id,
                 r.terms_total,
                 r.all_ready
            from public.enrolment e
            join section_readiness r on r.section_id = e.section_id
           where e.session_id = p_session_id
             and e.class_level_id = p_class_level_id
             and e.status = 'active'
             and e.deleted_at is null
        ) c
        join public.subject_result sr on sr.enrolment_id = c.enrolment_id
        -- Non-counting terms (weekly tests, mock/pre-board) are excluded from
        -- the aggregate outright — FR-I01 AC4's rule, still true a level up.
        -- They stay on the report card; they never move this number.
        join public.exam_term t
          on t.id = sr.exam_term_id
         and t.session_id = p_session_id
         and t.counts_toward_annual
       group by c.tenant_id, c.campus_id, c.section_id, c.enrolment_id,
                sr.subject_id, c.terms_total, c.all_ready
    ) a
    left join lateral public.fn_grade_for_percentage(a.grading_scheme_id, a.weighted_pct) g on true
  on conflict (tenant_id, session_id, enrolment_id, subject_id) do update
    set campus_id         = excluded.campus_id,
        class_level_id    = excluded.class_level_id,
        section_id        = excluded.section_id,
        weighted_pct      = excluded.weighted_pct,
        grading_scheme_id = excluded.grading_scheme_id,
        grade_label       = excluded.grade_label,
        gpa_point         = excluded.gpa_point,
        is_pass           = excluded.is_pass,
        status            = excluded.status,
        terms_counted     = excluded.terms_counted,
        terms_total       = excluded.terms_total,
        prorated_terms    = excluded.prorated_terms,
        is_blocked        = excluded.is_blocked,
        computed_at       = excluded.computed_at,
        computed_by       = excluded.computed_by;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- The FR's fn_compute_annual_result(p_session_id, p_class_id): the Exam
-- Controller's explicit recompute. p_class_id is a class LEVEL — an annual
-- result spans every section of the class, because FR-I02's exam_subject is
-- per class and only the class has one answer for what a subject was worth.
create or replace function public.fn_compute_annual_result(
  p_session_id uuid,
  p_class_id   uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_session   record;
  v_open      text;
begin
  select id, tenant_id into v_session
    from public.academic_session where id = p_session_id;
  if v_session.id is null then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from public.class_level
     where id = p_class_id and tenant_id = v_session.tenant_id
  ) then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- The Actors are System, Exam Controller and Principal. A null tenant is
  -- the System path (a scheduled job, a migration, pgTAP), the same posture
  -- every other definer function in this module takes.
  if v_tenant_id is not null then
    if v_session.tenant_id <> v_tenant_id then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if v_role not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  -- FR-J02's rule, for FR-J02's reason: FR-I17 stamps staleness once per
  -- window, so anything computed inside an open one would be out of date
  -- before the window shut and could no longer be re-flagged.
  select sub.name_en into v_open
    from public.v_exam_subject_section vs
    join public.exam_term t on t.id = vs.exam_term_id
    join public.subject sub on sub.id = vs.subject_id
    join public.class_section sec on sec.id = vs.section_id
   where t.session_id = p_session_id
     and sec.class_level_id = p_class_id
     and app.fn_break_glass_open(vs.exam_subject_id, vs.section_id)
   limit 1;
  if v_open is not null then
    raise exception '%', format('marks are open under a break-glass window on %s — recompute when it closes', v_open)
      using errcode = '42501',
            hint = 'An annual result computed mid-window would be out of date before the window shut.';
  end if;

  return app.fn_compute_annual_result(p_session_id, p_class_id, null, (select auth.uid()));
end;
$$;

revoke execute on function public.fn_compute_annual_result(uuid, uuid) from public, anon;
grant execute on function public.fn_compute_annual_result(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: publication is blocked
-- ═══════════════════════════════════════════════════════════════════════

-- The gate FR-J08/FR-J09 call before printing anything. It is a function
-- rather than a published_at column because publication is FR-J08's to build
-- and a column nothing writes is the table-with-no-reader FR-I16 declined —
-- but the REFUSAL is this FR's, so it lives here and is enforceable today.
--
-- Two things stop a report card. A provisional aggregate is AC2's own case.
-- A stale one is FR-I17 AC3's, and printing it would put a number on paper
-- that the database already knows is wrong.
--
-- errcode 23514, not SQLSTATE class 55: PostgREST maps class 55 to HTTP 500
-- and replaces the body with {"message":"Something went wrong"}, which would
-- strip the sentence naming what is unfinished.
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
-- AC4: the recompute job
-- ═══════════════════════════════════════════════════════════════════════

-- Not wired to a schedule — there is no pg_cron in this stack, the same
-- finding every other "System" actor in this codebase records. A real
-- 5-minute cron calls this; the ordinary path does not wait for it, because
-- app.fn_compute_subject_result() chains into the aggregate directly.
--
-- It recomputes what has gone stale for any reason. Where the underlying term
-- result is itself stale, recomputing the aggregate deliberately does NOT
-- clear the flag: staleness is re-derived on read and the term result is what
-- has to be recomputed first. So this is safe to run every five minutes
-- forever without ever painting over an uncorrected mark.
create or replace function public.fn_recompute_stale_annual_results(
  p_session_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row   record;
  v_total integer := 0;
begin
  if app.auth_tenant_id() is not null
     and app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  for v_row in
    select distinct ar.session_id, ar.class_level_id
      from public.annual_result ar
     where (p_session_id is null or ar.session_id = p_session_id)
       and (app.auth_tenant_id() is null or ar.tenant_id = app.auth_tenant_id())
       and app.fn_annual_result_stale(ar.session_id, ar.enrolment_id, ar.subject_id, ar.computed_at)
  loop
    v_total := v_total
      + app.fn_compute_annual_result(v_row.session_id, v_row.class_level_id, null, (select auth.uid()));
  end loop;

  return v_total;
end;
$$;

revoke execute on function public.fn_recompute_stale_annual_results(uuid) from public, anon;
grant execute on function public.fn_recompute_stale_annual_results(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The automatic path: FR-J02's engine now chains into the aggregate
-- ═══════════════════════════════════════════════════════════════════════

-- Same signature, so this is a genuine replacement rather than a second
-- overload — the defaulted-argument ambiguity this codebase has been bitten
-- by does not arise. Both of FR-J02's callers (the mark_lock trigger and the
-- Exam Controller's explicit recompute) inherit the chain, which is why a
-- corrected term updates its annual figure in the same transaction rather
-- than waiting for a cron that does not exist locally.
--
-- The only change is the tail. Everything above it is FR-J02's, verbatim.
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
  v_class   uuid;
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

  -- FR-J03. The aggregate is downstream of this and nothing else has to
  -- remember to run it. Narrowed to this section: the other sections of the
  -- class have their own locks and their own recompute.
  select sec.class_level_id into v_class
    from public.class_section sec where sec.id = p_section_id;
  if v_class is not null then
    perform app.fn_compute_annual_result(v_term.session_id, v_class, p_section_id, p_actor);
  end if;

  return v_count;
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- What a screen and FR-J09 read
-- ═══════════════════════════════════════════════════════════════════════

create view public.v_annual_result
with (security_invoker = true) as
select ar.id,
       ar.tenant_id,
       ar.campus_id,
       ar.session_id,
       ar.class_level_id,
       ar.section_id,
       ar.enrolment_id,
       ar.subject_id,
       sub.name_en    as subject_name,
       sub.name_ur    as subject_name_ur,
       st.name_en     as student_name,
       st.gr_number,
       e.roll_no,
       ar.weighted_pct,
       ar.grading_scheme_id,
       gs.name        as grading_scheme_name,
       gs.version     as grading_scheme_version,
       gs.board,
       ar.grade_label,
       ar.gpa_point,
       ar.is_pass,
       ar.status,
       ar.terms_counted,
       ar.terms_total,
       ar.prorated_terms,
       ar.proration_note,
       ar.is_blocked,
       ar.computed_at,
       app.fn_annual_result_stale(ar.session_id, ar.enrolment_id, ar.subject_id, ar.computed_at) as is_stale
  from public.annual_result ar
  join public.subject sub on sub.id = ar.subject_id
  join public.enrolment e on e.id = ar.enrolment_id
  join public.student st on st.id = e.student_id
  left join public.grading_scheme gs on gs.id = ar.grading_scheme_id;

revoke all on public.v_annual_result from public, anon;
grant select on public.v_annual_result to authenticated;

comment on view public.v_annual_result is
  'FR-J03: the weighted annual result with the scale it was graded on, whether it was pro-rated, and whether a term result has moved under it.';

-- One section's annual sheet in one round trip: which terms count and what
-- they are worth, every candidate's weighted subjects, and the two things
-- that stop a report card.
create or replace function public.fn_annual_result_sheet(
  p_session_id uuid,
  p_section_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_sec       record;
  v_role      text := app.auth_role();
  v_terms     jsonb;
  v_pending   jsonb;
  v_students  jsonb;
  v_computed  timestamptz;
  v_stale     integer := 0;
  v_prov      integer := 0;
begin
  select id, tenant_id, campus_id, class_level_id into v_sec
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

  -- Every term of the session, counting or not: FR-I01 AC4's non-counting
  -- term belongs on the report card and must be visibly outside the total.
  select coalesce(jsonb_agg(jsonb_build_object(
           'exam_term_id',         t.id,
           'code',                 t.code,
           'name',                 t.name,
           'sequence',             t.sequence,
           'weight_bp',            t.weight_bp,
           'weight_pct',           t.weight_pct,
           'counts_toward_annual', t.counts_toward_annual,
           'ready',                (public.fn_term_result_ready(t.id, p_section_id) ->> 'ready')::boolean
         ) order by t.sequence), '[]'::jsonb)
    into v_terms
    from public.exam_term t
   where t.session_id = p_session_id
     and t.campus_id = v_sec.campus_id;

  select coalesce(jsonb_agg(x.name order by x.sequence), '[]'::jsonb)
    into v_pending
    from jsonb_to_recordset(v_terms) as x(name text, sequence int, counts_toward_annual boolean, ready boolean)
   where x.counts_toward_annual and not x.ready;

  select coalesce(jsonb_agg(c.payload order by c.roll_no nulls last, c.student_name), '[]'::jsonb),
         max(c.computed_at),
         count(*) filter (where c.any_stale)::int,
         count(*) filter (where c.any_provisional)::int
    into v_students, v_computed, v_stale, v_prov
    from (
      select st.name_en as student_name,
             e.roll_no,
             max(ar.computed_at) as computed_at,
             bool_or(app.fn_annual_result_stale(ar.session_id, ar.enrolment_id, ar.subject_id, ar.computed_at))
               as any_stale,
             bool_or(ar.status = 'provisional') as any_provisional,
             jsonb_build_object(
               'enrolment_id', e.id,
               'roll_no',      e.roll_no,
               'student_name', st.name_en,
               'gr_number',    st.gr_number,
               'is_blocked',   bool_or(ar.is_blocked),
               'subjects',     jsonb_agg(jsonb_build_object(
                                 'subject_id',     ar.subject_id,
                                 'subject_name',   sub.name_en,
                                 'weighted_pct',   ar.weighted_pct,
                                 'grade_label',    ar.grade_label,
                                 'gpa_point',      ar.gpa_point,
                                 'is_pass',        ar.is_pass,
                                 'status',         ar.status,
                                 'terms_counted',  ar.terms_counted,
                                 'terms_total',    ar.terms_total,
                                 'proration_note', ar.proration_note,
                                 'is_blocked',     ar.is_blocked,
                                 'is_stale',       app.fn_annual_result_stale(
                                                     ar.session_id, ar.enrolment_id,
                                                     ar.subject_id, ar.computed_at)
                               ) order by sub.name_en)
             ) as payload
        from public.annual_result ar
        join public.subject sub on sub.id = ar.subject_id
        join public.enrolment e on e.id = ar.enrolment_id
        join public.student st on st.id = e.student_id
       where ar.session_id = p_session_id
         and ar.section_id = p_section_id
       group by e.id, e.roll_no, st.name_en, st.gr_number
    ) c;

  return jsonb_build_object(
    'session_id',       p_session_id,
    'section_id',       p_section_id,
    'class_level_id',   v_sec.class_level_id,
    'terms',            v_terms,
    'pending_terms',    v_pending,
    'can_compute',      app.auth_tenant_id() is null
                          or v_role in ('super_admin', 'owner', 'principal',
                                        'vice_principal', 'exam_controller'),
    'computed_at',      v_computed,
    'stale_count',      coalesce(v_stale, 0),
    'provisional_count', coalesce(v_prov, 0),
    'candidates',       v_students
  );
end;
$$;

revoke execute on function public.fn_annual_result_sheet(uuid, uuid) from public, anon;
grant execute on function public.fn_annual_result_sheet(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.annual_result enable row level security;

-- The FR's annual_result_campus_scope. Parents are excluded here and read
-- through the policy below instead, the split FR-C11 established and FR-J02
-- reused.
create policy annual_result_campus_scope on public.annual_result
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() <> 'parent'
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- The FR's annual_result_parent_own_child.
create policy annual_result_parent_own_child on public.annual_result
  for select to authenticated
  using (
    enrolment_id in (
      select id from public.enrolment where student_id = any(app.auth_guardian_student_ids())
    )
  );

-- No INSERT, UPDATE or DELETE policy, for FR-J02's reason: an aggregate is
-- computed, never edited. A correction is a recompute of the term results it
-- came from.
