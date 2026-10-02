-- FR-J01: board grading scheme configuration.
--
-- "As an Exam Controller, I want to configure grade bands and GPA points per
-- board, so that FBISE, Punjab Board and Cambridge students are graded on
-- their own scale."
--
-- This is the grading vocabulary FR-J02 computes into and FR-J03/J09 print
-- from. Nothing here computes a result; it defines what a percentage MEANS.
--
-- ── The representation decision, and why not basis points ─────────────
--
-- This schema uses paisa-bigint for money (FR-K01) and integer basis points
-- for term weightage (FR-I01) for one reason: those quantities are SUMMED and
-- then compared against an exact total, so a binary float would drift and a
-- set of weights would stop adding to exactly 100%.
--
-- A grade boundary is not that quantity. It is compared, never summed, and the
-- requirement FR-J02 states is "the percentage to two decimal places" — the
-- number the report card prints. So the discipline that matters here is not
-- "scale it to an integer", it is "never let a float near it and never let the
-- printed number and the graded number be two different numbers":
--
--   * every bound is numeric(5,2). Postgres numeric is exact decimal, so
--     33.00 is 33.00 and not 32.999999999999996 — the drift basis points
--     exist to prevent cannot occur here in the first place.
--   * the percentage is rounded to two decimals ONCE, by FR-J02, and the
--     grade lookup reads THAT value. fn_grade_for_percentage() rounds its
--     argument itself so a caller that forgets cannot produce a grade that
--     disagrees with the printed percentage.
--   * round(numeric, 2) is half-away-from-zero and deterministic. A candidate
--     on exactly 32.995% rounds to 33.00 and lands in FBISE's E band, on every
--     machine, on every run, forever. There is no "just below the boundary"
--     state for a number the report card would print as 33.00%.
--
-- ── Bands are stored the way boards publish them ──────────────────────
--
-- FBISE publishes "A1 80-100, A 70-79.99 ... F 0-32.99". Those are INCLUSIVE
-- bounds on the two-decimal grid, and that is exactly how min_pct/max_pct are
-- stored — an Exam Controller types what the gazette says.
--
-- The canonical form used for overlap exclusion is the half-open range
-- [min_pct, max_pct + 0.01), which on a two-decimal grid is precisely the
-- inclusive interval and has no boundary shared between two bands. So:
--
--   * contiguity is next.min_pct = prev.max_pct + 0.01 (79.99 -> 80.00,
--     32.99 -> 33.00), which is the FBISE set exactly;
--   * the EXCLUDE constraint refuses an overlap structurally, for every
--     writer including the table owner;
--   * coverage is [0.00, 100.00] with no gap, and a gap is named in the
--     refusal by the two bounds that leave it: bands 70-79 and 80-100 are
--     refused with "grading bands leave 79.00-80.00 uncovered", which is
--     AC2's own sentence.
--
-- ── AC4: effective-dating, and what freezes a band ────────────────────
--
-- The FR's Notes are the requirement: "editing a band silently re-grades
-- transcripts issued three years ago". Two mechanisms, and both are needed:
--
--   1. A band is editable only while its scheme is 'draft'. Once activated,
--     trg_grading_band_frozen refuses INSERT, UPDATE and DELETE for every
--     role — a signed-off scale is not a setting. new_grading_scheme_version()
--     is the only way to change one, and it clones the bands into a new draft
--     carrying version + 1 and its own effective_from.
--   2. FR-J02 stores grading_scheme_id, grade_label and gpa_point ON the
--     computed result. Resolution happens once, at computation, against the
--     date the result belongs to; a result computed under v1 keeps rendering
--     v1's grade after v2 becomes effective, because it is not re-resolved.
--
-- Neither alone is enough: (1) without (2) would still re-grade old results
-- the moment a newer version became effective, and (2) without (1) would let
-- an in-place band edit rewrite the scale a result already resolved against.
--
-- ── AC3: "a class tagged Cambridge", with no code change ──────────────
--
-- A scheme is per board, and public.board (FBISE / PUNJAB / SINDH / KPK /
-- BALOCHISTAN / AKU_EB / CAMBRIDGE) has existed since FR-E05. What did not
-- exist was a way to ask which board a SECTION sits, so that is what
-- app.fn_board_for_section() answers, from data only:
--
--   1. the section's stream, if it has one. public.stream.board is where a
--      Cambridge or a Pre-Medical FBISE tag already lives, and an O-Level
--      section and a Matric section of the same Class 9 differ exactly there.
--   2. otherwise the campus's board, held in public.campus_setting under the
--      key 'board' — the same generic (campus_id, key, value) store FR-I12
--      put mark_precision in, rather than a new column on campus.
--   3. otherwise FBISE, the federal default.
--
-- Adding a Cambridge scheme beside an FBISE one and tagging the section's
-- stream CAMBRIDGE is therefore the whole of "with no code change".
--
-- ── What is deliberately NOT here ─────────────────────────────────────
--
-- No seeded default scheme. A board's bands are a fact about a gazette in a
-- particular year, and quietly inventing one per tenant would be the exact
-- failure this FR's Notes are about — a scale nobody chose, silently grading
-- transcripts. FR-J02 refuses to compute with a named error instead, and the
-- configuration screen carries the published FBISE set as a preset a human
-- clicks.

create extension if not exists btree_gist;

-- ═══════════════════════════════════════════════════════════════════════
-- Schema
-- ═══════════════════════════════════════════════════════════════════════

-- 'draft'  bands editable, never resolved against.
-- 'active' bands frozen, resolvable for dates from effective_from.
-- 'retired' withdrawn; never resolved against, kept because results already
--           point at it and a result's scale must stay readable.
create type public.grading_scheme_status as enum ('draft', 'active', 'retired');

create table public.grading_scheme (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  board         public.board not null,
  name          text not null,
  -- AC4. The date the scale starts applying, not the date it was typed.
  effective_from date not null,
  version       integer not null default 1,
  status        public.grading_scheme_status not null default 'draft',
  -- The previous version this one was cloned from. Null for a first version.
  supersedes_id uuid references public.grading_scheme(id),
  created_by    uuid references public.app_user(user_id),
  created_at    timestamptz not null default now(),
  activated_at  timestamptz,
  constraint chk_grading_scheme_version check (version >= 1),
  constraint chk_grading_scheme_name check (length(btrim(name)) > 0)
);

-- Two schemes for one board effective the same day is an unanswerable
-- question, so it is not representable.
create unique index uq_grading_scheme_effective
  on public.grading_scheme (tenant_id, board, effective_from);
-- The FR's index, spelled as the FR spells it: resolution reads the newest
-- effective scheme for a board.
create index idx_scheme_board_effective
  on public.grading_scheme (tenant_id, board, effective_from desc);

create table public.grading_band (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  scheme_id   uuid not null references public.grading_scheme(id) on delete cascade,
  -- Inclusive bounds on the two-decimal grid, as the board publishes them.
  min_pct     numeric(5,2) not null,
  max_pct     numeric(5,2) not null,
  grade_label text not null,
  -- Null for an ungraded band — Cambridge U has no GPA point.
  gpa_point   numeric(3,2),
  -- FBISE F and Cambridge U are bands you can land in and not have passed.
  -- FR-J02 fails a subject on a component pass mark OR on a failing band.
  is_pass     boolean not null default true,
  remark_en   text,
  remark_ur   text,
  sequence    smallint not null,
  created_at  timestamptz not null default now(),
  constraint chk_band_bounds check (min_pct >= 0 and max_pct <= 100 and min_pct <= max_pct),
  constraint chk_band_gpa check (gpa_point is null or gpa_point >= 0),
  constraint chk_band_label check (length(btrim(grade_label)) > 0),
  -- The overlap refusal, structurally. [min, max + 0.01) is the inclusive
  -- interval on a two-decimal grid, so adjacent bands touch and do not
  -- overlap. btree_gist supplies the uuid equality operator class.
  constraint excl_grading_band_range exclude using gist (
    scheme_id with =,
    (numrange(min_pct, max_pct + 0.01, '[)')) with &&
  )
);

create unique index uq_grading_band_label on public.grading_band (scheme_id, grade_label);
create unique index uq_grading_band_sequence on public.grading_band (scheme_id, sequence);
create index idx_grading_band_scheme on public.grading_band (scheme_id, min_pct desc);

create trigger grading_scheme_audit after insert or update or delete on public.grading_scheme
  for each row execute function app.tg_audit_row();
create trigger grading_band_audit after insert or update or delete on public.grading_band
  for each row execute function app.tg_audit_row();

comment on table public.grading_scheme is
  'FR-J01: one board''s grade scale, effective-dated. Bands freeze on activation; new_grading_scheme_version() is the only way to change one.';
comment on column public.grading_band.min_pct is
  'Inclusive lower bound on the two-decimal grid — FBISE A is 70.00 to 79.99. Contiguity is next.min_pct = prev.max_pct + 0.01.';
comment on column public.grading_band.is_pass is
  'False for FBISE F and Cambridge U. FR-J02 fails a subject on a failing band OR on any component''s pass mark.';

-- ═══════════════════════════════════════════════════════════════════════
-- AC1 / AC2: coverage, in one implementation
-- ═══════════════════════════════════════════════════════════════════════

-- The single gap/overlap rule. It takes a jsonb array rather than a scheme id
-- so that save_grading_scheme() can refuse a bad set BEFORE writing any of it
-- — a caller must not have to read the error out of a half-applied edit — and
-- fn_validate_grading_bands() can ask the same question of what is stored.
-- Two entry points, one rule; there is nowhere for them to disagree.
--
-- Returns null when the set is sound, otherwise the sentence to raise.
create or replace function app.fn_grading_band_coverage_error(p_bands jsonb)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_row record;
  v_min numeric(5,2);
  v_max numeric(5,2);
begin
  if p_bands is null or jsonb_typeof(p_bands) <> 'array' or jsonb_array_length(p_bands) = 0 then
    return 'a grading scheme needs at least one band';
  end if;

  -- Per-band sanity first: a band whose own bounds are backwards would make
  -- every ordering question below meaningless.
  select (b.value->>'grade_label') as grade_label,
         (b.value->>'min_pct')::numeric as min_pct,
         (b.value->>'max_pct')::numeric as max_pct
    into v_row
    from jsonb_array_elements(p_bands) b
   where (b.value->>'min_pct')::numeric > (b.value->>'max_pct')::numeric
      or (b.value->>'min_pct')::numeric < 0
      or (b.value->>'max_pct')::numeric > 100
   limit 1;
  if found then
    return format('band %s has bounds %s-%s, which is not a range inside 0.00-100.00',
                  v_row.grade_label, v_row.min_pct, v_row.max_pct);
  end if;

  -- Bounds live on the two-decimal grid. Letting 79.995 through would round
  -- into storage and silently move a boundary nobody typed.
  select (b.value->>'grade_label') as grade_label,
         (b.value->>'min_pct')::numeric as min_pct,
         (b.value->>'max_pct')::numeric as max_pct
    into v_row
    from jsonb_array_elements(p_bands) b
   where (b.value->>'min_pct')::numeric <> round((b.value->>'min_pct')::numeric, 2)
      or (b.value->>'max_pct')::numeric <> round((b.value->>'max_pct')::numeric, 2)
   limit 1;
  if found then
    return format('band %s bounds must have at most two decimal places', v_row.grade_label);
  end if;

  select min((b.value->>'min_pct')::numeric(5,2)),
         max((b.value->>'max_pct')::numeric(5,2))
    into v_min, v_max
    from jsonb_array_elements(p_bands) b;

  if v_min > 0.00 then
    return format('grading bands leave %s-%s uncovered', 0.00::numeric(5,2), v_min);
  end if;
  if v_max < 100.00 then
    return format('grading bands leave %s-%s uncovered', v_max, 100.00::numeric(5,2));
  end if;

  -- The first discontinuity, walking the bands from the bottom. A gap and an
  -- overlap are the same comparison with opposite signs, and they need
  -- different sentences.
  select *
    into v_row
    from (
      select (b.value->>'grade_label') as grade_label,
             (b.value->>'min_pct')::numeric(5,2) as min_pct,
             lag((b.value->>'max_pct')::numeric(5,2))
               over (order by (b.value->>'min_pct')::numeric(5,2)) as prev_max,
             lag(b.value->>'grade_label')
               over (order by (b.value->>'min_pct')::numeric(5,2)) as prev_label
        from jsonb_array_elements(p_bands) b
    ) w
   where w.prev_max is not null
     and w.min_pct <> w.prev_max + 0.01
   order by w.min_pct
   limit 1;

  if found then
    if v_row.min_pct > v_row.prev_max + 0.01 then
      -- AC2's sentence: 70-79 beside 80-100 names 79.00-80.00.
      return format('grading bands leave %s-%s uncovered', v_row.prev_max, v_row.min_pct);
    end if;
    return format('grading bands %s and %s overlap between %s and %s',
                  v_row.prev_label, v_row.grade_label, v_row.min_pct, v_row.prev_max);
  end if;

  return null;
end;
$$;

comment on function app.fn_grading_band_coverage_error(jsonb) is
  'FR-J01 AC2: null when the bands cover 0.00-100.00 with no gap or overlap, else the sentence to refuse with.';

-- Read by v_grading_scheme, which is SECURITY INVOKER, so the caller needs it.
grant execute on function app.fn_grading_band_coverage_error(jsonb) to authenticated;

-- The FR's fn_validate_grading_bands, asking the rule above of what is stored.
-- SECURITY DEFINER, so the tenant scope is written out in SQL — a definer
-- function owned by postgres bypasses RLS entirely (FR-K24's finding).
create or replace function public.fn_validate_grading_bands(p_scheme_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_bands     jsonb;
  v_error     text;
begin
  select tenant_id into v_tenant_id from public.grading_scheme where id = p_scheme_id;
  if v_tenant_id is null then
    raise exception 'GRADING_SCHEME_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_tenant_id() is not null and v_tenant_id <> app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select coalesce(
           jsonb_agg(jsonb_build_object('grade_label', b.grade_label,
                                        'min_pct', b.min_pct,
                                        'max_pct', b.max_pct)
                     order by b.min_pct),
           '[]'::jsonb)
    into v_bands
    from public.grading_band b
   where b.scheme_id = p_scheme_id;

  v_error := app.fn_grading_band_coverage_error(v_bands);
  if v_error is not null then
    raise exception '%', v_error using errcode = '23514';
  end if;
  return true;
end;
$$;

revoke execute on function public.fn_validate_grading_bands(uuid) from public, anon;
grant execute on function public.fn_validate_grading_bands(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The lookup FR-J02 grades with
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY INVOKER on purpose: grading_band's RLS is the tenant filter, and a
-- definer function here would need to restate it for no gain. Called from
-- inside FR-J02's definer compute path it runs as the owner, which is the
-- intended path — that path has already resolved the section and the scheme.
--
-- The round() is not a convenience. It is the guarantee that the grade and the
-- printed percentage are derived from the same number: 32.995 grades as 33.00,
-- the value a report card would show, rather than falling into the band below
-- the boundary it prints as being on.
create or replace function public.fn_grade_for_percentage(
  p_scheme_id uuid,
  p_pct       numeric
)
returns public.grading_band
language sql
stable
set search_path = ''
as $$
  select b.*
    from public.grading_band b
   where b.scheme_id = p_scheme_id
     and p_pct is not null
     and round(p_pct, 2) between b.min_pct and b.max_pct
   limit 1;
$$;

revoke execute on function public.fn_grade_for_percentage(uuid, numeric) from public, anon;
grant execute on function public.fn_grade_for_percentage(uuid, numeric) to authenticated;

comment on function public.fn_grade_for_percentage(uuid, numeric) is
  'FR-J01: the band a percentage falls in. Rounds to two decimals first, so the graded number and the printed number are the same number.';

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: which board a section is graded on
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.fn_campus_board(p_campus_id uuid)
returns public.board
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select (s.value #>> '{}')::public.board
       from public.campus_setting s
      where s.campus_id = p_campus_id and s.key = 'board'),
    'FBISE'::public.board
  );
$$;

comment on function app.fn_campus_board(uuid) is
  'FR-J01 AC3: the campus''s board, in the same campus_setting store FR-I12 put mark_precision in. FBISE is the federal default.';

create or replace function public.set_campus_board(p_campus_id uuid, p_board public.board)
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
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.campus_setting (campus_id, key, value)
  values (p_campus_id, 'board', to_jsonb(p_board::text))
  on conflict (campus_id, key) do update set value = excluded.value;
end;
$$;

revoke execute on function public.set_campus_board(uuid, public.board) from public, anon;
grant execute on function public.set_campus_board(uuid, public.board) to authenticated;

-- The section's stream carries the board where one exists — an O-Level
-- section and a Matric section of the same Class 9 differ exactly there — and
-- the campus answers for a section with no stream.
create or replace function app.fn_board_for_section(p_section_id uuid)
returns public.board
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_sec record;
  v_board public.board;
begin
  select sec.campus_id, sec.stream_id into v_sec
    from public.class_section sec where sec.id = p_section_id;
  if v_sec.campus_id is null then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_sec.stream_id is not null then
    select st.board into v_board from public.stream st where st.id = v_sec.stream_id;
    if v_board is not null then
      return v_board;
    end if;
  end if;

  return app.fn_campus_board(v_sec.campus_id);
end;
$$;

-- The resolution AC3 turns on. Newest scheme whose effective_from is on or
-- before the date the result belongs to — which is the SESSION's date, not
-- today's, so recomputing a 2023 term in 2026 still resolves 2023's scale.
create or replace function app.fn_grading_scheme_for_board(
  p_tenant_id uuid,
  p_board     public.board,
  p_on_date   date
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select gs.id
    from public.grading_scheme gs
   where gs.tenant_id = p_tenant_id
     and gs.board = p_board
     and gs.status = 'active'
     and gs.effective_from <= p_on_date
   order by gs.effective_from desc, gs.version desc
   limit 1;
$$;

create or replace function public.fn_grading_scheme_for_section(
  p_section_id uuid,
  p_on_date    date default null
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_sec  record;
  v_date date;
begin
  select sec.tenant_id, sec.campus_id, sec.session_id into v_sec
    from public.class_section sec where sec.id = p_section_id;
  if v_sec.tenant_id is null then
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

  v_date := coalesce(
    p_on_date,
    (select s.starts_on from public.academic_session s where s.id = v_sec.session_id),
    current_date
  );

  return app.fn_grading_scheme_for_board(
    v_sec.tenant_id, app.fn_board_for_section(p_section_id), v_date
  );
end;
$$;

revoke execute on function public.fn_grading_scheme_for_section(uuid, date) from public, anon;
grant execute on function public.fn_grading_scheme_for_section(uuid, date) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: an activated scale does not move
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY INVOKER, exactly as FR-I16's append-only guards: current_user must
-- report the executing context, so "the caller is the table owner" means "we
-- are inside a definer function" and not "a logged-in role". Held by a trigger
-- rather than a policy so service_role and the owner are refused too.
create or replace function app.tg_grading_band_frozen()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_scheme uuid := case when tg_op = 'DELETE' then old.scheme_id else new.scheme_id end;
  v_status public.grading_scheme_status;
  v_name   text;
  v_ver    integer;
begin
  select status, name, version into v_status, v_name, v_ver
    from public.grading_scheme where id = v_scheme;

  if v_status is not null and v_status <> 'draft' then
    raise exception 'grading scheme is in use — create a new effective-dated version to change a band'
      using errcode = '42501',
            detail = format('%s on grading_band of scheme "%s" v%s (%s) by %s',
                            tg_op, v_name, v_ver, v_status, current_user),
            hint = 'Editing an active band would re-grade every result already computed against it.';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger trg_grading_band_frozen
  before insert or update or delete on public.grading_band
  for each row execute function app.tg_grading_band_frozen();

-- TRUNCATE fires no row trigger and consults no policy (FR-T08's finding).
create or replace function app.tg_grading_band_no_truncate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'grading bands cannot be truncated'
    using errcode = '42501',
          detail = format('truncate of grading_band by %s', current_user),
          hint = 'Every scale this school ever graded against stays readable.';
end;
$$;

create trigger trg_grading_band_no_truncate
  before truncate on public.grading_band
  for each statement execute function app.tg_grading_band_no_truncate();

-- A scheme's identity may not move once it is active either: changing the
-- board or the effective date of a live scale re-points every future
-- resolution at a scale nobody chose. Status and activated_at are what move.
create or replace function app.tg_grading_scheme_frozen()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status = 'draft' then
    return new;
  end if;
  if new.board is distinct from old.board
     or new.effective_from is distinct from old.effective_from
     or new.version is distinct from old.version
     or new.supersedes_id is distinct from old.supersedes_id then
    raise exception 'grading scheme is in use — create a new effective-dated version to change it'
      using errcode = '42501',
            detail = format('update of grading_scheme %s (%s) by %s', old.id, old.status, current_user);
  end if;
  return new;
end;
$$;

create trigger trg_grading_scheme_frozen
  before update on public.grading_scheme
  for each row execute function app.tg_grading_scheme_frozen();

-- ═══════════════════════════════════════════════════════════════════════
-- Writers
-- ═══════════════════════════════════════════════════════════════════════

-- The whole band set in one call, for the same reason FR-I02's
-- upsert_exam_subject() writes a component set whole: a scale only means
-- anything once every band is present, and a half-applied edit leaves a
-- boundary nobody chose.
--
-- p_bands: array of {grade_label, min_pct, max_pct, gpa_point?, is_pass?,
-- remark_en?, remark_ur?}. Order is irrelevant — sequence is assigned from
-- the top band down, the way a board prints its table.
create or replace function public.save_grading_scheme(
  p_board          public.board,
  p_name           text,
  p_effective_from date,
  p_bands          jsonb,
  p_scheme_id      uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_error     text;
  v_labels    int;
  v_count     int;
  v_id        uuid;
  v_status    public.grading_scheme_status;
begin
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_name is null or length(btrim(p_name)) = 0 then
    raise exception 'SCHEME_NAME_REQUIRED' using errcode = '23514';
  end if;
  if p_effective_from is null then
    raise exception 'EFFECTIVE_FROM_REQUIRED' using errcode = '23514';
  end if;

  select count(*)::int, count(distinct (b.value->>'grade_label'))::int
    into v_count, v_labels
    from jsonb_array_elements(coalesce(p_bands, '[]'::jsonb)) b;
  if v_count > 0 and v_labels <> v_count then
    raise exception 'GRADE_LABEL_DUPLICATED' using errcode = '23514',
      detail = 'Two bands of one scheme cannot carry the same grade.';
  end if;

  -- AC2, refused before a single row is written.
  v_error := app.fn_grading_band_coverage_error(p_bands);
  if v_error is not null then
    raise exception '%', v_error using errcode = '23514';
  end if;

  if p_scheme_id is not null then
    select status into v_status
      from public.grading_scheme
     where id = p_scheme_id and tenant_id = v_tenant_id;
    if v_status is null then
      raise exception 'GRADING_SCHEME_NOT_FOUND' using errcode = 'P0002';
    end if;
    -- Raised ahead of trg_grading_band_frozen so the caller gets the sentence
    -- rather than a trigger-wrapped one.
    if v_status <> 'draft' then
      raise exception 'grading scheme is in use — create a new effective-dated version to change a band'
        using errcode = '42501',
              hint = 'Call new_grading_scheme_version() to carry these bands into a new version.';
    end if;
    update public.grading_scheme
       set board = p_board, name = btrim(p_name), effective_from = p_effective_from
     where id = p_scheme_id
    returning id into v_id;
    delete from public.grading_band where scheme_id = v_id;
  else
    insert into public.grading_scheme (tenant_id, board, name, effective_from, created_by)
    values (v_tenant_id, p_board, btrim(p_name), p_effective_from, (select auth.uid()))
    returning id into v_id;
  end if;

  insert into public.grading_band (
    tenant_id, scheme_id, min_pct, max_pct, grade_label, gpa_point, is_pass,
    remark_en, remark_ur, sequence
  )
  select v_tenant_id,
         v_id,
         (b.value->>'min_pct')::numeric(5,2),
         (b.value->>'max_pct')::numeric(5,2),
         btrim(b.value->>'grade_label'),
         nullif(b.value->>'gpa_point', '')::numeric(3,2),
         coalesce((b.value->>'is_pass')::boolean, true),
         nullif(b.value->>'remark_en', ''),
         nullif(b.value->>'remark_ur', ''),
         (row_number() over (order by (b.value->>'min_pct')::numeric(5,2) desc))::smallint
    from jsonb_array_elements(p_bands) b;

  return v_id;
end;
$$;

revoke execute on function public.save_grading_scheme(public.board, text, date, jsonb, uuid)
  from public, anon;
grant execute on function public.save_grading_scheme(public.board, text, date, jsonb, uuid)
  to authenticated;

-- AC1: "when the scheme is saved, then validation passes and the scheme
-- becomes assignable". Activation is what makes it resolvable, and it
-- re-validates what is actually stored rather than trusting the save.
create or replace function public.activate_grading_scheme(p_scheme_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_scheme    record;
begin
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select id, status into v_scheme
    from public.grading_scheme
   where id = p_scheme_id and tenant_id = v_tenant_id;
  if v_scheme.id is null then
    raise exception 'GRADING_SCHEME_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_scheme.status = 'active' then
    return v_scheme.id;
  end if;
  if v_scheme.status = 'retired' then
    raise exception 'GRADING_SCHEME_RETIRED' using errcode = '23514';
  end if;

  perform public.fn_validate_grading_bands(p_scheme_id);

  update public.grading_scheme
     set status = 'active', activated_at = now()
   where id = p_scheme_id;

  return p_scheme_id;
end;
$$;

revoke execute on function public.activate_grading_scheme(uuid) from public, anon;
grant execute on function public.activate_grading_scheme(uuid) to authenticated;

-- AC4's "a new effective-dated version is created". The bands come across as
-- a draft so the boundary that prompted the version can be edited; the
-- original stays active and stays the answer for every date before the new
-- effective_from.
create or replace function public.new_grading_scheme_version(
  p_scheme_id      uuid,
  p_effective_from date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_old       record;
  v_id        uuid;
begin
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select id, board, name, version, effective_from, status
    into v_old
    from public.grading_scheme
   where id = p_scheme_id and tenant_id = v_tenant_id;
  if v_old.id is null then
    raise exception 'GRADING_SCHEME_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_effective_from is null or p_effective_from <= v_old.effective_from then
    raise exception 'EFFECTIVE_FROM_NOT_LATER' using errcode = '23514',
      detail = format('A new version must start after %s, when v%s took effect.',
                      v_old.effective_from, v_old.version);
  end if;

  insert into public.grading_scheme (
    tenant_id, board, name, effective_from, version, supersedes_id, created_by
  )
  values (
    v_tenant_id, v_old.board, v_old.name, p_effective_from,
    (select max(version) + 1 from public.grading_scheme
      where tenant_id = v_tenant_id and board = v_old.board),
    v_old.id, (select auth.uid())
  )
  returning id into v_id;

  insert into public.grading_band (
    tenant_id, scheme_id, min_pct, max_pct, grade_label, gpa_point, is_pass,
    remark_en, remark_ur, sequence
  )
  select v_tenant_id, v_id, b.min_pct, b.max_pct, b.grade_label, b.gpa_point,
         b.is_pass, b.remark_en, b.remark_ur, b.sequence
    from public.grading_band b
   where b.scheme_id = p_scheme_id;

  return v_id;
end;
$$;

revoke execute on function public.new_grading_scheme_version(uuid, date) from public, anon;
grant execute on function public.new_grading_scheme_version(uuid, date) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- What the configuration screen reads
-- ═══════════════════════════════════════════════════════════════════════

create view public.v_grading_scheme
with (security_invoker = true) as
select gs.id,
       gs.tenant_id,
       gs.board,
       gs.name,
       gs.effective_from,
       gs.version,
       gs.status,
       gs.supersedes_id,
       gs.activated_at,
       gs.created_at,
       coalesce(b.band_count, 0)                     as band_count,
       coalesce(b.bands, '[]'::jsonb)                as bands,
       app.fn_grading_band_coverage_error(coalesce(b.bands, '[]'::jsonb)) as coverage_error
  from public.grading_scheme gs
  left join lateral (
    select count(*)::int as band_count,
           jsonb_agg(jsonb_build_object(
             'id',          gb.id,
             'grade_label', gb.grade_label,
             'min_pct',     gb.min_pct,
             'max_pct',     gb.max_pct,
             'gpa_point',   gb.gpa_point,
             'is_pass',     gb.is_pass,
             'remark_en',   gb.remark_en,
             'remark_ur',   gb.remark_ur,
             'sequence',    gb.sequence
           ) order by gb.sequence) as bands
      from public.grading_band gb
     where gb.scheme_id = gs.id
  ) b on true;

revoke all on public.v_grading_scheme from public, anon;
grant select on public.v_grading_scheme to authenticated;

comment on view public.v_grading_scheme is
  'FR-J01: one row per scheme with its bands and, for a draft, the coverage error still to fix.';

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.grading_scheme enable row level security;
alter table public.grading_band enable row level security;

-- The FR's grading_scheme_tenant_scope. A grade scale is tenant-wide, not
-- per-campus: it is the board's, and every campus sitting that board grades
-- on it. Parents read it because a report card prints the band remark.
create policy grading_scheme_tenant_scope on public.grading_scheme
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create policy grading_band_tenant_scope on public.grading_band
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

-- FR-T08's argument, kept: a caller who can read a band should be TOLD why it
-- will not move, rather than handed a silent `UPDATE 0` by an absent policy.
-- USING is the SELECT predicate verbatim, so no row is offered that the caller
-- could not already read, and WITH CHECK is false because save_grading_scheme()
-- and activate_grading_scheme() are the only legal writers. An active band
-- reaches trg_grading_band_frozen and gets its sentence; a draft one is refused
-- by the policy. INSERT and DELETE get no policy and stay denied outright.
create policy grading_band_no_direct_update on public.grading_band
  for update to authenticated
  using (tenant_id = app.auth_tenant_id())
  with check (false);

create policy grading_scheme_no_direct_update on public.grading_scheme
  for update to authenticated
  using (tenant_id = app.auth_tenant_id())
  with check (false);
