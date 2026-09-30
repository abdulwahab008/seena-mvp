-- 20260801180000 joined timetable_slot.session_id, which does not exist (the
-- session lives on timetable_version). Any teacher not found in
-- section_subject_teacher therefore hit SQLSTATE 42703 instead of a clean
-- TEACHER_NOT_ASSIGNED_TO_SUBJECT refusal.
create or replace function public.upsert_exam_subject(
  p_exam_term_id     uuid,
  p_class_subject_id uuid,
  p_components       jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_term       record;
  v_cs         record;
  v_examinable boolean;
  v_count      int;
  v_distinct   int;
  v_bad        record;
  v_id         uuid;
begin
  if v_tenant_id is null
     or app.auth_role() not in (
       'super_admin', 'owner', 'principal', 'exam_controller',
       'subject_teacher', 'class_teacher', 'head_of_department'
     ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select id, campus_id, session_id into v_term
    from public.exam_term
   where id = p_exam_term_id and tenant_id = v_tenant_id;
  if v_term.id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner')
     and not (v_term.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select id, campus_id, session_id, subject_id into v_cs
    from public.class_subject
   where id = p_class_subject_id and tenant_id = v_tenant_id;
  if v_cs.id is null then
    raise exception 'CLASS_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- The curriculum row and the exam term have to be talking about the same
  -- campus and the same year, or the configuration means nothing.
  if v_cs.campus_id <> v_term.campus_id or v_cs.session_id <> v_term.session_id then
    raise exception 'CLASS_SUBJECT_TERM_MISMATCH' using errcode = '23514',
      detail = 'The class-subject and the exam term belong to different campuses or sessions.';
  end if;

  -- If caller is a subject teacher or class teacher, ensure they are allocated to teach this subject
  if app.auth_role() in ('subject_teacher', 'class_teacher') then
    if not exists (
      select 1 from public.section_subject_teacher sst
       where sst.tenant_id = v_tenant_id
         and sst.campus_id = v_term.campus_id
         and sst.session_id = v_term.session_id
         and sst.subject_id = v_cs.subject_id
         and sst.staff_id = (select auth.uid())
    ) and not exists (
      select 1 from public.timetable_slot sl
        join public.timetable_version tv on tv.id = sl.timetable_version_id
       where sl.tenant_id = v_tenant_id
         and sl.campus_id = v_term.campus_id
         and tv.session_id = v_term.session_id
         and sl.subject_id = v_cs.subject_id
         and sl.staff_id = (select auth.uid())
    ) then
      raise exception 'TEACHER_NOT_ASSIGNED_TO_SUBJECT' using errcode = '42501',
        detail = 'Teachers can only configure assessment components for subjects assigned to them.';
    end if;
  end if;

  select is_examinable into v_examinable from public.subject where id = v_cs.subject_id;
  if not v_examinable then
    raise exception 'SUBJECT_NOT_EXAMINABLE' using errcode = '23514';
  end if;

  -- Once results ride on this denominator it stops being setup.
  if app.fn_exam_term_weight_frozen(p_exam_term_id) then
    raise exception 'exam setup is locked by approved marks — raise a result-recompute request'
      using errcode = '42501';
  end if;

  if p_components is null or jsonb_typeof(p_components) <> 'array' then
    raise exception 'COMPONENTS_REQUIRED' using errcode = '23514';
  end if;

  select count(*), count(distinct (c->>'component'))
    into v_count, v_distinct
    from jsonb_array_elements(p_components) as c;

  if v_count < 1 then
    raise exception 'COMPONENTS_REQUIRED' using errcode = '23514',
      detail = 'A subject needs at least one component before marks can be entered against it.';
  end if;
  if v_distinct <> v_count then
    raise exception 'COMPONENT_DUPLICATED' using errcode = '23514';
  end if;

  -- AC2, in the acceptance criteria's own words, ahead of chk_pass_le_max.
  select (c->>'component') as component,
         (c->>'max_marks')::int as max_marks,
         (c->>'pass_marks')::int as pass_marks
    into v_bad
    from jsonb_array_elements(p_components) as c
   where (c->>'pass_marks')::int > (c->>'max_marks')::int
   limit 1;
  if found then
    raise exception 'pass marks cannot exceed maximum marks'
      using errcode = '23514',
            detail = format('%s: pass %s of a maximum of %s',
                            v_bad.component, v_bad.pass_marks, v_bad.max_marks);
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_components) as c
     where (c->>'max_marks')::int <= 0 or (c->>'pass_marks')::int < 0
  ) then
    raise exception 'MARKS_OUT_OF_RANGE' using errcode = '23514',
      detail = 'Maximum marks must be above zero and pass marks cannot be negative.';
  end if;

  insert into public.exam_subject (tenant_id, campus_id, exam_term_id, class_subject_id)
  values (v_tenant_id, v_term.campus_id, p_exam_term_id, p_class_subject_id)
  on conflict (exam_term_id, class_subject_id) do update set exam_term_id = excluded.exam_term_id
  returning id into v_id;

  delete from public.exam_subject_component where exam_subject_id = v_id;

  insert into public.exam_subject_component (
    tenant_id, exam_subject_id, component, max_marks, pass_marks, sequence
  )
  select v_tenant_id,
         v_id,
         (c.value->>'component')::public.mark_component_code,
         (c.value->>'max_marks')::int,
         (c.value->>'pass_marks')::int,
         c.ordinality::smallint
    from jsonb_array_elements(p_components) with ordinality as c(value, ordinality);

  return v_id;
end;
$$;


revoke execute on function public.upsert_exam_subject(uuid, uuid, jsonb) from public, anon;
grant execute on function public.upsert_exam_subject(uuid, uuid, jsonb) to authenticated;
