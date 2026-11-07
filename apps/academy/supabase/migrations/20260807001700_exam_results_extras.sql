-- Exam results extras: results by SMS, re-check requests, board (external)
-- results, and co-scholastic behaviour ratings.
--
-- Results by SMS read what the term already computed (result_position and
-- subject_result) and queue one message per student to the primary guardian
-- through the existing outbox. A withheld result (fee default) is never sent.
--
-- A re-check is a register: request with its fee, then the outcome. When the
-- marks change, the controller corrects them through the existing break-glass
-- unlock, so the audit trail stays in one place; the re-check records the
-- before and after.

create or replace function app.fn_exam_staff()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller', 'head_of_department', 'class_teacher');
$$;

create or replace function app.fn_assert_exam_admin(p_campus_id uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller')
     or (app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function app.fn_assert_exam_admin(uuid) from public, anon, authenticated;

-- ── results by SMS ────────────────────────────────────────────────────────

create or replace function public.queue_result_messages(p_exam_term_id uuid, p_section_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_term     public.exam_term%rowtype;
  v_queued   int := 0;
  v_no_phone int := 0;
  r record;
  v_msg uuid;
begin
  select * into v_term from public.exam_term where id = p_exam_term_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_exam_admin(v_term.campus_id);

  for r in
    select p.enrolment_id, s.name_en, p.total_obtained, p.total_max, p.rank_in_section, p.ranked_out_of,
           (select count(*) from public.subject_result sr where sr.exam_term_id = p.exam_term_id and sr.enrolment_id = p.enrolment_id and sr.is_pass = false) as failed,
           (select g.phone_e164 from public.student_guardian sg join public.guardian g on g.id = sg.guardian_id
             where sg.student_id = s.id and sg.receives_academic and (sg.to_date is null or sg.to_date >= current_date) and g.phone_e164 is not null
             order by sg.is_primary desc, sg.priority limit 1) as phone
      from public.result_position p
      join public.enrolment e on e.id = p.enrolment_id
      join public.student s on s.id = e.student_id
     where p.exam_term_id = p_exam_term_id and p.section_id = p_section_id
       and coalesce(p.exclusion_reason, '') <> 'withheld'
       and not exists (select 1 from public.subject_result sr where sr.exam_term_id = p.exam_term_id and sr.enrolment_id = p.enrolment_id and sr.is_blocked)
  loop
    if r.phone is null then
      v_no_phone := v_no_phone + 1;
      continue;
    end if;
    insert into public.message (tenant_id, campus_id, recipient_type, recipient_phone, channel, subject, body, status, idempotency_key, metadata)
    values (v_term.tenant_id, v_term.campus_id, 'guardian', r.phone, 'sms', v_term.name || ' result',
            format('Assalam o Alaikum. %s''s %s result: %s/%s (%s%%)%s%s.', r.name_en, v_term.name,
                   trim(to_char(r.total_obtained, 'FM999990.##')), r.total_max,
                   case when r.total_max > 0 then round(r.total_obtained * 100 / r.total_max, 1)::text else '0' end,
                   case when r.rank_in_section is not null then format(', position %s of %s', r.rank_in_section, r.ranked_out_of) else '' end,
                   case when r.failed > 0 then format(', needs to improve in %s subject%s', r.failed, case when r.failed = 1 then '' else 's' end) else '' end),
            'queued', 'result:' || p_exam_term_id || ':' || r.enrolment_id,
            jsonb_build_object('template', 'term_result', 'exam_term_id', p_exam_term_id, 'enrolment_id', r.enrolment_id))
    on conflict (tenant_id, idempotency_key) where idempotency_key is not null do nothing
    returning id into v_msg;
    if v_msg is not null then
      v_queued := v_queued + 1;
    end if;
  end loop;
  return jsonb_build_object('queued', v_queued, 'no_phone', v_no_phone);
end;
$$;
revoke execute on function public.queue_result_messages(uuid, uuid) from public, anon;
grant execute on function public.queue_result_messages(uuid, uuid) to authenticated;

-- ── re-checks ─────────────────────────────────────────────────────────────

create table public.result_recheck (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  exam_term_id  uuid not null references public.exam_term(id) on delete cascade,
  enrolment_id  uuid not null references public.enrolment(id) on delete cascade,
  subject_id    uuid not null references public.subject(id),
  fee_paisa     bigint not null default 0 check (fee_paisa >= 0),
  reason        text not null check (length(btrim(reason)) between 1 and 500),
  marks_before  numeric(7,2),
  status        text not null default 'requested' check (status in ('requested', 'unchanged', 'changed')),
  marks_after   numeric(7,2),
  outcome_note  text check (outcome_note is null or length(outcome_note) <= 500),
  requested_by  uuid default auth.uid() references auth.users(id),
  requested_at  timestamptz not null default now(),
  decided_by    uuid references auth.users(id),
  decided_at    timestamptz,
  constraint chk_recheck_decided check ((status = 'requested') = (decided_at is null)),
  constraint chk_recheck_changed check (status <> 'changed' or marks_after is not null)
);
create unique index uq_result_recheck_open on public.result_recheck (exam_term_id, enrolment_id, subject_id) where status = 'requested';
create index idx_result_recheck_campus on public.result_recheck (tenant_id, campus_id, exam_term_id);
alter table public.result_recheck enable row level security;
create policy result_recheck_read on public.result_recheck for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_exam_staff()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
select app.fn_block_portal_roles('public.result_recheck');

create or replace function public.request_result_recheck(p_exam_term_id uuid, p_enrolment_id uuid, p_subject_id uuid, p_fee_paisa bigint, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campus uuid;
  v_before numeric;
  v_id     uuid;
begin
  select campus_id into v_campus from public.exam_term where id = p_exam_term_id and tenant_id = app.auth_tenant_id();
  if v_campus is null then
    raise exception 'TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_exam_admin(v_campus);
  select obtained into v_before from public.subject_result
   where exam_term_id = p_exam_term_id and enrolment_id = p_enrolment_id and subject_id = p_subject_id;
  if not found then
    raise exception 'RESULT_NOT_FOUND' using errcode = 'P0002', hint = 'There is no computed result for this student and subject yet.';
  end if;
  insert into public.result_recheck (tenant_id, campus_id, exam_term_id, enrolment_id, subject_id, fee_paisa, reason, marks_before)
  values (app.auth_tenant_id(), v_campus, p_exam_term_id, p_enrolment_id, p_subject_id, coalesce(p_fee_paisa, 0), btrim(p_reason), v_before)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.request_result_recheck(uuid, uuid, uuid, bigint, text) from public, anon;
grant execute on function public.request_result_recheck(uuid, uuid, uuid, bigint, text) to authenticated;

create or replace function public.decide_result_recheck(p_id uuid, p_changed boolean, p_marks_after numeric, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.result_recheck%rowtype;
begin
  select * into v from public.result_recheck where id = p_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'RECHECK_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_exam_admin(v.campus_id);
  if v.status <> 'requested' then
    raise exception 'RECHECK_DECIDED' using errcode = '55000';
  end if;
  if p_changed and p_marks_after is null then
    raise exception 'MARKS_REQUIRED' using errcode = '22023';
  end if;
  update public.result_recheck
     set status = case when p_changed then 'changed' else 'unchanged' end,
         marks_after = case when p_changed then p_marks_after else marks_before end,
         outcome_note = nullif(btrim(coalesce(p_note, '')), ''),
         decided_by = auth.uid(), decided_at = now()
   where id = p_id;
end;
$$;
revoke execute on function public.decide_result_recheck(uuid, boolean, numeric, text) from public, anon;
grant execute on function public.decide_result_recheck(uuid, boolean, numeric, text) to authenticated;

-- ── board (external) results ──────────────────────────────────────────────

create table public.external_result (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  student_id uuid not null references public.student(id) on delete cascade,
  board      text not null check (length(btrim(board)) between 1 and 120),
  exam       text not null check (length(btrim(exam)) between 1 and 120),
  exam_year  int not null check (exam_year between 1990 and 2100),
  roll_no    text not null check (length(btrim(roll_no)) between 1 and 40),
  obtained   numeric(7,2) not null check (obtained >= 0),
  total      int not null check (total > 0),
  grade      text check (grade is null or length(grade) <= 20),
  created_by uuid default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  constraint chk_external_result_marks check (obtained <= total)
);
create unique index uq_external_result on public.external_result (student_id, exam, exam_year);
create index idx_external_result_campus on public.external_result (tenant_id, campus_id, exam_year desc);
alter table public.external_result enable row level security;
create policy external_result_read on public.external_result for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_exam_staff()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
select app.fn_block_portal_roles('public.external_result');

create or replace function public.save_external_result(p_student_id uuid, p_board text, p_exam text, p_exam_year int, p_roll_no text, p_obtained numeric, p_total int, p_grade text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campus uuid;
  v_id     uuid;
begin
  select campus_id into v_campus from public.student where id = p_student_id and tenant_id = app.auth_tenant_id();
  if v_campus is null then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_exam_admin(v_campus);
  insert into public.external_result (tenant_id, campus_id, student_id, board, exam, exam_year, roll_no, obtained, total, grade)
  values (app.auth_tenant_id(), v_campus, p_student_id, btrim(p_board), btrim(p_exam), p_exam_year, btrim(p_roll_no), p_obtained, p_total, nullif(btrim(coalesce(p_grade, '')), ''))
  on conflict (student_id, exam, exam_year) do update
     set board = excluded.board, roll_no = excluded.roll_no, obtained = excluded.obtained, total = excluded.total, grade = excluded.grade
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.save_external_result(uuid, text, text, int, text, numeric, int, text) from public, anon;
grant execute on function public.save_external_result(uuid, text, text, int, text, numeric, int, text) to authenticated;

-- ── behaviour (co-scholastic) ratings ─────────────────────────────────────

create table public.behaviour_trait (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  name       text not null check (length(btrim(name)) between 1 and 60),
  sort_order int not null default 0,
  is_active  boolean not null default true
);
create unique index uq_behaviour_trait on public.behaviour_trait (tenant_id, lower(name));
alter table public.behaviour_trait enable row level security;
create policy behaviour_trait_read on public.behaviour_trait for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_exam_staff());
select app.fn_block_portal_roles('public.behaviour_trait');

create table public.behaviour_rating (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  exam_term_id uuid not null references public.exam_term(id) on delete cascade,
  enrolment_id uuid not null references public.enrolment(id) on delete cascade,
  trait_id     uuid not null references public.behaviour_trait(id) on delete cascade,
  rating       char(1) not null check (rating in ('A', 'B', 'C', 'D', 'E')),
  rated_by     uuid default auth.uid() references auth.users(id),
  rated_at     timestamptz not null default now()
);
create unique index uq_behaviour_rating on public.behaviour_rating (exam_term_id, enrolment_id, trait_id);
create index idx_behaviour_rating_campus on public.behaviour_rating (tenant_id, campus_id);
alter table public.behaviour_rating enable row level security;
create policy behaviour_rating_read on public.behaviour_rating for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_exam_staff()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
select app.fn_block_portal_roles('public.behaviour_rating');

-- The standard traits a Pakistani report card carries, added the first time
-- they are needed.
create or replace function public.ensure_behaviour_traits()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app.fn_exam_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.behaviour_trait (tenant_id, name, sort_order)
  select app.auth_tenant_id(), t.name, t.ord
    from (values ('Punctuality', 1), ('Discipline', 2), ('Neatness', 3), ('Class participation', 4), ('Cooperation', 5)) as t(name, ord)
   where not exists (select 1 from public.behaviour_trait where tenant_id = app.auth_tenant_id());
end;
$$;
revoke execute on function public.ensure_behaviour_traits() from public, anon;
grant execute on function public.ensure_behaviour_traits() to authenticated;

-- p_ratings: [{"enrolment_id": uuid, "trait_id": uuid, "rating": "A".."E" or ""}]; "" clears.
create or replace function public.save_behaviour_ratings(p_exam_term_id uuid, p_ratings jsonb)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_term public.exam_term%rowtype;
  v_n    int;
begin
  select * into v_term from public.exam_term where id = p_exam_term_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app.fn_exam_staff() or (app.auth_role() not in ('super_admin', 'owner') and not (v_term.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if exists (select 1 from jsonb_array_elements(p_ratings) r
              where not exists (select 1 from public.enrolment e where e.id = (r ->> 'enrolment_id')::uuid and e.campus_id = v_term.campus_id)
                 or not exists (select 1 from public.behaviour_trait t where t.id = (r ->> 'trait_id')::uuid and t.tenant_id = v_term.tenant_id)) then
    raise exception 'NOT_FOUND' using errcode = 'P0002';
  end if;

  delete from public.behaviour_rating b
   using jsonb_array_elements(p_ratings) r
   where b.exam_term_id = p_exam_term_id and b.enrolment_id = (r ->> 'enrolment_id')::uuid and b.trait_id = (r ->> 'trait_id')::uuid
     and coalesce(r ->> 'rating', '') = '';
  insert into public.behaviour_rating (tenant_id, campus_id, exam_term_id, enrolment_id, trait_id, rating)
  select v_term.tenant_id, v_term.campus_id, p_exam_term_id, (r ->> 'enrolment_id')::uuid, (r ->> 'trait_id')::uuid, r ->> 'rating'
    from jsonb_array_elements(p_ratings) r
   where coalesce(r ->> 'rating', '') <> ''
  on conflict (exam_term_id, enrolment_id, trait_id) do update set rating = excluded.rating, rated_by = auth.uid(), rated_at = now();
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.save_behaviour_ratings(uuid, jsonb) from public, anon;
grant execute on function public.save_behaviour_ratings(uuid, jsonb) to authenticated;
