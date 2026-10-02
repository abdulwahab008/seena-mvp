-- FR-H01 (homework assignment creation) and FR-H04 (student/parent
-- homework feed).
--
-- Scope cuts:
--   * hw_student_read (a student's OWN login) is not built here — the
--     student table has no auth_user_id column and no FR has shipped a
--     student-facing sign-in mechanism yet (only staff and, as of FR-C11,
--     guardians can authenticate). Shipping an RLS branch for a role that
--     can never hold a session yet would be dead code, same reasoning
--     FR-A08's own migration gave for skipping its break-glass overlay.
--     hw_parent_read (via guardian, FR-C11's own auth_guardian_student_
--     ids()) is the only student-side read path this migration adds.
--   * homework_submission doesn't exist (no FR for it has shipped), so the
--     feed's "Overdue" grouping is computed from due_date alone, not
--     "due and not submitted" as the FR's AC literally states — the same
--     kind of documented, dependency-driven narrowing this session has
--     used throughout (e.g. class_level's deferred DELETE path).
--   * The 90-day-ahead "warning, not block" AC and the local-draft-autosave
--     note are both client-side UX concerns with nothing to build at the
--     DB layer; the UI still enforces them (see students/actions.ts
--     equivalent — createHomework's own zod schema warns, never blocks).

create type public.homework_status as enum ('draft', 'published', 'archived');

create table public.homework (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant(id) on delete cascade,
  campus_id          uuid not null references public.campus(id) on delete cascade,
  session_id         uuid not null references public.academic_session(id) on delete cascade,
  section_id         uuid not null references public.class_section(id) on delete cascade,
  subject_id         uuid not null references public.subject(id),
  teacher_id         uuid not null references public.app_user(user_id),
  title              varchar(120) not null,
  description        text,
  assigned_date      date not null default current_date,
  due_date           date not null,
  estimated_minutes  int,
  status             public.homework_status not null default 'draft',
  published_at       timestamptz,
  created_at         timestamptz not null default now(),
  constraint chk_hw_dates check (due_date >= assigned_date),
  constraint chk_hw_description_length check (description is null or char_length(description) <= 4000),
  constraint chk_hw_estimated_minutes check (estimated_minutes is null or estimated_minutes > 0)
);

create index idx_hw_section_due on public.homework (campus_id, section_id, due_date);
create index idx_hw_published on public.homework (section_id, status, published_at);

create trigger homework_audit after insert or update or delete on public.homework
  for each row execute function app.tg_audit_row();

alter publication supabase_realtime add table public.homework;

-- ── create_homework ───────────────────────────────────────────────────
-- The teacher_subject_assignment (section_subject_teacher) join is the
-- real authorisation boundary, not section membership — a class teacher
-- of 8-B isn't automatically qualified to post Chemistry homework there
-- unless they're also its assigned subject teacher (this FR's own Notes).

create or replace function public.create_homework(
  p_section_id        uuid,
  p_subject_id        uuid,
  p_title             text,
  p_due_date          date,
  p_assigned_date     date default current_date,
  p_description       text default null,
  p_estimated_minutes int default null,
  p_status            public.homework_status default 'draft'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_section public.class_section%rowtype;
  v_id      uuid;
begin
  select * into v_section from public.class_section where id = p_section_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_role() not in ('super_admin', 'owner', 'principal') and not exists (
    select 1 from public.section_subject_teacher
     where section_id = p_section_id and subject_id = p_subject_id
       and staff_id = (select auth.uid())
       and validity @> p_assigned_date
  ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_due_date < p_assigned_date then
    raise exception 'DUE_BEFORE_ASSIGNED' using errcode = '22023';
  end if;
  if p_status not in ('draft', 'published') then
    raise exception 'STATUS_INVALID' using errcode = '22023';
  end if;
  -- Named, app-level checks ahead of the same-shaped DB constraints
  -- (chk_hw_description_length, chk_hw_estimated_minutes) — same
  -- redundant-but-friendlier-error pattern as create_section's own
  -- CAPACITY_OUT_OF_RANGE ahead of the table's capacity check.
  if p_description is not null and char_length(p_description) > 4000 then
    raise exception 'DESCRIPTION_TOO_LONG' using errcode = '22023';
  end if;
  if p_estimated_minutes is not null and p_estimated_minutes <= 0 then
    raise exception 'ESTIMATED_MINUTES_INVALID' using errcode = '22023';
  end if;

  insert into public.homework (
    tenant_id, campus_id, session_id, section_id, subject_id, teacher_id,
    title, description, assigned_date, due_date, estimated_minutes, status, published_at
  ) values (
    app.auth_tenant_id(), v_section.campus_id, v_section.session_id, p_section_id, p_subject_id, (select auth.uid()),
    p_title, p_description, p_assigned_date, p_due_date, p_estimated_minutes, p_status,
    case when p_status = 'published' then now() end
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_homework(uuid, uuid, text, date, date, text, int, public.homework_status) from public, anon;
grant execute on function public.create_homework(uuid, uuid, text, date, date, text, int, public.homework_status) to authenticated;

-- ── publish_homework ──────────────────────────────────────────────────

create or replace function public.publish_homework(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hw public.homework%rowtype;
begin
  select * into v_hw from public.homework where id = p_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'HOMEWORK_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_role() not in ('super_admin', 'owner', 'principal') and v_hw.teacher_id <> (select auth.uid()) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_hw.status = 'published' then
    raise exception 'ALREADY_PUBLISHED' using errcode = '55000';
  end if;

  update public.homework set status = 'published', published_at = now() where id = p_id;
end;
$$;

revoke execute on function public.publish_homework(uuid) from public, anon;
grant execute on function public.publish_homework(uuid) to authenticated;

-- ── RLS ──────────────────────────────────────────────────────────────────

alter table public.homework enable row level security;

create policy homework_staff_read on public.homework
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'none')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- AC: a draft is invisible to a parent even for their own child — only
-- published work ever crosses into hw_parent_read.
create policy homework_parent_read on public.homework
  for select to authenticated
  using (
    status = 'published'
    and section_id in (
      select e.section_id from public.enrolment e
       where e.status = 'active' and e.student_id = any(app.auth_guardian_student_ids())
    )
  );

-- ── v_student_homework_feed ──────────────────────────────────────────────
-- security_invoker: RLS on the homework/subject base tables (above) is
-- what actually scopes this, exactly like v_onboarding_summary and
-- v_teach_scope_exception already do in this codebase.

create or replace view public.v_student_homework_feed
with (security_invoker = true) as
select
  h.id,
  h.section_id,
  h.subject_id,
  s.name_en as subject_name_en,
  s.name_ur as subject_name_ur,
  h.title,
  h.description,
  h.assigned_date,
  h.due_date,
  h.estimated_minutes,
  h.published_at,
  (h.due_date < current_date) as is_overdue
from public.homework h
join public.subject s on s.id = h.subject_id
where h.status = 'published';

revoke all on public.v_student_homework_feed from public, anon;
grant select on public.v_student_homework_feed to authenticated;
