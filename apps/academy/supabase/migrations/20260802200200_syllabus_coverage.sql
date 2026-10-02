-- FR-H11: syllabus coverage tracking.
--
-- A teacher marks each syllabus unit of a (section, subject) as not started,
-- in progress or completed. One row per (section, subject, unit); the latest
-- write wins and every write -- including the ones that lose -- is kept in
-- syllabus_coverage_history with the acting user, so two teachers sharing a
-- subject can both see what the other did.
--
-- Coverage is deliberately decoupled from lesson plans (FR-H10): teachers
-- update coverage because the Principal asks, but will not maintain weekly
-- plans, so nothing here reads lesson_plan.
--
-- Dates:
--   * completed without a start date  -> started_on = completed_on and the
--     row says 'start date inferred' (start_inferred = true);
--   * completed_on before started_on  -> refused with
--     'Completion date cannot precede start date' (also chk_coverage_dates);
--   * completed -> in_progress        -> completed_on is cleared and the
--     transition is in the history;
--   * not_started                     -> both dates cleared.
--
-- Percentage: coverage_pct() weights each unit by planned_periods, not by
-- unit count. A 2-period introduction and a 14-period core chapter are not
-- equal progress. Only completed units count (an in-progress unit contributes
-- nothing until it is finished). If a syllabus has no planned periods at all,
-- units weigh the same. A section tracks one board's syllabus (the board of
-- the units it has coverage rows for, otherwise the alphabetically first
-- board defined), so FBISE and Punjab Board versions are never mixed.

create type public.coverage_status as enum ('not_started', 'in_progress', 'completed');

create table public.syllabus_coverage (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  session_id       uuid not null references public.academic_session(id) on delete cascade,
  section_id       uuid not null references public.class_section(id) on delete cascade,
  subject_id       uuid not null references public.subject(id),
  syllabus_unit_id uuid not null references public.syllabus_unit(id) on delete cascade,
  status           public.coverage_status not null default 'not_started',
  started_on       date,
  completed_on     date,
  start_inferred   boolean not null default false,
  note             text,
  periods_used     int not null default 0 check (periods_used >= 0 and periods_used <= 1000),
  updated_by       uuid references auth.users(id),
  updated_at       timestamptz not null default now(),
  constraint uq_syllabus_coverage unique (section_id, subject_id, syllabus_unit_id),
  constraint chk_coverage_dates check (completed_on is null or started_on is null or completed_on >= started_on),
  constraint chk_coverage_status_dates check (
    (status = 'not_started' and started_on is null and completed_on is null)
    or (status = 'in_progress' and completed_on is null)
    or (status = 'completed' and completed_on is not null)
  )
);
create index idx_coverage_section on public.syllabus_coverage (section_id, subject_id, status);
create index idx_coverage_unit on public.syllabus_coverage (syllabus_unit_id);
create index idx_coverage_tenant on public.syllabus_coverage (tenant_id, campus_id);
create index idx_coverage_session on public.syllabus_coverage (session_id);
create index idx_coverage_subject on public.syllabus_coverage (subject_id);

create table public.syllabus_coverage_history (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant(id) on delete cascade,
  coverage_id        uuid not null references public.syllabus_coverage(id) on delete cascade,
  old_status         public.coverage_status,
  new_status         public.coverage_status not null,
  old_completed_on   date,
  new_completed_on   date,
  changed_by         uuid references auth.users(id),
  changed_at         timestamptz not null default clock_timestamp()
);
create index idx_coverage_history_coverage on public.syllabus_coverage_history (coverage_id, changed_at);
create index idx_coverage_history_tenant on public.syllabus_coverage_history (tenant_id);

alter table public.syllabus_coverage enable row level security;
alter table public.syllabus_coverage_history enable row level security;
-- Staff of the campus read; nobody writes directly (writes go through
-- set_syllabus_coverage()). Parents get a separate, column-limited view (FR-H13).
create policy coverage_staff_read on public.syllabus_coverage for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none', 'accountant')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy coverage_history_staff_read on public.syllabus_coverage_history for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.syllabus_coverage c where c.id = coverage_id));

-- The board whose syllabus a section is following for a subject.
create or replace function app.fn_section_board(p_section_id uuid, p_subject_id uuid)
returns public.board
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select u.board from public.syllabus_coverage c join public.syllabus_unit u on u.id = c.syllabus_unit_id
      where c.section_id = p_section_id and c.subject_id = p_subject_id order by c.updated_at desc limit 1),
    (select min(u.board::text)::public.board
       from public.class_section s join public.syllabus_unit u
         on u.campus_id = s.campus_id and u.session_id = s.session_id and u.class_level_id = s.class_level_id and u.subject_id = p_subject_id
      where s.id = p_section_id));
$$;
revoke execute on function app.fn_section_board(uuid, uuid) from public, anon, authenticated;

-- Coverage by planned-period weight, 0..100 with two decimals; NULL when the
-- section has no syllabus for the subject.
create or replace function app.fn_coverage_pct(p_section_id uuid, p_subject_id uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  with sec as (select * from public.class_section where id = p_section_id),
  b as (select app.fn_section_board(p_section_id, p_subject_id) as board),
  units as (
    select u.id, u.planned_periods from sec s join b on true join public.syllabus_unit u
      on u.campus_id = s.campus_id and u.session_id = s.session_id and u.class_level_id = s.class_level_id and u.subject_id = p_subject_id and u.board = b.board
  ),
  tot as (select count(*) n, sum(planned_periods) periods from units)
  select case when tot.n = 0 then null
              else round(100.0 * coalesce(sum(case when c.status = 'completed' then (case when tot.periods = 0 then 1 else u.planned_periods end) end), 0)
                         / (case when tot.periods = 0 then tot.n else tot.periods end), 2) end
    from tot left join units u on true
    left join public.syllabus_coverage c on c.syllabus_unit_id = u.id and c.section_id = p_section_id and c.subject_id = p_subject_id
   group by tot.n, tot.periods;
$$;
revoke execute on function app.fn_coverage_pct(uuid, uuid) from public, anon, authenticated;

create or replace function public.coverage_pct(p_section_id uuid, p_subject_id uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_sec public.class_section%rowtype;
begin
  select * into v_sec from public.class_section where id = p_section_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() in ('parent', 'student', 'none', 'accountant')
     or (app.auth_role() not in ('owner', 'super_admin') and not (v_sec.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return app.fn_coverage_pct(p_section_id, p_subject_id);
end;
$$;
revoke execute on function public.coverage_pct(uuid, uuid) from public, anon;
grant execute on function public.coverage_pct(uuid, uuid) to authenticated;

create or replace function public.set_syllabus_coverage(
  p_section_id uuid, p_subject_id uuid, p_unit_id uuid, p_status public.coverage_status,
  p_started_on date default null, p_completed_on date default null, p_periods_used int default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sec     public.class_section%rowtype;
  v_unit    public.syllabus_unit%rowtype;
  v_old     public.syllabus_coverage%rowtype;
  v_today   date := app.fn_karachi_today();
  v_started date;
  v_done    date;
  v_inferred boolean := false;
  v_id      uuid;
begin
  select * into v_sec from public.class_section where id = p_section_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal')
     and not exists (select 1 from public.section_subject_teacher t where t.section_id = p_section_id and t.subject_id = p_subject_id
                        and t.staff_id = (select auth.uid()) and t.validity @> v_today)
     and not exists (select 1 from public.section_class_teacher ct where ct.section_id = p_section_id and ct.staff_id = (select auth.uid()) and ct.validity @> v_today) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() in ('principal', 'vice_principal') and not (v_sec.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_unit from public.syllabus_unit
   where id = p_unit_id and tenant_id = v_sec.tenant_id and campus_id = v_sec.campus_id and session_id = v_sec.session_id
     and class_level_id = v_sec.class_level_id and subject_id = p_subject_id;
  if not found then
    raise exception 'UNIT_NOT_IN_SYLLABUS' using errcode = '22023';
  end if;

  select * into v_old from public.syllabus_coverage where section_id = p_section_id and subject_id = p_subject_id and syllabus_unit_id = p_unit_id for update;

  if p_status = 'not_started' then
    v_started := null;
    v_done := null;
  elsif p_status = 'in_progress' then
    v_started := coalesce(p_started_on, v_old.started_on, v_today);
    v_done := null;
    v_inferred := p_started_on is null and coalesce(v_old.start_inferred, false);
  else
    v_done := coalesce(p_completed_on, v_today);
    v_started := coalesce(p_started_on, v_old.started_on);
    if v_started is null then
      v_started := v_done;
      v_inferred := true;
    else
      v_inferred := p_started_on is null and coalesce(v_old.start_inferred, false);
    end if;
  end if;
  if v_done is not null and v_started is not null and v_done < v_started then
    raise exception 'Completion date cannot precede start date' using errcode = '23514';
  end if;

  insert into public.syllabus_coverage (tenant_id, campus_id, session_id, section_id, subject_id, syllabus_unit_id, status, started_on, completed_on, start_inferred, note, periods_used, updated_by, updated_at)
  values (v_sec.tenant_id, v_sec.campus_id, v_sec.session_id, p_section_id, p_subject_id, p_unit_id, p_status, v_started, v_done, v_inferred,
          case when v_inferred then 'start date inferred' end, coalesce(p_periods_used, 0), (select auth.uid()), clock_timestamp())
  on conflict (section_id, subject_id, syllabus_unit_id) do update
     set status = excluded.status, started_on = excluded.started_on, completed_on = excluded.completed_on,
         start_inferred = excluded.start_inferred, note = excluded.note,
         periods_used = coalesce(p_periods_used, public.syllabus_coverage.periods_used),
         updated_by = excluded.updated_by, updated_at = excluded.updated_at
  returning id into v_id;

  insert into public.syllabus_coverage_history (tenant_id, coverage_id, old_status, new_status, old_completed_on, new_completed_on, changed_by)
  values (v_sec.tenant_id, v_id, v_old.status, p_status, v_old.completed_on, v_done, (select auth.uid()));
  return v_id;
end;
$$;
revoke execute on function public.set_syllabus_coverage(uuid, uuid, uuid, public.coverage_status, date, date, int) from public, anon;
grant execute on function public.set_syllabus_coverage(uuid, uuid, uuid, public.coverage_status, date, date, int) to authenticated;
