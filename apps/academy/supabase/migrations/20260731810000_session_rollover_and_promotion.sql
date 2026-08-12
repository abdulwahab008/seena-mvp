-- FR-A06: session rollover and promotion engine.
--
-- "As a Principal, I want to roll the whole school into the next academic
-- session in one run with per-student promote/retain/pass-out decisions,
-- so that I do not re-enrol 1,200 students by hand every April."
--
-- Prior art this migration builds on rather than duplicates:
--   * class_level.sql's own comment already committed to the design:
--     "Ordinal, not code, drives the promotion path" — the target class for
--     a 'promote' decision is whichever class_level has ordinal = source
--     ordinal + 1, exactly, not "the next active class at any ordinal".
--     class_level has no DELETE path (is_active=false is how a tenant
--     "removes" one), so "class 10 has no class 11 defined" is modelled the
--     same way every other migration in this schema models "doesn't exist
--     for this tenant": is_active=false.
--   * arrears_carry_forward.sql (FR-K24) already added
--     enrolment.previous_enrolment_id and said outright: "FR-A06 (session
--     rollover/promotion engine) doesn't exist yet... link_enrolment_
--     promotion() is the real, callable primitive that engine will use once
--     it exists". That function's own role list (super_admin/owner/
--     accountant) doesn't include principal, so this migration does NOT
--     call it — this engine sets previous_enrolment_id directly on the
--     enrolment row it just created, inside its own already-authorized
--     SECURITY DEFINER function, the same way link_enrolment_promotion
--     itself does a bare UPDATE rather than delegating.
--   * academic_structure_rollover.sql (FR-E11) clones class_section/
--     class_subject/teacher allocations into a new session but explicitly
--     never touches enrolment ("promotion is a per-student decision").
--     This engine is that per-student decision — it assumes the target
--     session's class_section rows already exist (via clone_academic_
--     structure or manual create_section), the same dependency FR-E11's
--     own header implies. A class with no active section in the target
--     session behaves the same as a class with no target class level at
--     all: held, not silently dropped (error_code NO_TARGET_SECTION,
--     alongside the AC's own NO_TARGET_CLASS).
--   * soft_delete_business_records.sql (FR-A15) added deleted_at to
--     student/enrolment; both are excluded from the eligible-enrolment scan
--     below, same as generate_challans already does.
--   * student_status_lifecycle.sql (FR-C12) built the legal-transition
--     matrix (student_status_transition) specifically so a status change
--     always has a role check, a reason and a history row. 'active' ->
--     'passed_out' reuses that machinery via fn_change_student_status
--     rather than a bare UPDATE, with reason_code 'graduation' (an
--     existing value — no new reason code needed, only a new status; see
--     the previous migration). A symmetric 'passed_out' -> 'active'
--     readmission path is added for consistency with every other terminal
--     status in that same seed data (graduated/struck_off/transferred all
--     have one).
--
-- Terminal-class default, not in the AC's own words but required for the
-- AC's NO_TARGET_CLASS scenario to make sense at all: a class whose
-- ordinal+1 doesn't exist defaults to 'hold'/NO_TARGET_CLASS only when a
-- HIGHER ordinal class exists somewhere for the tenant (a genuine gap in
-- the catalogue, the AC's own "class 10 has no class 11" scenario). When
-- the source class is the tenant's actual highest active class level (no
-- higher ordinal exists at all), the default is 'pass_out', not a hold —
-- otherwise every Class 12 student would show up in the exception list on
-- every single rollover, forever, which is not an exception, it is the
-- normal way school ends.
--
-- Resumability, given no real background worker/pg_cron locally (same
-- constraint every other "batch job" FR in this codebase has hit):
-- start_session_rollover() only snapshots the decision set (one row per
-- eligible enrolment, cheap) and returns immediately. execute_rollover_
-- batch(run_id, p_limit) is the actual worker step — it processes up to
-- p_limit not-yet-processed decisions and returns. Each call is its own
-- transaction (an ordinary RPC call, not a sub-transaction of some larger
-- job), so "the job crashes after 1,100 students" is simply "the driver
-- stopped calling execute_rollover_batch after enough calls processed
-- 1,100 rows" — the next call resumes from whatever decision rows still
-- have processed_at is null, with no separate checkpoint bookkeeping
-- needed. The driver itself (repeated calls until status='completed') is
-- the Next.js server action layer here, the same "no cron locally, model
-- it as the app/UI calling the resumable primitive repeatedly" shape this
-- session's other FRs already used (compute_month_attendance, dispatch_
-- absentee_notifications, purge_soft_deleted_records).
--
-- Idempotency (AC: re-running with identical input is a true no-op): NOT
-- implemented as "refuse to run twice". A second start_session_rollover
-- call for the same (campus, from_session, to_session) creates a fresh run
-- and a fresh decision snapshot — but the eligibility scan is `enrolment.
-- status = 'active' AND student.status = 'active'` in from_session, and
-- (a) a student already promoted/retained keeps student.status='active',
-- so they ARE re-scanned, but execute_rollover_batch finds their enrolment
-- already exists in to_session (unique(student_id, session_id)) and marks
-- the decision processed without inserting a second row; (b) a student
-- already passed out now has student.status='passed_out', so the
-- eligibility scan excludes them entirely on the re-run. Either way,
-- created_count stays 0 and the run reports is_no_op=true. No separate
-- "has this already run" check was needed — the same enrolment uniqueness
-- constraint that makes the whole schema idempotent everywhere else
-- (generate_challans, clone_academic_structure) does the work here too.
--
-- Per-decision failure isolation: each decision is processed inside its
-- own BEGIN/EXCEPTION block (same shape as generate_challans' per-
-- enrolment try/catch) so one student hitting SECTION_FULL, or any other
-- unexpected error, holds that one row with the error captured verbatim as
-- error_code rather than aborting the rest of the batch.
--
-- Scope cuts:
--   * Target section within the target class is chosen automatically
--     (least-filled active section, gender-restriction aware — the same
--     greedy rule fn_auto_balance_sections already uses for FR-C02), not
--     exposed as a per-student override in the UI. The AC's own "per-
--     student decision" is promote/retain/pass-out; picking a specific
--     section is a distinct, smaller feature this FR's ACs don't ask for.
--   * Stream selection (e.g. Class 10 -> Class 11 Pre-Medical/Pre-
--     Engineering) is not modelled — the section picker ignores stream_id
--     entirely, same as fn_auto_balance_sections already does.
--   * The engine never flips academic_session.is_current/status — that
--     stays a separate, explicit set_current_session() call (FR-A04),
--     not a side effect of rollover completing.

-- ── types ─────────────────────────────────────────────────────────────

create type public.rollover_run_status as enum ('pending', 'running', 'completed');
create type public.rollover_decision as enum ('promote', 'retain', 'pass_out', 'hold');

-- ── student_status_transition: allow the new terminal status, both ways ─

insert into public.student_status_transition (from_status, to_status, requires_role, requires_document, requires_reason_code) values
  ('active',      'passed_out', 'principal', false, null),
  ('passed_out',  'active',     'principal', false, 'readmission');

-- ── tables ────────────────────────────────────────────────────────────

create table public.session_rollover_run (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               uuid not null references public.tenant(id) on delete cascade,
  campus_id               uuid not null references public.campus(id) on delete cascade,
  from_session_id         uuid not null references public.academic_session(id),
  to_session_id           uuid not null references public.academic_session(id),
  status                  public.rollover_run_status not null default 'pending',
  total_count             int not null default 0,
  processed_count         int not null default 0,
  created_count           int not null default 0,
  already_existing_count  int not null default 0,
  promoted_count          int not null default 0,
  retained_count          int not null default 0,
  passed_out_count        int not null default 0,
  held_count              int not null default 0,
  is_no_op                boolean,
  started_at              timestamptz,
  finished_at             timestamptz,
  started_by              uuid references public.app_user(user_id),
  created_at              timestamptz not null default now(),
  constraint chk_rollover_different_sessions check (from_session_id <> to_session_id)
);

create index idx_rollover_run_campus_to_session on public.session_rollover_run (tenant_id, campus_id, to_session_id);
create index idx_rollover_run_lookup on public.session_rollover_run (tenant_id, campus_id, from_session_id, to_session_id, status);

create table public.session_rollover_decision (
  id                   uuid primary key default gen_random_uuid(),
  run_id               uuid not null references public.session_rollover_run(id) on delete cascade,
  student_id           uuid not null references public.student(id),
  source_enrolment_id  uuid not null references public.enrolment(id),
  decision             public.rollover_decision not null default 'promote',
  target_class_id      uuid references public.class_level(id),
  target_section_id    uuid references public.class_section(id),
  new_enrolment_id     uuid references public.enrolment(id),
  error_code           text,
  processed_at         timestamptz,
  created_at           timestamptz not null default now(),
  unique (run_id, student_id)
);

-- The resumability index: execute_rollover_batch's whole "pick up where it
-- left off" behaviour is this partial index over the unprocessed rows.
create index idx_rollover_decision_pending on public.session_rollover_decision (run_id, created_at) where processed_at is null;
create index idx_rollover_decision_exceptions on public.session_rollover_decision (run_id) where error_code is not null;

create trigger session_rollover_run_audit after insert or update or delete on public.session_rollover_run
  for each row execute function app.tg_audit_row();

-- ── rollover_run_summary: the jsonb progress payload every entry point
--    (start, batch, and the UI's own polling) returns, so all three agree
--    on shape ─────────────────────────────────────────────────────────

create or replace function public.rollover_run_summary(p_run_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'run_id', r.id, 'status', r.status,
    'total_count', r.total_count, 'processed_count', r.processed_count,
    'created_count', r.created_count, 'already_existing_count', r.already_existing_count,
    'promoted_count', r.promoted_count, 'retained_count', r.retained_count,
    'passed_out_count', r.passed_out_count, 'held_count', r.held_count,
    'is_no_op', r.is_no_op, 'started_at', r.started_at, 'finished_at', r.finished_at
  )
  from public.session_rollover_run r
  where r.id = p_run_id
    and r.tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or r.campus_id = any(app.auth_campus_ids()));
$$;

revoke execute on function public.rollover_run_summary(uuid) from public, anon;
grant execute on function public.rollover_run_summary(uuid) to authenticated;

-- ── start_session_rollover: snapshot the decision set, write nothing to
--    student/enrolment yet ──────────────────────────────────────────────

create or replace function public.start_session_rollover(
  p_campus_id uuid, p_from_session_id uuid, p_to_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_run_id        uuid;
  v_existing_run  uuid;
  v_total         int := 0;
  v_enrol         record;
  v_target_class  uuid;
  v_decision      public.rollover_decision;
  v_error_code    text;
  v_has_higher    boolean;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_from_session_id and tenant_id = v_tenant_id) then
    raise exception 'FROM_SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_to_session_id and tenant_id = v_tenant_id) then
    raise exception 'TO_SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_from_session_id = p_to_session_id then
    raise exception 'SAME_SESSION' using errcode = '22023';
  end if;

  -- A run already in flight for this exact tuple is resumed, not
  -- duplicated — protects against a Principal double-clicking "Start"
  -- before the first click's decisions finish generating.
  select id into v_existing_run
    from public.session_rollover_run
   where tenant_id = v_tenant_id and campus_id = p_campus_id
     and from_session_id = p_from_session_id and to_session_id = p_to_session_id
     and status in ('pending', 'running')
   limit 1;
  if v_existing_run is not null then
    return public.rollover_run_summary(v_existing_run);
  end if;

  insert into public.session_rollover_run (tenant_id, campus_id, from_session_id, to_session_id, started_by)
  values (v_tenant_id, p_campus_id, p_from_session_id, p_to_session_id, auth.uid())
  returning id into v_run_id;

  for v_enrol in
    select e.id as enrolment_id, e.student_id, e.class_level_id, cl.ordinal
      from public.enrolment e
      join public.student s on s.id = e.student_id
      join public.class_level cl on cl.id = e.class_level_id
     where e.tenant_id = v_tenant_id and e.campus_id = p_campus_id and e.session_id = p_from_session_id
       and e.status = 'active' and e.deleted_at is null
       and s.status = 'active' and s.deleted_at is null
  loop
    v_target_class := null;
    v_error_code := null;

    select id into v_target_class from public.class_level
     where tenant_id = v_tenant_id and ordinal = v_enrol.ordinal + 1 and is_active;

    if v_target_class is not null then
      v_decision := 'promote';
    else
      select exists (
        select 1 from public.class_level
         where tenant_id = v_tenant_id and ordinal > v_enrol.ordinal and is_active
      ) into v_has_higher;

      if v_has_higher then
        v_decision := 'hold';
        v_error_code := 'NO_TARGET_CLASS';
      else
        v_decision := 'pass_out';
      end if;
    end if;

    insert into public.session_rollover_decision (
      run_id, student_id, source_enrolment_id, decision, target_class_id, error_code
    ) values (
      v_run_id, v_enrol.student_id, v_enrol.enrolment_id, v_decision, v_target_class, v_error_code
    );

    v_total := v_total + 1;
  end loop;

  update public.session_rollover_run set total_count = v_total where id = v_run_id;

  return public.rollover_run_summary(v_run_id);
end;
$$;

revoke execute on function public.start_session_rollover(uuid, uuid, uuid) from public, anon;
grant execute on function public.start_session_rollover(uuid, uuid, uuid) to authenticated;

-- ── set_rollover_decision / set_rollover_decisions_bulk: Principal
--    overrides before a decision is executed ─────────────────────────────

create or replace function public.set_rollover_decision(
  p_run_id uuid, p_student_id uuid, p_decision public.rollover_decision, p_target_class_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run              public.session_rollover_run%rowtype;
  v_decision_row     public.session_rollover_decision%rowtype;
  v_source_class_id  uuid;
  v_source_ordinal   smallint;
  v_target_class_id  uuid;
  v_error_code       text;
begin
  select * into v_run from public.session_rollover_run where id = p_run_id;
  if not found or v_run.tenant_id <> app.auth_tenant_id() then
    raise exception 'RUN_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_run.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_run.status = 'completed' then
    raise exception 'RUN_ALREADY_COMPLETED' using errcode = '55000';
  end if;

  select * into v_decision_row from public.session_rollover_decision
   where run_id = p_run_id and student_id = p_student_id;
  if not found then
    raise exception 'DECISION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_decision_row.processed_at is not null then
    raise exception 'DECISION_ALREADY_PROCESSED' using errcode = '55000';
  end if;

  select class_level_id into v_source_class_id from public.enrolment where id = v_decision_row.source_enrolment_id;
  select ordinal into v_source_ordinal from public.class_level where id = v_source_class_id;

  v_target_class_id := null;
  v_error_code := null;

  if p_decision = 'promote' then
    if p_target_class_id is not null then
      -- An explicit target class is caller-supplied input to a SECURITY
      -- DEFINER function, so it gets the same tenant check every other
      -- caller-supplied id in this schema gets (FR-A12 / the
      -- security_definer_campus_scope_audit convention) rather than
      -- being trusted because it has a valid FK.
      if not exists (
        select 1 from public.class_level
         where id = p_target_class_id and tenant_id = v_run.tenant_id and is_active
      ) then
        raise exception 'TARGET_CLASS_NOT_FOUND' using errcode = 'P0002';
      end if;
      v_target_class_id := p_target_class_id;
    else
      select id into v_target_class_id from public.class_level
       where tenant_id = v_run.tenant_id and is_active and ordinal = v_source_ordinal + 1;
    end if;
    if v_target_class_id is null then
      v_error_code := 'NO_TARGET_CLASS';
    end if;
  elsif p_decision = 'retain' then
    v_target_class_id := v_source_class_id;
  elsif p_decision = 'hold' then
    v_error_code := coalesce(v_decision_row.error_code, 'MANUAL_HOLD');
  end if;
  -- pass_out: target_class_id and error_code both stay null.

  update public.session_rollover_decision
     set decision = p_decision, target_class_id = v_target_class_id, target_section_id = null, error_code = v_error_code
   where id = v_decision_row.id;
end;
$$;

revoke execute on function public.set_rollover_decision(uuid, uuid, public.rollover_decision, uuid) from public, anon;
grant execute on function public.set_rollover_decision(uuid, uuid, public.rollover_decision, uuid) to authenticated;

create or replace function public.set_rollover_decisions_bulk(
  p_run_id uuid, p_student_ids uuid[], p_decision public.rollover_decision
)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student_id uuid;
  v_count      int := 0;
begin
  foreach v_student_id in array p_student_ids loop
    perform public.set_rollover_decision(p_run_id, v_student_id, p_decision);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke execute on function public.set_rollover_decisions_bulk(uuid, uuid[], public.rollover_decision) from public, anon;
grant execute on function public.set_rollover_decisions_bulk(uuid, uuid[], public.rollover_decision) to authenticated;

-- ── execute_rollover_batch: the resumable worker step ────────────────────

create or replace function public.execute_rollover_batch(p_run_id uuid, p_limit int default 200)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run               public.session_rollover_run%rowtype;
  v_dec               record;
  v_target_section    uuid;
  v_target_class_id   uuid;
  v_new_enrolment_id  uuid;
  v_gender            public.gender;
  v_now               timestamptz := clock_timestamp();
  v_error_text        text;
  v_batch_processed   int := 0;
  v_promoted          int := 0;
  v_retained          int := 0;
  v_passed_out        int := 0;
  v_held              int := 0;
  v_created           int := 0;
  v_already_existing  int := 0;
begin
  select * into v_run from public.session_rollover_run where id = p_run_id;
  if not found or v_run.tenant_id <> app.auth_tenant_id() then
    raise exception 'RUN_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_run.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if v_run.status = 'completed' then
    return public.rollover_run_summary(p_run_id) || jsonb_build_object('batch_processed', 0);
  end if;

  -- Serializes concurrent batch calls against the SAME run — two browser
  -- tabs (or a retried request racing the original) both driving the same
  -- run_id must never double-process a decision row.
  perform pg_advisory_xact_lock(hashtextextended('rollover-run:' || p_run_id::text, 0));

  if v_run.status = 'pending' then
    update public.session_rollover_run set status = 'running', started_at = v_now where id = p_run_id;
  end if;

  for v_dec in
    select d.* from public.session_rollover_decision d
     where d.run_id = p_run_id and d.processed_at is null
     order by d.created_at
     limit p_limit
  loop
    begin
      if v_dec.decision = 'hold' then
        update public.session_rollover_decision set processed_at = v_now where id = v_dec.id;
        v_held := v_held + 1;

      elsif v_dec.decision = 'pass_out' then
        perform public.fn_change_student_status(
          v_dec.student_id, 'passed_out'::public.student_status, 'graduation'::public.status_reason_code,
          current_date, 'Session rollover: pass out', false
        );
        update public.session_rollover_decision set processed_at = v_now where id = v_dec.id;
        v_passed_out := v_passed_out + 1;

      else
        -- promote or retain: idempotent re-run check first — a prior run
        -- (or a prior, crashed attempt at THIS run) may already have
        -- created this student's enrolment in the target session.
        select id into v_new_enrolment_id
          from public.enrolment
         where student_id = v_dec.student_id and session_id = v_run.to_session_id and deleted_at is null;

        if v_new_enrolment_id is not null then
          update public.session_rollover_decision
             set processed_at = v_now, new_enrolment_id = v_new_enrolment_id
           where id = v_dec.id;
          v_already_existing := v_already_existing + 1;
        else
          v_target_class_id := v_dec.target_class_id;
          if v_dec.decision = 'retain' and v_target_class_id is null then
            select class_level_id into v_target_class_id from public.enrolment where id = v_dec.source_enrolment_id;
          end if;
          if v_target_class_id is null then
            raise exception 'NO_TARGET_CLASS';
          end if;

          select gender into v_gender from public.student where id = v_dec.student_id;

          -- Least-filled active section for the target class/session/
          -- campus, gender-restriction aware — same greedy rule
          -- fn_auto_balance_sections already uses (FR-C02).
          select cs.id into v_target_section
            from public.class_section cs
            left join (
              select section_id, count(*) as c from public.enrolment
               where status = 'active' and deleted_at is null group by section_id
            ) cnt on cnt.section_id = cs.id
           where cs.class_level_id = v_target_class_id and cs.session_id = v_run.to_session_id
             and cs.campus_id = v_run.campus_id and cs.is_active
             and (cs.gender_restriction is null or cs.gender_restriction = v_gender)
           order by (cs.capacity - coalesce(cnt.c, 0)) desc, cs.name asc
           limit 1;

          if v_target_section is null then
            raise exception 'NO_TARGET_SECTION';
          end if;

          v_new_enrolment_id := public.enrol_student(v_target_section, v_dec.student_id);
          update public.enrolment set previous_enrolment_id = v_dec.source_enrolment_id where id = v_new_enrolment_id;

          update public.session_rollover_decision
             set processed_at = v_now, new_enrolment_id = v_new_enrolment_id,
                 target_class_id = v_target_class_id, target_section_id = v_target_section
           where id = v_dec.id;
          v_created := v_created + 1;
        end if;

        if v_dec.decision = 'promote' then
          v_promoted := v_promoted + 1;
        else
          v_retained := v_retained + 1;
        end if;
      end if;

    exception
      when others then
        get stacked diagnostics v_error_text = message_text;
        update public.session_rollover_decision
           set processed_at = v_now, error_code = left(v_error_text, 200)
         where id = v_dec.id;
        v_held := v_held + 1;
    end;

    v_batch_processed := v_batch_processed + 1;
  end loop;

  update public.session_rollover_run
     set processed_count         = processed_count + v_batch_processed,
         promoted_count          = promoted_count + v_promoted,
         retained_count          = retained_count + v_retained,
         passed_out_count        = passed_out_count + v_passed_out,
         held_count              = held_count + v_held,
         created_count           = created_count + v_created,
         already_existing_count  = already_existing_count + v_already_existing
   where id = p_run_id;

  update public.session_rollover_run
     set status = 'completed', finished_at = v_now, is_no_op = (created_count = 0)
   where id = p_run_id and processed_count >= total_count and status <> 'completed';

  return public.rollover_run_summary(p_run_id) || jsonb_build_object('batch_processed', v_batch_processed);
end;
$$;

revoke execute on function public.execute_rollover_batch(uuid, int) from public, anon;
grant execute on function public.execute_rollover_batch(uuid, int) to authenticated;

-- ── read model for the decision list / exception list UI ────────────────

create or replace view public.v_rollover_decision_detail
with (security_invoker = true) as
select
  d.id, d.run_id, r.tenant_id, r.campus_id, r.from_session_id, r.to_session_id, r.status as run_status,
  d.student_id, s.gr_number, s.name_en as student_name,
  sc.id as source_class_id, sc.name_en as source_class_name,
  d.decision, d.target_class_id, tc.name_en as target_class_name,
  d.target_section_id, ts.name as target_section_name,
  d.new_enrolment_id, d.error_code, d.processed_at, d.created_at
from public.session_rollover_decision d
join public.session_rollover_run r on r.id = d.run_id
join public.student s on s.id = d.student_id
join public.enrolment se on se.id = d.source_enrolment_id
join public.class_level sc on sc.id = se.class_level_id
left join public.class_level tc on tc.id = d.target_class_id
left join public.class_section ts on ts.id = d.target_section_id;

-- ── RLS ───────────────────────────────────────────────────────────────

alter table public.session_rollover_run enable row level security;
alter table public.session_rollover_decision enable row level security;

create policy session_rollover_run_campus_scope on public.session_rollover_run
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy session_rollover_decision_campus_scope on public.session_rollover_decision
  for select to authenticated
  using (
    run_id in (
      select id from public.session_rollover_run
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );
