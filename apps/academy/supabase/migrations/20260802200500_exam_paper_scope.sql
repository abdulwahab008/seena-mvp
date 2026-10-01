-- FR-H09: syllabus mapping to exam paper generation.
--
-- An Exam Controller (or teacher) picks syllabus units as the SCOPE of a
-- generated paper, so the Seena Exams generator only draws questions from
-- chapters that have actually been taught. This is the hinge between the
-- school system and the Seena Exams RAG asset; the RAG internals are not
-- touched. What the school side adds:
--
--   * exam_paper_request.scope_unit_ids -- the unit ids handed to the worker
--     as a metadata filter (syllabus_unit_id), nothing else;
--   * exam_paper_question.syllabus_unit_id / syllabus_topic_id -- the
--     provenance of every generated question. A trigger refuses a question
--     whose unit is not in the request's scope, so provenance can never name
--     a chapter that was not asked for;
--   * validate_paper_scope() -- a unit counts as taught once coverage for it
--     is in_progress or completed. With a section given, that section's
--     coverage is read; without, any section of the class on the campus
--     having started the unit is enough (a paper is set for the class);
--   * an explicit override: only an exam_controller (or the owner) can
--     confirm "include untaught chapters"; the override and who gave it are
--     stored on the request;
--   * syllabus_unit_source_chapter -- a many-to-many link from a school's
--     syllabus unit to the textbook chapter(s) indexed on the Seena Exams
--     side. A school may split one textbook chapter across two teaching
--     units, or teach two chapters as one, so equality is never assumed.
--
-- The generator itself is outside this database: a worker claims requests with
-- claim_exam_paper_request(), generates, and reports back through
-- record_generated_paper() / fail_exam_paper_request() (service_role only).
-- The app ships a stub generator behind a GeneratorInterface for development
-- (lib/exam-papers); the real RAG worker plugs into the same three calls.

create table public.syllabus_unit_source_chapter (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  syllabus_unit_id uuid not null references public.syllabus_unit(id) on delete cascade,
  source_book      text not null check (length(btrim(source_book)) > 0),
  source_chapter   text not null check (length(btrim(source_chapter)) > 0),
  created_at       timestamptz not null default now(),
  constraint uq_unit_source_chapter unique (syllabus_unit_id, source_book, source_chapter)
);
create index idx_unit_source_chapter_tenant on public.syllabus_unit_source_chapter (tenant_id);
create index idx_unit_source_chapter_ref on public.syllabus_unit_source_chapter (source_book, source_chapter);

create table public.exam_paper_request (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  session_id       uuid not null references public.academic_session(id) on delete cascade,
  class_level_id   uuid not null references public.class_level(id),
  subject_id       uuid not null references public.subject(id),
  section_id       uuid references public.class_section(id),
  title            text not null check (length(btrim(title)) > 0),
  scope_unit_ids   uuid[] not null check (cardinality(scope_unit_ids) between 1 and 100),
  untaught_override boolean not null default false,
  override_by      uuid references auth.users(id),
  override_at      timestamptz,
  status           text not null default 'submitted' check (status in ('submitted', 'generating', 'generated', 'failed')),
  attempts         int not null default 0,
  error            text,
  requested_by     uuid references auth.users(id),
  created_at       timestamptz not null default now(),
  generated_at     timestamptz,
  constraint chk_override_recorded check (not untaught_override or (override_by is not null and override_at is not null))
);
create index idx_paper_request_scope on public.exam_paper_request (tenant_id, campus_id, created_at desc);
create index idx_paper_request_status on public.exam_paper_request (status, created_at);
create index idx_paper_request_subject on public.exam_paper_request (subject_id);
create index idx_paper_request_class on public.exam_paper_request (class_level_id);
create index idx_paper_request_session on public.exam_paper_request (session_id);

create table public.exam_paper_question (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  paper_request_id  uuid not null references public.exam_paper_request(id) on delete cascade,
  sequence          int not null check (sequence > 0),
  question_text     text not null check (length(btrim(question_text)) > 0),
  marks             int not null default 1 check (marks between 0 and 100),
  syllabus_unit_id  uuid not null references public.syllabus_unit(id),
  syllabus_topic_id uuid references public.syllabus_topic(id),
  source_chapter    text,
  created_at        timestamptz not null default now(),
  constraint uq_paper_question_seq unique (paper_request_id, sequence)
);
create index idx_paper_q_unit on public.exam_paper_question (syllabus_unit_id);
create index idx_paper_q_topic on public.exam_paper_question (syllabus_topic_id);
create index idx_paper_q_tenant on public.exam_paper_question (tenant_id);

create trigger exam_paper_request_audit after insert or update or delete on public.exam_paper_request
  for each row execute function app.tg_audit_row();

-- Provenance can only name units that were in scope, and a topic must belong to its unit.
create or replace function app.tg_paper_question_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_scope uuid[];
begin
  select scope_unit_ids into v_scope from public.exam_paper_request where id = new.paper_request_id;
  if v_scope is null or not (new.syllabus_unit_id = any (v_scope)) then
    raise exception 'QUESTION_OUTSIDE_SCOPE' using errcode = '22023';
  end if;
  if new.syllabus_topic_id is not null and not exists (select 1 from public.syllabus_topic t where t.id = new.syllabus_topic_id and t.syllabus_unit_id = new.syllabus_unit_id) then
    raise exception 'TOPIC_NOT_IN_UNIT' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger trg_paper_question_scope before insert or update on public.exam_paper_question
  for each row execute function app.tg_paper_question_scope();

alter table public.syllabus_unit_source_chapter enable row level security;
alter table public.exam_paper_request enable row level security;
alter table public.exam_paper_question enable row level security;

create policy unit_source_chapter_read on public.syllabus_unit_source_chapter for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.syllabus_unit u where u.id = syllabus_unit_id));
create policy paper_request_read on public.exam_paper_request for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none', 'accountant')
         and (requested_by = (select auth.uid())
              or (app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'exam_controller', 'head_of_department')
                  and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())))));
create policy paper_question_read on public.exam_paper_question for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.exam_paper_request r where r.id = paper_request_id));

-- ── unit <-> source chapter links ────────────────────────────────────────
create or replace function public.link_unit_source_chapter(p_unit_id uuid, p_source_book text, p_source_chapter text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_u public.syllabus_unit%rowtype;
begin
  v_u := app.fn_syllabus_unit_for_edit(p_unit_id);
  insert into public.syllabus_unit_source_chapter (tenant_id, syllabus_unit_id, source_book, source_chapter)
  values (v_u.tenant_id, p_unit_id, btrim(p_source_book), btrim(p_source_chapter))
  on conflict (syllabus_unit_id, source_book, source_chapter) do nothing;
end;
$$;
revoke execute on function public.link_unit_source_chapter(uuid, text, text) from public, anon;
grant execute on function public.link_unit_source_chapter(uuid, text, text) to authenticated;

create or replace function public.unlink_unit_source_chapter(p_link_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_l public.syllabus_unit_source_chapter%rowtype;
  v_u public.syllabus_unit%rowtype;
begin
  select * into v_l from public.syllabus_unit_source_chapter where id = p_link_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'LINK_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_u := app.fn_syllabus_unit_for_edit(v_l.syllabus_unit_id);
  delete from public.syllabus_unit_source_chapter where id = p_link_id;
end;
$$;
revoke execute on function public.unlink_unit_source_chapter(uuid) from public, anon;
grant execute on function public.unlink_unit_source_chapter(uuid) to authenticated;

-- ── scope validation ─────────────────────────────────────────────────────
create or replace function app.fn_paper_roles_ok()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'exam_controller', 'head_of_department', 'class_teacher', 'subject_teacher');
$$;
revoke execute on function app.fn_paper_roles_ok() from public, anon, authenticated;

create or replace function public.validate_paper_scope(p_unit_ids uuid[], p_section_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_n        int;
  v_first    public.syllabus_unit%rowtype;
  v_found    int;
  v_untaught jsonb;
  v_count    int;
  v_msg      text;
begin
  if not app.fn_paper_roles_ok() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_unit_ids is null or cardinality(p_unit_ids) = 0 or cardinality(p_unit_ids) > 100 then
    raise exception 'UNITS_MUST_BE_1_TO_100' using errcode = '22023';
  end if;
  select * into v_first from public.syllabus_unit where id = p_unit_ids[1] and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'UNIT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_first.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select count(distinct x) into v_n from unnest(p_unit_ids) x;
  select count(*) into v_found from public.syllabus_unit u
   where u.id = any (p_unit_ids) and u.tenant_id = v_first.tenant_id and u.campus_id = v_first.campus_id and u.session_id = v_first.session_id
     and u.class_level_id = v_first.class_level_id and u.subject_id = v_first.subject_id and u.board = v_first.board;
  if v_found <> v_n then
    raise exception 'UNITS_MUST_SHARE_ONE_SYLLABUS' using errcode = '22023';
  end if;
  if p_section_id is not null and not exists (
       select 1 from public.class_section s where s.id = p_section_id and s.tenant_id = v_first.tenant_id and s.campus_id = v_first.campus_id
          and s.session_id = v_first.session_id and s.class_level_id = v_first.class_level_id) then
    raise exception 'SECTION_NOT_IN_CLASS' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('unit_id', u.id, 'sequence', u.sequence, 'title', u.title) order by u.sequence), '[]'::jsonb), count(*)::int
    into v_untaught, v_count
    from public.syllabus_unit u
   where u.id = any (p_unit_ids)
     and not exists (
       select 1 from public.syllabus_coverage c
        where c.syllabus_unit_id = u.id and c.status in ('in_progress', 'completed')
          and (p_section_id is null or c.section_id = p_section_id));

  if v_count = 0 then
    v_msg := null;
  elsif v_count = 1 then
    v_msg := format('Chapter %s %s has not been taught yet — remove it or update coverage', v_untaught -> 0 ->> 'sequence', v_untaught -> 0 ->> 'title');
  else
    v_msg := format('Chapters %s have not been taught yet — remove them or update coverage',
                    (select string_agg(e ->> 'sequence' || ' ' || (e ->> 'title'), ', ' order by (e ->> 'sequence')::int) from jsonb_array_elements(v_untaught) e));
  end if;
  return jsonb_build_object('ok', v_count = 0, 'unit_count', v_n, 'untaught', v_untaught, 'message', v_msg);
end;
$$;
revoke execute on function public.validate_paper_scope(uuid[], uuid) from public, anon;
grant execute on function public.validate_paper_scope(uuid[], uuid) to authenticated;

create or replace function public.submit_exam_paper_request(p_unit_ids uuid[], p_title text, p_section_id uuid default null, p_untaught_override boolean default false)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_check  jsonb := public.validate_paper_scope(p_unit_ids, p_section_id);
  v_first  public.syllabus_unit%rowtype;
  v_ids    uuid[];
  v_over   boolean := false;
  v_id     uuid;
begin
  if p_title is null or length(btrim(p_title)) = 0 then
    raise exception 'TITLE_REQUIRED' using errcode = '22023';
  end if;
  if not (v_check ->> 'ok')::boolean then
    if not coalesce(p_untaught_override, false) then
      raise exception '%', v_check ->> 'message' using errcode = '22023';
    end if;
    if app.auth_role() not in ('exam_controller', 'owner', 'super_admin') then
      raise exception 'OVERRIDE_REQUIRES_EXAM_CONTROLLER' using errcode = '42501';
    end if;
    v_over := true;
  end if;
  select * into v_first from public.syllabus_unit where id = p_unit_ids[1];
  select array_agg(distinct x order by x) into v_ids from unnest(p_unit_ids) x;
  insert into public.exam_paper_request (tenant_id, campus_id, session_id, class_level_id, subject_id, section_id, title, scope_unit_ids,
                                         untaught_override, override_by, override_at, requested_by)
  values (v_first.tenant_id, v_first.campus_id, v_first.session_id, v_first.class_level_id, v_first.subject_id, p_section_id, btrim(p_title), v_ids,
          v_over, case when v_over then (select auth.uid()) end, case when v_over then now() end, (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.submit_exam_paper_request(uuid[], text, uuid, boolean) from public, anon;
grant execute on function public.submit_exam_paper_request(uuid[], text, uuid, boolean) to authenticated;

-- ── worker side (service_role only) ──────────────────────────────────────
-- The payload is what the Seena Exams worker needs: the unit ids as a
-- metadata filter on the indexed textbook chunks, the textbook chapters those
-- units map onto, and the topics (so questions can cite one).
create or replace function public.claim_exam_paper_request()
returns table (request_id uuid, tenant_id uuid, payload jsonb)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r public.exam_paper_request%rowtype;
begin
  select * into v_r from public.exam_paper_request r
   where (r.status = 'submitted' or (r.status = 'generating' and r.created_at < now() - interval '15 minutes')) and r.attempts < 3
   order by r.created_at
   for update skip locked limit 1;
  if not found then
    return;
  end if;
  update public.exam_paper_request set status = 'generating', attempts = attempts + 1 where id = v_r.id;
  return query
  select v_r.id, v_r.tenant_id, jsonb_build_object(
    'request_id', v_r.id,
    'title', v_r.title,
    'subject_id', v_r.subject_id,
    'class_level_id', v_r.class_level_id,
    'metadata_filter', jsonb_build_object('syllabus_unit_id', to_jsonb(v_r.scope_unit_ids)),
    'units', (select coalesce(jsonb_agg(jsonb_build_object(
                'id', u.id, 'sequence', u.sequence, 'title', u.title,
                'source_chapters', (select coalesce(jsonb_agg(jsonb_build_object('book', sc.source_book, 'chapter', sc.source_chapter) order by sc.source_book, sc.source_chapter), '[]'::jsonb)
                                      from public.syllabus_unit_source_chapter sc where sc.syllabus_unit_id = u.id),
                'topics', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title) order by t.sequence), '[]'::jsonb)
                             from public.syllabus_topic t where t.syllabus_unit_id = u.id)) order by u.sequence), '[]'::jsonb)
                from public.syllabus_unit u where u.id = any (v_r.scope_unit_ids))
  );
end;
$$;
revoke execute on function public.claim_exam_paper_request() from public, anon, authenticated;
grant execute on function public.claim_exam_paper_request() to service_role;

create or replace function public.record_generated_paper(p_request_id uuid, p_questions jsonb)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r public.exam_paper_request%rowtype;
  q   jsonb;
  v_n int := 0;
begin
  select * into v_r from public.exam_paper_request where id = p_request_id and status = 'generating' for update;
  if not found then
    raise exception 'REQUEST_NOT_GENERATING' using errcode = '55000';
  end if;
  if jsonb_typeof(p_questions) <> 'array' or jsonb_array_length(p_questions) = 0 then
    raise exception 'QUESTIONS_REQUIRED' using errcode = '22023';
  end if;
  delete from public.exam_paper_question where paper_request_id = p_request_id;
  for q in select * from jsonb_array_elements(p_questions) loop
    v_n := v_n + 1;
    insert into public.exam_paper_question (tenant_id, paper_request_id, sequence, question_text, marks, syllabus_unit_id, syllabus_topic_id, source_chapter)
    values (v_r.tenant_id, p_request_id, v_n, q ->> 'question_text', coalesce((q ->> 'marks')::int, 1), (q ->> 'syllabus_unit_id')::uuid,
            nullif(q ->> 'syllabus_topic_id', '')::uuid, nullif(q ->> 'source_chapter', ''));
  end loop;
  update public.exam_paper_request set status = 'generated', generated_at = now(), error = null where id = p_request_id;
  return v_n;
end;
$$;
revoke execute on function public.record_generated_paper(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.record_generated_paper(uuid, jsonb) to service_role;

create or replace function public.fail_exam_paper_request(p_request_id uuid, p_error text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.exam_paper_request set status = case when attempts >= 3 then 'failed' else 'submitted' end, error = left(coalesce(p_error, 'unknown error'), 500)
   where id = p_request_id and status = 'generating';
end;
$$;
revoke execute on function public.fail_exam_paper_request(uuid, text) from public, anon, authenticated;
grant execute on function public.fail_exam_paper_request(uuid, text) to service_role;
