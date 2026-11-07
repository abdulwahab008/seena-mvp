-- Online quizzes: a teacher builds a multiple-choice quiz for a section, sets
-- when it opens and closes and how long a student gets, and publishes it.
-- Students take it in the student portal; the server marks it.
--
-- The correct answers never leave the database while a quiz can still be
-- taken: students only ever read questions through student_quiz(), which
-- leaves correct_index out, and their answers are scored by submit_quiz_attempt().
-- One attempt per student; a submission after the time limit (plus a minute of
-- grace for a slow connection) or after the quiz closes is refused.

create table public.quiz (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  section_id   uuid not null references public.class_section(id) on delete cascade,
  title        text not null check (length(btrim(title)) between 1 and 200),
  opens_at     timestamptz not null,
  closes_at    timestamptz not null,
  duration_min smallint not null check (duration_min between 1 and 300),
  status       text not null default 'draft' check (status in ('draft', 'published')),
  created_by   uuid not null default auth.uid() references auth.users(id),
  created_at   timestamptz not null default now(),
  constraint chk_quiz_window check (closes_at > opens_at)
);
create index idx_quiz_scope on public.quiz (tenant_id, campus_id, opens_at desc);
create index idx_quiz_section on public.quiz (section_id, status);

create table public.quiz_question (
  id            uuid primary key default gen_random_uuid(),
  quiz_id       uuid not null references public.quiz(id) on delete cascade,
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  position      smallint not null,
  prompt        text not null check (length(btrim(prompt)) between 1 and 2000),
  options       text[] not null check (array_length(options, 1) between 2 and 6),
  correct_index smallint not null,
  marks         smallint not null default 1 check (marks between 1 and 100),
  constraint uq_quiz_question_position unique (quiz_id, position),
  constraint chk_quiz_question_correct check (correct_index between 0 and array_length(options, 1) - 1)
);
create index idx_quiz_question_scope on public.quiz_question (tenant_id, campus_id);

create table public.quiz_attempt (
  id           uuid primary key default gen_random_uuid(),
  quiz_id      uuid not null references public.quiz(id) on delete cascade,
  student_id   uuid not null references public.student(id) on delete cascade,
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  started_at   timestamptz not null default now(),
  submitted_at timestamptz,
  answers      smallint[],
  score        int,
  max_score    int,
  constraint uq_quiz_attempt unique (quiz_id, student_id)
);
create index idx_quiz_attempt_scope on public.quiz_attempt (tenant_id, campus_id);
create index idx_quiz_attempt_student on public.quiz_attempt (student_id);

alter table public.quiz enable row level security;
alter table public.quiz_question enable row level security;
alter table public.quiz_attempt enable row level security;

create policy quiz_staff_read on public.quiz for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())));
create policy quiz_question_staff_read on public.quiz_question for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())));
create policy quiz_attempt_staff_read on public.quiz_attempt for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())));

select app.fn_block_portal_roles('public.quiz');
select app.fn_block_portal_roles('public.quiz_question');
select app.fn_block_portal_roles('public.quiz_attempt');

-- ── teacher side ──────────────────────────────────────────────────────────

create or replace function app.fn_quiz_editable(p_quiz_id uuid)
returns public.quiz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_quiz public.quiz%rowtype;
begin
  select * into v_quiz from public.quiz where id = p_quiz_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'QUIZ_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not (v_quiz.created_by = (select auth.uid())
          or (app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'head_of_department')
              and (app.auth_role() in ('super_admin', 'owner') or v_quiz.campus_id = any(app.auth_campus_ids())))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return v_quiz;
end;
$$;
revoke execute on function app.fn_quiz_editable(uuid) from public, anon, authenticated;

create or replace function public.create_quiz(p_section_id uuid, p_title text, p_opens_at timestamptz, p_closes_at timestamptz, p_duration_min smallint)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campus uuid;
  v_id     uuid;
begin
  if app.auth_tenant_id() is null or app.auth_role() in ('parent', 'student', 'none') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select campus_id into v_campus from public.class_section where id = p_section_id and tenant_id = app.auth_tenant_id();
  if v_campus is null then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_campus = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501', detail = 'campus outside your scope';
  end if;
  insert into public.quiz (tenant_id, campus_id, section_id, title, opens_at, closes_at, duration_min)
  values (app.auth_tenant_id(), v_campus, p_section_id, btrim(p_title), p_opens_at, p_closes_at, p_duration_min)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.create_quiz(uuid, text, timestamptz, timestamptz, smallint) from public, anon;
grant execute on function public.create_quiz(uuid, text, timestamptz, timestamptz, smallint) to authenticated;

create or replace function public.add_quiz_question(p_quiz_id uuid, p_prompt text, p_options text[], p_correct_index smallint, p_marks smallint default 1)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_quiz public.quiz%rowtype := app.fn_quiz_editable(p_quiz_id);
  v_id   uuid;
begin
  if v_quiz.status <> 'draft' then
    raise exception 'QUIZ_PUBLISHED' using errcode = '22023', hint = 'A published quiz cannot be changed.';
  end if;
  insert into public.quiz_question (quiz_id, tenant_id, campus_id, position, prompt, options, correct_index, marks)
  values (v_quiz.id, v_quiz.tenant_id, v_quiz.campus_id,
          coalesce((select max(position) from public.quiz_question where quiz_id = v_quiz.id), 0) + 1,
          btrim(p_prompt), (select array_agg(btrim(o) order by n) from unnest(p_options) with ordinality t(o, n) where btrim(o) <> ''),
          p_correct_index, coalesce(p_marks, 1))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.add_quiz_question(uuid, text, text[], smallint, smallint) from public, anon;
grant execute on function public.add_quiz_question(uuid, text, text[], smallint, smallint) to authenticated;

create or replace function public.publish_quiz(p_quiz_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_quiz public.quiz%rowtype := app.fn_quiz_editable(p_quiz_id);
begin
  if not exists (select 1 from public.quiz_question where quiz_id = v_quiz.id) then
    raise exception 'QUIZ_EMPTY' using errcode = '22023';
  end if;
  update public.quiz set status = 'published' where id = v_quiz.id;
end;
$$;
revoke execute on function public.publish_quiz(uuid) from public, anon;
grant execute on function public.publish_quiz(uuid) to authenticated;

-- ── student side ──────────────────────────────────────────────────────────

create or replace function app.fn_student_quiz(p_quiz_id uuid)
returns public.quiz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_quiz public.quiz%rowtype;
begin
  select q.* into v_quiz
    from public.quiz q
    join public.enrolment e on e.section_id = q.section_id and e.status = 'active'
   where q.id = p_quiz_id and q.status = 'published' and e.student_id = public.my_student_id();
  if not found then
    raise exception 'QUIZ_NOT_FOUND' using errcode = 'P0002';
  end if;
  return v_quiz;
end;
$$;
revoke execute on function app.fn_student_quiz(uuid) from public, anon, authenticated;

create or replace function public.my_quizzes()
returns table (id uuid, title text, opens_at timestamptz, closes_at timestamptz, duration_min smallint, questions int, submitted boolean, score int, max_score int)
language sql
stable
security definer
set search_path = ''
as $$
  select q.id, q.title, q.opens_at, q.closes_at, q.duration_min,
         (select count(*)::int from public.quiz_question qq where qq.quiz_id = q.id),
         a.submitted_at is not null,
         case when a.submitted_at is not null then a.score end,
         case when a.submitted_at is not null then a.max_score end
    from public.quiz q
    join public.enrolment e on e.section_id = q.section_id and e.status = 'active'
    left join public.quiz_attempt a on a.quiz_id = q.id and a.student_id = e.student_id
   where q.status = 'published' and e.student_id = public.my_student_id()
   order by q.opens_at desc;
$$;
revoke execute on function public.my_quizzes() from public, anon;
grant execute on function public.my_quizzes() to authenticated;

-- Starting (or resuming) an attempt returns the questions without answers.
create or replace function public.start_quiz_attempt(p_quiz_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_quiz    public.quiz%rowtype := app.fn_student_quiz(p_quiz_id);
  v_attempt public.quiz_attempt%rowtype;
begin
  select * into v_attempt from public.quiz_attempt where quiz_id = v_quiz.id and student_id = public.my_student_id();
  if found and v_attempt.submitted_at is not null then
    raise exception 'ALREADY_SUBMITTED' using errcode = '22023';
  end if;
  if not found then
    if now() < v_quiz.opens_at or now() > v_quiz.closes_at then
      raise exception 'QUIZ_NOT_OPEN' using errcode = '22023';
    end if;
    insert into public.quiz_attempt (quiz_id, student_id, tenant_id, campus_id)
    values (v_quiz.id, public.my_student_id(), v_quiz.tenant_id, v_quiz.campus_id)
    returning * into v_attempt;
  end if;

  return jsonb_build_object(
    'title', v_quiz.title,
    'ends_at', least(v_attempt.started_at + make_interval(mins => v_quiz.duration_min), v_quiz.closes_at),
    'questions', (select jsonb_agg(jsonb_build_object('id', qq.id, 'prompt', qq.prompt, 'options', to_jsonb(qq.options), 'marks', qq.marks) order by qq.position)
                    from public.quiz_question qq where qq.quiz_id = v_quiz.id)
  );
end;
$$;
revoke execute on function public.start_quiz_attempt(uuid) from public, anon;
grant execute on function public.start_quiz_attempt(uuid) to authenticated;

-- p_answers is one option index per question in position order; -1 = skipped.
create or replace function public.submit_quiz_attempt(p_quiz_id uuid, p_answers smallint[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_quiz    public.quiz%rowtype := app.fn_student_quiz(p_quiz_id);
  v_attempt public.quiz_attempt%rowtype;
  v_score   int;
  v_max     int;
begin
  select * into v_attempt from public.quiz_attempt where quiz_id = v_quiz.id and student_id = public.my_student_id() for update;
  if not found then
    raise exception 'ATTEMPT_NOT_STARTED' using errcode = '22023';
  end if;
  if v_attempt.submitted_at is not null then
    raise exception 'ALREADY_SUBMITTED' using errcode = '22023';
  end if;
  if now() > least(v_attempt.started_at + make_interval(mins => v_quiz.duration_min), v_quiz.closes_at) + interval '1 minute' then
    raise exception 'TIME_UP' using errcode = '22023';
  end if;

  select coalesce(sum(qq.marks) filter (where p_answers[qq.position] = qq.correct_index), 0), coalesce(sum(qq.marks), 0)
    into v_score, v_max
    from public.quiz_question qq where qq.quiz_id = v_quiz.id;

  update public.quiz_attempt
     set submitted_at = now(), answers = p_answers, score = v_score, max_score = v_max
   where id = v_attempt.id;
  return jsonb_build_object('score', v_score, 'max_score', v_max);
end;
$$;
revoke execute on function public.submit_quiz_attempt(uuid, smallint[]) from public, anon;
grant execute on function public.submit_quiz_attempt(uuid, smallint[]) to authenticated;
