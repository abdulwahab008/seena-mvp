-- Admit cards (roll number slips) for an exam term, per section.
--
-- Everything a slip shows already exists: the published datesheet gives each
-- paper's date and time, the seating plan (exam_hall_seating_plan.sql) gives
-- the student's hall and seat, and the fee ledger says whether they owe money.
-- A student with dues gets a slip marked as held rather than a usable one.
-- Stream-specific papers are only listed for students who were seated for
-- them, since enrolment does not carry the stream.

create or replace function public.admit_card_batch(p_exam_term_id uuid, p_section_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_term      record;
  v_section   record;
  v_sheet     uuid;
begin
  if v_tenant_id is null or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select id, name, campus_id into v_term from public.exam_term where id = p_exam_term_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  select cs.id, cs.name, cs.campus_id, cs.class_level_id, cl.name_en as class_name
    into v_section
    from public.class_section cs join public.class_level cl on cl.id = cs.class_level_id
   where cs.id = p_section_id and cs.campus_id = v_term.campus_id;
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_section.campus_id);

  select id into v_sheet from public.datesheet where exam_term_id = p_exam_term_id and campus_id = v_term.campus_id and status = 'published';
  if v_sheet is null then
    raise exception 'DATESHEET_NOT_PUBLISHED' using errcode = '55000', hint = 'Publish the datesheet for this term first.';
  end if;

  return jsonb_build_object(
    'term', v_term.name,
    'class_name', trim(v_section.class_name || ' ' || v_section.name),
    'students', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', st.name_en,
               'father_name', st.father_name_en,
               'gr_number', st.gr_number,
               'balance_paisa', app.fn_enrolment_ledger_balance(e.id),
               'papers', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'subject', sub.name_en,
                          'start_at', sl.start_at,
                          'end_at', sl.end_at,
                          'hall', h.name,
                          'seat', case when sa.id is not null then 'R' || sa.row_no || '-S' || sa.seat_no end)
                        order by sl.start_at)
                   from public.datesheet_slot sl
                   join public.exam_subject es on es.id = sl.exam_subject_id
                   join public.class_subject csub on csub.id = es.class_subject_id
                   join public.subject sub on sub.id = csub.subject_id
                   left join public.exam_seat_allocation sa on sa.slot_id = sl.id and sa.enrolment_id = e.id
                   left join public.exam_hall h on h.id = coalesce(sa.hall_id, sl.hall_id)
                  where sl.datesheet_id = v_sheet
                    and csub.class_level_id = e.class_level_id
                    and (csub.stream_id is null or sa.id is not null)
               ), '[]'::jsonb))
             order by st.name_en)
        from public.enrolment e
        join public.student st on st.id = e.student_id
       where e.section_id = p_section_id and e.status = 'active'
    ), '[]'::jsonb)
  );
end;
$$;
revoke execute on function public.admit_card_batch(uuid, uuid) from public, anon;
grant execute on function public.admit_card_batch(uuid, uuid) to authenticated;
