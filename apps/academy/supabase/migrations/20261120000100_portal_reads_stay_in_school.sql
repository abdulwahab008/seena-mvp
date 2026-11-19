-- A circular or calendar event sent to "all campuses" has no campus_id, and the parent read
-- checks only asked whether the reader had a child anywhere. A parent in one school could
-- read every other school's school-wide circulars, and any signed-in user could read every
-- other school's school-wide calendar events. Both now require the child to be in the same
-- school as the circular or event.

create or replace function public.guardian_can_read_circular(p_circular_id uuid, p_campus_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    where not exists (select 1 from public.circular_audience ca where ca.circular_id = p_circular_id)
      and exists (
        select 1 from public.student s
        where s.id = any(app.auth_guardian_student_ids())
          and s.tenant_id = (select c.tenant_id from public.circular c where c.id = p_circular_id)
          and (p_campus_id is null or s.campus_id = p_campus_id)
      )

    union all

    select 1
    from public.circular_audience ca
    join public.student s on s.id = any(app.auth_guardian_student_ids())
    where ca.circular_id = p_circular_id
      and s.tenant_id = (select c.tenant_id from public.circular c where c.id = p_circular_id)
      and (p_campus_id is null or s.campus_id = p_campus_id)
      and public.student_matches_segment(s.id, ca.segment_id)
  );
$$;

drop policy campus_event_portal_read on public.campus_event;
create policy campus_event_portal_read on public.campus_event
  for select
  to authenticated
  using (
    not is_cancelled
    and exists (
      select 1 from public.student s
      where s.id = any((select app.auth_guardian_student_ids())::uuid[])
        and s.tenant_id = campus_event.tenant_id
        and (campus_event.campus_id is null or s.campus_id = campus_event.campus_id)
    )
  );
