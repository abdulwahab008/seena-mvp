-- Teachers type questions into the bank. Until now the bank filled only from
-- published papers, so "Set A / Set B from the bank" had nothing to draw on for a
-- school without a paper generator.
--
-- Who may write to a class subject's bank is who may request its papers: the
-- office (owner, super_admin, principal, exam_controller) on its campus, or a
-- teacher assigned that subject in a section of that class and session.

create or replace function app.fn_can_edit_bank(p_class_subject_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.class_subject cs
     where cs.id = p_class_subject_id and cs.tenant_id = app.auth_tenant_id()
       and (
         (app.auth_role() in ('owner', 'super_admin', 'principal', 'exam_controller')
          and (app.auth_role() in ('owner', 'super_admin') or cs.campus_id = any (app.auth_campus_ids())))
         or exists (select 1 from public.section_subject_teacher t
                      join public.class_section sec on sec.id = t.section_id
                     where t.staff_id = (select auth.uid()) and t.subject_id = cs.subject_id
                       and sec.class_level_id = cs.class_level_id and sec.session_id = cs.session_id)
       )
  );
$$;
revoke execute on function app.fn_can_edit_bank(uuid) from public, anon;
grant execute on function app.fn_can_edit_bank(uuid) to authenticated;

-- The class subjects the caller may add questions to, for the picker.
create or replace function public.my_bank_class_subjects()
returns table (class_subject_id uuid, subject_name text, class_name text, class_ordinal smallint)
language sql
stable
security definer
set search_path = ''
as $$
  select cs.id, s.name_en, cl.name_en, cl.ordinal
    from public.class_subject cs
    join public.subject s on s.id = cs.subject_id
    join public.class_level cl on cl.id = cs.class_level_id
    join public.academic_session sess on sess.id = cs.session_id
   where cs.tenant_id = app.auth_tenant_id() and sess.is_current and app.fn_can_edit_bank(cs.id)
   order by cl.ordinal, s.name_en;
$$;
revoke execute on function public.my_bank_class_subjects() from public, anon;
grant execute on function public.my_bank_class_subjects() to authenticated;

create or replace function public.add_bank_question(
  p_class_subject_id uuid, p_chapter text, p_type text, p_marks int, p_text text,
  p_options jsonb default null, p_answer text default null, p_difficulty text default 'medium'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cs public.class_subject%rowtype;
  v_id uuid;
begin
  select * into v_cs from public.class_subject where id = p_class_subject_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CLASS_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app.fn_can_edit_bank(p_class_subject_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if coalesce(btrim(p_chapter), '') = '' then
    raise exception 'CHAPTER_REQUIRED' using errcode = '22023';
  end if;
  if p_type = 'mcq' and (jsonb_typeof(p_options) is distinct from 'array' or jsonb_array_length(p_options) <> 4
                         or coalesce(p_answer, '') not in ('A', 'B', 'C', 'D')) then
    raise exception 'MCQ_OPTIONS_INVALID' using errcode = '22023';
  end if;

  insert into public.question_bank_item (tenant_id, campus_id, subject_id, class_level_id, chapter, difficulty, marks, question_type, question_text, options, answer, created_by)
  values (v_cs.tenant_id, v_cs.campus_id, v_cs.subject_id, v_cs.class_level_id, btrim(p_chapter), coalesce(p_difficulty, 'medium'), p_marks, p_type,
          btrim(p_text), case when p_type = 'mcq' then p_options end, nullif(btrim(coalesce(p_answer, '')), ''), (select auth.uid()))
  returning id into v_id;
  return v_id;
exception
  when unique_violation then
    raise exception 'QUESTION_EXISTS' using errcode = '23505';
end;
$$;
revoke execute on function public.add_bank_question(uuid, text, text, int, text, jsonb, text, text) from public, anon;
grant execute on function public.add_bank_question(uuid, text, text, int, text, jsonb, text, text) to authenticated;

-- Retiring keeps the row (usage history points at it) but takes it out of new sets.
create or replace function public.set_bank_question_active(p_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cs uuid;
begin
  select cs.id into v_cs
    from public.question_bank_item b
    join public.class_subject cs on cs.subject_id = b.subject_id and cs.class_level_id = b.class_level_id and cs.campus_id = b.campus_id
    join public.academic_session sess on sess.id = cs.session_id and sess.is_current
   where b.id = p_id and b.tenant_id = app.auth_tenant_id()
   limit 1;
  if v_cs is null then
    raise exception 'QUESTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app.fn_can_edit_bank(v_cs) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.question_bank_item set is_active = coalesce(p_active, false) where id = p_id;
end;
$$;
revoke execute on function public.set_bank_question_active(uuid, boolean) from public, anon;
grant execute on function public.set_bank_question_active(uuid, boolean) to authenticated;
