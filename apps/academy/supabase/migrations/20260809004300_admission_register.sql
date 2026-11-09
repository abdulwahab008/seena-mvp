-- The admission and withdrawal register: one line per student in GR order,
-- with the admission date and class taken from the student's first
-- enrolment, and the leaving date and reason from the status change that
-- took a student who is no longer studying out of the school. Read-only; it
-- is assembled from records that already exist.
--
-- p_session_id filters to students admitted in that session, p_class_level_id
-- to students admitted to that class. A student never enrolled has no
-- admission session or class and appears only when neither filter is set.

create or replace function public.admission_register(p_session_id uuid default null, p_class_level_id uuid default null)
returns table (
  student_id        uuid,
  gr_number         text,
  admitted_on       date,
  name_en           text,
  father_name_en    text,
  dob               date,
  class_admitted    text,
  session_name      text,
  status            text,
  withdrawn_on      date,
  withdrawal_reason text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'admissions_officer', 'receptionist') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
  select s.id, s.gr_number, coalesce(fe.joined_on, s.created_at::date), s.name_en, s.father_name_en, s.dob,
         cl.name_en, ss.name, s.status::text,
         case when s.status in ('left', 'expelled', 'transferred', 'struck_off', 'graduated', 'passed_out')
              then coalesce(h.effective_date, le.left_on) end,
         case when s.status in ('left', 'expelled', 'transferred', 'struck_off', 'graduated', 'passed_out')
              then coalesce(initcap(replace(h.reason_code::text, '_', ' ')) || coalesce(': ' || nullif(btrim(h.reason_note), ''), ''),
                            initcap(s.status::text)) end
    from public.student s
    left join lateral (
      select e.joined_on, e.session_id, e.class_level_id
        from public.enrolment e
       where e.student_id = s.id and e.deleted_at is null
       order by e.joined_on, e.created_at
       limit 1
    ) fe on true
    left join public.class_level cl on cl.id = fe.class_level_id
    left join public.academic_session ss on ss.id = fe.session_id
    left join lateral (
      select x.effective_date, x.reason_code, x.reason_note
        from public.student_status_history x
       where x.student_id = s.id and x.to_status = s.status
       order by x.effective_date desc, x.changed_at desc
       limit 1
    ) h on true
    left join lateral (
      select e.left_on
        from public.enrolment e
       where e.student_id = s.id and e.deleted_at is null and e.left_on is not null
       order by e.left_on desc
       limit 1
    ) le on true
   where s.tenant_id = app.auth_tenant_id()
     and s.deleted_at is null
     and (app.auth_role() in ('super_admin', 'owner') or s.campus_id = any (app.auth_campus_ids()))
     and (p_session_id is null or fe.session_id = p_session_id)
     and (p_class_level_id is null or fe.class_level_id = p_class_level_id)
   order by s.gr_number;
end;
$$;
revoke execute on function public.admission_register(uuid, uuid) from public, anon;
grant execute on function public.admission_register(uuid, uuid) to authenticated;
