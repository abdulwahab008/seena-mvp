-- FR-H06: teacher review and feedback on submissions.
--
-- A submission is checked with a mandatory feedback code, an optional remark
-- (500 characters) and an optional score against the assignment's max_score.
-- Any teacher assigned to that section and subject may check it, not only the
-- one who set it; checked_by records who did, distinct from homework.teacher_id.
-- Editing a checked submission is allowed and the previous feedback is kept in
-- homework_feedback_history. bulk_check_submissions applies one code and remark
-- to many submissions in a single transaction. Scores stay in the homework
-- module: nothing here reads or writes the exam result tables, and the
-- Assessment module has to opt in explicitly.
-- The student's page refreshes over realtime when a submission row changes.

alter table public.homework add column if not exists max_score numeric(5, 2) check (max_score is null or max_score > 0);
alter table public.homework_submission
  add column if not exists feedback_code text check (feedback_code is null or feedback_code in ('excellent', 'good', 'satisfactory', 'needs_improvement', 'incomplete')),
  add column if not exists feedback_remark text check (feedback_remark is null or char_length(feedback_remark) <= 500),
  add column if not exists score numeric(5, 2) check (score is null or score >= 0);
alter table public.homework_submission add constraint chk_checked_has_feedback check (status <> 'checked' or (feedback_code is not null and checked_by is not null and checked_at is not null));

create table public.homework_feedback_history (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  submission_id   uuid not null references public.homework_submission(id) on delete cascade,
  feedback_code   text,
  feedback_remark text,
  score           numeric(5, 2),
  changed_by      uuid references auth.users(id),
  changed_at      timestamptz not null default now()
);
create index idx_hw_feedback_history_submission on public.homework_feedback_history (submission_id, changed_at desc);
create index idx_hw_feedback_history_tenant on public.homework_feedback_history (tenant_id);
alter table public.homework_feedback_history enable row level security;
create policy hw_feedback_history_read on public.homework_feedback_history for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.homework_submission s where s.id = submission_id));

alter publication supabase_realtime add table public.homework_submission;

-- Teachers of the section and subject can read and check, not only the author.
create or replace function app.fn_teacher_of_homework(p_homework_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.homework h
     where h.id = p_homework_id and h.tenant_id = app.auth_tenant_id()
       and (h.teacher_id = (select auth.uid())
            or exists (select 1 from public.section_subject_teacher t
                        where t.section_id = h.section_id and t.subject_id = h.subject_id and t.staff_id = (select auth.uid())
                          and t.validity @> app.fn_karachi_today())
            or (app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal')
                and (app.auth_role() in ('owner', 'super_admin') or h.campus_id = any (app.auth_campus_ids()))))
  );
$$;

create or replace function public.set_homework_max_score(p_homework_id uuid, p_max_score numeric default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app.fn_teacher_of_homework(p_homework_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_max_score is not null and (p_max_score <= 0 or p_max_score > 999.99) then
    raise exception 'MAX_SCORE_INVALID' using errcode = '22023';
  end if;
  if exists (select 1 from public.homework_submission where homework_id = p_homework_id and score is not null and p_max_score is not null and score > p_max_score) then
    raise exception 'EXISTING_SCORE_EXCEEDS_MAX' using errcode = '23514';
  end if;
  update public.homework set max_score = p_max_score where id = p_homework_id and tenant_id = app.auth_tenant_id();
end;
$$;
revoke execute on function public.set_homework_max_score(uuid, numeric) from public, anon;
grant execute on function public.set_homework_max_score(uuid, numeric) to authenticated;

create or replace function app.fn_apply_check(p_s public.homework_submission, p_code text, p_remark text, p_score numeric, p_hw public.homework)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_s.status = 'checked' then
    insert into public.homework_feedback_history (tenant_id, submission_id, feedback_code, feedback_remark, score, changed_by, changed_at)
    values (p_s.tenant_id, p_s.id, p_s.feedback_code, p_s.feedback_remark, p_s.score, p_s.checked_by, p_s.checked_at);
  end if;
  update public.homework_submission
     set status = 'checked', feedback_code = p_code, feedback_remark = p_remark, score = p_score,
         checked_by = (select auth.uid()), checked_at = clock_timestamp()
   where id = p_s.id;
end;
$$;
revoke execute on function app.fn_apply_check(public.homework_submission, text, text, numeric, public.homework) from public, anon, authenticated;

create or replace function public.check_submission(p_submission_id uuid, p_feedback_code text, p_remark text default null, p_score numeric default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s  public.homework_submission%rowtype;
  v_hw public.homework%rowtype;
begin
  select * into v_s from public.homework_submission where id = p_submission_id and tenant_id = app.auth_tenant_id() for update;
  if not found or not app.fn_teacher_of_homework(v_s.homework_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_s.status = 'draft' then
    raise exception 'SUBMISSION_NOT_SUBMITTED' using errcode = '55000';
  end if;
  select * into v_hw from public.homework where id = v_s.homework_id;
  if p_feedback_code is null or p_feedback_code not in ('excellent', 'good', 'satisfactory', 'needs_improvement', 'incomplete') then
    raise exception 'FEEDBACK_REQUIRED' using errcode = '22023';
  end if;
  if char_length(coalesce(p_remark, '')) > 500 then
    raise exception 'REMARK_TOO_LONG' using errcode = '23514';
  end if;
  if p_score is not null then
    if v_hw.max_score is null then
      raise exception 'SCORE_NOT_ENABLED' using errcode = '22023';
    end if;
    if p_score < 0 then
      raise exception 'SCORE_NEGATIVE' using errcode = '23514';
    end if;
    if p_score > v_hw.max_score then
      raise exception 'SCORE_EXCEEDS_MAX' using errcode = '23514', detail = format('max=%s', trim_scale(v_hw.max_score));
    end if;
  end if;
  perform app.fn_apply_check(v_s, p_feedback_code, nullif(btrim(p_remark), ''), p_score, v_hw);
end;
$$;
revoke execute on function public.check_submission(uuid, text, text, numeric) from public, anon;
grant execute on function public.check_submission(uuid, text, text, numeric) to authenticated;

create or replace function public.bulk_check_submissions(p_homework_id uuid, p_submission_ids uuid[], p_feedback_code text, p_remark text default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hw public.homework%rowtype;
  v_s  public.homework_submission%rowtype;
  v_n  int := 0;
begin
  select * into v_hw from public.homework where id = p_homework_id and tenant_id = app.auth_tenant_id();
  if not found or not app.fn_teacher_of_homework(p_homework_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_feedback_code is null or p_feedback_code not in ('excellent', 'good', 'satisfactory', 'needs_improvement', 'incomplete') then
    raise exception 'FEEDBACK_REQUIRED' using errcode = '22023';
  end if;
  if char_length(coalesce(p_remark, '')) > 500 then
    raise exception 'REMARK_TOO_LONG' using errcode = '23514';
  end if;
  if p_submission_ids is null or cardinality(p_submission_ids) = 0 or cardinality(p_submission_ids) > 300 then
    raise exception 'SUBMISSIONS_MUST_BE_1_TO_300' using errcode = '22023';
  end if;
  for v_s in
    select * from public.homework_submission
     where homework_id = p_homework_id and id = any (p_submission_ids) and status in ('submitted', 'checked')
     order by id for update
  loop
    perform app.fn_apply_check(v_s, p_feedback_code, nullif(btrim(p_remark), ''), v_s.score, v_hw);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.bulk_check_submissions(uuid, uuid[], text, text) from public, anon;
grant execute on function public.bulk_check_submissions(uuid, uuid[], text, text) to authenticated;
