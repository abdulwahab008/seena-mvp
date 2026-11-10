-- Parents apply for a child's leave from the portal; the school office or the
-- class teacher approves or rejects it here.
create or replace function public.decide_student_leave(p_leave_id uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a public.student_leave_application%rowtype;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal', 'admissions_officer', 'receptionist', 'class_teacher', 'head_of_department') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_a from public.student_leave_application
   where id = p_leave_id and tenant_id = app.auth_tenant_id()
     and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids()))
   for update;
  if not found then
    raise exception 'LEAVE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_a.status <> 'pending' then
    raise exception 'LEAVE_NOT_PENDING' using errcode = '55000';
  end if;
  if p_note is not null and char_length(p_note) > 500 then
    raise exception 'NOTE_TOO_LONG' using errcode = '22001';
  end if;
  update public.student_leave_application
     set status = case when p_approve then 'approved' else 'rejected' end::public.student_leave_status,
         decided_by = auth.uid(), decided_at = now(), decision_note = nullif(btrim(p_note), '')
   where id = p_leave_id;
end;
$$;
revoke execute on function public.decide_student_leave(uuid, boolean, text) from public, anon;
grant execute on function public.decide_student_leave(uuid, boolean, text) to authenticated;
