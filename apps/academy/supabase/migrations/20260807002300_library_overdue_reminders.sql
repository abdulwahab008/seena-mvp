-- Library overdue reminders: one SMS per overdue book borrowed by a student,
-- to the guardian who receives academic notices. Never twice for the same
-- loan on the same day. Staff borrowers are reminded in person.

create or replace function public.queue_library_overdue_messages(p_campus_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_queued   int := 0;
  v_no_phone int := 0;
  r record;
  v_msg uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'librarian')
     or (app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  for r in
    select l.id, l.due_on, s.name_en, t.title,
           (select g.phone_e164 from public.student_guardian sg join public.guardian g on g.id = sg.guardian_id
             where sg.student_id = s.id and sg.receives_academic and (sg.to_date is null or sg.to_date >= current_date) and g.phone_e164 is not null
             order by sg.is_primary desc, sg.priority limit 1) as phone
      from public.library_loan l
      join public.student s on s.id = l.borrower_id
      join public.library_copy c on c.id = l.copy_id
      join public.library_title t on t.id = c.title_id
     where l.tenant_id = app.auth_tenant_id() and l.campus_id = p_campus_id
       and l.borrower_role = 'student' and l.returned_at is null and l.due_on < current_date
  loop
    if r.phone is null then
      v_no_phone := v_no_phone + 1;
      continue;
    end if;
    insert into public.message (tenant_id, campus_id, recipient_type, recipient_phone, channel, subject, body, status, idempotency_key, metadata)
    values (app.auth_tenant_id(), p_campus_id, 'guardian', r.phone, 'sms', 'Library book overdue',
            format('Assalam o Alaikum. %s has not returned the library book "%s", which was due on %s. Please send it back to school.',
                   r.name_en, left(r.title, 60), to_char(r.due_on, 'DD Mon YYYY')),
            'queued', 'library-overdue:' || r.id || ':' || current_date,
            jsonb_build_object('template', 'library_overdue', 'loan_id', r.id))
    on conflict (tenant_id, idempotency_key) where idempotency_key is not null do nothing
    returning id into v_msg;
    if v_msg is not null then
      v_queued := v_queued + 1;
    end if;
  end loop;
  return jsonb_build_object('queued', v_queued, 'no_phone', v_no_phone);
end;
$$;
revoke execute on function public.queue_library_overdue_messages(uuid) from public, anon;
grant execute on function public.queue_library_overdue_messages(uuid) to authenticated;
