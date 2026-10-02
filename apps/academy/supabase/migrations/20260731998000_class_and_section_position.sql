-- FR-J05: class and section position.
--
-- "As a parent, I want to see my child's position in the section and in the
-- class, so that I understand the result in context."
--
-- ── Two denominators, and why the class one needs the whole class ─────
--
-- "Class and section position" is two different cohorts, not one number shown
-- twice. rank_in_section is against the candidate's own section; rank_in_class
-- is against every section of the class sitting the same term.
--
-- That second one is the one that constrains the design. FR-I02 makes
-- exam_subject per CLASS, but FR-I16 makes approval per (exam_subject,
-- section) precisely so 9-A can compute while 9-B is still marking. A class
-- rank taken while 9-B is unmarked would be a rank against half a cohort, and
-- it would change the day 9-B landed — which is exactly the number the FR's
-- Notes say parents litigate. So fn_compute_positions() refuses until every
-- section of the class that has candidates is signed off, and names the ones
-- it is waiting on. Section ranks wait with it: publishing 9-A's section rank
-- now and its class rank next week would put two positions on one report card
-- that were computed against two different cohorts.
--
-- ── Ties: shared, and the next position is NOT skipped ────────────────
--
-- AC1 is explicit: totals of 480, 472, 472 and 465 are positions 1, 2, 2 and
-- 3. That is dense_rank(), not rank() — rank() would give 1, 2, 2, 4. The
-- requirement fixes this, so it is not a knob; it is asserted in pgTAP at the
-- exact numbers the acceptance criterion names and printed on screen in
-- words, rather than left implicit in an ORDER BY somewhere.
--
-- What IS a knob is who gets ranked at all, and the FR's Notes are right that
-- it has to be quotable. So rank_policy is a stored campus setting AND it is
-- frozen onto every row it decided, next to the reason that row was left out.
-- A parent asking "why has my daughter no position" gets an answer off the
-- row rather than off someone's memory of a config screen.
--
-- ── Who is ranked ─────────────────────────────────────────────────────
--
--   * WITHHELD (debarred somewhere in the term, FR-I11/FR-J02's is_blocked)
--     is never ranked, under either policy. There is no published total to
--     rank; a position would put a number in a merit list for a result the
--     school is refusing to release.
--   * ABSENT in any paper is unranked under 'exclude_absentees' (AC2) and
--     ranked under 'include_all', where the zeros simply count.
--   * EXEMPT is ranked. The policy names absentees and only absentees, and an
--     exemption is an entitlement rather than a failure to appear. The
--     consequence is real and deliberate: FR-I11 shrank that candidate's
--     denominator, so their total_obtained is out of less, and a merit list
--     ordered on total_obtained places them accordingly. total_max is stored
--     alongside so the list can show it rather than hide it.
--
-- An unranked candidate still gets a ROW, with is_ranked false and the reason
-- named. AC2 wants the report card to print a dash, and a missing row is not
-- a dash — it is indistinguishable from "not computed yet".
--
-- ── ranked_out_of is the cohort, not the register ─────────────────────
--
-- AC1: 'the "out of" figure equals the number of ranked candidates rather
-- than the section strength'. A section of 40 with 3 absentees excluded ranks
-- 37, and "5 of 37" is the truthful sentence. Both denominators are stored,
-- because the class one is not derivable from the section one.
--
-- ── Stored, and staleness is CLASS-wide ───────────────────────────────
--
-- FR-J02 stored because a view would silently re-grade. A position has the
-- same problem and a worse one: it is relative to a cohort, so a derived view
-- would silently RE-RANK every report card already handed out the moment one
-- late result landed. Storing it means the number a parent is holding is the
-- number the database still says, and a changed cohort shows up as stale
-- rather than as a quiet correction.
--
-- Which is why staleness here is class-wide and not per candidate. AC4:
-- "every report card in that class is marked stale". One mark changing in
-- 9-C moves 9-C's totals, which moves the class ranks of 9-A and 9-B too. So
-- app.fn_position_stale() asks about the whole (term, class): is any
-- contributing subject_result stale (FR-I17's own stamp, inherited), or has
-- any been recomputed since these positions were taken. Same two disjuncts
-- FR-J03 uses, same reason — recomputing positions cannot paint over a mark
-- nobody has corrected yet.
--
-- ── The nightly job ───────────────────────────────────────────────────
--
-- There is no pg_cron in this stack. fn_recompute_stale_positions() is the
-- callable a real 02:00 schedule would invoke; the ordinary path does not
-- wait for it, because computing a section's term results now chains into the
-- class's positions as soon as the last section of the class is in.

-- ═══════════════════════════════════════════════════════════════════════
-- The setting
-- ═══════════════════════════════════════════════════════════════════════

create type public.rank_policy as enum ('exclude_absentees', 'include_all');

-- The FR suggests exam_settings.rank_policy. It lands in campus_setting
-- because that is where this codebase already keeps exactly this kind of
-- per-campus exam knob (FR-I12's mark_precision), and a second settings table
-- holding one key would be a second place to look.
--
-- 'exclude_absentees' is the default because it is the case AC2 describes and
-- because a merit list that ranks a candidate who never sat the paper is the
-- one a school gets complaints about.
create or replace function app.fn_rank_policy(p_campus_id uuid)
returns public.rank_policy
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select (s.value #>> '{}')::public.rank_policy
       from public.campus_setting s
      where s.campus_id = p_campus_id and s.key = 'rank_policy'),
    'exclude_absentees'::public.rank_policy
  );
$$;

comment on function app.fn_rank_policy(uuid) is
  'FR-J05: whether a candidate absent in any paper is ranked. Stored so the rule is quotable, and frozen onto every result_position row it decided.';

create or replace function public.set_rank_policy(
  p_campus_id uuid,
  p_policy    public.rank_policy
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  -- The same list fn_compute_positions() accepts, deliberately: a screen that
  -- offers the re-rank button and refuses the setting behind it would be two
  -- different answers to one question.
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
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
  if p_policy is null then
    raise exception 'RANK_POLICY_REQUIRED' using errcode = '23514';
  end if;

  insert into public.campus_setting (campus_id, key, value)
  values (p_campus_id, 'rank_policy', to_jsonb(p_policy::text))
  on conflict (campus_id, key) do update set value = excluded.value;
end;
$$;

revoke execute on function public.set_rank_policy(uuid, public.rank_policy) from public, anon;
grant execute on function public.set_rank_policy(uuid, public.rank_policy) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Schema
-- ═══════════════════════════════════════════════════════════════════════

create table public.result_position (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  campus_id           uuid not null references public.campus(id) on delete cascade,
  exam_term_id        uuid not null references public.exam_term(id) on delete cascade,
  class_level_id      uuid not null references public.class_level(id),
  section_id          uuid not null references public.class_section(id) on delete cascade,
  enrolment_id        uuid not null references public.enrolment(id) on delete cascade,
  -- What the ranking is ordered on, and what it is out of. The second is
  -- stored rather than assumed: FR-I11's exemption shrinks it.
  total_obtained      numeric(9,2) not null,
  total_max           integer not null,
  -- Null for an unranked candidate. AC2's dash has to be a null, not a zero.
  rank_in_section     integer,
  rank_in_class       integer,
  -- AC1: the number of RANKED candidates, not the section strength.
  ranked_out_of       integer,
  ranked_out_of_class integer,
  is_ranked           boolean not null,
  -- 'absent' or 'withheld'. Null for a ranked candidate.
  exclusion_reason    text,
  -- The setting that decided it, frozen onto the row it decided.
  rank_policy         public.rank_policy not null,
  computed_at         timestamptz not null default clock_timestamp(),
  computed_by         uuid references public.app_user(user_id),
  constraint chk_result_position_ranked
    check (
      (is_ranked and rank_in_section is not null and rank_in_class is not null
        and ranked_out_of is not null and ranked_out_of_class is not null
        and exclusion_reason is null)
      or
      (not is_ranked and rank_in_section is null and rank_in_class is null
        and exclusion_reason is not null)
    ),
  constraint chk_result_position_totals check (total_obtained >= 0 and total_max >= 0)
);

create unique index uq_result_position
  on public.result_position (tenant_id, exam_term_id, enrolment_id);
-- The FR's index, spelled as the FR spells it.
create index idx_position_section
  on public.result_position (exam_term_id, section_id, rank_in_section);
create index idx_position_class
  on public.result_position (exam_term_id, class_level_id, rank_in_class);
create index idx_position_enrolment on public.result_position (enrolment_id);

create trigger result_position_audit after insert or update or delete on public.result_position
  for each row execute function app.tg_audit_row();

comment on table public.result_position is
  'FR-J05: one row per candidate per term, ranked within the section and within the class by dense_rank on total marks. Unranked candidates keep a row so the report card can print a dash rather than nothing.';
comment on column public.result_position.ranked_out_of is
  'FR-J05 AC1: the number of ranked candidates in the section, NOT the section strength. A section of 40 with 3 absentees excluded ranks 37.';
comment on column public.result_position.rank_policy is
  'FR-J05: the campus setting as it stood when this row was computed. Stored so "why has my child no position" is answered off the row.';

-- ═══════════════════════════════════════════════════════════════════════
-- Staleness, class-wide
-- ═══════════════════════════════════════════════════════════════════════

-- AC4: "every report card in that class is marked stale". A position is
-- relative to the whole class, so ANY contributing term result moving stales
-- every row of it — including sections nobody touched.
--
-- The two disjuncts are FR-J03's, for FR-J03's reasons: the first is FR-I17's
-- stamp inherited unchanged, the second is cache coherence. Because the first
-- is re-derived on read, recomputing positions cannot clear staleness the
-- term result still has.
create or replace function app.fn_position_stale(
  p_exam_term_id   uuid,
  p_class_level_id uuid,
  p_computed_at    timestamptz
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
      join public.enrolment e on e.id = sr.enrolment_id
     where sr.exam_term_id = p_exam_term_id
       and e.class_level_id = p_class_level_id
       and (app.auth_tenant_id() is null or sr.tenant_id = app.auth_tenant_id())
       and (
         coalesce(app.fn_result_stale_at(sr.exam_subject_id, sr.section_id) > sr.computed_at, false)
         or sr.computed_at > p_computed_at
       )
  );
$$;

comment on function app.fn_position_stale(uuid, uuid, timestamptz) is
  'FR-J05 AC4: positions are stale when any term result in the CLASS is stale or has moved. One mark in 9-C changes the class rank of 9-A.';

-- ═══════════════════════════════════════════════════════════════════════
-- Readiness: the class, not the section
-- ═══════════════════════════════════════════════════════════════════════

-- The sections of a class that have candidates, and whether each has had its
-- term signed off. A section with nobody enrolled has nobody to rank and is
-- not something the class waits on.
create or replace function public.fn_position_readiness(
  p_exam_term_id   uuid,
  p_class_level_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_term    record;
  v_total   integer;
  v_ready   integer;
  v_pending jsonb;
begin
  select t.id, t.tenant_id, t.campus_id, t.session_id into v_term
    from public.exam_term t where t.id = p_exam_term_id;
  if v_term.id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_tenant_id() is not null then
    if v_term.tenant_id <> app.auth_tenant_id() then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if app.auth_role() not in ('super_admin', 'owner')
       and not (v_term.campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  select count(*)::int,
         count(*) filter (where s.ready)::int,
         coalesce(jsonb_agg(s.name order by s.name) filter (where not s.ready), '[]'::jsonb)
    into v_total, v_ready, v_pending
    from (
      select sec.id, sec.name,
             (public.fn_term_result_ready(p_exam_term_id, sec.id) ->> 'ready')::boolean as ready
        from public.class_section sec
       where sec.session_id = v_term.session_id
         and sec.campus_id = v_term.campus_id
         and sec.class_level_id = p_class_level_id
         and sec.is_active
         and exists (
           select 1 from public.enrolment e
            where e.section_id = sec.id
              and e.status = 'active'
              and e.deleted_at is null
         )
    ) s;

  return jsonb_build_object(
    'exam_term_id',     p_exam_term_id,
    'class_level_id',   p_class_level_id,
    'section_count',    v_total,
    'ready_count',      v_ready,
    'pending_sections', v_pending,
    -- A class with no enrolled sections is not "ready", it is empty.
    'ready',            v_total > 0 and v_ready = v_total
  );
end;
$$;

revoke execute on function public.fn_position_readiness(uuid, uuid) from public, anon;
grant execute on function public.fn_position_readiness(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The computation
-- ═══════════════════════════════════════════════════════════════════════

-- The engine. No authorisation of its own and no readiness gate, the split
-- FR-J02 and FR-J03 established: both callers below have already decided that
-- this class is ready and that the caller may see it.
create or replace function app.fn_compute_positions(
  p_exam_term_id   uuid,
  p_class_level_id uuid,
  p_actor          uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campus uuid;
  v_policy public.rank_policy;
  v_count  integer := 0;
begin
  select t.campus_id into v_campus from public.exam_term t where t.id = p_exam_term_id;
  if v_campus is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_policy := app.fn_rank_policy(v_campus);

  -- A candidate who has left the class is not in the cohort any more, and a
  -- rank they no longer belong to is worse than no rank at all.
  delete from public.result_position rp
   where rp.exam_term_id = p_exam_term_id
     and rp.class_level_id = p_class_level_id
     and not exists (
       select 1
         from public.subject_result sr
         join public.enrolment e on e.id = sr.enrolment_id
        where sr.exam_term_id = p_exam_term_id
          and sr.enrolment_id = rp.enrolment_id
          and e.status = 'active'
          and e.deleted_at is null
     );

  -- The cohort is taken off the ENROLMENT's section, not the term result's.
  -- A candidate moved between sections mid-term has results stamped with the
  -- section that computed them, which would put one enrolment in two cohorts
  -- and make the upsert below touch a row twice. Their current section is also
  -- the only honest answer to "position in the section".
  with cand as (
    select sr.tenant_id,
           sr.campus_id,
           e.section_id,
           sr.enrolment_id,
           e.class_level_id,
           sum(sr.obtained)                            as total_obtained,
           sum(sr.max_marks)::int                      as total_max,
           bool_or(sr.is_blocked)                      as blocked,
           bool_or(sr.report_symbol = 'AB')            as absent
      from public.subject_result sr
      join public.enrolment e on e.id = sr.enrolment_id
      join public.class_section sec on sec.id = e.section_id
     where sr.exam_term_id = p_exam_term_id
       and e.class_level_id = p_class_level_id
       and e.status = 'active'
       and e.deleted_at is null
       and sec.is_active
     group by sr.tenant_id, sr.campus_id, e.section_id, sr.enrolment_id, e.class_level_id
  ),
  judged as (
    select c.*,
           case when c.blocked then 'withheld'
                when c.absent and v_policy = 'exclude_absentees' then 'absent'
           end as exclusion_reason
      from cand c
  ),
  ranked as (
    select j.*,
           -- Partitioning on the exclusion itself keeps the unranked out of
           -- the numbering rather than filtering them and losing their row.
           case when j.exclusion_reason is null then
             dense_rank() over (
               partition by j.section_id, (j.exclusion_reason is null)
               order by j.total_obtained desc)
           end as rank_in_section,
           case when j.exclusion_reason is null then
             dense_rank() over (
               partition by j.campus_id, j.class_level_id, (j.exclusion_reason is null)
               order by j.total_obtained desc)
           end as rank_in_class,
           case when j.exclusion_reason is null then
             count(*) filter (where j.exclusion_reason is null)
               over (partition by j.section_id)
           end as ranked_out_of,
           case when j.exclusion_reason is null then
             count(*) filter (where j.exclusion_reason is null)
               over (partition by j.campus_id, j.class_level_id)
           end as ranked_out_of_class
      from judged j
  )
  insert into public.result_position (
    tenant_id, campus_id, exam_term_id, class_level_id, section_id, enrolment_id,
    total_obtained, total_max, rank_in_section, rank_in_class, ranked_out_of,
    ranked_out_of_class, is_ranked, exclusion_reason, rank_policy,
    computed_at, computed_by
  )
  select r.tenant_id, r.campus_id, p_exam_term_id, r.class_level_id, r.section_id, r.enrolment_id,
         r.total_obtained, r.total_max, r.rank_in_section, r.rank_in_class,
         r.ranked_out_of::int, r.ranked_out_of_class::int,
         r.exclusion_reason is null, r.exclusion_reason, v_policy,
         clock_timestamp(), p_actor
    from ranked r
  on conflict (tenant_id, exam_term_id, enrolment_id) do update
    set campus_id           = excluded.campus_id,
        class_level_id      = excluded.class_level_id,
        section_id          = excluded.section_id,
        total_obtained      = excluded.total_obtained,
        total_max           = excluded.total_max,
        rank_in_section     = excluded.rank_in_section,
        rank_in_class       = excluded.rank_in_class,
        ranked_out_of       = excluded.ranked_out_of,
        ranked_out_of_class = excluded.ranked_out_of_class,
        is_ranked           = excluded.is_ranked,
        exclusion_reason    = excluded.exclusion_reason,
        rank_policy         = excluded.rank_policy,
        computed_at         = excluded.computed_at,
        computed_by         = excluded.computed_by;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- The FR's fn_compute_positions(p_exam_term_id, p_class_id): the Exam
-- Controller's explicit re-rank.
create or replace function public.fn_compute_positions(
  p_exam_term_id uuid,
  p_class_id     uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_term      record;
  v_ready     jsonb;
  v_pending   text;
  v_open      text;
begin
  select t.id, t.tenant_id, t.campus_id, t.session_id into v_term
    from public.exam_term t where t.id = p_exam_term_id;
  if v_term.id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from public.class_level where id = p_class_id and tenant_id = v_term.tenant_id
  ) then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_tenant_id is not null then
    if v_term.tenant_id <> v_tenant_id then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if v_role not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if v_role not in ('super_admin', 'owner')
       and not (v_term.campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  -- See the header: a class rank against half a class is the number the FR's
  -- Notes say parents litigate.
  v_ready := public.fn_position_readiness(p_exam_term_id, p_class_id);
  if not (v_ready ->> 'ready')::boolean then
    select string_agg(s #>> '{}', ', ')
      into v_pending
      from jsonb_array_elements(v_ready -> 'pending_sections') s;
    raise exception '%',
      format('positions wait on section %s', coalesce(v_pending, 'enrolments in this class'))
      using errcode = '23514',
            detail = format('%s of %s sections signed off',
                            v_ready ->> 'ready_count', v_ready ->> 'section_count'),
            hint = 'A class position is against the whole class, so every section has to be in.';
  end if;

  -- FR-J02's rule, for FR-J02's reason: FR-I17 stamps staleness once per
  -- window, so anything computed inside an open one would be out of date
  -- before the window shut and could no longer be re-flagged.
  select sub.name_en into v_open
    from public.v_exam_subject_section vs
    join public.subject sub on sub.id = vs.subject_id
    join public.class_section sec on sec.id = vs.section_id
   where vs.exam_term_id = p_exam_term_id
     and sec.class_level_id = p_class_id
     and app.fn_break_glass_open(vs.exam_subject_id, vs.section_id)
   limit 1;
  if v_open is not null then
    raise exception '%', format('marks are open under a break-glass window on %s — recompute when it closes', v_open)
      using errcode = '42501',
            hint = 'A merit list computed mid-window would be out of date before the window shut.';
  end if;

  return app.fn_compute_positions(p_exam_term_id, p_class_id, (select auth.uid()));
end;
$$;

revoke execute on function public.fn_compute_positions(uuid, uuid) from public, anon;
grant execute on function public.fn_compute_positions(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: the nightly job
-- ═══════════════════════════════════════════════════════════════════════

-- Not wired to a schedule — no pg_cron in this stack, the same finding every
-- other "System" actor here records. A real 02:00 cron calls this.
--
-- Like FR-J03's, it recomputes what has gone stale for any reason, and where
-- the underlying term result is itself stale it deliberately does not clear
-- the flag: staleness is re-derived on read and the term is what has to be
-- recomputed first.
create or replace function public.fn_recompute_stale_positions(
  p_exam_term_id uuid default null
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
    select distinct rp.exam_term_id, rp.class_level_id
      from public.result_position rp
     where (p_exam_term_id is null or rp.exam_term_id = p_exam_term_id)
       and (app.auth_tenant_id() is null or rp.tenant_id = app.auth_tenant_id())
       and app.fn_position_stale(rp.exam_term_id, rp.class_level_id, rp.computed_at)
  loop
    v_total := v_total + app.fn_compute_positions(v_row.exam_term_id, v_row.class_level_id, (select auth.uid()));
  end loop;

  return v_total;
end;
$$;

revoke execute on function public.fn_recompute_stale_positions(uuid) from public, anon;
grant execute on function public.fn_recompute_stale_positions(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The automatic path
-- ═══════════════════════════════════════════════════════════════════════

-- FR-J03 appended the annual aggregate to the tail of the term-result engine
-- by re-emitting the whole two-hundred-line body. Doing that a second time
-- would mean three copies of FR-J02's loop in the migration history, any of
-- which a later reader could mistake for the current one. So the tail becomes
-- a function of its own and the engine calls it; the next FR downstream of a
-- computed term result appends here instead.
--
-- Nothing in it may fail an approval. Positions wait for the whole class, and
-- a class whose other sections are still marking simply does not get ranked
-- yet — the Exam Controller's explicit call is the one that says so out loud.
create or replace function app.fn_compute_result_downstream(
  p_exam_term_id uuid,
  p_section_id   uuid,
  p_actor        uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session uuid;
  v_class   uuid;
begin
  select t.session_id into v_session from public.exam_term t where t.id = p_exam_term_id;
  select sec.class_level_id into v_class
    from public.class_section sec where sec.id = p_section_id;
  if v_session is null or v_class is null then
    return;
  end if;

  -- FR-J03: the year, narrowed to this section — the class's other sections
  -- have their own locks and their own recompute.
  perform app.fn_compute_annual_result(v_session, v_class, p_section_id, p_actor);

  -- FR-J05: the merit list, which is the whole class or nothing.
  if (public.fn_position_readiness(p_exam_term_id, v_class) ->> 'ready')::boolean then
    perform app.fn_compute_positions(p_exam_term_id, v_class, p_actor);
  end if;
end;
$$;

-- Same signature as FR-J02's and FR-J03's, so this is a genuine replacement
-- rather than a second overload. The only change from FR-J03's version is
-- that the tail is now one call.
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

  perform app.fn_compute_result_downstream(p_exam_term_id, p_section_id, p_actor);

  return v_count;
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- What a screen and FR-J09 read
-- ═══════════════════════════════════════════════════════════════════════

create view public.v_result_position
with (security_invoker = true) as
select rp.id,
       rp.tenant_id,
       rp.campus_id,
       rp.exam_term_id,
       rp.class_level_id,
       cl.name_en   as class_name,
       rp.section_id,
       sec.name     as section_name,
       rp.enrolment_id,
       st.name_en   as student_name,
       st.gr_number,
       e.roll_no,
       rp.total_obtained,
       rp.total_max,
       rp.rank_in_section,
       rp.rank_in_class,
       rp.ranked_out_of,
       rp.ranked_out_of_class,
       rp.is_ranked,
       rp.exclusion_reason,
       rp.rank_policy,
       rp.computed_at,
       app.fn_position_stale(rp.exam_term_id, rp.class_level_id, rp.computed_at) as is_stale
  from public.result_position rp
  join public.class_level cl on cl.id = rp.class_level_id
  join public.class_section sec on sec.id = rp.section_id
  join public.enrolment e on e.id = rp.enrolment_id
  join public.student st on st.id = e.student_id;

revoke all on public.v_result_position from public, anon;
grant select on public.v_result_position to authenticated;

comment on view public.v_result_position is
  'FR-J05: a candidate''s position in their section and in their class, with the cohort each is out of and whether a mark has moved under the class since.';

-- The merit list, in one round trip: the whole class ordered by class
-- position, the policy in force, and whether the list is safe to print.
create or replace function public.fn_position_sheet(
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
  v_term     record;
  v_role     text := app.auth_role();
  v_ready    jsonb;
  v_rows     jsonb;
  v_computed timestamptz;
  v_stale    boolean := false;
begin
  select t.id, t.tenant_id, t.campus_id, t.name into v_term
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

  v_ready := public.fn_position_readiness(p_exam_term_id, p_class_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'enrolment_id',        rp.enrolment_id,
           'student_name',        st.name_en,
           'gr_number',           st.gr_number,
           'roll_no',             e.roll_no,
           'section_id',          rp.section_id,
           'section_name',        sec.name,
           'total_obtained',      rp.total_obtained,
           'total_max',           rp.total_max,
           'rank_in_section',     rp.rank_in_section,
           'ranked_out_of',       rp.ranked_out_of,
           'rank_in_class',       rp.rank_in_class,
           'ranked_out_of_class', rp.ranked_out_of_class,
           'is_ranked',           rp.is_ranked,
           'exclusion_reason',    rp.exclusion_reason
         ) order by rp.rank_in_class nulls last, rp.total_obtained desc, st.name_en), '[]'::jsonb),
         max(rp.computed_at),
         bool_or(app.fn_position_stale(rp.exam_term_id, rp.class_level_id, rp.computed_at))
    into v_rows, v_computed, v_stale
    from public.result_position rp
    join public.class_section sec on sec.id = rp.section_id
    join public.enrolment e on e.id = rp.enrolment_id
    join public.student st on st.id = e.student_id
   where rp.exam_term_id = p_exam_term_id
     and rp.class_level_id = p_class_id;

  return jsonb_build_object(
    'exam_term_id',   p_exam_term_id,
    'exam_term_name', v_term.name,
    'class_level_id', p_class_id,
    'readiness',      v_ready,
    'rank_policy',    app.fn_rank_policy(v_term.campus_id),
    'can_compute',    app.auth_tenant_id() is null
                        or v_role in ('super_admin', 'owner', 'principal',
                                      'vice_principal', 'exam_controller'),
    'computed_at',    v_computed,
    'is_stale',       coalesce(v_stale, false),
    'candidates',     v_rows
  );
end;
$$;

revoke execute on function public.fn_position_sheet(uuid, uuid) from public, anon;
grant execute on function public.fn_position_sheet(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.result_position enable row level security;

-- The FR's position_campus_scope. Parents are excluded here and read through
-- the policy below, the split FR-C11 established and FR-J02/J03 reused.
create policy position_campus_scope on public.result_position
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() <> 'parent'
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- The FR's position_parent_own_child. A parent sees their own child's
-- position and not the classmate's total it was measured against — the merit
-- list is the school's to publish, not something a policy leaks a row at a
-- time.
create policy position_parent_own_child on public.result_position
  for select to authenticated
  using (
    enrolment_id in (
      select id from public.enrolment where student_id = any(app.auth_guardian_student_ids())
    )
  );

-- No INSERT, UPDATE or DELETE policy, for FR-J02's reason: a position is
-- computed against a cohort, never typed in. Editing one would put a number
-- on a report card that no set of marks produces.
