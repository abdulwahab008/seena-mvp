-- FR-B14: capture a structured interview scorecard and recommendation,
-- forcing a written justification whenever the recommendation overrides
-- the applicant's merit-rank position.
--
-- Scope cuts / deliberate deviations from the literal Supabase Objects
-- text (same class of deviation already documented for FR-B13's named
-- RLS write policies — this codebase gates writes through SECURITY
-- DEFINER functions, not RLS INSERT/UPDATE policies):
--   * chk_justification_required_on_merit_override is NOT a plain table
--     CHECK constraint — the override determination needs the
--     applicant's merit rank (FR-B12's v_admission_merit_rank, itself
--     joined through FR-B13's admission_interview.application_id) and
--     the class's total seat count, neither of which a same-row CHECK
--     can see. Enforced inside submit_interview_scorecard() instead.
--   * "audit_log entries kind='interview_outcome_edit'" — audit_log has
--     no free-text kind column; the existing generic per-row audit
--     trigger (table_name='admission_interview_outcome', action='update')
--     already produces one audit row per edit, satisfying the AC as-is.
--   * "the applicant's merit rank position relative to available seats"
--     is undefined for an application with no test candidate (an
--     interview-only track) — fn_is_merit_override() returns false in
--     that case (nothing to override), not an error.
--   * trg_scorecard_immutable_after_submit is implemented as a role
--     check inside submit_interview_scorecard() rather than a table
--     trigger, since "immutable to the submitter, editable by a
--     Principal" is a role-conditional rule a BEFORE trigger can't see
--     (triggers have no caller-role context beyond what the function
--     already checks).

create type public.interview_criterion as enum (
  'communication', 'confidence', 'academic_readiness', 'parental_engagement', 'overall_impression'
);
create type public.interview_recommendation as enum ('accept', 'waitlist', 'reject');

create table public.admission_interview_score (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  interview_id uuid not null references public.admission_interview(id) on delete cascade,
  criterion    public.interview_criterion not null,
  score        int not null check (score between 1 and 5),
  unique (interview_id, criterion)
);

create table public.admission_interview_outcome (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  interview_id  uuid not null unique references public.admission_interview(id) on delete cascade,
  recommendation public.interview_recommendation not null,
  justification text,
  submitted_by  uuid references public.app_user(user_id),
  submitted_at  timestamptz not null default clock_timestamp()
);

create trigger interview_outcome_audit after insert or update or delete on public.admission_interview_outcome
  for each row execute function app.tg_audit_row();

-- AC: whether a recommendation overrides merit is undefined without a
-- test rank — the class's total seats (not "seats still open") is the
-- AC's own denominator ("3rd of 60 for 40 seats").
create or replace function app.fn_is_merit_override(p_application_id uuid, p_recommendation public.interview_recommendation)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_seats int;
  v_rank  int;
  v_class uuid;
  v_session uuid;
  v_campus uuid;
begin
  select class_applied_id, session_id, campus_id into v_class, v_session, v_campus
    from public.admission_application where id = p_application_id;

  select coalesce(sum(cs.capacity), 0) into v_seats
    from public.class_section cs
   where cs.class_level_id = v_class and cs.session_id = v_session and cs.campus_id = v_campus;

  select vmr.rnk into v_rank
    from public.admission_test_candidate tc
    join public.v_admission_merit_rank vmr on vmr.candidate_id = tc.id
   where tc.application_id = p_application_id and tc.cancelled_at is null
   limit 1;

  if v_rank is null then
    return false;
  end if;

  return (p_recommendation = 'reject' and v_rank <= v_seats) or (p_recommendation = 'accept' and v_rank > v_seats);
end;
$$;

create or replace function public.submit_interview_scorecard(
  p_interview_id uuid, p_scores jsonb, p_recommendation public.interview_recommendation, p_justification text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid := app.auth_tenant_id();
  v_application_id uuid;
  v_already_submitted boolean;
  v_missing        text[];
  v_is_override    boolean;
  v_id             uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select application_id into v_application_id from public.admission_interview where id = p_interview_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'INTERVIEW_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- AC: read-only to the submitter once submitted — only a Principal (or
  -- owner/super_admin) may edit an already-submitted scorecard.
  select exists(select 1 from public.admission_interview_outcome where interview_id = p_interview_id) into v_already_submitted;
  if v_already_submitted and app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'SCORECARD_LOCKED' using errcode = '55006', detail = 'This scorecard is already submitted — only a Principal can edit it.';
  end if;

  -- AC: a criterion left unscored is rejected, listing what's missing.
  select array_agg(c::text) into v_missing
    from unnest(enum_range(null::public.interview_criterion)) c
   where not exists (select 1 from jsonb_array_elements(p_scores) e where (e ->> 'criterion') = c::text);
  if v_missing is not null and array_length(v_missing, 1) > 0 then
    raise exception 'MISSING_CRITERIA' using errcode = '23514', detail = array_to_string(v_missing, ', ');
  end if;

  -- AC: a recommendation that contradicts the merit-rank position needs
  -- a written justification of at least 20 characters.
  v_is_override := app.fn_is_merit_override(v_application_id, p_recommendation);
  if v_is_override and (p_justification is null or length(trim(p_justification)) < 20) then
    raise exception 'JUSTIFICATION_REQUIRED' using errcode = '23514', detail = 'A justification of at least 20 characters is required when the recommendation overrides the merit rank.';
  end if;

  delete from public.admission_interview_score where interview_id = p_interview_id;
  insert into public.admission_interview_score (tenant_id, interview_id, criterion, score)
  select v_tenant_id, p_interview_id, (e ->> 'criterion')::public.interview_criterion, (e ->> 'score')::int
    from jsonb_array_elements(p_scores) e;

  insert into public.admission_interview_outcome (tenant_id, interview_id, recommendation, justification, submitted_by, submitted_at)
  values (v_tenant_id, p_interview_id, p_recommendation, p_justification, auth.uid(), clock_timestamp())
  on conflict (interview_id) do update
    set recommendation = excluded.recommendation, justification = excluded.justification,
        submitted_by = excluded.submitted_by, submitted_at = excluded.submitted_at
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.submit_interview_scorecard(uuid, jsonb, public.interview_recommendation, text) from public, anon;
grant execute on function public.submit_interview_scorecard(uuid, jsonb, public.interview_recommendation, text) to authenticated;

-- AC: when an applicant was seen by more than one panel member, every
-- scorecard and the mean of each criterion across them are displayed
-- together.
create or replace function public.fn_scorecard_summary(p_application_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_scorecards jsonb;
  v_means      jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.admission_application where id = p_application_id and tenant_id = v_tenant_id) then
    raise exception 'APPLICATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'interview_id', ai.id,
           'panel_name', au.full_name,
           'recommendation', aio.recommendation,
           'justification', aio.justification,
           'scores', (
             select coalesce(jsonb_object_agg(ais.criterion, ais.score), '{}'::jsonb)
               from public.admission_interview_score ais where ais.interview_id = ai.id
           )
         ) order by aio.submitted_at), '[]'::jsonb)
    into v_scorecards
    from public.admission_interview ai
    join public.admission_interview_outcome aio on aio.interview_id = ai.id
    join public.app_user au on au.user_id = ai.panel_user_id
   where ai.application_id = p_application_id;

  select coalesce(jsonb_object_agg(criterion, mean_score), '{}'::jsonb) into v_means
    from (
      select ais.criterion, round(avg(ais.score), 2) as mean_score
        from public.admission_interview_score ais
        join public.admission_interview ai on ai.id = ais.interview_id
       where ai.application_id = p_application_id
       group by ais.criterion
    ) m;

  return jsonb_build_object('application_id', p_application_id, 'scorecards', v_scorecards, 'mean_by_criterion', v_means);
end;
$$;

revoke execute on function public.fn_scorecard_summary(uuid) from public, anon;
grant execute on function public.fn_scorecard_summary(uuid) to authenticated;

alter table public.admission_interview_score enable row level security;
alter table public.admission_interview_outcome enable row level security;

create policy interview_score_tenant_read on public.admission_interview_score
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or interview_id in (
        select ai.id from public.admission_interview ai
        join public.admission_application aa on aa.id = ai.application_id
        where aa.campus_id = any(app.auth_campus_ids())
      )
    )
  );

create policy interview_outcome_tenant_read on public.admission_interview_outcome
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or interview_id in (
        select ai.id from public.admission_interview ai
        join public.admission_application aa on aa.id = ai.application_id
        where aa.campus_id = any(app.auth_campus_ids())
      )
    )
  );
