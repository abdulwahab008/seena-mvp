-- FR-J07: topic-wise mastery analytics.
--
-- "As a teacher, I want per-chapter mastery for each student and for the
-- section, so that I know exactly what to re-teach."
--
-- ── Where per-question marks come from ──────────────────────────────────
--
-- Topic analytics only exist where per-question marks were captured, i.e.
-- OCR-graded or online papers. A paper entered as one total (mark_entry) has no
-- chapters in it, and this module never invents a breakdown for it: the screen
-- says the per-question data was not captured (fn_topic_mastery_sheet
-- 'uncaptured'), which is the Notes' "explain its own absence rather than render
-- an empty chart that reads as a bug".
--
--   exam_question           the marking scheme of ONE sat paper: question number,
--                           its maximum, and the chapter it tests. Distinct from
--                           the paper-request builder's questions (module G):
--                           those are questions on a paper being generated, this
--                           is the scheme of a paper that was sat and marked, so
--                           it hangs off exam_subject and shares nothing with it.
--   question_response_mark  a candidate's mark on one question. Entered through
--                           save_question_marks (a grid), or imported from an
--                           OCR job's reviewed values (fn_import_ocr_question_marks,
--                           FR-I13/I14: ocr_review_action already stores
--                           question_no and the human-confirmed final_value).
--
-- The FR names the foreign key exam_paper_question_id; it is kept on
-- question_response_mark and points at exam_question.
--
-- ── Materialised, refreshed nightly ─────────────────────────────────────
--
-- app.mv_topic_mastery is (candidate, subject, chapter) -> obtained, maximum,
-- percentage, question count, accumulated over every paper of the session the
-- candidate has per-question marks for. It is refreshed CONCURRENTLY by
-- fn_refresh_topic_mastery() — nightly at 03:00 Karachi (22:00 UTC) by pg_cron
-- (refresh-topic-mastery), and on demand after a marking session. As in FR-J06
-- it lives in the app schema (a materialized view cannot carry RLS) and every
-- person reads it through the views below, whose predicates are the gate.
--
-- ── Who sees what (topic_mastery_* policies) ────────────────────────────
--
--   parent          their own child's chapters only (topic_mastery_parent_own_child)
--   student         their own
--   teacher         the sections they teach that subject in
--                   (topic_mastery_teacher_own_section)
--   principal etc.  every section of their campuses
--
-- The same predicates are policies on question_response_mark and exam_question
-- (the base tables), and the predicate of the views over the MV.
--
-- ── Reading the numbers ─────────────────────────────────────────────────
--
--   * the section figure is POOLED (total obtained / total available across the
--     section), not an average of percentages, so a chapter with two absent
--     students is not skewed;
--   * a chapter whose section figure is below 50% is a re-teach candidate;
--   * a chapter covered by fewer than 3 questions carries low_confidence: one
--     question can swing a percentage by a third.

-- ═══════════════════════════════════════════════════════════════════════
-- Marking scheme and responses
-- ═══════════════════════════════════════════════════════════════════════

create table public.exam_question (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  exam_subject_id uuid not null references public.exam_subject(id) on delete cascade,
  question_no      integer not null check (question_no > 0),
  max_marks        numeric(6,2) not null check (max_marks > 0),
  chapter_no       smallint check (chapter_no is null or chapter_no > 0),
  topic_tag        text not null check (btrim(topic_tag) <> '' and char_length(topic_tag) <= 120),
  created_at       timestamptz not null default now(),
  constraint uq_exam_question unique (exam_subject_id, question_no)
);
create index idx_exam_question_campus on public.exam_question (tenant_id, campus_id);

create table public.question_response_mark (
  id                     uuid primary key default gen_random_uuid(),
  tenant_id              uuid not null references public.tenant(id) on delete cascade,
  campus_id              uuid not null references public.campus(id) on delete cascade,
  enrolment_id           uuid not null references public.enrolment(id) on delete cascade,
  exam_paper_question_id uuid not null references public.exam_question(id) on delete cascade,
  obtained               numeric(6,2) not null check (obtained >= 0),
  max_marks              numeric(6,2) not null check (max_marks > 0),
  source                 text not null default 'manual' check (source in ('manual', 'ocr')),
  entered_by             uuid references public.app_user(user_id),
  entered_at             timestamptz not null default clock_timestamp(),
  constraint chk_qrm_within check (obtained <= max_marks)
);
create unique index uq_qrm on public.question_response_mark (enrolment_id, exam_paper_question_id);
create index idx_qrm_question on public.question_response_mark (exam_paper_question_id);
create index idx_qrm_campus on public.question_response_mark (tenant_id, campus_id);

create trigger exam_question_audit after insert or update or delete on public.exam_question
  for each row execute function app.tg_audit_row();
create trigger question_response_mark_audit after insert or update or delete on public.question_response_mark
  for each row execute function app.tg_audit_row();

-- ═══════════════════════════════════════════════════════════════════════
-- Access
-- ═══════════════════════════════════════════════════════════════════════

-- Is the caller a teacher of this subject in this section today?
create or replace function app.fn_teaches_section_subject(p_section_id uuid, p_subject_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.section_subject_teacher t
     where t.section_id = p_section_id and t.subject_id = p_subject_id
       and t.staff_id = (select auth.uid()) and t.validity @> app.fn_karachi_today());
$$;
revoke execute on function app.fn_teaches_section_subject(uuid, uuid) from public, anon;
grant execute on function app.fn_teaches_section_subject(uuid, uuid) to authenticated;

-- Reading is wider than writing: the class teacher of a section reads every
-- subject's mastery for it (they own the child's whole picture), while only the
-- subject's own teacher captures that subject's marks.
create or replace function app.fn_teacher_reads_section(p_section_id uuid, p_subject_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app.fn_teaches_section_subject(p_section_id, p_subject_id)
      or exists (select 1 from public.section_class_teacher c
                  where c.section_id = p_section_id and c.staff_id = (select auth.uid())
                    and c.validity @> app.fn_karachi_today());
$$;
revoke execute on function app.fn_teacher_reads_section(uuid, uuid) from public, anon;
grant execute on function app.fn_teacher_reads_section(uuid, uuid) to authenticated;

-- The single predicate every mastery read shares.
create or replace function app.fn_can_read_mastery(p_tenant_id uuid, p_campus_id uuid, p_section_id uuid, p_subject_id uuid, p_enrolment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_tenant_id = app.auth_tenant_id() and (
    case app.auth_role()
      when 'super_admin' then true
      when 'owner' then true
      when 'principal' then p_campus_id = any (app.auth_campus_ids())
      when 'vice_principal' then p_campus_id = any (app.auth_campus_ids())
      when 'exam_controller' then p_campus_id = any (app.auth_campus_ids())
      when 'subject_teacher' then app.fn_teacher_reads_section(p_section_id, p_subject_id)
      when 'class_teacher' then app.fn_teacher_reads_section(p_section_id, p_subject_id)
      when 'parent' then exists (select 1 from public.enrolment e where e.id = p_enrolment_id and e.student_id = any (app.auth_guardian_student_ids()))
      when 'student' then exists (select 1 from public.enrolment e where e.id = p_enrolment_id and e.student_id = public.my_student_id())
      else false
    end);
$$;
revoke execute on function app.fn_can_read_mastery(uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function app.fn_can_read_mastery(uuid, uuid, uuid, uuid, uuid) to authenticated;

alter table public.exam_question enable row level security;
alter table public.question_response_mark enable row level security;

-- The scheme itself carries no student data: any staff member of the campus.
create policy exam_question_campus_scope on public.exam_question
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'student', 'none')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));

create policy topic_mastery_parent_own_child on public.question_response_mark
  for select to authenticated
  using (
    app.auth_role() = 'parent'
    and enrolment_id in (select id from public.enrolment where student_id = any (app.auth_guardian_student_ids())));

create policy topic_mastery_teacher_own_section on public.question_response_mark
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'student', 'none')
    and (
      app.auth_role() in ('super_admin', 'owner')
      or (app.auth_role() in ('principal', 'vice_principal', 'exam_controller') and campus_id = any (app.auth_campus_ids()))
      or (app.auth_role() in ('subject_teacher', 'class_teacher') and exists (
            select 1 from public.enrolment e
              join public.exam_question q on q.id = exam_paper_question_id
              join public.exam_subject es on es.id = q.exam_subject_id
              join public.class_subject cs on cs.id = es.class_subject_id
             where e.id = question_response_mark.enrolment_id
               and app.fn_teacher_reads_section(e.section_id, cs.subject_id)))));

create policy topic_mastery_student_own on public.question_response_mark
  for select to authenticated
  using (app.auth_role() = 'student' and enrolment_id in (select id from public.enrolment where student_id = public.my_student_id()));
-- No DML policies: save_question_marks / fn_import_ocr_question_marks write.

-- ═══════════════════════════════════════════════════════════════════════
-- Writing
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.save_exam_questions(p_exam_subject_id uuid, p_questions jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_role   text := app.auth_role();
  v_es     record;
  v_paper  numeric;
  v_total  numeric;
  v_q      jsonb;
  v_no     integer;
  v_max    numeric;
  v_ch     smallint;
  v_title  text;
  v_tag    text;
  v_seen   integer[] := '{}';
  v_n      integer := 0;
begin
  if v_tenant is null or v_role not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller', 'subject_teacher', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select es.id, es.tenant_id, es.campus_id, cs.subject_id into v_es
    from public.exam_subject es join public.class_subject cs on cs.id = es.class_subject_id where es.id = p_exam_subject_id;
  if v_es.id is null or v_es.tenant_id <> v_tenant then
    raise exception 'EXAM_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_es.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_role in ('subject_teacher', 'class_teacher') and not exists (
       select 1 from public.section_subject_teacher t
        where t.subject_id = v_es.subject_id and t.staff_id = (select auth.uid()) and t.validity @> app.fn_karachi_today()) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if jsonb_typeof(p_questions) <> 'array' or jsonb_array_length(p_questions) = 0 then
    raise exception 'QUESTIONS_REQUIRED' using errcode = '22023';
  end if;
  if exists (select 1 from public.question_response_mark m join public.exam_question q on q.id = m.exam_paper_question_id
              where q.exam_subject_id = p_exam_subject_id) then
    raise exception 'QUESTIONS_LOCKED' using errcode = '23514',
      hint = 'Marks have already been captured against this scheme; changing it would re-label them.';
  end if;

  select coalesce(sum(c.max_marks), 0) into v_paper from public.exam_subject_component c where c.exam_subject_id = p_exam_subject_id;
  select coalesce(sum((x ->> 'max_marks')::numeric), 0) into v_total from jsonb_array_elements(p_questions) x;
  if v_paper > 0 and v_total > v_paper then
    raise exception 'QUESTIONS_EXCEED_PAPER' using errcode = '23514',
      detail = format('The questions add up to %s but the paper is out of %s.', v_total, v_paper);
  end if;

  delete from public.exam_question where exam_subject_id = p_exam_subject_id;
  for v_q in select * from jsonb_array_elements(p_questions) loop
    v_no := (v_q ->> 'question_no')::int;
    v_max := (v_q ->> 'max_marks')::numeric;
    v_ch := nullif(v_q ->> 'chapter_no', '')::smallint;
    v_title := nullif(btrim(coalesce(v_q ->> 'chapter_title', '')), '');
    if v_no is null or v_no <= 0 or v_no = any (v_seen) or v_max is null or v_max <= 0 then
      raise exception 'QUESTION_INVALID' using errcode = '22023', detail = format('question %s', v_q ->> 'question_no');
    end if;
    v_seen := v_seen || v_no;
    v_tag := nullif(btrim(concat_ws(' ', case when v_ch is not null then 'Ch.' || v_ch end, v_title)), '');
    if v_tag is null then
      raise exception 'QUESTION_TOPIC_REQUIRED' using errcode = '22023', detail = format('question %s needs a chapter', v_no);
    end if;
    insert into public.exam_question (tenant_id, campus_id, exam_subject_id, question_no, max_marks, chapter_no, topic_tag)
    values (v_tenant, v_es.campus_id, p_exam_subject_id, v_no, v_max, v_ch, v_tag);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.save_exam_questions(uuid, jsonb) from public, anon;
grant execute on function public.save_exam_questions(uuid, jsonb) to authenticated;

-- p_rows: [{"enrolment_id": "...", "marks": [{"question_no": 1, "obtained": 4.5}, ...]}, ...]
create or replace function public.save_question_marks(p_exam_subject_id uuid, p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_role   text := app.auth_role();
  v_es     record;
  v_row    jsonb;
  v_m      jsonb;
  v_enr    record;
  v_q      public.exam_question%rowtype;
  v_obt    numeric;
  v_n      integer := 0;
begin
  if v_tenant is null or v_role not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller', 'subject_teacher', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select es.id, es.tenant_id, es.campus_id, cs.subject_id into v_es
    from public.exam_subject es join public.class_subject cs on cs.id = es.class_subject_id where es.id = p_exam_subject_id;
  if v_es.id is null or v_es.tenant_id <> v_tenant then
    raise exception 'EXAM_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_es.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.exam_question where exam_subject_id = p_exam_subject_id) then
    raise exception 'NO_QUESTION_SCHEME' using errcode = '23514',
      hint = 'Define the paper''s questions and their chapters before capturing per-question marks.';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    select e.id, e.section_id, e.campus_id into v_enr
      from public.enrolment e where e.id = (v_row ->> 'enrolment_id')::uuid and e.tenant_id = v_tenant and e.deleted_at is null;
    if v_enr.id is null or v_enr.campus_id <> v_es.campus_id then
      raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
    end if;
    if v_role in ('subject_teacher', 'class_teacher') and not app.fn_teaches_section_subject(v_enr.section_id, v_es.subject_id) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    for v_m in select * from jsonb_array_elements(coalesce(v_row -> 'marks', '[]'::jsonb)) loop
      select * into v_q from public.exam_question where exam_subject_id = p_exam_subject_id and question_no = (v_m ->> 'question_no')::int;
      if v_q.id is null then
        raise exception 'QUESTION_NOT_FOUND' using errcode = 'P0002', detail = format('question %s', v_m ->> 'question_no');
      end if;
      v_obt := (v_m ->> 'obtained')::numeric;
      if v_obt is null or v_obt < 0 or v_obt > v_q.max_marks then
        raise exception 'MARKS_OUT_OF_RANGE' using errcode = '22003', detail = format('question %s is out of %s', v_q.question_no, v_q.max_marks);
      end if;
      insert into public.question_response_mark (tenant_id, campus_id, enrolment_id, exam_paper_question_id, obtained, max_marks, source, entered_by)
      values (v_tenant, v_es.campus_id, v_enr.id, v_q.id, v_obt, v_q.max_marks, 'manual', (select auth.uid()))
      on conflict (enrolment_id, exam_paper_question_id) do update
        set obtained = excluded.obtained, max_marks = excluded.max_marks, source = 'manual',
            entered_by = excluded.entered_by, entered_at = clock_timestamp();
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.save_question_marks(uuid, jsonb) from public, anon;
grant execute on function public.save_question_marks(uuid, jsonb) to authenticated;

-- OCR-graded papers already carry per-question marks: ocr_review_action has
-- the human-confirmed final_value per (candidate, question_no). This lifts them
-- into question_response_mark wherever the paper has a scheme row for that
-- question number; questions outside the scheme are counted, not guessed.
create or replace function public.fn_import_ocr_question_marks(p_job_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant  uuid := app.auth_tenant_id();
  v_job     public.ocr_mark_job%rowtype;
  v_n       integer;
  v_skipped integer;
begin
  if v_tenant is null or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_job from public.ocr_mark_job where id = p_job_id and tenant_id = v_tenant;
  if v_job.id is null then
    raise exception 'OCR_JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_job.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.exam_question where exam_subject_id = v_job.exam_subject_id) then
    raise exception 'NO_QUESTION_SCHEME' using errcode = '23514';
  end if;

  with latest as (
    select distinct on (a.enrolment_id, a.question_no) a.enrolment_id, a.question_no, a.final_value
      from public.ocr_review_action a
     where a.job_id = p_job_id and a.final_value is not null
     order by a.enrolment_id, a.question_no, a.acted_at desc
  ), ins as (
    insert into public.question_response_mark (tenant_id, campus_id, enrolment_id, exam_paper_question_id, obtained, max_marks, source, entered_by)
    select v_tenant, v_job.campus_id, l.enrolment_id, q.id, least(l.final_value, q.max_marks), q.max_marks, 'ocr', (select auth.uid())
      from latest l join public.exam_question q on q.exam_subject_id = v_job.exam_subject_id and q.question_no = l.question_no
    on conflict (enrolment_id, exam_paper_question_id) do update
      set obtained = excluded.obtained, max_marks = excluded.max_marks, source = 'ocr',
          entered_by = excluded.entered_by, entered_at = clock_timestamp()
    returning 1
  )
  select (select count(*) from ins), (select count(*) from latest) - (select count(*) from ins) into v_n, v_skipped;
  return jsonb_build_object('imported', v_n, 'skipped_no_scheme_row', greatest(v_skipped, 0));
end;
$$;
revoke execute on function public.fn_import_ocr_question_marks(uuid) from public, anon;
grant execute on function public.fn_import_ocr_question_marks(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The materialized view
-- ═══════════════════════════════════════════════════════════════════════

create materialized view app.mv_topic_mastery as
select m.tenant_id,
       e.campus_id,
       e.section_id,
       m.enrolment_id,
       cs.subject_id,
       q.topic_tag,
       sum(m.obtained)::numeric(9,2)  as obtained,
       sum(m.max_marks)::numeric(9,2) as max_marks,
       round(sum(m.obtained) * 100 / nullif(sum(m.max_marks), 0), 2)::numeric(5,2) as pct,
       count(*)::int                  as question_count
  from public.question_response_mark m
  join public.exam_question q on q.id = m.exam_paper_question_id
  join public.exam_subject es on es.id = q.exam_subject_id
  join public.class_subject cs on cs.id = es.class_subject_id
  join public.enrolment e on e.id = m.enrolment_id
 group by m.tenant_id, e.campus_id, e.section_id, m.enrolment_id, cs.subject_id, q.topic_tag;

create unique index uq_mv_topic_mastery on app.mv_topic_mastery (enrolment_id, subject_id, topic_tag);
create index idx_mv_topic_mastery_section on app.mv_topic_mastery (section_id, subject_id);
create index idx_mv_topic_mastery_scope on app.mv_topic_mastery (tenant_id, campus_id);

revoke all on app.mv_topic_mastery from public, anon;
grant select on app.mv_topic_mastery to authenticated;

create or replace function app.fn_refresh_topic_mastery_all()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  refresh materialized view concurrently app.mv_topic_mastery;
  select count(*)::int into v_n from app.mv_topic_mastery;
  insert into public.agg_refresh_log (job_name, status, rows_written) values ('topic_mastery', 'ok', v_n);
  return v_n;
exception when others then
  insert into public.agg_refresh_log (job_name, status, error) values ('topic_mastery', 'failed', left(sqlerrm, 500));
  raise;
end;
$$;
revoke execute on function app.fn_refresh_topic_mastery_all() from public, anon, authenticated;

-- PostgreSQL cannot refresh part of a materialized view; the term is validated
-- and the whole view is refreshed (null = all, the nightly job).
create or replace function public.fn_refresh_topic_mastery(p_exam_term_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
begin
  if v_tenant is not null and app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller', 'subject_teacher', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_exam_term_id is not null
     and not exists (select 1 from public.exam_term t where t.id = p_exam_term_id and (v_tenant is null or t.tenant_id = v_tenant)) then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  return app.fn_refresh_topic_mastery_all();
end;
$$;
revoke execute on function public.fn_refresh_topic_mastery(uuid) from public, anon;
grant execute on function public.fn_refresh_topic_mastery(uuid) to authenticated, service_role;

-- Nightly at 03:00 Karachi (22:00 UTC the evening before).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('refresh-topic-mastery', '0 22 * * *', 'select public.fn_refresh_topic_mastery(null);');
  end if;
exception
  when others then null;
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- What a screen reads
-- ═══════════════════════════════════════════════════════════════════════

create view public.v_topic_mastery
with (security_invoker = true) as
select m.tenant_id,
       m.campus_id,
       m.section_id,
       m.enrolment_id,
       m.subject_id,
       app.fn_subject_name(m.subject_id) as subject_name,
       m.topic_tag,
       m.obtained,
       m.max_marks,
       m.pct,
       m.question_count,
       (m.question_count < 3)             as low_confidence
  from app.mv_topic_mastery m
 where app.fn_can_read_mastery(m.tenant_id, m.campus_id, m.section_id, m.subject_id, m.enrolment_id);

revoke all on public.v_topic_mastery from public, anon;
grant select on public.v_topic_mastery to authenticated;

-- The section's pooled figure per chapter, with no student in it.
create view public.v_section_topic_mastery
with (security_invoker = true) as
select m.tenant_id,
       m.campus_id,
       m.section_id,
       m.subject_id,
       app.fn_subject_name(m.subject_id) as subject_name,
       m.topic_tag,
       sum(m.obtained)::numeric(9,2)      as obtained,
       sum(m.max_marks)::numeric(9,2)     as max_marks,
       round(sum(m.obtained) * 100 / nullif(sum(m.max_marks), 0), 2)::numeric(5,2) as pct,
       count(distinct m.enrolment_id)::int as students,
       max(m.question_count)::int          as question_count,
       (round(sum(m.obtained) * 100 / nullif(sum(m.max_marks), 0), 2) < 50) as reteach,
       (max(m.question_count) < 3)         as low_confidence
  from app.mv_topic_mastery m
 where app.auth_role() not in ('parent', 'student')
   and app.fn_can_read_mastery(m.tenant_id, m.campus_id, m.section_id, m.subject_id, m.enrolment_id)
 group by m.tenant_id, m.campus_id, m.section_id, m.subject_id, m.topic_tag;

revoke all on public.v_section_topic_mastery from public, anon;
grant select on public.v_section_topic_mastery to authenticated;

-- One candidate's page: the chapters, and, for every paper they sat that has no
-- per-question marks, a line saying so (AC2).
create or replace function public.fn_topic_mastery_sheet(p_enrolment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_e      record;
  v_topics jsonb;
  v_unc    jsonb;
begin
  select e.id, e.tenant_id, e.campus_id, e.section_id, e.student_id, st.name_en as student_name
    into v_e from public.enrolment e join public.student st on st.id = e.student_id
   where e.id = p_enrolment_id and e.deleted_at is null;
  if v_e.id is null or v_e.tenant_id <> app.auth_tenant_id() then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  -- Subject-agnostic check first: the caller must be allowed to see this child
  -- at all. Teachers are then narrowed to their subjects below.
  if not (case app.auth_role()
            when 'parent' then v_e.student_id = any (app.auth_guardian_student_ids())
            when 'student' then v_e.student_id = public.my_student_id()
            when 'super_admin' then true
            when 'owner' then true
            when 'principal' then v_e.campus_id = any (app.auth_campus_ids())
            when 'vice_principal' then v_e.campus_id = any (app.auth_campus_ids())
            when 'exam_controller' then v_e.campus_id = any (app.auth_campus_ids())
            when 'subject_teacher' then exists (select 1 from public.section_subject_teacher t where t.section_id = v_e.section_id and t.staff_id = (select auth.uid()) and t.validity @> app.fn_karachi_today())
            when 'class_teacher' then exists (select 1 from public.section_class_teacher c where c.section_id = v_e.section_id and c.staff_id = (select auth.uid()) and c.validity @> app.fn_karachi_today())
            else false end) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'subject_id', m.subject_id, 'subject_name', app.fn_subject_name(m.subject_id), 'topic_tag', m.topic_tag,
           'obtained', m.obtained, 'max_marks', m.max_marks, 'pct', m.pct,
           'question_count', m.question_count, 'low_confidence', m.question_count < 3)
           order by app.fn_subject_name(m.subject_id), m.pct, m.topic_tag), '[]'::jsonb)
    into v_topics
    from app.mv_topic_mastery m
   where m.enrolment_id = p_enrolment_id
     and app.fn_can_read_mastery(m.tenant_id, m.campus_id, m.section_id, m.subject_id, m.enrolment_id);

  -- A paper the candidate has a result for, with no per-question mark behind it.
  select coalesce(jsonb_agg(jsonb_build_object(
           'subject_name', sub.name_en, 'term_name', t.name, 'exam_subject_id', sr.exam_subject_id,
           'reason', case when exists (select 1 from public.exam_question q where q.exam_subject_id = sr.exam_subject_id)
                          then 'no_marks_for_candidate' else 'no_question_scheme' end)
           order by t.sequence, sub.name_en), '[]'::jsonb)
    into v_unc
    from public.subject_result sr
    join public.subject sub on sub.id = sr.subject_id
    join public.exam_term t on t.id = sr.exam_term_id
   where sr.enrolment_id = p_enrolment_id
     and not sr.is_blocked
     and not app.fn_result_withheld(sr.enrolment_id, sr.exam_term_id)
     and not exists (select 1 from public.question_response_mark m join public.exam_question q on q.id = m.exam_paper_question_id
                      where m.enrolment_id = p_enrolment_id and q.exam_subject_id = sr.exam_subject_id)
     and (app.auth_role() not in ('subject_teacher', 'class_teacher') or app.fn_teacher_reads_section(v_e.section_id, sr.subject_id));

  return jsonb_build_object(
    'enrolment_id', p_enrolment_id, 'student_name', v_e.student_name,
    'has_breakdown', jsonb_array_length(v_topics) > 0,
    'topics', v_topics,
    'uncaptured', v_unc);
end;
$$;
revoke execute on function public.fn_topic_mastery_sheet(uuid) from public, anon;
grant execute on function public.fn_topic_mastery_sheet(uuid) to authenticated;

-- The scheme and the students of a paper, for the capture grid.
create or replace function public.fn_question_marks_sheet(p_exam_subject_id uuid, p_section_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_role   text := app.auth_role();
  v_es     record;
begin
  if v_tenant is null or v_role not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller', 'subject_teacher', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select es.id, es.tenant_id, es.campus_id, cs.subject_id into v_es
    from public.exam_subject es join public.class_subject cs on cs.id = es.class_subject_id where es.id = p_exam_subject_id;
  if v_es.id is null or v_es.tenant_id <> v_tenant then
    raise exception 'EXAM_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_es.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_role in ('subject_teacher', 'class_teacher') and not app.fn_teaches_section_subject(p_section_id, v_es.subject_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'exam_subject_id', p_exam_subject_id,
    'questions', coalesce((select jsonb_agg(jsonb_build_object('question_no', q.question_no, 'max_marks', q.max_marks,
                                    'chapter_no', q.chapter_no, 'topic_tag', q.topic_tag) order by q.question_no)
                            from public.exam_question q where q.exam_subject_id = p_exam_subject_id), '[]'::jsonb),
    'students', coalesce((select jsonb_agg(jsonb_build_object(
                  'enrolment_id', e.id, 'roll_no', e.roll_no, 'student_name', st.name_en, 'gr_number', st.gr_number,
                  'marks', coalesce((select jsonb_object_agg(q.question_no::text, m.obtained)
                                       from public.question_response_mark m join public.exam_question q on q.id = m.exam_paper_question_id
                                      where m.enrolment_id = e.id and q.exam_subject_id = p_exam_subject_id), '{}'::jsonb))
                  order by e.roll_no nulls last, st.name_en)
                  from public.enrolment e join public.student st on st.id = e.student_id
                 where e.section_id = p_section_id and e.status = 'active' and e.deleted_at is null), '[]'::jsonb));
end;
$$;
revoke execute on function public.fn_question_marks_sheet(uuid, uuid) from public, anon;
grant execute on function public.fn_question_marks_sheet(uuid, uuid) to authenticated;
