-- FR-J14: re-sit and improvement result substitution.
--
-- "As an Exam Controller, I want re-sit and improvement attempts recorded
-- separately with a clear substitution rule, so that the published result is
-- defensible and the original is never lost."
--
-- ── One function decides which attempt counts ───────────────────────────
--
-- The Notes: "Every downstream computation — percentage, rank, promotion,
-- transcript — must read the effective attempt through the single function
-- rather than joining mark_entry directly, or the report card, the rank list
-- and the transcript will each independently pick a different attempt."
--
-- app.fn_attempt_publication() is that function (public.fn_effective_attempt
-- is its API shape). Everything else reads the result, not the attempts:
--
--   * subject_result is where percentage, grade, rank (FR-J05), annual
--     aggregate (FR-J03), promotion (FR-J04) and the transcript (FR-J13) all
--     start. A BEFORE INSERT/UPDATE trigger on it asks the function and, when
--     a later attempt is the one that publishes, writes the published mark,
--     percentage, grade and pass/fail onto the row and marks it 'R'. FR-J02's
--     engine is not touched and cannot disagree with it: the engine computes
--     from the original paper, the trigger substitutes, and every consumer
--     downstream reads the substituted row.
--   * the report card payload asks the same function for its attempt number
--     and its footnote.
--
-- ── What is stored ──────────────────────────────────────────────────────
--
-- The ORIGINAL paper is never copied into exam_attempt. It stays in mark_entry
-- (read through v_exam_result_input) as attempt 1 of type 'regular', so a
-- break-glass correction to the original flows through without a second copy
-- going stale. exam_attempt stores only what was sat afterwards (attempt_no >=
-- 2, 'resit' or 'improvement'), with the RAW mark: 61 stays visible in the
-- internal record even when 33 is what is published.
--
-- ── The substitution policy (exam_settings.resit_policy, per campus) ────
--
--   latest          the most recent attempt publishes, as it stands.
--   best_of         the highest mark publishes; ties keep the earlier attempt.
--   capped_at_pass  a RE-SIT counts at most the paper's pass mark (a re-sit
--                   cannot show more than "passed"); an IMPROVEMENT is not
--                   capped; the highest counted mark publishes.
--
-- A paper's pass mark is the sum of its components' pass marks, or, where none
-- are set, resit_default_pass_pct (default 33) of its maximum. A published mark
-- that comes from a later attempt is annotated 'R' on the report card and the
-- card carries a footnote naming the attempt and its date.
--
-- ── Eligibility ─────────────────────────────────────────────────────────
--
-- A re-sit is for a paper the candidate FAILED, or ABSENT from for a medical
-- reason, or absent for any other reason where the Principal records an
-- exception (resit_eligibility.basis = 'principal_exception', with the actor
-- and the reason). fn_generate_resit_eligibility_list() builds the list per
-- term; record_exam_attempt() refuses a re-sit for anyone not on it as
-- eligible. An improvement attempt needs a PASSED original.

-- ═══════════════════════════════════════════════════════════════════════
-- Settings
-- ═══════════════════════════════════════════════════════════════════════

-- exam_settings is a per-campus table other modules also extend (FR-I/FR-G
-- add their own columns); created here only if nothing has yet.
create table if not exists public.exam_settings (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_exam_settings_campus unique (campus_id)
);
create index if not exists idx_exam_settings_tenant on public.exam_settings (tenant_id);

alter table public.exam_settings
  add column if not exists resit_policy text not null default 'capped_at_pass',
  add column if not exists resit_default_pass_pct numeric(5,2) not null default 33;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'chk_exam_settings_resit_policy') then
    alter table public.exam_settings
      add constraint chk_exam_settings_resit_policy check (resit_policy in ('latest', 'best_of', 'capped_at_pass')),
      add constraint chk_exam_settings_resit_pct check (resit_default_pass_pct between 0 and 100);
  end if;
end $$;

alter table public.exam_settings enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where tablename = 'exam_settings' and policyname = 'exam_settings_campus_scope') then
    create policy exam_settings_campus_scope on public.exam_settings
      for select to authenticated
      using (
        tenant_id = app.auth_tenant_id()
        and app.auth_role() not in ('parent', 'student', 'none')
        and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
  end if;
end $$;

create or replace function public.set_resit_policy(p_campus_id uuid, p_policy text, p_default_pass_pct numeric default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
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
  if p_policy not in ('latest', 'best_of', 'capped_at_pass') then
    raise exception 'POLICY_INVALID' using errcode = '22023';
  end if;
  if p_default_pass_pct is not null and (p_default_pass_pct < 0 or p_default_pass_pct > 100) then
    raise exception 'POLICY_INVALID' using errcode = '22023';
  end if;
  insert into public.exam_settings (tenant_id, campus_id, resit_policy, resit_default_pass_pct)
  values (v_tenant, p_campus_id, p_policy, coalesce(p_default_pass_pct, 33))
  on conflict (campus_id) do update
    set resit_policy = excluded.resit_policy,
        resit_default_pass_pct = case when p_default_pass_pct is null then public.exam_settings.resit_default_pass_pct else excluded.resit_default_pass_pct end,
        updated_at = now();
end;
$$;
revoke execute on function public.set_resit_policy(uuid, text, numeric) from public, anon;
grant execute on function public.set_resit_policy(uuid, text, numeric) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Attempts and eligibility
-- ═══════════════════════════════════════════════════════════════════════

create type public.exam_attempt_type as enum ('regular', 'resit', 'improvement');

create table public.exam_attempt (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  enrolment_id    uuid not null references public.enrolment(id) on delete cascade,
  exam_subject_id uuid not null references public.exam_subject(id) on delete cascade,
  attempt_no      smallint not null,
  attempt_type    public.exam_attempt_type not null,
  obtained        numeric(7,2) not null check (obtained >= 0),
  sat_on          date not null,
  recorded_by     uuid references public.app_user(user_id),
  recorded_at     timestamptz not null default clock_timestamp(),
  -- The original paper is attempt 1 and lives in mark_entry; see the header.
  constraint chk_attempt_later check (attempt_no >= 2 and attempt_type <> 'regular')
);
create unique index uq_attempt on public.exam_attempt (enrolment_id, exam_subject_id, attempt_no);
create index idx_attempt_campus on public.exam_attempt (tenant_id, campus_id);
create index idx_attempt_subject on public.exam_attempt (exam_subject_id);

create table public.resit_eligibility (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  enrolment_id    uuid not null references public.enrolment(id) on delete cascade,
  exam_subject_id uuid not null references public.exam_subject(id) on delete cascade,
  eligible        boolean not null,
  basis           text not null check (basis in ('failed', 'absent_medical', 'absent_other', 'principal_exception')),
  granted_by      uuid references public.app_user(user_id),
  exception_reason text,
  decided_at      timestamptz not null default clock_timestamp(),
  constraint chk_resit_exception check (
    (basis = 'principal_exception') = (granted_by is not null and exception_reason is not null))
);
create unique index uq_resit_eligibility on public.resit_eligibility (enrolment_id, exam_subject_id);
create index idx_resit_eligibility_campus on public.resit_eligibility (tenant_id, campus_id);
create index idx_resit_eligibility_subject on public.resit_eligibility (exam_subject_id);

create trigger exam_attempt_audit after insert or update or delete on public.exam_attempt
  for each row execute function app.tg_audit_row();
create trigger resit_eligibility_audit after insert or update or delete on public.resit_eligibility
  for each row execute function app.tg_audit_row();

alter table public.exam_attempt enable row level security;
alter table public.resit_eligibility enable row level security;

-- Internal record: the raw marks are never parent-facing (61 stays here while
-- 33 is published).
create policy attempt_campus_scope on public.exam_attempt
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'student', 'none')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
create policy resit_eligibility_campus_scope on public.resit_eligibility
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'student', 'none')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
-- No DML policies: record_exam_attempt / grant_resit_exception /
-- fn_generate_resit_eligibility_list are the only writers.

-- ═══════════════════════════════════════════════════════════════════════
-- The single function
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.fn_paper_pass_mark(p_exam_subject_id uuid, p_default_pct numeric)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
           nullif((select sum(c.pass_marks) from public.exam_subject_component c where c.exam_subject_id = p_exam_subject_id), 0),
           round(coalesce((select sum(c.max_marks) from public.exam_subject_component c where c.exam_subject_id = p_exam_subject_id), 0)
                 * p_default_pct / 100, 2));
$$;
revoke execute on function app.fn_paper_pass_mark(uuid, numeric) from public, anon, authenticated;

create or replace function app.fn_attempt_publication(p_enrolment_id uuid, p_exam_subject_id uuid)
returns table (
  attempt_no         integer,
  attempt_type       public.exam_attempt_type,
  sat_on             date,
  raw_obtained       numeric,
  published_obtained numeric,
  substituted        boolean,
  pass_mark          numeric,
  max_marks          numeric,
  policy             text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_es       record;
  v_orig     record;
  v_policy   text;
  v_pct      numeric;
  v_pass     numeric;
begin
  select es.tenant_id, es.campus_id into v_es from public.exam_subject es where es.id = p_exam_subject_id;
  select r.obtained_marks, r.paper_max_marks, r.attendance_status::text as att
    into v_orig
    from public.v_exam_result_input r
   where r.exam_subject_id = p_exam_subject_id and r.enrolment_id = p_enrolment_id;
  if v_es.tenant_id is null or v_orig.att is null then
    return;
  end if;

  select coalesce(s.resit_policy, 'capped_at_pass'), coalesce(s.resit_default_pass_pct, 33)
    into v_policy, v_pct
    from (select 1) x left join public.exam_settings s on s.campus_id = v_es.campus_id;
  v_pass := app.fn_paper_pass_mark(p_exam_subject_id, v_pct);

  return query
  with cand as (
    select 1 as no, 'regular'::public.exam_attempt_type as typ, null::date as sat, v_orig.obtained_marks as raw,
           v_orig.obtained_marks as counted
    union all
    select a.attempt_no::int, a.attempt_type, a.sat_on, a.obtained,
           case when v_policy = 'capped_at_pass' and a.attempt_type = 'resit' then least(a.obtained, v_pass) else a.obtained end
      from public.exam_attempt a
     where a.enrolment_id = p_enrolment_id and a.exam_subject_id = p_exam_subject_id
       and v_orig.att in ('present', 'absent')
  ), chosen as (
    select * from cand
     order by case when v_policy = 'latest' then -no else 0 end, counted desc, no
     limit 1
  )
  select c.no, c.typ, c.sat, c.raw, c.counted, c.no > 1, v_pass, v_orig.paper_max_marks::numeric, v_policy
    from chosen c;
end;
$$;
revoke execute on function app.fn_attempt_publication(uuid, uuid) from public, anon, authenticated;

-- The FR's fn_effective_attempt: the attempt that publishes, as an exam_attempt
-- row whose `obtained` is the PUBLISHED mark (33), the raw mark (61) staying in
-- the table. For the original paper (attempt 1) there is no stored row, so the
-- id is null.
create or replace function public.fn_effective_attempt(p_enrolment_id uuid, p_exam_subject_id uuid)
returns public.exam_attempt
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_e   record;
  v_p   record;
  v_row public.exam_attempt;
begin
  select e.tenant_id, e.campus_id into v_e from public.enrolment e where e.id = p_enrolment_id;
  if v_e.tenant_id is null
     or (app.auth_tenant_id() is not null and v_e.tenant_id <> app.auth_tenant_id())
     or (app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner')
         and not (v_e.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_p from app.fn_attempt_publication(p_enrolment_id, p_exam_subject_id);
  if v_p.attempt_no is null then
    return null;
  end if;
  select * into v_row from public.exam_attempt a
   where a.enrolment_id = p_enrolment_id and a.exam_subject_id = p_exam_subject_id and a.attempt_no = v_p.attempt_no;
  if v_row.id is null then
    v_row.tenant_id := v_e.tenant_id;
    v_row.campus_id := v_e.campus_id;
    v_row.enrolment_id := p_enrolment_id;
    v_row.exam_subject_id := p_exam_subject_id;
    v_row.attempt_no := v_p.attempt_no;
    v_row.attempt_type := v_p.attempt_type;
    v_row.sat_on := v_p.sat_on;
  end if;
  v_row.obtained := v_p.published_obtained;
  return v_row;
end;
$$;
revoke execute on function public.fn_effective_attempt(uuid, uuid) from public, anon;
grant execute on function public.fn_effective_attempt(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Substituting into the result
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_subject_result_apply_attempt()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p     record;
  v_band  public.grading_band;
begin
  if new.is_blocked or new.max_marks <= 0 then
    return new;
  end if;
  select * into v_p from app.fn_attempt_publication(new.enrolment_id, new.exam_subject_id);
  if v_p.attempt_no is null or not v_p.substituted then
    return new;
  end if;

  new.obtained := v_p.published_obtained;
  new.pct := round(v_p.published_obtained * 100 / new.max_marks, 2);
  select * into v_band from public.fn_grade_for_percentage(new.grading_scheme_id, new.pct);
  new.grade_label := v_band.grade_label;
  new.gpa_point := v_band.gpa_point;
  -- The paper that publishes is the later attempt, so the original's failed
  -- components no longer describe the result.
  new.failed_components := '[]'::jsonb;
  new.is_pass := v_p.published_obtained >= v_p.pass_mark and coalesce(v_band.is_pass, true);
  new.report_symbol := 'R';
  return new;
end;
$$;

create trigger trg_subject_result_apply_attempt
  before insert or update on public.subject_result
  for each row execute function app.tg_subject_result_apply_attempt();

-- ═══════════════════════════════════════════════════════════════════════
-- Eligibility list (AC4)
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.fn_generate_resit_eligibility_list(p_exam_term_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_term   public.exam_term%rowtype;
  v_pct    numeric;
  v_n      integer := 0;
  r        record;
begin
  if v_tenant is not null and app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_term from public.exam_term where id = p_exam_term_id and (v_tenant is null or tenant_id = v_tenant);
  if v_term.id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_tenant is not null and app.auth_role() not in ('super_admin', 'owner') and not (v_term.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select coalesce((select s.resit_default_pass_pct from public.exam_settings s where s.campus_id = v_term.campus_id), 33) into v_pct;

  for r in
    select i.exam_subject_id, i.enrolment_id, i.tenant_id, i.campus_id, i.attendance_status::text as att,
           i.absence_reason::text as reason, i.obtained_marks,
           app.fn_paper_pass_mark(i.exam_subject_id, v_pct) as pass_mark
      from public.v_exam_result_input i
     where i.exam_term_id = p_exam_term_id
       and i.attendance_status in ('present', 'absent')
       -- only papers whose marks are signed off have a result to fail
       and exists (select 1 from public.subject_result sr
                    where sr.exam_term_id = p_exam_term_id and sr.enrolment_id = i.enrolment_id and sr.exam_subject_id = i.exam_subject_id)
  loop
    if r.att = 'absent' then
      insert into public.resit_eligibility (tenant_id, campus_id, enrolment_id, exam_subject_id, eligible, basis)
      values (r.tenant_id, r.campus_id, r.enrolment_id, r.exam_subject_id, r.reason = 'medical',
              case when r.reason = 'medical' then 'absent_medical' else 'absent_other' end)
      on conflict (enrolment_id, exam_subject_id) do update
        set eligible = excluded.eligible, basis = excluded.basis, decided_at = clock_timestamp()
        where public.resit_eligibility.basis <> 'principal_exception';
      v_n := v_n + 1;
    elsif r.obtained_marks < r.pass_mark then
      insert into public.resit_eligibility (tenant_id, campus_id, enrolment_id, exam_subject_id, eligible, basis)
      values (r.tenant_id, r.campus_id, r.enrolment_id, r.exam_subject_id, true, 'failed')
      on conflict (enrolment_id, exam_subject_id) do update
        set eligible = true, basis = 'failed', decided_at = clock_timestamp()
        where public.resit_eligibility.basis <> 'principal_exception';
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.fn_generate_resit_eligibility_list(uuid) from public, anon;
grant execute on function public.fn_generate_resit_eligibility_list(uuid) to authenticated, service_role;

create or replace function public.grant_resit_exception(p_enrolment_id uuid, p_exam_subject_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e record;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'EXCEPTION_REASON_REQUIRED' using errcode = '22023';
  end if;
  select e.tenant_id, e.campus_id into v_e from public.enrolment e where e.id = p_enrolment_id and e.deleted_at is null;
  if v_e.tenant_id is null or v_e.tenant_id <> app.auth_tenant_id()
     or not exists (select 1 from public.exam_subject es where es.id = p_exam_subject_id and es.tenant_id = v_e.tenant_id and es.campus_id = v_e.campus_id) then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_e.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.resit_eligibility (tenant_id, campus_id, enrolment_id, exam_subject_id, eligible, basis, granted_by, exception_reason)
  values (v_e.tenant_id, v_e.campus_id, p_enrolment_id, p_exam_subject_id, true, 'principal_exception', (select auth.uid()), btrim(p_reason))
  on conflict (enrolment_id, exam_subject_id) do update
    set eligible = true, basis = 'principal_exception', granted_by = excluded.granted_by,
        exception_reason = excluded.exception_reason, decided_at = clock_timestamp();
end;
$$;
revoke execute on function public.grant_resit_exception(uuid, uuid, text) from public, anon;
grant execute on function public.grant_resit_exception(uuid, uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Recording an attempt
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.record_exam_attempt(
  p_enrolment_id    uuid,
  p_exam_subject_id uuid,
  p_attempt_type    public.exam_attempt_type,
  p_obtained        numeric,
  p_sat_on          date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_role   text := app.auth_role();
  v_e      record;
  v_es     record;
  v_orig   record;
  v_pct    numeric;
  v_max    numeric;
  v_no     integer;
  v_id     uuid;
  v_pass   numeric;
begin
  if v_tenant is null or v_role not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller', 'subject_teacher', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_attempt_type = 'regular' then
    raise exception 'ATTEMPT_TYPE_INVALID' using errcode = '22023',
      hint = 'The original paper is entered through mark entry; only a re-sit or an improvement is recorded here.';
  end if;

  select e.tenant_id, e.campus_id, e.section_id into v_e from public.enrolment e where e.id = p_enrolment_id and e.deleted_at is null;
  select es.tenant_id, es.campus_id, es.exam_term_id, cs.subject_id into v_es
    from public.exam_subject es join public.class_subject cs on cs.id = es.class_subject_id where es.id = p_exam_subject_id;
  if v_e.tenant_id is null or v_es.tenant_id is null or v_e.tenant_id <> v_tenant or v_es.tenant_id <> v_tenant or v_e.campus_id <> v_es.campus_id then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_e.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_role in ('subject_teacher', 'class_teacher') and not exists (
       select 1 from public.section_subject_teacher t
        where t.section_id = v_e.section_id and t.subject_id = v_es.subject_id
          and t.staff_id = (select auth.uid()) and t.validity @> app.fn_karachi_today()) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select r.obtained_marks, r.paper_max_marks, r.attendance_status::text as att into v_orig
    from public.v_exam_result_input r where r.exam_subject_id = p_exam_subject_id and r.enrolment_id = p_enrolment_id;
  if v_orig.att is null then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_orig.att in ('exempt', 'debarred') then
    raise exception 'ATTEMPT_NOT_ALLOWED' using errcode = '23514',
      hint = 'An exempt or debarred candidate has no original paper to re-sit or improve on.';
  end if;
  v_max := v_orig.paper_max_marks;
  if p_obtained is null or p_obtained < 0 or p_obtained > v_max then
    raise exception 'MARKS_OUT_OF_RANGE' using errcode = '22003', detail = format('0 to %s', v_max);
  end if;
  if p_sat_on is null or p_sat_on > app.fn_karachi_today() then
    raise exception 'SAT_ON_INVALID' using errcode = '22023';
  end if;

  select coalesce((select s.resit_default_pass_pct from public.exam_settings s where s.campus_id = v_es.campus_id), 33) into v_pct;
  v_pass := app.fn_paper_pass_mark(p_exam_subject_id, v_pct);

  if p_attempt_type = 'resit' then
    if not exists (select 1 from public.resit_eligibility q
                    where q.enrolment_id = p_enrolment_id and q.exam_subject_id = p_exam_subject_id and q.eligible) then
      raise exception 'RESIT_NOT_ELIGIBLE' using errcode = '23514',
        hint = 'Failed papers and medical absences qualify; otherwise the Principal records an exception.';
    end if;
  else
    -- improvement: only on a paper that was passed (a failed one is a re-sit)
    if v_orig.att = 'absent' or v_orig.obtained_marks < v_pass then
      raise exception 'IMPROVEMENT_REQUIRES_PASS' using errcode = '23514';
    end if;
  end if;

  select coalesce(max(a.attempt_no), 1) + 1 into v_no
    from public.exam_attempt a where a.enrolment_id = p_enrolment_id and a.exam_subject_id = p_exam_subject_id;

  insert into public.exam_attempt (tenant_id, campus_id, enrolment_id, exam_subject_id, attempt_no, attempt_type, obtained, sat_on, recorded_by)
  values (v_tenant, v_e.campus_id, p_enrolment_id, p_exam_subject_id, v_no, p_attempt_type, p_obtained, p_sat_on, (select auth.uid()))
  returning id into v_id;

  -- The published result follows: recompute the section's results (which also
  -- chains the annual aggregate and the positions), and mark any report card
  -- already handed out as stale so the next revision carries the new mark.
  if exists (select 1 from public.subject_result sr where sr.enrolment_id = p_enrolment_id and sr.exam_subject_id = p_exam_subject_id) then
    begin
      perform app.fn_compute_subject_result(v_es.exam_term_id, v_e.section_id, (select auth.uid()));
    exception when others then
      -- No grade scale configured, say: the attempt is recorded and the
      -- result catches up at the next compute.
      null;
    end;
    -- Whether or not the engine could run, the stored result must carry the
    -- published mark: touching the row fires the substitution trigger.
    update public.subject_result sr set computed_at = sr.computed_at
     where sr.enrolment_id = p_enrolment_id and sr.exam_subject_id = p_exam_subject_id;
    update public.report_card rc
       set status = 'stale', stale_at = now(), stale_reason = 'A re-sit or improvement attempt was recorded'
     where rc.enrolment_id = p_enrolment_id and rc.exam_term_id = v_es.exam_term_id and rc.status = 'issued';
  end if;
  return v_id;
end;
$$;
revoke execute on function public.record_exam_attempt(uuid, uuid, public.exam_attempt_type, numeric, date) from public, anon;
grant execute on function public.record_exam_attempt(uuid, uuid, public.exam_attempt_type, numeric, date) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The screen
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.fn_resit_sheet(p_exam_term_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_role   text := app.auth_role();
  v_term   public.exam_term%rowtype;
  v_rows   jsonb;
  v_policy text;
begin
  if v_tenant is null or v_role not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_term from public.exam_term where id = p_exam_term_id and tenant_id = v_tenant;
  if v_term.id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_term.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select coalesce((select s.resit_policy from public.exam_settings s where s.campus_id = v_term.campus_id), 'capped_at_pass') into v_policy;

  select coalesce(jsonb_agg(jsonb_build_object(
           'enrolment_id', q.enrolment_id, 'exam_subject_id', q.exam_subject_id,
           'student_name', st.name_en, 'gr_number', st.gr_number, 'roll_no', e.roll_no,
           'subject_name', sub.name_en, 'eligible', q.eligible, 'basis', q.basis,
           'exception_reason', q.exception_reason,
           'attempts', coalesce((select jsonb_agg(jsonb_build_object('attempt_no', a.attempt_no, 'type', a.attempt_type,
                                  'obtained', a.obtained, 'sat_on', a.sat_on) order by a.attempt_no)
                                   from public.exam_attempt a where a.enrolment_id = q.enrolment_id and a.exam_subject_id = q.exam_subject_id), '[]'::jsonb),
           'published', (select jsonb_build_object('attempt_no', p.attempt_no, 'published_obtained', p.published_obtained,
                                                   'raw_obtained', p.raw_obtained, 'substituted', p.substituted, 'max_marks', p.max_marks)
                           from app.fn_attempt_publication(q.enrolment_id, q.exam_subject_id) p)
         ) order by e.roll_no nulls last, st.name_en, sub.name_en), '[]'::jsonb)
    into v_rows
    from public.resit_eligibility q
    join public.exam_subject es on es.id = q.exam_subject_id and es.exam_term_id = p_exam_term_id
    join public.class_subject cs on cs.id = es.class_subject_id
    join public.subject sub on sub.id = cs.subject_id
    join public.enrolment e on e.id = q.enrolment_id
    join public.student st on st.id = e.student_id
   where q.tenant_id = v_tenant
     and (v_role in ('super_admin', 'owner') or q.campus_id = any (app.auth_campus_ids()));

  return jsonb_build_object('exam_term_id', p_exam_term_id, 'policy', v_policy,
                            'can_grant', v_role in ('super_admin', 'owner', 'principal'), 'rows', v_rows);
end;
$$;
revoke execute on function public.fn_resit_sheet(uuid) from public, anon;
grant execute on function public.fn_resit_sheet(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the report card
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.fn_dd_mon_yyyy(p_date date)
returns text
language sql
immutable
as $$
  select lpad(extract(day from p_date)::int::text, 2, '0') || '-'
         || (array['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'])[extract(month from p_date)::int]
         || '-' || extract(year from p_date)::int;
$$;

-- fn_build_report_card_payload() is wrapped, as FR-J04 wrapped it, so this FR
-- only ADDS: each subject gains attempt_no, and attempt_notes carries the
-- footnotes. The attempt is asked of the single function.
do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'app' and p.proname = 'fn_build_report_card_payload_pre_j14') then
    alter function app.fn_build_report_card_payload(uuid, uuid, text) rename to fn_build_report_card_payload_pre_j14;
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
  v_payload  jsonb := app.fn_build_report_card_payload_pre_j14(p_enrolment_id, p_exam_term_id, p_remark);
  v_subjects jsonb;
  v_notes    jsonb;
begin
  with att as (
    select sub.name_en as subject_name, p.attempt_no, p.attempt_type, p.sat_on, p.substituted
      from public.exam_subject es
      join public.class_subject cs on cs.id = es.class_subject_id
      join public.subject sub on sub.id = cs.subject_id
      cross join lateral app.fn_attempt_publication(p_enrolment_id, es.id) p
     where es.exam_term_id = p_exam_term_id
  )
  select coalesce(jsonb_agg(
           s.value || jsonb_build_object('attempt_no', coalesce((select a.attempt_no from att a where a.subject_name = s.value ->> 'subject_name'), 1))
           order by s.ord), '[]'::jsonb),
         (select coalesce(jsonb_agg(
                   a.subject_name || ': result of ' ||
                   case a.attempt_type when 'resit' then 're-sit' else 'improvement attempt' end
                   || ' dated ' || app.fn_dd_mon_yyyy(a.sat_on)
                   order by a.subject_name), '[]'::jsonb)
            from att a where a.substituted and a.sat_on is not null)
    into v_subjects, v_notes
    from jsonb_array_elements(coalesce(v_payload -> 'subjects', '[]'::jsonb)) with ordinality s(value, ord);

  return v_payload || jsonb_build_object('subjects', coalesce(v_subjects, '[]'::jsonb), 'attempt_notes', coalesce(v_notes, '[]'::jsonb));
end;
$$;
grant execute on function app.fn_build_report_card_payload(uuid, uuid, text) to public;
