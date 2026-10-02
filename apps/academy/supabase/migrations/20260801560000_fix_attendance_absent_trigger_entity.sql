-- 20260801480000 (FR-M14) rewrote trg_fn_attendance_absent() to key fires on
-- attendance_day.id. The FR-M08 consumer (comm_dispatch for 'attendance_absent')
-- reads fire.entity_id as an enrolment id, so every absence alert resolved no
-- student and fell through to the placeholder recipient. Restore the enrolment
-- key and the FR-M08 metadata; keep the FR-M14 holiday suppression.
create or replace function public.trg_fn_attendance_absent()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule record;
begin
  if NEW.status = 'absent' then
    if not public.is_working_day(NEW.campus_id, NEW.attendance_date) then
      return NEW;
    end if;

    for v_rule in
      select id, tenant_id
      from public.comm_trigger_rule
      where tenant_id = NEW.tenant_id
        and is_enabled = true
        and event_type = 'attendance_absent'
        and (campus_id is null or campus_id = NEW.campus_id)
    loop
      insert into public.comm_trigger_fire (tenant_id, rule_id, entity_id, fire_key, status, metadata)
      values (
        NEW.tenant_id,
        v_rule.id,
        NEW.enrolment_id,
        NEW.attendance_date::text,
        'pending',
        jsonb_build_object(
          'attendance_date', NEW.attendance_date,
          'campus_id', NEW.campus_id,
          'session_id', NEW.session_id,
          'section_id', NEW.section_id
        )
      )
      on conflict (rule_id, entity_id, fire_key) do nothing;
    end loop;
  end if;

  return NEW;
end;
$$;
