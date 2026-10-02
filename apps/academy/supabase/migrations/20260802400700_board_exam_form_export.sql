-- FR-T12: board examination form export and fee reconciliation.
--
-- "As an Exam Controller, I want to export the board examination form data with
-- each candidate's subject combination and computed board fee, so that the
-- amount I deposit with the board matches the amount I collected from parents."
--
-- ── The reconciliation is the deliverable ───────────────────────────────
--
-- The school collects the board fee from parents and remits it to the board, so
-- a mismatch is the school's cash loss (the Notes). The export file is the easy
-- half; what is built carefully is v_board_exam_reconciliation and
-- fn_board_exam_reconciliation(): for each registered candidate, what the board
-- will charge (computed from the effective-dated schedule), what the fee module
-- billed on the parent's challan (fee head board_exam), and what was actually
-- collected against that line. The totals, and the candidates who have paid
-- nothing (unpaid) or less than the board charges (short), come from one place.
--
-- billed and collected are read from the fee module's own tables by definer
-- helpers (app.fn_board_exam_billed / _collected), not through the viewer's RLS:
-- an Exam Controller who may not open the fee ledger must still see an honest
-- number, not a silent zero.
--
-- ── The fee ─────────────────────────────────────────────────────────────
--
--   fee = per_candidate_amount + per_paper_amount x papers
--
-- from the schedule row for (board, session year, candidate category) whose
-- [effective_from, effective_to] contains the date the fee is computed AS OF.
-- That date is the registration's session_date (the board exam session it is
-- for), never "today": the board revises fees mid-session and the school cannot
-- retroactively bill parents, so regenerating an export in July for an April
-- session prices it on the April schedule (AC4). Papers are the subjects being
-- improved for an improvement candidate, and every registered subject otherwise.
-- A regular candidate pays a flat per-candidate fee; an improvement candidate a
-- per-paper rate; a private candidate has a schedule row of their own (Notes:
-- "Improvement and private candidates use different fee bases and are routinely
-- miscounted"). Amounts are bigint paisa.
--
-- ── What blocks an export ───────────────────────────────────────────────
--
--   MISSING_MANDATORY_SUBJECT  the candidate's group requires a subject code the
--                              registration does not carry (AC2), named
--   NO_FEE_SCHEDULE            nothing prices this candidate as at their session
--   NO_SUBJECTS                a registration with nothing in it
--   IMPROVEMENT_NO_SUBJECTS    an improvement candidate improving nothing
--   CONSENT_MISSING            no guardian consent to share with a third party
--                              (the same rule FR-T11 applies)
--
-- An improvement candidate's export carries ONLY the subjects being improved
-- (AC3): the original combination is the board's record already.

-- ═══════════════════════════════════════════════════════════════════════
-- Fee schedule
-- ═══════════════════════════════════════════════════════════════════════

create table public.board_fee_schedule (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  board_code           text not null check (board_code in ('FBISE', 'PUNJAB', 'SINDH', 'KPK', 'BALOCHISTAN', 'AKU_EB', 'CAMBRIDGE')),
  session_year         integer not null check (session_year between 2000 and 2100),
  candidate_category   text not null check (candidate_category in ('regular', 'improvement', 'private')),
  -- bigint paisa, like every money column
  per_candidate_amount bigint not null default 0 check (per_candidate_amount >= 0),
  per_paper_amount     bigint not null default 0 check (per_paper_amount >= 0),
  effective_from       date not null,
  effective_to         date,
  note                 text,
  created_by           uuid references public.app_user(user_id),
  created_at           timestamptz not null default now(),
  constraint chk_board_fee_window check (effective_to is null or effective_to >= effective_from),
  constraint chk_board_fee_nonzero check (per_candidate_amount > 0 or per_paper_amount > 0)
);
create unique index uq_board_fee_schedule
  on public.board_fee_schedule (tenant_id, board_code, session_year, candidate_category, effective_from);
create index idx_board_fee_schedule_tenant on public.board_fee_schedule (tenant_id);

create trigger board_fee_schedule_audit after insert or update or delete on public.board_fee_schedule
  for each row execute function app.tg_audit_row();

alter table public.board_fee_schedule enable row level security;

-- Every member of the school's staff can read the schedule (it is public
-- information published by the board); writing goes through save_board_fee_schedule.
create policy board_fee_schedule_read_all_tenant on public.board_fee_schedule
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none'));

create or replace function public.save_board_fee_schedule(
  p_board_code         text,
  p_session_year       integer,
  p_candidate_category text,
  p_per_candidate      bigint,
  p_per_paper          bigint,
  p_effective_from     date,
  p_note               text default null
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
  if v_tenant is null or app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_candidate_category not in ('regular', 'improvement', 'private') or p_per_candidate < 0 or p_per_paper < 0
     or (p_per_candidate = 0 and p_per_paper = 0) or p_effective_from is null then
    raise exception 'SCHEDULE_INVALID' using errcode = '22023';
  end if;

  -- A revision closes the version it replaces the day before it takes effect, so
  -- exactly one version applies to any date.
  update public.board_fee_schedule s
     set effective_to = p_effective_from - 1
   where s.tenant_id = v_tenant and s.board_code = p_board_code and s.session_year = p_session_year
     and s.candidate_category = p_candidate_category and s.effective_from < p_effective_from
     and (s.effective_to is null or s.effective_to >= p_effective_from);

  insert into public.board_fee_schedule (tenant_id, board_code, session_year, candidate_category, per_candidate_amount,
                                         per_paper_amount, effective_from, note, created_by)
  values (v_tenant, p_board_code, p_session_year, p_candidate_category, p_per_candidate, p_per_paper, p_effective_from,
          nullif(btrim(p_note), ''), (select auth.uid()))
  returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'SCHEDULE_EXISTS' using errcode = '23505';
end;
$$;
revoke execute on function public.save_board_fee_schedule(text, integer, text, bigint, bigint, date, text) from public, anon;
grant execute on function public.save_board_fee_schedule(text, integer, text, bigint, bigint, date, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Registrations
-- ═══════════════════════════════════════════════════════════════════════

-- exam_registration is a board-examination table other certificate features
-- read too (the Leaving Certificate takes board, roll number and group from it),
-- and each of them creates it only if absent. This is the fuller definition: the
-- shared columns (student_id, enrolment_id, board_code text, roll_no, group_code)
-- keep their names and types, and the columns this feature needs are added with
-- IF NOT EXISTS, so whichever migration runs first, the other finds what it
-- expects. A row written by another feature that knows nothing of fees simply
-- has no session_id or session_year and is outside every export here.
create table if not exists public.exam_registration (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  student_id   uuid references public.student(id),
  enrolment_id uuid references public.enrolment(id),
  board_code   text,
  roll_no      text,
  group_code   text,
  created_at   timestamptz not null default now()
);
alter table public.exam_registration
  add column if not exists session_id uuid references public.academic_session(id) on delete cascade,
  add column if not exists session_year integer,
  -- The board exam session this registration is for. Fees are priced as at
  -- this date, never as at the day the export is regenerated.
  add column if not exists session_date date,
  add column if not exists candidate_category text not null default 'regular',
  add column if not exists registered_by uuid references public.app_user(user_id);
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'chk_exam_registration_category') then
    alter table public.exam_registration
      add constraint chk_exam_registration_category check (candidate_category in ('regular', 'improvement', 'private')),
      add constraint chk_exam_registration_year check (session_year is null or session_year between 2000 and 2100),
      add constraint chk_exam_registration_fee_scope check (session_id is null or (session_year is not null and session_date is not null and student_id is not null and board_code is not null));
  end if;
end $$;
create unique index if not exists uq_exam_registration on public.exam_registration (session_id, student_id, board_code) where session_id is not null;
create index if not exists idx_exam_registration_scope on public.exam_registration (tenant_id, campus_id, board_code, session_year);
create index if not exists idx_exam_registration_student on public.exam_registration (student_id);
create index if not exists idx_exam_registration_enrolment on public.exam_registration (enrolment_id, board_code);
create index if not exists idx_exam_registration_tenant on public.exam_registration (tenant_id, campus_id);

create table public.exam_registration_subject (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  registration_id uuid not null references public.exam_registration(id) on delete cascade,
  subject_code    text not null check (btrim(subject_code) <> ''),
  election        text not null check (election in ('compulsory', 'elective', 'improvement')),
  constraint uq_exam_registration_subject unique (registration_id, subject_code)
);
create index idx_exam_reg_subject on public.exam_registration_subject (registration_id);
create index idx_exam_reg_subject_tenant on public.exam_registration_subject (tenant_id);

drop trigger if exists exam_registration_audit on public.exam_registration;
create trigger exam_registration_audit after insert or update or delete on public.exam_registration
  for each row execute function app.tg_audit_row();

-- Mandatory subjects per group. tenant_id null = the platform's default for the
-- board; a school's own row for the same (board, group, subject) is additive.
create table public.board_group_rule (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid references public.tenant(id) on delete cascade,
  board_code   text not null check (board_code in ('FBISE', 'PUNJAB', 'SINDH', 'KPK', 'BALOCHISTAN', 'AKU_EB', 'CAMBRIDGE')),
  group_code   text not null check (btrim(group_code) <> ''),
  subject_code text not null check (btrim(subject_code) <> ''),
  created_at   timestamptz not null default now()
);
create unique index uq_board_group_rule_tenant on public.board_group_rule (tenant_id, board_code, group_code, subject_code) where tenant_id is not null;
create unique index uq_board_group_rule_global on public.board_group_rule (board_code, group_code, subject_code) where tenant_id is null;

-- Platform defaults, as data: the three science/computing groups every board
-- offers, with the internal subject codes (subject.code).
insert into public.board_group_rule (tenant_id, board_code, group_code, subject_code)
select null, b.board, g.grp, g.subj
  from (values ('FBISE'), ('PUNJAB'), ('SINDH'), ('KPK'), ('BALOCHISTAN'), ('AKU_EB')) b(board)
  cross join (values
    ('PRE_ENG', 'PHY'), ('PRE_ENG', 'CHM'), ('PRE_ENG', 'MTH'),
    ('PRE_MED', 'PHY'), ('PRE_MED', 'CHM'), ('PRE_MED', 'BIO'),
    ('ICS', 'PHY'), ('ICS', 'MTH'), ('ICS', 'CS')) g(grp, subj);

alter table public.exam_registration enable row level security;
alter table public.exam_registration_subject enable row level security;
alter table public.board_group_rule enable row level security;

-- Same roles the other certificate features expect (admissions officers read a
-- student's registration too); redefined rather than skipped so the result does
-- not depend on which migration ran first.
drop policy if exists exam_reg_campus_scope on public.exam_registration;
create policy exam_reg_campus_scope on public.exam_registration
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller', 'admissions_officer', 'accountant')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
create policy exam_reg_subject_campus_scope on public.exam_registration_subject
  for select to authenticated
  using (exists (select 1 from public.exam_registration r where r.id = registration_id));
create policy board_group_rule_read on public.board_group_rule
  for select to authenticated
  using ((tenant_id is null or tenant_id = app.auth_tenant_id()) and app.auth_role() not in ('parent', 'student', 'none'));

create or replace function public.save_exam_registration(
  p_student_id         uuid,
  p_session_id         uuid,
  p_board_code         text,
  p_session_year       integer,
  p_session_date       date,
  p_candidate_category text,
  p_group_code         text,
  p_roll_no            text,
  p_subjects           jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_stu    record;
  v_id     uuid;
  v_s      jsonb;
begin
  if v_tenant is null or app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select s.id, s.campus_id into v_stu from public.student s where s.id = p_student_id and s.tenant_id = v_tenant and s.deleted_at is null;
  if v_stu.id is null then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_stu.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = v_tenant) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_candidate_category not in ('regular', 'improvement', 'private') or p_session_date is null then
    raise exception 'REGISTRATION_INVALID' using errcode = '22023';
  end if;
  if jsonb_typeof(coalesce(p_subjects, '[]'::jsonb)) <> 'array' then
    raise exception 'REGISTRATION_INVALID' using errcode = '22023';
  end if;

  insert into public.exam_registration (tenant_id, campus_id, session_id, student_id, board_code, session_year, session_date,
                                        roll_no, candidate_category, group_code, registered_by)
  values (v_tenant, v_stu.campus_id, p_session_id, p_student_id, p_board_code, p_session_year, p_session_date,
          nullif(btrim(coalesce(p_roll_no, '')), ''), p_candidate_category, nullif(btrim(coalesce(p_group_code, '')), ''), (select auth.uid()))
  on conflict (session_id, student_id, board_code) where session_id is not null do update
    set session_year = excluded.session_year, session_date = excluded.session_date, roll_no = excluded.roll_no,
        candidate_category = excluded.candidate_category, group_code = excluded.group_code
  returning id into v_id;

  delete from public.exam_registration_subject where registration_id = v_id;
  for v_s in select * from jsonb_array_elements(coalesce(p_subjects, '[]'::jsonb)) loop
    if nullif(btrim(coalesce(v_s ->> 'subject_code', '')), '') is null or (v_s ->> 'election') not in ('compulsory', 'elective', 'improvement') then
      raise exception 'REGISTRATION_INVALID' using errcode = '22023', detail = 'each subject needs a code and an election';
    end if;
    insert into public.exam_registration_subject (tenant_id, registration_id, subject_code, election)
    values (v_tenant, v_id, upper(btrim(v_s ->> 'subject_code')), v_s ->> 'election')
    on conflict (registration_id, subject_code) do update set election = excluded.election;
  end loop;
  return v_id;
end;
$$;
revoke execute on function public.save_exam_registration(uuid, uuid, text, integer, date, text, text, text, jsonb) from public, anon;
grant execute on function public.save_exam_registration(uuid, uuid, text, integer, date, text, text, text, jsonb) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The fee
-- ═══════════════════════════════════════════════════════════════════════

-- The schedule version in force on a date. Null when nothing prices the
-- candidate, which callers must treat as a blocking error, never as zero.
create or replace function app.fn_board_fee_schedule_on(
  p_tenant_id uuid, p_board text, p_year integer, p_category text, p_as_of date
)
returns public.board_fee_schedule
language sql
stable
security definer
set search_path = ''
as $$
  select s.*
    from public.board_fee_schedule s
   where s.tenant_id = p_tenant_id and s.board_code = p_board and s.session_year = p_year
     and s.candidate_category = p_category
     and s.effective_from <= p_as_of and (s.effective_to is null or s.effective_to >= p_as_of)
   order by s.effective_from desc
   limit 1;
$$;
revoke execute on function app.fn_board_fee_schedule_on(uuid, text, integer, text, date) from public, anon, authenticated;

-- Null-safe form used by views and the export (no schedule -> null).
create or replace function app.fn_board_exam_fee(p_registration_id uuid, p_as_of date default null)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_r      public.exam_registration%rowtype;
  v_sched  public.board_fee_schedule;
  v_papers integer;
begin
  select * into v_r from public.exam_registration where id = p_registration_id and tenant_id = app.auth_tenant_id();
  if v_r.id is null then
    return null;
  end if;
  v_sched := app.fn_board_fee_schedule_on(v_r.tenant_id, v_r.board_code, v_r.session_year, v_r.candidate_category,
                                          coalesce(p_as_of, v_r.session_date));
  if v_sched.id is null then
    return null;
  end if;
  -- Improvement: only the papers being improved are billed (and exported).
  select count(*) filter (where v_r.candidate_category <> 'improvement' or s.election = 'improvement')::int
    into v_papers from public.exam_registration_subject s where s.registration_id = p_registration_id;
  return v_sched.per_candidate_amount + v_sched.per_paper_amount * v_papers;
end;
$$;
revoke execute on function app.fn_board_exam_fee(uuid, date) from public, anon;
-- The reconciliation view is security_invoker, so its viewers call this; it
-- answers only for the caller's own school.
grant execute on function app.fn_board_exam_fee(uuid, date) to authenticated;

create or replace function public.compute_board_exam_fee(p_registration_id uuid, p_as_of date default null)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_r   public.exam_registration%rowtype;
  v_fee bigint;
begin
  select * into v_r from public.exam_registration where id = p_registration_id;
  if v_r.id is null or v_r.tenant_id <> coalesce(app.auth_tenant_id(), v_r.tenant_id) then
    raise exception 'REGISTRATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner')
     and not (v_r.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  v_fee := app.fn_board_exam_fee(p_registration_id, p_as_of);
  if v_fee is null then
    raise exception 'NO_FEE_SCHEDULE' using errcode = '23514',
      detail = format('no %s fee schedule for %s %s is in force on %s', v_r.candidate_category, v_r.board_code, v_r.session_year,
                      coalesce(p_as_of, v_r.session_date));
  end if;
  return v_fee;
end;
$$;
revoke execute on function public.compute_board_exam_fee(uuid, date) from public, anon;
grant execute on function public.compute_board_exam_fee(uuid, date) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- What the parents were billed and paid (the fee module's, read as it stands)
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.fn_board_exam_billed(p_student_id uuid, p_session_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(l.net_paisa), 0)::bigint
    from public.fee_challan c
    join public.enrolment e on e.id = c.enrolment_id
    join public.fee_challan_line l on l.challan_id = c.id
    join public.fee_head h on h.id = l.fee_head_id
   where e.student_id = p_student_id and c.session_id = p_session_id and c.tenant_id = app.auth_tenant_id()
     and c.deleted_at is null and c.status <> 'cancelled'
     and lower(h.code) = 'board_exam';
$$;
revoke execute on function app.fn_board_exam_billed(uuid, uuid) from public, anon;
grant execute on function app.fn_board_exam_billed(uuid, uuid) to authenticated;

create or replace function app.fn_board_exam_collected(p_student_id uuid, p_session_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(a.amount_paisa), 0)::bigint
    from public.fee_payment_allocation a
    join public.fee_challan c on c.id = a.challan_id
    join public.enrolment e on e.id = c.enrolment_id
    join public.fee_head h on h.id = a.fee_head_id
   where e.student_id = p_student_id and c.session_id = p_session_id and c.tenant_id = app.auth_tenant_id()
     and c.deleted_at is null and c.status <> 'cancelled'
     and lower(h.code) = 'board_exam';
$$;
revoke execute on function app.fn_board_exam_collected(uuid, uuid) from public, anon;
grant execute on function app.fn_board_exam_collected(uuid, uuid) to authenticated;

-- The reconciliation, per candidate. security_invoker: rows follow
-- exam_reg_campus_scope, so a campus sees its own candidates and no one else's.
create view public.v_board_exam_reconciliation
with (security_invoker = true) as
select r.id                    as registration_id,
       r.tenant_id,
       r.campus_id,
       r.session_id,
       r.student_id,
       r.board_code,
       r.session_year,
       r.session_date,
       r.candidate_category,
       r.roll_no,
       r.group_code,
       st.name_en              as student_name,
       st.gr_number,
       x.computed_paisa,
       x.billed_paisa,
       x.collected_paisa,
       case when x.computed_paisa is null then null else x.computed_paisa - x.collected_paisa end as outstanding_paisa,
       case
         when x.computed_paisa is null then 'no_schedule'
         when x.collected_paisa = 0 then 'unpaid'
         when x.collected_paisa < x.computed_paisa then 'short'
         when x.collected_paisa = x.computed_paisa then 'paid'
         else 'overpaid' end   as payment_status,
       (x.computed_paisa is not null and x.billed_paisa <> x.computed_paisa) as billing_mismatch
  from public.exam_registration r
  join public.student st on st.id = r.student_id
  cross join lateral (
    select app.fn_board_exam_fee(r.id, r.session_date)            as computed_paisa,
           app.fn_board_exam_billed(r.student_id, r.session_id)    as billed_paisa,
           app.fn_board_exam_collected(r.student_id, r.session_id) as collected_paisa
  ) x;

revoke all on public.v_board_exam_reconciliation from public, anon;
grant select on public.v_board_exam_reconciliation to authenticated;

comment on view public.v_board_exam_reconciliation is
  'FR-T12: per candidate, the board fee computed on the schedule in force at their session date, beside what the fee module billed and collected on the board_exam head.';

create or replace function public.fn_board_exam_reconciliation(
  p_campus_id    uuid,
  p_session_id   uuid,
  p_board_code   text,
  p_session_year integer default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
begin
  if v_tenant is null or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  return (
    with rows as (
      select * from public.v_board_exam_reconciliation v
       where v.campus_id = p_campus_id and v.session_id = p_session_id and v.board_code = p_board_code
         and (p_session_year is null or v.session_year = p_session_year)
    )
    select jsonb_build_object(
      'board_code', p_board_code,
      'candidates', (select count(*) from rows),
      'computed_total_paisa', coalesce((select sum(computed_paisa) from rows), 0),
      'billed_total_paisa', coalesce((select sum(billed_paisa) from rows), 0),
      'collected_total_paisa', coalesce((select sum(collected_paisa) from rows), 0),
      'difference_paisa', coalesce((select sum(computed_paisa) from rows), 0) - coalesce((select sum(collected_paisa) from rows), 0),
      'by_category', coalesce((select jsonb_object_agg(candidate_category, jsonb_build_object(
                          'candidates', n, 'computed_paisa', computed)) from (
                        select candidate_category, count(*) n, coalesce(sum(computed_paisa), 0) computed from rows group by candidate_category) c), '{}'::jsonb),
      'unpaid', coalesce((select jsonb_agg(jsonb_build_object('registration_id', registration_id, 'student_name', student_name,
                          'gr_number', gr_number, 'candidate_category', candidate_category, 'owed_paisa', computed_paisa) order by student_name)
                          from rows where payment_status = 'unpaid'), '[]'::jsonb),
      'short', coalesce((select jsonb_agg(jsonb_build_object('registration_id', registration_id, 'student_name', student_name,
                          'gr_number', gr_number, 'candidate_category', candidate_category, 'owed_paisa', outstanding_paisa) order by student_name)
                          from rows where payment_status = 'short'), '[]'::jsonb),
      'billing_mismatch', coalesce((select jsonb_agg(jsonb_build_object('registration_id', registration_id, 'student_name', student_name,
                          'gr_number', gr_number, 'computed_paisa', computed_paisa, 'billed_paisa', billed_paisa) order by student_name)
                          from rows where billing_mismatch), '[]'::jsonb),
      'no_schedule', coalesce((select jsonb_agg(jsonb_build_object('registration_id', registration_id, 'student_name', student_name,
                          'gr_number', gr_number, 'candidate_category', candidate_category) order by student_name)
                          from rows where payment_status = 'no_schedule'), '[]'::jsonb))
  );
end;
$$;
revoke execute on function public.fn_board_exam_reconciliation(uuid, uuid, text, integer) from public, anon;
grant execute on function public.fn_board_exam_reconciliation(uuid, uuid, text, integer) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The export run
-- ═══════════════════════════════════════════════════════════════════════

create table public.board_exam_form_export (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenant(id) on delete cascade,
  campus_id             uuid not null references public.campus(id) on delete cascade,
  session_id            uuid not null references public.academic_session(id) on delete cascade,
  board_code            text not null check (board_code in ('FBISE', 'PUNJAB', 'SINDH', 'KPK', 'BALOCHISTAN', 'AKU_EB', 'CAMBRIDGE')),
  session_year          integer not null,
  status                text not null default 'draft' check (status in ('draft', 'completed', 'failed')),
  row_count             integer,
  blocking_count        integer not null default 0,
  warning_count         integer not null default 0,
  computed_total_paisa  bigint,
  collected_total_paisa bigint,
  file_path             text,
  checksum              text,
  error                 text,
  requested_by          uuid references public.app_user(user_id),
  requested_at          timestamptz not null default now(),
  validated_at          timestamptz,
  generated_by          uuid references public.app_user(user_id),
  generated_at          timestamptz
);
create index idx_board_exam_form_export_scope on public.board_exam_form_export (tenant_id, campus_id, requested_at desc);

create table public.board_exam_form_error (
  id              uuid primary key default gen_random_uuid(),
  export_id       uuid not null references public.board_exam_form_export(id) on delete cascade,
  registration_id uuid not null references public.exam_registration(id) on delete cascade,
  rule_code       text not null,
  severity        text not null check (severity in ('blocking', 'warning')),
  subject_code    text,
  message         text not null
);
create index idx_board_exam_form_error_export on public.board_exam_form_error (export_id);
create index idx_board_exam_form_error_registration on public.board_exam_form_error (registration_id);

create trigger board_exam_form_export_audit after insert or update or delete on public.board_exam_form_export
  for each row execute function app.tg_audit_row();

alter table public.board_exam_form_export enable row level security;
alter table public.board_exam_form_error enable row level security;
create policy board_exam_form_export_scope on public.board_exam_form_export
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller', 'accountant')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
create policy board_exam_form_error_scope on public.board_exam_form_error
  for select to authenticated
  using (exists (select 1 from public.board_exam_form_export e where e.id = export_id));

create or replace function app.fn_assert_board_exam_export_access(p_export_id uuid, p_write boolean)
returns public.board_exam_form_export
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_run public.board_exam_form_export;
begin
  select * into v_run from public.board_exam_form_export where id = p_export_id and tenant_id = app.auth_tenant_id();
  if v_run.id is null then
    raise exception 'EXPORT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not (case when p_write then app.auth_role() in ('super_admin', 'owner', 'principal', 'exam_controller')
               else app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller', 'accountant') end) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_run.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return v_run;
end;
$$;
revoke execute on function app.fn_assert_board_exam_export_access(uuid, boolean) from public, anon, authenticated;

create or replace function public.begin_board_exam_form_export(
  p_campus_id uuid, p_session_id uuid, p_board_code text, p_session_year integer
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
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = v_tenant) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.exam_registration r
                  where r.campus_id = p_campus_id and r.session_id = p_session_id and r.board_code = p_board_code and r.session_year = p_session_year) then
    raise exception 'NO_REGISTRATIONS' using errcode = '23514';
  end if;
  insert into public.board_exam_form_export (tenant_id, campus_id, session_id, board_code, session_year, requested_by)
  values (v_tenant, p_campus_id, p_session_id, p_board_code, p_session_year, (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.begin_board_exam_form_export(uuid, uuid, text, integer) from public, anon;
grant execute on function public.begin_board_exam_form_export(uuid, uuid, text, integer) to authenticated;

-- The same pass the dashboard and the generator use: one implementation, so the
-- readiness screen cannot disagree with the gate.
create or replace function public.validate_board_exam_form_export(p_export_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run  public.board_exam_form_export;
  v_reg  record;
  v_rule record;
  v_total bigint;
  v_collected bigint;
begin
  v_run := app.fn_assert_board_exam_export_access(p_export_id, true);
  if v_run.status <> 'draft' then
    raise exception 'RUN_NOT_EDITABLE' using errcode = '23514';
  end if;
  delete from public.board_exam_form_error where export_id = p_export_id;

  for v_reg in
    select r.* from public.exam_registration r
     where r.campus_id = v_run.campus_id and r.session_id = v_run.session_id and r.board_code = v_run.board_code and r.session_year = v_run.session_year
     order by r.id
  loop
    if not exists (select 1 from public.exam_registration_subject s where s.registration_id = v_reg.id) then
      insert into public.board_exam_form_error (export_id, registration_id, rule_code, severity, message)
      values (p_export_id, v_reg.id, 'NO_SUBJECTS', 'blocking', 'The registration has no subjects.');
    elsif v_reg.candidate_category = 'improvement' and not exists (
            select 1 from public.exam_registration_subject s where s.registration_id = v_reg.id and s.election = 'improvement') then
      insert into public.board_exam_form_error (export_id, registration_id, rule_code, severity, message)
      values (p_export_id, v_reg.id, 'IMPROVEMENT_NO_SUBJECTS', 'blocking', 'An improvement candidate has no subject marked for improvement.');
    end if;

    -- AC2: the group's mandatory subject codes, each named when missing.
    if v_reg.candidate_category <> 'improvement' and v_reg.group_code is not null then
      for v_rule in
        select distinct g.subject_code
          from public.board_group_rule g
         where g.board_code = v_reg.board_code and g.group_code = v_reg.group_code
           and (g.tenant_id is null or g.tenant_id = v_reg.tenant_id)
           and not exists (select 1 from public.exam_registration_subject s
                            where s.registration_id = v_reg.id and s.subject_code = g.subject_code)
         order by g.subject_code
      loop
        insert into public.board_exam_form_error (export_id, registration_id, rule_code, severity, subject_code, message)
        values (p_export_id, v_reg.id, 'MISSING_MANDATORY_SUBJECT', 'blocking', v_rule.subject_code,
                format('Group %s requires subject code %s, which the registration omits.', v_reg.group_code, v_rule.subject_code));
      end loop;
    end if;

    if app.fn_board_exam_fee(v_reg.id, v_reg.session_date) is null then
      insert into public.board_exam_form_error (export_id, registration_id, rule_code, severity, message)
      values (p_export_id, v_reg.id, 'NO_FEE_SCHEDULE', 'blocking',
              format('No %s fee schedule for %s %s is in force on %s.', v_reg.candidate_category, v_reg.board_code, v_reg.session_year, v_reg.session_date));
    end if;

    if not public.has_consent(v_reg.student_id, 'third_party_data_sharing') then
      insert into public.board_exam_form_error (export_id, registration_id, rule_code, severity, message)
      values (p_export_id, v_reg.id, 'CONSENT_MISSING', 'blocking', 'No guardian consent to share this student''s data with the board.');
    end if;

    if v_reg.roll_no is null then
      insert into public.board_exam_form_error (export_id, registration_id, rule_code, severity, message)
      values (p_export_id, v_reg.id, 'ROLL_NO_PENDING', 'warning', 'No board roll number has been recorded yet.');
    end if;
  end loop;

  select coalesce(sum(app.fn_board_exam_fee(r.id, r.session_date)), 0),
         coalesce(sum(app.fn_board_exam_collected(r.student_id, r.session_id)), 0)
    into v_total, v_collected
    from public.exam_registration r
   where r.campus_id = v_run.campus_id and r.session_id = v_run.session_id and r.board_code = v_run.board_code and r.session_year = v_run.session_year;

  update public.board_exam_form_export
     set validated_at = now(),
         blocking_count = (select count(*) from public.board_exam_form_error where export_id = p_export_id and severity = 'blocking'),
         warning_count = (select count(*) from public.board_exam_form_error where export_id = p_export_id and severity = 'warning'),
         computed_total_paisa = v_total, collected_total_paisa = v_collected
   where id = p_export_id;

  return public.fn_board_exam_form_readiness(p_export_id);
end;
$$;
revoke execute on function public.validate_board_exam_form_export(uuid) from public, anon;
grant execute on function public.validate_board_exam_form_export(uuid) to authenticated;

create or replace function public.fn_board_exam_form_readiness(p_export_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_run public.board_exam_form_export;
begin
  v_run := app.fn_assert_board_exam_export_access(p_export_id, false);
  return jsonb_build_object(
    'export_id', v_run.id, 'status', v_run.status, 'validated_at', v_run.validated_at,
    'blocking_count', v_run.blocking_count, 'warning_count', v_run.warning_count,
    'computed_total_paisa', v_run.computed_total_paisa, 'collected_total_paisa', v_run.collected_total_paisa,
    'can_generate', v_run.status = 'draft' and v_run.validated_at is not null and v_run.blocking_count = 0,
    'errors', coalesce((
      select jsonb_agg(jsonb_build_object(
               'registration_id', e.registration_id, 'student_name', st.name_en, 'gr_number', st.gr_number,
               'rule_code', e.rule_code, 'severity', e.severity, 'subject_code', e.subject_code, 'message', e.message)
             order by e.severity, st.name_en, e.rule_code)
        from public.board_exam_form_error e
        join public.exam_registration r on r.id = e.registration_id
        join public.student st on st.id = r.student_id
       where e.export_id = p_export_id), '[]'::jsonb));
end;
$$;
revoke execute on function public.fn_board_exam_form_readiness(uuid) from public, anon;
grant execute on function public.fn_board_exam_form_readiness(uuid) to authenticated;

create or replace function public.fn_board_exam_form_headers(p_export_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.fn_assert_board_exam_export_access(p_export_id, false);
  return '["Roll No","GR No","Candidate Name","Father Name","Group","Category","Subjects","Fee (PKR)"]'::jsonb;
end;
$$;
revoke execute on function public.fn_board_exam_form_headers(uuid) from public, anon;
grant execute on function public.fn_board_exam_form_headers(uuid) to authenticated;

-- One row per candidate. An improvement candidate lists ONLY the papers being
-- improved (AC3); the fee is the schedule's as at their session date (AC4).
create or replace function public.fn_board_exam_form_rows(p_export_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_run public.board_exam_form_export;
begin
  v_run := app.fn_assert_board_exam_export_access(p_export_id, false);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'registration_id', r.id,
             'cells', jsonb_build_array(
               r.roll_no, st.gr_number, st.name_en, st.father_name_en, r.group_code, r.candidate_category,
               (select string_agg(s.subject_code, ' ' order by s.subject_code)
                  from public.exam_registration_subject s
                 where s.registration_id = r.id and (r.candidate_category <> 'improvement' or s.election = 'improvement')),
               to_char(app.fn_board_exam_fee(r.id, r.session_date)::numeric / 100, 'FM999999990.00')))
           order by r.roll_no nulls last, st.name_en)
      from public.exam_registration r
      join public.student st on st.id = r.student_id
     where r.campus_id = v_run.campus_id and r.session_id = v_run.session_id and r.board_code = v_run.board_code
       and r.session_year = v_run.session_year and st.deleted_at is null), '[]'::jsonb);
end;
$$;
revoke execute on function public.fn_board_exam_form_rows(uuid) from public, anon;
grant execute on function public.fn_board_exam_form_rows(uuid) to authenticated;

create or replace function public.complete_board_exam_form_export(p_export_id uuid, p_row_count integer, p_file_path text, p_checksum text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run public.board_exam_form_export;
begin
  v_run := app.fn_assert_board_exam_export_access(p_export_id, true);
  if v_run.status <> 'draft' then
    raise exception 'RUN_NOT_EDITABLE' using errcode = '23514';
  end if;
  if v_run.validated_at is null then
    raise exception 'EXPORT_NOT_VALIDATED' using errcode = '23514';
  end if;
  if exists (select 1 from public.board_exam_form_error where export_id = p_export_id and severity = 'blocking') then
    raise exception 'EXPORT_BLOCKED' using errcode = '23514';
  end if;
  if p_file_path is null or btrim(p_file_path) = '' or p_checksum is null or btrim(p_checksum) = '' then
    raise exception 'EXPORT_FILE_MISSING' using errcode = '23514';
  end if;
  update public.board_exam_form_export
     set status = 'completed', row_count = p_row_count, file_path = p_file_path, checksum = p_checksum,
         generated_by = (select auth.uid()), generated_at = now()
   where id = p_export_id;
end;
$$;
revoke execute on function public.complete_board_exam_form_export(uuid, integer, text, text) from public, anon;
grant execute on function public.complete_board_exam_form_export(uuid, integer, text, text) to authenticated;

create or replace function public.fail_board_exam_form_export(p_export_id uuid, p_error text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run public.board_exam_form_export;
begin
  v_run := app.fn_assert_board_exam_export_access(p_export_id, true);
  if v_run.status <> 'draft' then
    raise exception 'RUN_NOT_EDITABLE' using errcode = '23514';
  end if;
  update public.board_exam_form_export set status = 'failed', error = left(p_error, 500) where id = p_export_id;
end;
$$;
revoke execute on function public.fail_board_exam_form_export(uuid, text) from public, anon;
grant execute on function public.fail_board_exam_form_export(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Storage: the board-exports bucket (FR-T11's), {tenant}/{export}/file.csv
-- ═══════════════════════════════════════════════════════════════════════

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('board-exports', 'board-exports', false, 52428800, array['text/csv', 'text/plain'])
on conflict (id) do nothing;

create policy board_exam_form_export_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'board-exports'
    and (storage.foldername(name))[1] = app.auth_tenant_id()::text
    and exists (
      select 1 from public.board_exam_form_export e
       where e.id::text = (storage.foldername(name))[2]
         and e.tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or e.campus_id = any (app.auth_campus_ids()))));
