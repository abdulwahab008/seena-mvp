-- FR-I05: Seena Exams paper generation.
--
-- A teacher asks for a question paper for an exam subject from a board pattern
-- and a chapter list. The request is only a ROW: paper_generation_job, status
-- 'queued', written in one statement so the UI can show a job card at once. The
-- generation itself runs in an external worker (Render); the database never
-- calls out. The worker is handed the job by the app, and reports back with a
-- signed callback that lands in fn_ingest_generated_paper():
--
--   * the callback is idempotent on the job: a second delivery finds the job
--     completed and returns the paper it already made - exactly one exam_paper
--     per job and set;
--   * the copyright guard runs BEFORE anything is stored: a paper carrying a
--     question that reproduces the textbook beyond the allowed ratio ends the job
--     'copyright_blocked' and stores nothing;
--   * the pattern check is exact: every section's question count, every
--     question's marks and the paper total must equal the requested pattern, or
--     the job ends 'pattern_mismatch' and no paper is stored;
--   * failures are retried with exponential backoff (30s, 60s, 120s) and after
--     the third retry the job is 'failed' with a retry action; a failed attempt
--     never leaves a partial paper because a paper only exists as the result of
--     one successful ingest.
--
-- Papers are the requester's and the exam office's. FR-I08 seals published
-- papers behind a release window on top of this.

create table public.board_pattern_ref (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  code         text not null check (length(btrim(code)) > 0),
  name         text not null check (length(btrim(name)) > 0),
  board        public.board not null,
  total_marks  int not null check (total_marks between 1 and 1000),
  -- [{"no":1,"name":"Section A","type":"mcq","count":12,"marks_each":1}, ...]
  sections     jsonb not null,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  constraint uq_board_pattern_code unique (tenant_id, code)
);
create index idx_board_pattern_tenant on public.board_pattern_ref (tenant_id);

create table public.paper_generation_job (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  requested_by     uuid not null references auth.users(id),
  exam_subject_id  uuid not null references public.exam_subject(id) on delete cascade,
  board_pattern_id uuid not null references public.board_pattern_ref(id),
  pattern_snapshot jsonb not null,
  chapters         text[] not null check (cardinality(chapters) between 1 and 40),
  total_marks      int not null,
  set_count        smallint not null default 1 check (set_count between 1 and 4),
  status           text not null default 'queued' check (status in ('queued', 'running', 'completed', 'failed', 'pattern_mismatch', 'copyright_blocked')),
  attempts         int not null default 0,
  max_retries      int not null default 3,
  next_attempt_at  timestamptz not null default now(),
  last_error       text,
  created_at       timestamptz not null default now(),
  started_at       timestamptz,
  finished_at      timestamptz
);
create index idx_paper_job_status on public.paper_generation_job (tenant_id, status, created_at);
create index idx_paper_job_due on public.paper_generation_job (status, next_attempt_at);
create index idx_paper_job_requester on public.paper_generation_job (requested_by);
create index idx_paper_job_subject on public.paper_generation_job (exam_subject_id);
create index idx_paper_job_pattern on public.paper_generation_job (board_pattern_id);
create index idx_paper_job_campus on public.paper_generation_job (campus_id);

create table public.exam_paper (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  job_id           uuid not null references public.paper_generation_job(id) on delete cascade,
  exam_subject_id  uuid not null references public.exam_subject(id) on delete cascade,
  set_code         char(1) not null default 'A' check (set_code between 'A' and 'D'),
  status           text not null default 'draft' check (status in ('draft', 'published', 'superseded')),
  title            text not null,
  total_marks      int not null,
  pattern_snapshot jsonb not null,
  created_by       uuid not null references auth.users(id),
  created_at       timestamptz not null default now(),
  published_at     timestamptz,
  constraint uq_exam_paper_job_set unique (job_id, set_code)
);
create index idx_exam_paper_tenant on public.exam_paper (tenant_id, campus_id);
create index idx_exam_paper_subject on public.exam_paper (exam_subject_id);
create index idx_exam_paper_creator on public.exam_paper (created_by);

create table public.exam_paper_item (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  paper_id      uuid not null references public.exam_paper(id) on delete cascade,
  section_no    int not null check (section_no >= 1),
  question_no   int not null check (question_no >= 1),
  question_type text not null check (question_type in ('mcq', 'short', 'long')),
  marks         int not null check (marks >= 1),
  question_text text not null check (length(btrim(question_text)) > 0),
  options       jsonb,
  answer        text,
  chapter       text,
  topic_tag     text,
  slo_code      text,
  source_pages  jsonb not null default '[]'::jsonb,
  bank_item_id  uuid,
  constraint uq_exam_paper_item unique (paper_id, section_no, question_no)
);
create index idx_exam_paper_item_tenant on public.exam_paper_item (tenant_id);
create index idx_exam_paper_item_bank on public.exam_paper_item (bank_item_id);

create trigger board_pattern_ref_audit after insert or update or delete on public.board_pattern_ref
  for each row execute function app.tg_audit_row();
create trigger paper_generation_job_audit after insert or update or delete on public.paper_generation_job
  for each row execute function app.tg_audit_row();
create trigger exam_paper_audit after insert or update or delete on public.exam_paper
  for each row execute function app.tg_audit_row();

alter table public.board_pattern_ref enable row level security;
alter table public.paper_generation_job enable row level security;
alter table public.exam_paper enable row level security;
alter table public.exam_paper_item enable row level security;
create policy board_pattern_tenant_read on public.board_pattern_ref for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none'));
create policy paper_job_owner_or_controller on public.paper_generation_job for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (requested_by = (select auth.uid())
              or (app.auth_role() in ('owner', 'super_admin', 'principal', 'exam_controller')
                  and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())))));
create policy exam_paper_owner_or_controller on public.exam_paper for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (created_by = (select auth.uid())
              or (app.auth_role() in ('owner', 'super_admin', 'principal', 'exam_controller')
                  and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())))));
create policy exam_paper_item_via_paper on public.exam_paper_item for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.exam_paper p where p.id = paper_id));

-- Private bucket for generated papers and answer keys. No policy on
-- storage.objects: files are written by the service-role renderer and left
-- only through issue-paper-download-url (FR-I08).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('exam-papers', 'exam-papers', false, 15728640, array['application/pdf'])
on conflict (id) do nothing;

-- ═══════════════════════════════════════════════════════════════════════
-- Patterns
-- ═══════════════════════════════════════════════════════════════════════

-- sections: [{"no":1,"name":"Section A","type":"mcq","count":12,"marks_each":1}, ...];
-- the sum of count * marks_each must equal the pattern's total.
create or replace function app.fn_pattern_total(p_sections jsonb)
returns int
language sql
immutable
set search_path = ''
as $$
  select coalesce(sum((s ->> 'count')::int * (s ->> 'marks_each')::int), 0)::int from jsonb_array_elements(p_sections) s;
$$;

create or replace function public.save_board_pattern(p_code text, p_name text, p_board public.board, p_sections jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id    uuid;
  v_total int;
  s       jsonb;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_sections is null or jsonb_typeof(p_sections) <> 'array' or jsonb_array_length(p_sections) = 0 then
    raise exception 'PATTERN_SECTIONS_INVALID' using errcode = '22023';
  end if;
  for s in select * from jsonb_array_elements(p_sections) loop
    if (s ->> 'type') not in ('mcq', 'short', 'long')
       or coalesce((s ->> 'count')::int, 0) < 1 or coalesce((s ->> 'marks_each')::int, 0) < 1
       or coalesce((s ->> 'no')::int, 0) < 1 then
      raise exception 'PATTERN_SECTIONS_INVALID' using errcode = '22023';
    end if;
  end loop;
  if (select count(distinct (e ->> 'no')) from jsonb_array_elements(p_sections) e) <> jsonb_array_length(p_sections) then
    raise exception 'PATTERN_SECTIONS_INVALID' using errcode = '22023';
  end if;
  v_total := app.fn_pattern_total(p_sections);
  if length(btrim(coalesce(p_code, ''))) = 0 or length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'PATTERN_NAME_REQUIRED' using errcode = '22023';
  end if;
  insert into public.board_pattern_ref (tenant_id, code, name, board, total_marks, sections)
  values (app.auth_tenant_id(), btrim(p_code), btrim(p_name), p_board, v_total, p_sections)
  on conflict (tenant_id, code) do update set name = excluded.name, board = excluded.board, total_marks = excluded.total_marks, sections = excluded.sections
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.save_board_pattern(text, text, public.board, jsonb) from public, anon;
grant execute on function public.save_board_pattern(text, text, public.board, jsonb) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Request
-- ═══════════════════════════════════════════════════════════════════════

-- Who may ask: the exam office, or a teacher assigned to this subject for this
-- class. The reference to the term's class is resolved from the exam subject.
create or replace function app.fn_can_request_paper(p_exam_subject_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.exam_subject es
      join public.class_subject cs on cs.id = es.class_subject_id
     where es.id = p_exam_subject_id and es.tenant_id = app.auth_tenant_id()
       and (
         (app.auth_role() in ('owner', 'super_admin', 'principal', 'exam_controller')
          and (app.auth_role() in ('owner', 'super_admin') or es.campus_id = any (app.auth_campus_ids())))
         or exists (select 1 from public.section_subject_teacher t
                      join public.class_section sec on sec.id = t.section_id
                     where t.staff_id = (select auth.uid()) and t.subject_id = cs.subject_id
                       and sec.class_level_id = cs.class_level_id and sec.session_id = cs.session_id)
       )
  );
$$;
revoke execute on function app.fn_can_request_paper(uuid) from public, anon;
grant execute on function app.fn_can_request_paper(uuid) to authenticated;

create or replace function public.request_paper_generation(
  p_exam_subject_id uuid, p_board_pattern_id uuid, p_chapters text[], p_total_marks int, p_set_count int default 1
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_es      public.exam_subject%rowtype;
  v_pattern public.board_pattern_ref%rowtype;
  v_id      uuid;
begin
  select * into v_es from public.exam_subject where id = p_exam_subject_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'EXAM_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app.fn_can_request_paper(p_exam_subject_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_pattern from public.board_pattern_ref where id = p_board_pattern_id and tenant_id = v_es.tenant_id and is_active;
  if not found then
    raise exception 'PATTERN_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_chapters is null or cardinality(p_chapters) = 0 then
    raise exception 'CHAPTERS_REQUIRED' using errcode = '22023';
  end if;
  if p_total_marks is distinct from v_pattern.total_marks then
    raise exception 'PATTERN_TOTAL_MISMATCH' using errcode = '22023',
      detail = format('The pattern %s totals %s marks, not %s.', v_pattern.code, v_pattern.total_marks, p_total_marks);
  end if;
  if p_set_count is null or p_set_count not between 1 and 4 then
    raise exception 'SET_COUNT_INVALID' using errcode = '22023';
  end if;
  insert into public.paper_generation_job (tenant_id, campus_id, requested_by, exam_subject_id, board_pattern_id, pattern_snapshot, chapters, total_marks, set_count)
  values (v_es.tenant_id, v_es.campus_id, (select auth.uid()), p_exam_subject_id, p_board_pattern_id,
          jsonb_build_object('code', v_pattern.code, 'board', v_pattern.board, 'total_marks', v_pattern.total_marks, 'sections', v_pattern.sections),
          p_chapters, p_total_marks, p_set_count)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.request_paper_generation(uuid, uuid, text[], int, int) from public, anon;
grant execute on function public.request_paper_generation(uuid, uuid, text[], int, int) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Worker side: claim, fail, retry, ingest. service_role only.
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.fn_claim_paper_jobs(p_limit int default 5)
returns setof public.paper_generation_job
language sql
security definer
set search_path = ''
as $$
  update public.paper_generation_job j
     set status = 'running', attempts = j.attempts + 1, started_at = now()
   where j.id in (select id from public.paper_generation_job
                   where status = 'queued' and next_attempt_at <= now()
                   order by created_at limit greatest(coalesce(p_limit, 5), 1) for update skip locked)
  returning j.*;
$$;
revoke execute on function public.fn_claim_paper_jobs(int) from public, anon, authenticated;
grant execute on function public.fn_claim_paper_jobs(int) to service_role;

-- A failed attempt. Retries are 30s, 60s, 120s; after the third retry the job
-- is 'failed' and waits for a person to retry it.
create or replace function public.fn_record_paper_job_failure(p_job_id uuid, p_error text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  j public.paper_generation_job%rowtype;
begin
  select * into j from public.paper_generation_job where id = p_job_id for update;
  if not found then
    raise exception 'JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  if j.status not in ('running', 'queued') then
    return j.status;
  end if;
  if j.attempts > j.max_retries then
    update public.paper_generation_job set status = 'failed', last_error = left(p_error, 500), finished_at = now() where id = p_job_id;
    return 'failed';
  end if;
  update public.paper_generation_job
     set status = 'queued', last_error = left(p_error, 500),
         next_attempt_at = now() + make_interval(secs => 30 * power(2, j.attempts - 1))
   where id = p_job_id;
  return 'queued';
end;
$$;
revoke execute on function public.fn_record_paper_job_failure(uuid, text) from public, anon, authenticated;
grant execute on function public.fn_record_paper_job_failure(uuid, text) to service_role;

-- The retry action on a failed card: back to the queue with a fresh budget.
create or replace function public.retry_paper_job(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  j public.paper_generation_job%rowtype;
begin
  select * into j from public.paper_generation_job where id = p_job_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  if j.requested_by <> (select auth.uid())
     and not (app.fn_can_request_paper(j.exam_subject_id) and app.auth_role() in ('owner', 'super_admin', 'principal', 'exam_controller')) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if j.status <> 'failed' then
    raise exception 'JOB_NOT_FAILED' using errcode = '22023';
  end if;
  update public.paper_generation_job set status = 'queued', attempts = 0, next_attempt_at = now(), last_error = null, finished_at = null where id = p_job_id;
end;
$$;
revoke execute on function public.retry_paper_job(uuid) from public, anon;
grant execute on function public.retry_paper_job(uuid) to authenticated;

-- Compares one generated set with the requested pattern. Returns null when it
-- matches exactly, otherwise a sentence naming the first difference.
create or replace function app.fn_paper_pattern_diff(p_pattern jsonb, p_questions jsonb)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  s        jsonb;
  v_count  int;
  v_marks  int := 0;
  v_expect int := 0;
  q        jsonb;
begin
  for s in select * from jsonb_array_elements(p_pattern -> 'sections') loop
    select count(*) into v_count from jsonb_array_elements(p_questions) x where (x ->> 'section_no')::int = (s ->> 'no')::int;
    if v_count <> (s ->> 'count')::int then
      return format('section %s has %s questions, expected %s', s ->> 'no', v_count, s ->> 'count');
    end if;
    v_expect := v_expect + (s ->> 'count')::int * (s ->> 'marks_each')::int;
  end loop;
  for q in select * from jsonb_array_elements(p_questions) loop
    select s2 into s from jsonb_array_elements(p_pattern -> 'sections') s2 where (s2 ->> 'no')::int = (q ->> 'section_no')::int;
    if s is null then
      return format('question %s is in section %s, which is not in the pattern', q ->> 'question_no', q ->> 'section_no');
    end if;
    if (q ->> 'marks')::int is distinct from (s ->> 'marks_each')::int then
      return format('question %s of section %s carries %s marks, expected %s', q ->> 'question_no', q ->> 'section_no', q ->> 'marks', s ->> 'marks_each');
    end if;
    if (q ->> 'type') is distinct from (s ->> 'type') then
      return format('question %s of section %s is %s, expected %s', q ->> 'question_no', q ->> 'section_no', q ->> 'type', s ->> 'type');
    end if;
    v_marks := v_marks + (q ->> 'marks')::int;
  end loop;
  if v_marks <> v_expect then
    return format('paper totals %s of %s marks', v_marks, v_expect);
  end if;
  return null;
end;
$$;

-- The callback. p_payload = {"sets":[{"set_code":"A","title":"...","questions":[
--   {"section_no":1,"question_no":1,"type":"mcq","marks":1,"text":"...","options":[...],"answer":"b",
--    "chapter":"Ch.2","topic_tag":"...","slo_code":"P-09-A-01","source_pages":[12,13],"verbatim_ratio":0.0}]}]}
-- Returns {"status": ..., "paper_ids": [...], "detail": ...}.
create or replace function public.fn_ingest_generated_paper(p_job_id uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  j        public.paper_generation_job%rowtype;
  v_set    jsonb;
  v_diff   text;
  v_ids    uuid[] := '{}';
  v_paper  uuid;
  v_codes  text[];
  q        jsonb;
  v_max_ratio numeric;
begin
  select * into j from public.paper_generation_job where id = p_job_id for update;
  if not found then
    raise exception 'JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  -- Idempotent: a repeat delivery (or a late one for a closed job) changes nothing.
  if j.status <> 'running' and j.status <> 'queued' then
    return jsonb_build_object('status', j.status, 'paper_ids', coalesce((select jsonb_agg(id) from public.exam_paper where job_id = p_job_id), '[]'::jsonb), 'duplicate', true);
  end if;
  if p_payload is null or coalesce(jsonb_typeof(p_payload -> 'sets'), '') <> 'array' or jsonb_array_length(p_payload -> 'sets') <> j.set_count then
    update public.paper_generation_job set status = 'pattern_mismatch', last_error = format('expected %s set(s) in the callback', j.set_count), finished_at = now() where id = p_job_id;
    return jsonb_build_object('status', 'pattern_mismatch', 'paper_ids', '[]'::jsonb, 'detail', format('expected %s set(s) in the callback', j.set_count));
  end if;

  -- The copyright guard comes first: nothing is stored from a blocked paper.
  select coalesce(max((x ->> 'verbatim_ratio')::numeric), 0) into v_max_ratio
    from jsonb_array_elements(p_payload -> 'sets') st, jsonb_array_elements(st -> 'questions') x;
  if v_max_ratio > 0.5 then
    update public.paper_generation_job set status = 'copyright_blocked', last_error = format('a question reproduces %s%% of its source text', round(v_max_ratio * 100)), finished_at = now() where id = p_job_id;
    return jsonb_build_object('status', 'copyright_blocked', 'paper_ids', '[]'::jsonb, 'detail', 'a question reproduces the textbook beyond the allowed ratio');
  end if;

  select array_agg(st ->> 'set_code' order by st ->> 'set_code') into v_codes from jsonb_array_elements(p_payload -> 'sets') st;
  if v_codes <> (select array_agg(chr(64 + g)) from generate_series(1, j.set_count) g) then
    update public.paper_generation_job set status = 'pattern_mismatch', last_error = 'set codes must be A, B, ... in order', finished_at = now() where id = p_job_id;
    return jsonb_build_object('status', 'pattern_mismatch', 'paper_ids', '[]'::jsonb, 'detail', 'set codes must be A, B, ... in order');
  end if;

  for v_set in select * from jsonb_array_elements(p_payload -> 'sets') loop
    v_diff := app.fn_paper_pattern_diff(j.pattern_snapshot, v_set -> 'questions');
    if v_diff is not null then
      update public.paper_generation_job set status = 'pattern_mismatch', last_error = left(format('set %s: %s', v_set ->> 'set_code', v_diff), 500), finished_at = now() where id = p_job_id;
      return jsonb_build_object('status', 'pattern_mismatch', 'paper_ids', '[]'::jsonb, 'detail', format('set %s: %s', v_set ->> 'set_code', v_diff));
    end if;
  end loop;

  for v_set in select * from jsonb_array_elements(p_payload -> 'sets') loop
    insert into public.exam_paper (tenant_id, campus_id, job_id, exam_subject_id, set_code, title, total_marks, pattern_snapshot, created_by)
    values (j.tenant_id, j.campus_id, j.id, j.exam_subject_id, (v_set ->> 'set_code')::char(1),
            coalesce(nullif(btrim(v_set ->> 'title'), ''), format('%s paper', j.pattern_snapshot ->> 'code')), j.total_marks, j.pattern_snapshot, j.requested_by)
    returning id into v_paper;
    for q in select * from jsonb_array_elements(v_set -> 'questions') loop
      insert into public.exam_paper_item (tenant_id, paper_id, section_no, question_no, question_type, marks, question_text, options, answer, chapter, topic_tag, slo_code, source_pages)
      values (j.tenant_id, v_paper, (q ->> 'section_no')::int, (q ->> 'question_no')::int, q ->> 'type', (q ->> 'marks')::int, q ->> 'text',
              q -> 'options', q ->> 'answer', q ->> 'chapter', q ->> 'topic_tag', q ->> 'slo_code', coalesce(q -> 'source_pages', '[]'::jsonb));
    end loop;
    v_ids := v_ids || v_paper;
  end loop;

  update public.paper_generation_job set status = 'completed', last_error = null, finished_at = now() where id = p_job_id;
  return jsonb_build_object('status', 'completed', 'paper_ids', to_jsonb(v_ids));
end;
$$;
revoke execute on function public.fn_ingest_generated_paper(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.fn_ingest_generated_paper(uuid, jsonb) to service_role;

-- A worker that accepted a job and never called back must not leave it 'running'
-- forever: after p_minutes it counts as a failed attempt (with the same backoff).
create or replace function public.fn_fail_stalled_paper_jobs(p_minutes int default 15)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  n int := 0;
begin
  for r in select id from public.paper_generation_job
            where status = 'running' and started_at < now() - make_interval(mins => greatest(coalesce(p_minutes, 15), 1)) loop
    perform public.fn_record_paper_job_failure(r.id, 'the worker did not report back in time');
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.fn_fail_stalled_paper_jobs(int) from public, anon, authenticated;
grant execute on function public.fn_fail_stalled_paper_jobs(int) to service_role;
