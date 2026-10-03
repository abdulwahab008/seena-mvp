-- A seat was counted twice once a student was enrolled from an offer.
--
-- fn_available_seats() subtracts the active enrolments AND every accepted offer. An accepted offer
-- keeps the status 'accepted' after fn_enrol_from_offer() turns it into an enrolment (it only marks
-- the application 'enrolled'), so each admitted student used up two seats: a class of capacity 1
-- with one enrolled student reported "-1 seat(s) left", and a class of 30 looked full at 15.
--
-- An accepted offer holds a seat only until it becomes an enrolment, so offers whose application is
-- already enrolled no longer count. Everything else is unchanged.
create or replace function app.fn_available_seats(p_class_level_id uuid, p_session_id uuid, p_campus_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(cs.capacity), 0)::int - (
    select count(*)::int from public.enrolment e
     where e.class_level_id = p_class_level_id and e.session_id = p_session_id
       and e.campus_id = p_campus_id and e.status = 'active' and e.deleted_at is null
  ) - (
    select count(*)::int
      from public.admission_offer o
      join public.admission_application a on a.id = o.application_id
     where a.class_applied_id = p_class_level_id
       and a.session_id = p_session_id
       and a.campus_id = p_campus_id
       and a.status <> 'enrolled'
       and ((o.status = 'issued' and o.expires_at > now()) or o.status = 'accepted')
  ) - (
    select count(*)::int from public.admission_waitlist w
     where w.class_level_id = p_class_level_id and w.session_id = p_session_id and w.campus_id = p_campus_id
       and w.status = 'offer_pending'
  )
  from public.class_section cs
 where cs.class_level_id = p_class_level_id and cs.session_id = p_session_id and cs.campus_id = p_campus_id
   and cs.is_active;
$$;
