-- FR-H10: lesson plan creation against syllabus units.
--
-- One plan per (section, subject, week). A teacher assigned to that section and
-- subject links the week to syllabus topics of THAT class and subject (topics of
-- any other subject are refused, which is also why the picker never offers
-- them), writes objectives (1000 characters) and optional resources. The week
-- is always the Monday of the ISO week, whatever date was given. Marking a plan
-- completed stamps completed_at and completion_date (Asia/Karachi), which is
-- what coverage tracking reads. Plans are optional: nothing else requires one.
-- A Principal reads every plan of the campus, read-only.

create table public.lesson_plan (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  session_id      uuid not null references public.academic_session(id) on delete cascade,
  section_id      uuid not null references public.class_section(id) on delete cascade,
  subject_id      uuid not null references public.subject(id),
  teacher_id      uuid not null references public.app_user(user_id),
  week_start_date date not null check (extract(isodow from week_start_date) = 1),
  objectives      text check (objectives is null or char_length(objectives) <= 1000),
  resources       text check (resources is null or char_length(resources) <= 1000),
  status          text not null default 'planned' check (status in ('planned', 'in_progress', 'completed')),
  completed_at    timestamptz,
  completion_date date,
  created_at      timestamptz not null default now(),
  constraint uq_lesson_plan_week unique (section_id, subject_id, week_start_date),
  constraint chk_lesson_plan_completed check ((status = 'completed') = (completed_at is not null and completion_date is not null))
);
create index idx_lesson_plan_week on public.lesson_plan (campus_id, week_start_date);
create index idx_lesson_plan_teacher on public.lesson_plan (teacher_id, week_start_date);
create index idx_lesson_plan_tenant on public.lesson_plan (tenant_id);
create index idx_lesson_plan_session on public.lesson_plan (session_id);
create index idx_lesson_plan_subject on public.lesson_plan (subject_id);

create table public.lesson_plan_topic (
  lesson_plan_id    uuid not null references public.lesson_plan(id) on delete cascade,
  syllabus_topic_id uuid not null references public.syllabus_topic(id) on delete cascade,
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  primary key (lesson_plan_id, syllabus_topic_id)
);
create index idx_lesson_plan_topic_topic on public.lesson_plan_topic (syllabus_topic_id);
create index idx_lesson_plan_topic_tenant on public.lesson_plan_topic (tenant_id);

create trigger lesson_plan_audit after insert or update or delete on public.lesson_plan
  for each row execute function app.tg_audit_row();

alter table public.lesson_plan enable row level security;
alter table public.lesson_plan_topic enable row level security;
create policy lesson_plan_principal_read on public.lesson_plan for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (teacher_id = (select auth.uid())
              or (app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'exam_controller')
                  and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())))));
create policy lesson_plan_topic_read on public.lesson_plan_topic for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.lesson_plan p where p.id = lesson_plan_id));

create or replace function app.fn_lesson_plan_check(p_section_id uuid, p_subject_id uuid, p_week date)
returns public.class_section
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
  if app.auth_role() not in ('owner', 'super_admin') and not exists (
       select 1 from public.section_subject_teacher t
        where t.section_id = p_section_id and t.subject_id = p_subject_id and t.staff_id = (select auth.uid()) and t.validity && daterange(p_week, p_week + 6, '[]')) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return v_sec;
end;
$$;
revoke execute on function app.fn_lesson_plan_check(uuid, uuid, date) from public, anon, authenticated;

create or replace function app.fn_lesson_plan_set_topics(p_plan_id uuid, p_section public.class_section, p_subject_id uuid, p_topic_ids uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_topic_ids is not null and cardinality(p_topic_ids) > 0 then
    if exists (
      select 1 from unnest(p_topic_ids) x
       where not exists (
         select 1 from public.syllabus_topic t join public.syllabus_unit u on u.id = t.syllabus_unit_id
          where t.id = x and u.tenant_id = p_section.tenant_id and u.campus_id = p_section.campus_id and u.session_id = p_section.session_id
            and u.class_level_id = p_section.class_level_id and u.subject_id = p_subject_id)
    ) then
      raise exception 'TOPIC_NOT_IN_SYLLABUS' using errcode = '22023';
    end if;
  end if;
  delete from public.lesson_plan_topic where lesson_plan_id = p_plan_id;
  insert into public.lesson_plan_topic (lesson_plan_id, syllabus_topic_id, tenant_id)
  select p_plan_id, distinct_id, p_section.tenant_id from (select distinct unnest(coalesce(p_topic_ids, '{}'::uuid[])) as distinct_id) d;
end;
$$;
revoke execute on function app.fn_lesson_plan_set_topics(uuid, public.class_section, uuid, uuid[]) from public, anon, authenticated;

create or replace function public.create_lesson_plan(p_section_id uuid, p_subject_id uuid, p_week_start date, p_objectives text default null, p_resources text default null, p_topic_ids uuid[] default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_week date := date_trunc('week', p_week_start)::date;
  v_sec  public.class_section%rowtype;
  v_id   uuid;
begin
  v_sec := app.fn_lesson_plan_check(p_section_id, p_subject_id, v_week);
  if char_length(coalesce(p_objectives, '')) > 1000 or char_length(coalesce(p_resources, '')) > 1000 then
    raise exception 'TEXT_TOO_LONG' using errcode = '23514';
  end if;
  insert into public.lesson_plan (tenant_id, campus_id, session_id, section_id, subject_id, teacher_id, week_start_date, objectives, resources)
  values (v_sec.tenant_id, v_sec.campus_id, v_sec.session_id, p_section_id, p_subject_id, (select auth.uid()), v_week, nullif(btrim(p_objectives), ''), nullif(btrim(p_resources), ''))
  returning id into v_id;
  perform app.fn_lesson_plan_set_topics(v_id, v_sec, p_subject_id, p_topic_ids);
  return v_id;
exception when unique_violation then
  raise exception 'LESSON_PLAN_EXISTS' using errcode = '23505';
end;
$$;
revoke execute on function public.create_lesson_plan(uuid, uuid, date, text, text, uuid[]) from public, anon;
grant execute on function public.create_lesson_plan(uuid, uuid, date, text, text, uuid[]) to authenticated;

create or replace function public.update_lesson_plan(p_plan_id uuid, p_objectives text default null, p_resources text default null, p_topic_ids uuid[] default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p   public.lesson_plan%rowtype;
  v_sec public.class_section%rowtype;
begin
  select * into v_p from public.lesson_plan where id = p_plan_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'LESSON_PLAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_sec := app.fn_lesson_plan_check(v_p.section_id, v_p.subject_id, v_p.week_start_date);
  if char_length(coalesce(p_objectives, '')) > 1000 or char_length(coalesce(p_resources, '')) > 1000 then
    raise exception 'TEXT_TOO_LONG' using errcode = '23514';
  end if;
  update public.lesson_plan set objectives = nullif(btrim(p_objectives), ''), resources = nullif(btrim(p_resources), '') where id = p_plan_id;
  perform app.fn_lesson_plan_set_topics(p_plan_id, v_sec, v_p.subject_id, p_topic_ids);
end;
$$;
revoke execute on function public.update_lesson_plan(uuid, text, text, uuid[]) from public, anon;
grant execute on function public.update_lesson_plan(uuid, text, text, uuid[]) to authenticated;

create or replace function public.set_lesson_plan_status(p_plan_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p public.lesson_plan%rowtype;
begin
  if p_status not in ('planned', 'in_progress', 'completed') then
    raise exception 'STATUS_INVALID' using errcode = '22023';
  end if;
  select * into v_p from public.lesson_plan where id = p_plan_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'LESSON_PLAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_lesson_plan_check(v_p.section_id, v_p.subject_id, v_p.week_start_date);
  update public.lesson_plan
     set status = p_status,
         completed_at = case when p_status = 'completed' then coalesce(completed_at, clock_timestamp()) end,
         completion_date = case when p_status = 'completed' then coalesce(completion_date, app.fn_karachi_today()) end
   where id = p_plan_id;
end;
$$;
revoke execute on function public.set_lesson_plan_status(uuid, text) from public, anon;
grant execute on function public.set_lesson_plan_status(uuid, text) to authenticated;
