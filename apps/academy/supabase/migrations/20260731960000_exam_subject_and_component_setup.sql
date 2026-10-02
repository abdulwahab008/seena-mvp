-- FR-I02: exam subject and component setup.
--
-- "As an Exam Controller, I want to set max and pass marks per component
-- for each class-subject in a term, so that mark entry and pass/fail logic
-- have an unambiguous denominator."
--
-- Builds directly on FR-I01 (20260731950000): an exam subject is always a
-- subject configured FOR a term, and the term is what carries the campus,
-- the session and the weightage it rolls up into.
--
-- ── "group_id" is public.stream, and it already exists ─────────────────
--
-- The FR's suggested index is
--   uq_exam_subject (tenant_id, campus_id, exam_term_id, class_id,
--                    group_id, subject_id)
-- and AC1 is written about "Class 9 Pre-Medical Biology", so streams
-- genuinely matter. They also genuinely exist: FR-E05 shipped
-- public.stream (Pre-Medical / Pre-Engineering, keyed to a board and an
-- applies_from_ordinal), FR-E06 shipped public.class_subject carrying
-- (session_id, campus_id, class_level_id, stream_id, subject_id) with
-- uq_class_subject over exactly that tuple, and FR-E02's class_section
-- carries its own stream_id.
--
-- So five of the six columns the FR names are already one table, already
-- unique over that tuple, already the thing the curriculum screen writes,
-- and already the definition of "this subject is offered to this class".
-- exam_subject therefore points at a class_subject row rather than
-- re-listing class_level_id / stream_id / subject_id beside it:
--
--   * duplicating the tuple gives it somewhere to disagree — an
--     exam_subject naming (Class 9, Pre-Medical, Biology) with no matching
--     curriculum row is a configuration for a subject the class does not
--     take, and nothing would have caught it.
--   * the FK makes AC4's "no configuration exists for Class 9 Computer
--     Science" answerable in one join instead of a five-column lookup.
--   * uq_exam_subject (exam_term_id, class_subject_id) is the FR's index
--     with the redundancy factored out: exam_term supplies tenant_id and
--     campus_id, class_subject supplies class, stream and subject.
--
-- tenant_id and campus_id ARE still stored on exam_subject, because every
-- RLS policy in this schema filters on them directly and a policy that had
-- to join two tables to find the campus would be both slower and easier to
-- get wrong. upsert_exam_subject() writes them from the exam term and
-- checks the class_subject agrees, so they cannot drift.
--
-- ── AC3: sections inherit because there is nothing to inherit ──────────
--
-- "Class 10 has three sections... configured ONCE at class level, all three
-- inherit with no further setup" is satisfied structurally, not by a copy
-- step: class_subject is keyed on class_level_id and has no section_id at
-- all, so there is exactly one configuration per (term, class, stream,
-- subject) and every section of that class resolves to it.
-- v_exam_section_subject_setup below is that resolution written down — it
-- is what a mark-entry grid queries, and it is asserted in pgTAP across
-- three sections of one class.
--
-- ── AC1/AC2: marks are integers, and pass <= max is enforced twice ─────
--
-- max_marks/pass_marks are int, matching subject.default_max_marks and
-- class_subject.max_marks, which are already int. Half marks are not
-- representable and that is the existing schema's decision, not a new one.
--
-- chk_pass_le_max is a CHECK constraint so no path can write pass > max,
-- and upsert_exam_subject() raises the acceptance criteria's own sentence,
-- 'pass marks cannot exceed maximum marks', BEFORE the constraint would
-- fire a generic violation — the same explicit-check-ahead-of-the-backstop
-- shape as upsert_class_subject()'s WEEKLY_PERIODS_REQUIRED. It is raised
-- with errcode 23514, which PostgREST maps to 400 with the message intact
-- (unlike SQLSTATE class 55, which it replaces with "Something went
-- wrong" — see FR-I01's migration for that finding).
--
-- ── AC4: the readiness check, and what is honestly a stub ──────────────
--
-- FR-I12 (teacher mark entry) does not exist. There is no grid to disable,
-- and this migration does not build one and call it FR-I12.
--
-- What it builds is the question that grid has to ask, as a real, queryable
-- function with the acceptance criteria's exact wording:
--
--   fn_exam_entry_readiness(p_exam_term_id, p_section_id, p_subject_id)
--     -> {"ready": false, "message": "exam setup pending — contact the
--         exam office", "components": [], ...}
--
-- The signature is the teacher's, not the controller's — a teacher opens
-- mark entry holding a section and a subject, and the function resolves
-- that to the class-level class_subject row itself. That is the same
-- resolution AC3 relies on, so one function answers both criteria.
--
-- REAL here: the function, the component list it returns, the total max,
-- and the RLS/campus scoping around them. STUBBED pending FR-I12: the only
-- surface that renders the result today is a read-only preview panel on the
-- FR-I02 setup screen. It draws the component columns AC1 describes and
-- shows AC4's disabled state, and it cannot save a mark, because there is
-- nowhere to save one.
--
-- ── Editing a configuration after results are locked ───────────────────
--
-- A component set is the denominator of every mark entered against it, so
-- it is frozen by the same predicate FR-I01 uses for weightage —
-- app.fn_exam_term_weight_frozen(exam_term_id) — rather than by a second,
-- differently-shaped rule. When FR-I16 starts calling lock_exam_term(),
-- component edits shut at exactly the same moment weightage edits do.

-- ═══════════════════════════════════════════════════════════════════════
-- Schema
-- ═══════════════════════════════════════════════════════════════════════

create type public.mark_component_code as enum ('theory', 'practical', 'internal', 'project', 'viva');

create table public.exam_subject (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  exam_term_id    uuid not null references public.exam_term(id) on delete cascade,
  -- Carries class_level_id, stream_id ("group") and subject_id — see the
  -- header for why they are not repeated here.
  class_subject_id uuid not null references public.class_subject(id) on delete cascade,
  created_at      timestamptz not null default now()
);

create unique index uq_exam_subject on public.exam_subject (exam_term_id, class_subject_id);
create index idx_exam_subject_term_campus on public.exam_subject (exam_term_id, campus_id);
create index idx_exam_subject_class_subject on public.exam_subject (class_subject_id);

create table public.exam_subject_component (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  exam_subject_id uuid not null references public.exam_subject(id) on delete cascade,
  component       public.mark_component_code not null,
  max_marks       integer not null,
  pass_marks      integer not null,
  sequence        smallint not null,
  created_at      timestamptz not null default now(),
  constraint chk_pass_le_max check (pass_marks <= max_marks),
  constraint chk_max_marks_positive check (max_marks > 0 and max_marks <= 1000),
  constraint chk_pass_marks_nonneg check (pass_marks >= 0)
);

-- A subject cannot carry two "practical" components: the grid would have
-- two columns with the same heading and no way to tell the marks apart.
create unique index uq_exam_subject_component on public.exam_subject_component (exam_subject_id, component);
create unique index uq_exam_subject_component_seq on public.exam_subject_component (exam_subject_id, sequence);

create trigger exam_subject_audit after insert or update or delete on public.exam_subject
  for each row execute function app.tg_audit_row();
create trigger exam_subject_component_audit after insert or update or delete on public.exam_subject_component
  for each row execute function app.tg_audit_row();

comment on table public.exam_subject is
  'FR-I02: one class-subject configured for one exam term. The class, stream/group and subject come from class_subject_id.';
comment on column public.exam_subject_component.max_marks is
  'The denominator for this component. fn_exam_subject_total_max() sums these — AC1''s theory 65 + practical 20 = 85.';

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: the total max
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY DEFINER so the mark-entry path can read it without a policy
-- round trip, with the tenant/campus scope written out explicitly — a
-- SECURITY DEFINER function owned by postgres bypasses RLS, so leaving the
-- filter to a policy would leave no filter at all (FR-K24's finding).
create or replace function public.fn_exam_subject_total_max(p_exam_subject_id uuid)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_campus_id uuid;
  v_tenant_id uuid;
  v_total     integer;
begin
  select tenant_id, campus_id into v_tenant_id, v_campus_id
    from public.exam_subject where id = p_exam_subject_id;
  if v_tenant_id is null then
    return null;
  end if;

  if app.auth_tenant_id() is not null then
    if v_tenant_id <> app.auth_tenant_id() then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if app.auth_role() not in ('super_admin', 'owner')
       and not (v_campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  select sum(max_marks)::integer into v_total
    from public.exam_subject_component
   where exam_subject_id = p_exam_subject_id;

  return v_total;
end;
$$;

revoke execute on function public.fn_exam_subject_total_max(uuid) from public, anon;
grant execute on function public.fn_exam_subject_total_max(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Writers
-- ═══════════════════════════════════════════════════════════════════════

-- Saves a class-subject's whole component set for one term in one call.
-- The set is written as a whole rather than component by component because
-- the total max only means anything once every component is present, and a
-- half-applied edit would leave a denominator nobody chose.
--
-- p_components: jsonb array of {component, max_marks, pass_marks}, in the
-- order the grid should render its columns.
create or replace function public.upsert_exam_subject(
  p_exam_term_id     uuid,
  p_class_subject_id uuid,
  p_components       jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_term       record;
  v_cs         record;
  v_examinable boolean;
  v_count      int;
  v_distinct   int;
  v_bad        record;
  v_id         uuid;
begin
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select id, campus_id, session_id into v_term
    from public.exam_term
   where id = p_exam_term_id and tenant_id = v_tenant_id;
  if v_term.id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner')
     and not (v_term.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select id, campus_id, session_id, subject_id into v_cs
    from public.class_subject
   where id = p_class_subject_id and tenant_id = v_tenant_id;
  if v_cs.id is null then
    raise exception 'CLASS_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  -- The curriculum row and the exam term have to be talking about the same
  -- campus and the same year, or the configuration means nothing.
  if v_cs.campus_id <> v_term.campus_id or v_cs.session_id <> v_term.session_id then
    raise exception 'CLASS_SUBJECT_TERM_MISMATCH' using errcode = '23514',
      detail = 'The class-subject and the exam term belong to different campuses or sessions.';
  end if;

  select is_examinable into v_examinable from public.subject where id = v_cs.subject_id;
  if not v_examinable then
    raise exception 'SUBJECT_NOT_EXAMINABLE' using errcode = '23514';
  end if;

  -- Once results ride on this denominator it stops being setup. Same
  -- predicate as FR-I01's weightage freeze, deliberately.
  if app.fn_exam_term_weight_frozen(p_exam_term_id) then
    raise exception 'exam setup is locked by approved marks — raise a result-recompute request'
      using errcode = '42501';
  end if;

  if p_components is null or jsonb_typeof(p_components) <> 'array' then
    raise exception 'COMPONENTS_REQUIRED' using errcode = '23514';
  end if;

  select count(*), count(distinct (c->>'component'))
    into v_count, v_distinct
    from jsonb_array_elements(p_components) as c;

  if v_count < 1 then
    raise exception 'COMPONENTS_REQUIRED' using errcode = '23514',
      detail = 'A subject needs at least one component before marks can be entered against it.';
  end if;
  if v_distinct <> v_count then
    raise exception 'COMPONENT_DUPLICATED' using errcode = '23514';
  end if;

  -- AC2, in the acceptance criteria's own words, ahead of chk_pass_le_max.
  select (c->>'component') as component,
         (c->>'max_marks')::int as max_marks,
         (c->>'pass_marks')::int as pass_marks
    into v_bad
    from jsonb_array_elements(p_components) as c
   where (c->>'pass_marks')::int > (c->>'max_marks')::int
   limit 1;
  if found then
    raise exception 'pass marks cannot exceed maximum marks'
      using errcode = '23514',
            detail = format('%s: pass %s of a maximum of %s',
                            v_bad.component, v_bad.pass_marks, v_bad.max_marks);
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_components) as c
     where (c->>'max_marks')::int <= 0 or (c->>'pass_marks')::int < 0
  ) then
    raise exception 'MARKS_OUT_OF_RANGE' using errcode = '23514',
      detail = 'Maximum marks must be above zero and pass marks cannot be negative.';
  end if;

  insert into public.exam_subject (tenant_id, campus_id, exam_term_id, class_subject_id)
  values (v_tenant_id, v_term.campus_id, p_exam_term_id, p_class_subject_id)
  on conflict (exam_term_id, class_subject_id) do update set exam_term_id = excluded.exam_term_id
  returning id into v_id;

  delete from public.exam_subject_component where exam_subject_id = v_id;

  insert into public.exam_subject_component (
    tenant_id, exam_subject_id, component, max_marks, pass_marks, sequence
  )
  select v_tenant_id,
         v_id,
         (c.value->>'component')::public.mark_component_code,
         (c.value->>'max_marks')::int,
         (c.value->>'pass_marks')::int,
         c.ordinality::smallint
    from jsonb_array_elements(p_components) with ordinality as c(value, ordinality);

  return v_id;
end;
$$;

revoke execute on function public.upsert_exam_subject(uuid, uuid, jsonb) from public, anon;
grant execute on function public.upsert_exam_subject(uuid, uuid, jsonb) to authenticated;

create or replace function public.delete_exam_subject(p_exam_subject_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_campus_id uuid;
  v_term_id   uuid;
begin
  if v_tenant_id is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select campus_id, exam_term_id into v_campus_id, v_term_id
    from public.exam_subject
   where id = p_exam_subject_id and tenant_id = v_tenant_id;
  if v_campus_id is null then
    raise exception 'EXAM_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner')
     and not (v_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.fn_exam_term_weight_frozen(v_term_id) then
    raise exception 'exam setup is locked by approved marks — raise a result-recompute request'
      using errcode = '42501';
  end if;

  delete from public.exam_subject where id = p_exam_subject_id;
end;
$$;

revoke execute on function public.delete_exam_subject(uuid) from public, anon;
grant execute on function public.delete_exam_subject(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the resolution every section of a class shares
-- ═══════════════════════════════════════════════════════════════════════

-- One row per (section, exam term, class-subject the section takes),
-- carrying whether it is configured and what its grid would look like.
-- A stream-less curriculum row (compulsory subjects) applies to every
-- section of the class; a stream-specific one only to the sections in that
-- stream — the same rule FR-E06's uq_class_subject encodes.
create view public.v_exam_section_subject_setup
with (security_invoker = true) as
select
  sec.id                    as section_id,
  sec.name                  as section_name,
  sec.class_level_id,
  sec.stream_id             as section_stream_id,
  t.id                      as exam_term_id,
  t.code                    as exam_term_code,
  cs.id                     as class_subject_id,
  cs.subject_id,
  cs.stream_id              as class_subject_stream_id,
  sec.tenant_id,
  sec.campus_id,
  es.id                     as exam_subject_id,
  es.id is not null         as is_configured,
  comp.component_count,
  comp.total_max_marks
from public.class_section sec
join public.exam_term t
  on t.tenant_id = sec.tenant_id
 and t.campus_id = sec.campus_id
 and t.session_id = sec.session_id
join public.class_subject cs
  on cs.tenant_id = sec.tenant_id
 and cs.campus_id = sec.campus_id
 and cs.session_id = sec.session_id
 and cs.class_level_id = sec.class_level_id
 and (cs.stream_id is null or cs.stream_id = sec.stream_id)
left join public.exam_subject es
  on es.exam_term_id = t.id
 and es.class_subject_id = cs.id
left join lateral (
  select count(*)::int as component_count, sum(c.max_marks)::int as total_max_marks
    from public.exam_subject_component c
   where c.exam_subject_id = es.id
) comp on true
where sec.is_active;

revoke all on public.v_exam_section_subject_setup from public, anon;
grant select on public.v_exam_section_subject_setup to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: "exam setup pending — contact the exam office"
-- ═══════════════════════════════════════════════════════════════════════

-- The question FR-I12's grid has to ask before it renders anything. See the
-- header for what is real and what is waiting on FR-I12.
create or replace function public.fn_exam_entry_readiness(
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
  v_sec        record;
  v_term       record;
  v_cs_id      uuid;
  v_es_id      uuid;
  v_components jsonb;
  v_total      integer;
begin
  select id, tenant_id, campus_id, session_id, class_level_id, stream_id
    into v_sec
    from public.class_section
   where id = p_section_id;
  if v_sec.id is null then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Explicit, because SECURITY DEFINER means RLS will not do it here.
  if app.auth_tenant_id() is not null then
    if v_sec.tenant_id <> app.auth_tenant_id() then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if app.auth_role() not in ('super_admin', 'owner')
       and not (v_sec.campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  select id, campus_id, session_id into v_term
    from public.exam_term
   where id = p_exam_term_id and tenant_id = v_sec.tenant_id;
  if v_term.id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- AC3: the section resolves to its CLASS's curriculum row. Three sections
  -- of Class 10 resolve to the same one, which is why configuring it once
  -- is enough. A stream-specific row wins over the stream-less one when the
  -- section is in that stream.
  select cs.id into v_cs_id
    from public.class_subject cs
   where cs.tenant_id = v_sec.tenant_id
     and cs.campus_id = v_sec.campus_id
     and cs.session_id = v_sec.session_id
     and cs.class_level_id = v_sec.class_level_id
     and cs.subject_id = p_subject_id
     and (cs.stream_id is null or cs.stream_id = v_sec.stream_id)
   order by (cs.stream_id is null)
   limit 1;

  if v_cs_id is not null then
    select es.id into v_es_id
      from public.exam_subject es
     where es.exam_term_id = p_exam_term_id and es.class_subject_id = v_cs_id;
  end if;

  if v_es_id is not null then
    select jsonb_agg(
             jsonb_build_object(
               'component', c.component,
               'max_marks', c.max_marks,
               'pass_marks', c.pass_marks,
               'sequence', c.sequence
             ) order by c.sequence
           ),
           sum(c.max_marks)::integer
      into v_components, v_total
      from public.exam_subject_component c
     where c.exam_subject_id = v_es_id;
  end if;

  if v_components is null or jsonb_array_length(v_components) = 0 then
    return jsonb_build_object(
      'ready', false,
      -- AC4 asserts this wording.
      'message', 'exam setup pending — contact the exam office',
      'exam_subject_id', null,
      'class_subject_id', v_cs_id,
      'total_max_marks', null,
      'components', '[]'::jsonb
    );
  end if;

  return jsonb_build_object(
    'ready', true,
    'message', null,
    'exam_subject_id', v_es_id,
    'class_subject_id', v_cs_id,
    'total_max_marks', v_total,
    'components', v_components
  );
end;
$$;

revoke execute on function public.fn_exam_entry_readiness(uuid, uuid, uuid) from public, anon;
grant execute on function public.fn_exam_entry_readiness(uuid, uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.exam_subject enable row level security;
alter table public.exam_subject_component enable row level security;

create policy exam_subject_campus_scope on public.exam_subject
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- The parent's campus rule, restated rather than left to nested RLS on the
-- subquery — the same shape as subject_board_code_tenant_read, and the
-- explicit-filter discipline FR-K24's finding argues for.
create policy exam_subject_component_campus_scope on public.exam_subject_component
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and exam_subject_id in (
      select id from public.exam_subject
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );
