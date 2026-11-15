-- Withdrawing a student: the status matrix had no way into 'left', and nothing closed the class
-- enrolment, so the withdrawal register could never fill. One call does both, the way a TC does
-- for a transfer: the student record goes to 'left' with a reason on the history, and the active
-- enrolment gets status 'left' and its leaving date (hostel and transport end through their
-- existing triggers on enrolment status).
insert into public.student_status_transition (from_status, to_status, requires_role, requires_document, requires_reason_code)
values ('active', 'left', 'principal', false, null),
       ('on_leave', 'left', 'principal', false, null)
on conflict (from_status, to_status) do nothing;

create or replace function public.withdraw_student(
  p_student_id   uuid,
  p_leaving_date date,
  p_reason_code  public.status_reason_code,
  p_reason_note  text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student public.student%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_student from public.student
   where id = p_student_id and tenant_id = app.auth_tenant_id() and deleted_at is null;
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not (v_student.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_student.status not in ('active', 'on_leave') then
    raise exception 'STUDENT_NOT_ACTIVE' using errcode = '23514', detail = format('status=%s', v_student.status);
  end if;
  if p_reason_code not in ('relocation', 'transfer_out', 'fee_default', 'disciplinary', 'medical', 'long_absence', 'other') then
    raise exception 'REASON_INVALID' using errcode = '22023';
  end if;
  if p_leaving_date is null or p_leaving_date > app.fn_karachi_today()
     or exists (select 1 from public.enrolment e where e.student_id = p_student_id and e.status = 'active'
                   and e.deleted_at is null and e.joined_on > p_leaving_date) then
    raise exception 'LEAVING_DATE_INVALID' using errcode = '22023';
  end if;

  perform public.fn_change_student_status(p_student_id, 'left', p_reason_code, p_leaving_date, nullif(btrim(p_reason_note), ''));

  update public.enrolment
     set status = 'left', left_on = p_leaving_date
   where student_id = p_student_id and status = 'active' and deleted_at is null;
end;
$$;

revoke execute on function public.withdraw_student(uuid, date, public.status_reason_code, text) from public, anon;
grant execute on function public.withdraw_student(uuid, date, public.status_reason_code, text) to authenticated;
