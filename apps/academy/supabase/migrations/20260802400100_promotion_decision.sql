-- FR-J04: promotion and compartment decision.
--
-- "As a Principal, I want promotion decisions derived from configurable rules,
-- so that the end-of-session class lists are produced consistently instead of
-- by argument."
--
-- ── What is read, and what is written ───────────────────────────────────
--
-- The inputs are FR-J03's annual_result rows (one per candidate per subject:
-- weighted_pct, is_pass, status, is_blocked). Nothing is recomputed from
-- marks: a decision that disagreed with the report card's own pass/fail would
-- be the argument this FR exists to end.
--
-- The output is one promotion_decision per (session, enrolment). It stores
--   * the decision that stands (`decision`),
--   * the decision the rules produced (`system_decision`) so an override never
--     destroys what the system said,
--   * the failed subjects and the aggregate it was derived from, and
--   * a snapshot of the rule that applied, so a rule edited next year does not
--     re-explain this year's list.
--
-- ── The rule ────────────────────────────────────────────────────────────
--
--   failed > max_failed_for_compartment                       -> detained
--   max_failed_for_promotion < failed <= max_failed_for_compartment
--                                                            -> compartment
--   failed <= max_failed_for_promotion, aggregate >= minimum  -> promoted
--   failed <= max_failed_for_promotion, aggregate <  minimum  -> detained
--
-- "Detain on 3 or more failed subjects, compartment on 1 to 2, promote when
-- the aggregate is at least 40% with no failures" is therefore
-- (min 40, max_failed_for_compartment 2, max_failed_for_promotion 0), which is
-- also the default when a campus has configured nothing. A rule row with
-- class_id null is the campus default; a class-specific row wins over it.
--
-- ── Pending ─────────────────────────────────────────────────────────────
--
-- A candidate whose year is withheld (FR-J07/fee default), debarred, still
-- provisional, or without any annual result is `pending`. Pending is not a
-- verdict: such a candidate is excluded from the promotion batch, and the
-- enrolment gate below holds them at their current class until the result
-- exists. It is never shown to a parent.
--
-- ── The hand-off is one transaction, and it is a gate not a hint ────────
--
-- The Notes: promotion feeds next-session enrolment, "otherwise a break-glass
-- correction after roll-over leaves a student enrolled in Class 10 whose Class
-- 9 result has since flipped to Detained". Two things make that impossible to
-- ignore:
--
--   1. trg_enrolment_promotion_gate (BEFORE INSERT ON enrolment) refuses to
--      enrol a student into a HIGHER class than the one a detained/pending
--      decision of their previous session allows. It sits on the table, not on
--      a particular RPC, so session rollover (FR-C), enrol_student and a
--      future bulk path all hit it. A retained (same class) enrolment is
--      untouched. Rollover already isolates each decision, so a blocked
--      student lands in its `held` bucket with the reason.
--   2. fn_evaluate_promotion is one function and therefore one transaction. If
--      a re-evaluation flips a decision to detained/pending while the student
--      already holds a higher-class enrolment in a later session, the same
--      transaction raises handoff_conflict on the decision, which the screen
--      shows loudly. The enrolment is NOT silently cancelled: a conflicting
--      enrolment has fees and attendance hanging off it, so undoing it is a
--      human decision (FR-C withdrawal), not a side effect of a result.
--
-- ── Override ────────────────────────────────────────────────────────────
--
-- Only a Principal (or owner) can override, always with a reason, and the
-- actor and reason are stored on the row (AC4). The report card is a parent
-- document: it prints the FINAL decision only (see the payload wrapper at the
-- bottom) — never `system_decision`, the actor or the reason.

create type public.promotion_decision_type as enum ('promoted', 'promoted_on_trial', 'compartment', 'detained', 'pending');

create table public.promotion_rule (
  id                         uuid primary key default gen_random_uuid(),
  tenant_id                  uuid not null references public.tenant(id) on delete cascade,
  campus_id                  uuid not null references public.campus(id) on delete cascade,
  class_id                   uuid references public.class_level(id) on delete cascade,
  min_aggregate_pct          numeric(5,2) not null default 40 check (min_aggregate_pct between 0 and 100),
  max_failed_for_compartment smallint not null default 2 check (max_failed_for_compartment >= 0),
  max_failed_for_promotion   smallint not null default 0 check (max_failed_for_promotion >= 0),
  updated_by                 uuid references public.app_user(user_id),
  updated_at                 timestamptz not null default now(),
  constraint chk_promotion_rule_order check (max_failed_for_promotion <= max_failed_for_compartment)
);
-- class_id null = the campus default; at most one rule per (campus, class).
create unique index uq_promotion_rule
  on public.promotion_rule (campus_id, coalesce(class_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index idx_promotion_rule_tenant on public.promotion_rule (tenant_id);
create index idx_promotion_rule_class on public.promotion_rule (class_id);

create table public.promotion_decision (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  session_id        uuid not null references public.academic_session(id) on delete cascade,
  class_level_id    uuid not null references public.class_level(id),
  enrolment_id      uuid not null references public.enrolment(id) on delete cascade,
  student_id        uuid not null references public.student(id) on delete cascade,
  decision          public.promotion_decision_type not null,
  system_decision   public.promotion_decision_type not null,
  failed_subjects   jsonb not null default '[]'::jsonb,
  aggregate_pct     numeric(5,2),
  pending_reason    text,
  rule_snapshot     jsonb not null default '{}'::jsonb,
  overridden_by     uuid references public.app_user(user_id),
  override_reason   text,
  overridden_at     timestamptz,
  handoff_conflict  boolean not null default false,
  evaluated_at      timestamptz not null default clock_timestamp(),
  -- An override carries its actor, reason and time together, and a decision
  -- that differs from what the rules said can only exist as an override: a
  -- direct UPDATE of `decision` cannot dodge the reason.
  constraint chk_promotion_override_complete check (
    (overridden_by is null) = (overridden_at is null)
    and (overridden_by is null) = (override_reason is null)
    and (override_reason is null or btrim(override_reason) <> '')
  ),
  constraint chk_promotion_decision_source check (overridden_by is not null or decision = system_decision)
);
create unique index uq_promotion on public.promotion_decision (session_id, enrolment_id);
create index idx_promotion_decision_class on public.promotion_decision (session_id, class_level_id, decision);
create index idx_promotion_decision_student on public.promotion_decision (student_id);
create index idx_promotion_decision_campus on public.promotion_decision (tenant_id, campus_id);
create index idx_promotion_decision_enrolment on public.promotion_decision (enrolment_id);

create trigger promotion_rule_audit after insert or update or delete on public.promotion_rule
  for each row execute function app.tg_audit_row();
create trigger promotion_decision_audit after insert or update or delete on public.promotion_decision
  for each row execute function app.tg_audit_row();

comment on table public.promotion_decision is
  'FR-J04: one end-of-session decision per candidate. system_decision is what the rules said, decision is what stands; they differ only through an audited Principal override.';

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.promotion_rule enable row level security;
alter table public.promotion_decision enable row level security;

create policy promotion_rule_campus_scope on public.promotion_rule
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'student')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids()))
  );

-- The FR's promotion_decision_campus_scope. Parents and students are excluded
-- outright: they receive the final decision through the report card only.
create policy promotion_decision_campus_scope on public.promotion_decision
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller', 'class_teacher')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids()))
  );

-- The FR's promotion_override_principal_only: the only UPDATE path, and it is
-- open to the Principal alone. chk_promotion_decision_source means an UPDATE
-- that changes `decision` must also stamp actor, time and reason.
create policy promotion_override_principal_only on public.promotion_decision
  for update to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids()))
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal')
    and overridden_by = (select auth.uid())
  );

revoke insert, delete, truncate on public.promotion_decision from authenticated, anon;

-- ═══════════════════════════════════════════════════════════════════════
-- Rules
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.save_promotion_rule(
  p_campus_id                  uuid,
  p_class_id                   uuid,
  p_min_aggregate_pct          numeric,
  p_max_failed_for_compartment smallint,
  p_max_failed_for_promotion   smallint
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_id     uuid;
begin
  if v_tenant is null or app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_class_id is not null
     and not exists (select 1 from public.class_level where id = p_class_id and tenant_id = v_tenant) then
    raise exception 'CLASS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_min_aggregate_pct is null or p_min_aggregate_pct < 0 or p_min_aggregate_pct > 100
     or p_max_failed_for_compartment < 0 or p_max_failed_for_promotion < 0 then
    raise exception 'RULE_INVALID' using errcode = '22023';
  end if;
  if p_max_failed_for_promotion > p_max_failed_for_compartment then
    raise exception 'RULE_ORDER' using errcode = '22023',
      hint = 'The failures allowed for promotion cannot exceed those allowed for a compartment.';
  end if;

  insert into public.promotion_rule (tenant_id, campus_id, class_id, min_aggregate_pct,
                                     max_failed_for_compartment, max_failed_for_promotion, updated_by)
  values (v_tenant, p_campus_id, p_class_id, round(p_min_aggregate_pct, 2),
          p_max_failed_for_compartment, p_max_failed_for_promotion, (select auth.uid()))
  on conflict (campus_id, coalesce(class_id, '00000000-0000-0000-0000-000000000000'::uuid)) do update
    set min_aggregate_pct = excluded.min_aggregate_pct,
        max_failed_for_compartment = excluded.max_failed_for_compartment,
        max_failed_for_promotion = excluded.max_failed_for_promotion,
        updated_by = excluded.updated_by,
        updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.save_promotion_rule(uuid, uuid, numeric, smallint, smallint) from public, anon;
grant execute on function public.save_promotion_rule(uuid, uuid, numeric, smallint, smallint) to authenticated;

-- The rule that applies to a class on a campus: class-specific, else the
-- campus default, else the built-in 40 / 2 / 0.
create or replace function app.fn_promotion_rule(p_campus_id uuid, p_class_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select jsonb_build_object('min_aggregate_pct', r.min_aggregate_pct,
                               'max_failed_for_compartment', r.max_failed_for_compartment,
                               'max_failed_for_promotion', r.max_failed_for_promotion,
                               'source', case when r.class_id is null then 'campus' else 'class' end)
       from public.promotion_rule r
      where r.campus_id = p_campus_id and (r.class_id = p_class_id or r.class_id is null)
      order by (r.class_id is null)
      limit 1),
    jsonb_build_object('min_aggregate_pct', 40, 'max_failed_for_compartment', 2,
                       'max_failed_for_promotion', 0, 'source', 'default'));
$$;
revoke execute on function app.fn_promotion_rule(uuid, uuid) from public, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Evaluation
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.fn_evaluate_promotion(p_session_id uuid, p_class_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant   uuid := app.auth_tenant_id();
  v_role     text := app.auth_role();
  v_session  public.academic_session%rowtype;
  v_enr      record;
  v_rule     jsonb;
  v_max_c    int;
  v_max_p    int;
  v_min      numeric;
  v_total    int;
  v_failed   int;
  v_prov     int;
  v_blocked  boolean;
  v_agg      numeric(5,2);
  v_fsubj    jsonb;
  v_decision public.promotion_decision_type;
  v_pending  text;
  v_conflict boolean;
  v_final    public.promotion_decision_type;
  v_counts   jsonb := '{}'::jsonb;
  v_n        int := 0;
  v_conflicts int := 0;
begin
  select * into v_session from public.academic_session where id = p_session_id;
  if not found or (v_tenant is not null and v_session.tenant_id <> v_tenant) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.class_level where id = p_class_id and tenant_id = v_session.tenant_id) then
    raise exception 'CLASS_NOT_FOUND' using errcode = 'P0002';
  end if;
  -- Principal, Exam Controller, and the System (a null tenant is a scheduled
  -- job or a migration, the posture FR-J02's engine takes).
  if v_tenant is not null and v_role not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  for v_enr in
    select e.id, e.tenant_id, e.campus_id, e.student_id
      from public.enrolment e
     where e.session_id = p_session_id and e.class_level_id = p_class_id
       and e.tenant_id = v_session.tenant_id
       and e.status = 'active' and e.deleted_at is null
       and (v_tenant is null or v_role in ('super_admin', 'owner') or e.campus_id = any (app.auth_campus_ids()))
     order by e.id
  loop
    v_rule  := app.fn_promotion_rule(v_enr.campus_id, p_class_id);
    v_max_c := (v_rule ->> 'max_failed_for_compartment')::int;
    v_max_p := (v_rule ->> 'max_failed_for_promotion')::int;
    v_min   := (v_rule ->> 'min_aggregate_pct')::numeric;

    select count(*)::int,
           count(*) filter (where a.is_pass is false)::int,
           count(*) filter (where a.status = 'provisional')::int,
           coalesce(bool_or(a.is_blocked), false),
           round(avg(a.weighted_pct), 2),
           coalesce(jsonb_agg(jsonb_build_object('subject_id', a.subject_id, 'subject_name', sub.name_en,
                                                 'pct', a.weighted_pct) order by sub.name_en)
                    filter (where a.is_pass is false), '[]'::jsonb)
      into v_total, v_failed, v_prov, v_blocked, v_agg, v_fsubj
      from public.annual_result a
      join public.subject sub on sub.id = a.subject_id
     where a.enrolment_id = v_enr.id and a.session_id = p_session_id;

    v_pending := null;
    if app.fn_session_withheld(p_session_id, v_enr.id) then
      v_pending := 'withheld';
    elsif v_blocked then
      v_pending := 'debarred';
    elsif v_total = 0 then
      v_pending := 'no_result';
    elsif v_prov > 0 then
      v_pending := 'provisional';
    elsif v_agg is null then
      v_pending := 'no_result';
    end if;

    if v_pending is not null then
      v_decision := 'pending';
    elsif v_failed > v_max_c then
      v_decision := 'detained';
    elsif v_failed > v_max_p then
      v_decision := 'compartment';
    elsif v_agg < v_min then
      v_decision := 'detained';
    else
      v_decision := 'promoted';
    end if;

    insert into public.promotion_decision (
      tenant_id, campus_id, session_id, class_level_id, enrolment_id, student_id,
      decision, system_decision, failed_subjects, aggregate_pct, pending_reason, rule_snapshot, evaluated_at
    ) values (
      v_enr.tenant_id, v_enr.campus_id, p_session_id, p_class_id, v_enr.id, v_enr.student_id,
      v_decision, v_decision, case when v_decision = 'pending' then '[]'::jsonb else v_fsubj end,
      v_agg, v_pending, v_rule, clock_timestamp()
    )
    on conflict (session_id, enrolment_id) do update
      set system_decision = excluded.system_decision,
          -- A Principal's override stands across re-evaluation; only the
          -- system's own verdict and its inputs move.
          decision        = case when public.promotion_decision.overridden_by is not null
                                 then public.promotion_decision.decision else excluded.decision end,
          failed_subjects = excluded.failed_subjects,
          aggregate_pct   = excluded.aggregate_pct,
          pending_reason  = excluded.pending_reason,
          rule_snapshot   = excluded.rule_snapshot,
          evaluated_at    = excluded.evaluated_at
    returning decision into v_final;

    -- The hand-off check, in the same transaction as the decision: a student
    -- already enrolled in a higher class of a later session while the stand-
    -- ing decision says detained or pending.
    v_conflict := v_final in ('detained', 'pending') and exists (
      select 1
        from public.enrolment n
        join public.academic_session ns on ns.id = n.session_id
        join public.class_level nc on nc.id = n.class_level_id
        join public.class_level sc on sc.id = p_class_id
       where n.student_id = v_enr.student_id and n.id <> v_enr.id
         and n.deleted_at is null and n.status = 'active'
         and ns.starts_on > v_session.starts_on
         and nc.ordinal > sc.ordinal);
    update public.promotion_decision set handoff_conflict = v_conflict
     where session_id = p_session_id and enrolment_id = v_enr.id and handoff_conflict is distinct from v_conflict;

    v_n := v_n + 1;
    if v_conflict then v_conflicts := v_conflicts + 1; end if;
    v_counts := jsonb_set(v_counts, array[v_final::text], to_jsonb(coalesce((v_counts ->> v_final::text)::int, 0) + 1));
  end loop;

  return jsonb_build_object('session_id', p_session_id, 'class_id', p_class_id,
                            'evaluated', v_n, 'conflicts', v_conflicts, 'counts', v_counts);
end;
$$;
revoke execute on function public.fn_evaluate_promotion(uuid, uuid) from public, anon;
grant execute on function public.fn_evaluate_promotion(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Override (AC4)
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.override_promotion_decision(
  p_decision_id uuid,
  p_new_decision public.promotion_decision_type,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_d public.promotion_decision%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_d from public.promotion_decision
   where id = p_decision_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'DECISION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_d.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_new_decision = 'pending' then
    raise exception 'OVERRIDE_TARGET_INVALID' using errcode = '22023',
      hint = 'Pending is a missing result, not a decision a Principal can grant.';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'OVERRIDE_REASON_REQUIRED' using errcode = '22023';
  end if;

  update public.promotion_decision
     set decision = p_new_decision,
         overridden_by = (select auth.uid()),
         overridden_at = clock_timestamp(),
         override_reason = btrim(p_reason),
         handoff_conflict = p_new_decision in ('detained', 'pending') and exists (
           select 1
             from public.enrolment e
             join public.academic_session ss on ss.id = e.session_id
             join public.class_level sc on sc.id = e.class_level_id
             join public.enrolment n on n.student_id = e.student_id and n.id <> e.id
                                    and n.deleted_at is null and n.status = 'active'
             join public.academic_session ns on ns.id = n.session_id
             join public.class_level nc on nc.id = n.class_level_id
            where e.id = v_d.enrolment_id and ns.starts_on > ss.starts_on and nc.ordinal > sc.ordinal)
   where id = p_decision_id;

  -- A card already handed out printed the old decision; it is now stale, and
  -- the report card machinery (FR-J09/J10) will reissue it as a new revision.
  update public.report_card rc
     set status = 'stale', stale_at = now(), stale_reason = 'Promotion decision changed'
   where rc.enrolment_id = v_d.enrolment_id and rc.status = 'issued';
end;
$$;
revoke execute on function public.override_promotion_decision(uuid, public.promotion_decision_type, text) from public, anon;
grant execute on function public.override_promotion_decision(uuid, public.promotion_decision_type, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: the enrolment gate
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_enrolment_promotion_gate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev_decision public.promotion_decision_type;
  v_prev_ordinal  smallint;
  v_new_ordinal   smallint;
  v_new_start     date;
begin
  select s.starts_on into v_new_start from public.academic_session s where s.id = new.session_id;
  select d.decision, c.ordinal
    into v_prev_decision, v_prev_ordinal
    from public.promotion_decision d
    join public.enrolment pe on pe.id = d.enrolment_id
    join public.academic_session ps on ps.id = pe.session_id
    join public.class_level c on c.id = pe.class_level_id
   where d.student_id = new.student_id
     and ps.starts_on < v_new_start
   order by ps.starts_on desc
   limit 1;

  if v_prev_decision in ('detained', 'pending') then
    select c.ordinal into v_new_ordinal from public.class_level c where c.id = new.class_level_id;
    if v_new_ordinal > v_prev_ordinal then
      raise exception 'PROMOTION_BLOCKED' using errcode = '23514',
        detail = format('The previous session ended with a %s decision for this student.', v_prev_decision),
        hint = 'Enrol into the same class, or have the Principal override the decision with a reason.';
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_enrolment_promotion_gate
  before insert on public.enrolment
  for each row execute function app.tg_enrolment_promotion_gate();

-- ═══════════════════════════════════════════════════════════════════════
-- The screen
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.fn_promotion_sheet(p_session_id uuid, p_class_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_role   text := app.auth_role();
  v_campus uuid;
  v_rule   jsonb;
  v_rows   jsonb;
begin
  if v_tenant is null or v_role not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = v_tenant) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  select c.id into v_campus from public.campus c
   where c.tenant_id = v_tenant and (v_role in ('super_admin', 'owner') or c.id = any (app.auth_campus_ids()))
   order by c.code limit 1;
  v_rule := app.fn_promotion_rule(v_campus, p_class_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'decision_id', d.id, 'enrolment_id', d.enrolment_id, 'student_name', st.name_en,
           'gr_number', st.gr_number, 'roll_no', e.roll_no,
           'decision', d.decision, 'system_decision', d.system_decision,
           'aggregate_pct', d.aggregate_pct, 'failed_subjects', d.failed_subjects,
           'pending_reason', d.pending_reason, 'overridden', d.overridden_by is not null,
           'overridden_by_name', ou.full_name, 'override_reason', d.override_reason,
           'handoff_conflict', d.handoff_conflict)
         order by e.roll_no nulls last, st.name_en), '[]'::jsonb)
    into v_rows
    from public.promotion_decision d
    join public.enrolment e on e.id = d.enrolment_id
    join public.student st on st.id = d.student_id
    left join public.app_user ou on ou.user_id = d.overridden_by
   where d.session_id = p_session_id and d.class_level_id = p_class_id
     and d.tenant_id = v_tenant
     and (v_role in ('super_admin', 'owner') or d.campus_id = any (app.auth_campus_ids()));

  return jsonb_build_object(
    'session_id', p_session_id, 'class_id', p_class_id, 'campus_id', v_campus, 'rule', v_rule,
    'can_evaluate', true,
    'can_override', v_role in ('super_admin', 'owner', 'principal'),
    'decisions', v_rows);
end;
$$;
revoke execute on function public.fn_promotion_sheet(uuid, uuid) from public, anon;
grant execute on function public.fn_promotion_sheet(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: the parent-facing card shows the final decision only
-- ═══════════════════════════════════════════════════════════════════════
--
-- fn_build_report_card_payload() is FR-J09's. It is wrapped rather than copied
-- so that this FR changes the payload by ADDING a key and nothing else: the
-- original is renamed once (guarded, so re-applying is harmless) and the
-- wrapper appends `promotion`. Only the session's final counting term carries
-- it — that is the report card an end-of-session decision belongs to.
-- Pending is never printed, and neither are the actor, the reason or the
-- system's own verdict.

do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'app' and p.proname = 'fn_build_report_card_payload_pre_j04') then
    alter function app.fn_build_report_card_payload(uuid, uuid, text) rename to fn_build_report_card_payload_pre_j04;
  end if;
end $$;

create or replace function app.fn_build_report_card_payload(
  p_enrolment_id uuid,
  p_exam_term_id uuid,
  p_remark       text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_payload   jsonb := app.fn_build_report_card_payload_pre_j04(p_enrolment_id, p_exam_term_id, p_remark);
  v_promotion jsonb;
begin
  select jsonb_build_object(
           'decision', d.decision,
           'subjects', case when d.decision = 'compartment'
                            then (select coalesce(jsonb_agg(f ->> 'subject_name' order by f ->> 'subject_name'), '[]'::jsonb)
                                    from jsonb_array_elements(d.failed_subjects) f)
                            else '[]'::jsonb end)
    into v_promotion
    from public.promotion_decision d
    join public.exam_term t on t.id = p_exam_term_id and t.session_id = d.session_id
   where d.enrolment_id = p_enrolment_id
     and d.decision <> 'pending'
     and t.sequence = (select max(t2.sequence) from public.exam_term t2
                        where t2.session_id = t.session_id and t2.campus_id = t.campus_id and t2.counts_toward_annual);
  return v_payload || jsonb_build_object('promotion', v_promotion);
end;
$$;
-- Same exposure as the function this wraps (FR-J09 never restricted it).
grant execute on function app.fn_build_report_card_payload(uuid, uuid, text) to public;
