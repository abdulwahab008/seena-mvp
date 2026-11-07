-- Timetable: fill a section's empty periods automatically, and copy one
-- section's timetable to another.
--
-- Both only ever write through upsert_timetable_slot, so every existing rule
-- applies: subject offered to the class, teacher not double-booked (across
-- campuses too), room not double-booked, draft versions only. A cell that a
-- rule refuses is skipped and the next one is tried; nothing already placed
-- is overwritten.
--
-- Auto-fill is greedy: subjects with the most weekly periods first, each
-- period on the day that has the fewest of that subject so far, with the
-- section's primary teacher for the subject and its home room. The periods
-- come from the campus's default bell template for the section's shift
-- (teaching periods only) and the campus's working days.

create or replace function app.fn_try_slot(p_version_id uuid, p_section_id uuid, p_weekday smallint, p_period_no smallint, p_subject_id uuid, p_staff_id uuid, p_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.upsert_timetable_slot(p_version_id, p_section_id, p_weekday, p_period_no, p_subject_id, p_staff_id, p_room_id);
  return true;
exception
  when others then
    if sqlstate = '42501' then
      raise;
    end if;
    return false;
end;
$$;
revoke execute on function app.fn_try_slot(uuid, uuid, smallint, smallint, uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public.autofill_section_timetable(p_version_id uuid, p_section_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_version public.timetable_version%rowtype;
  v_section public.class_section%rowtype;
  v_days    smallint[];
  v_periods smallint[];
  v_placed  int := 0;
  v_short   jsonb := '[]'::jsonb;
  s record;
  c record;
  v_need int;
  v_have int;
  v_ok boolean;
begin
  select * into v_version from public.timetable_version where id = p_version_id and tenant_id = app.auth_tenant_id();
  select * into v_section from public.class_section where id = p_section_id and tenant_id = app.auth_tenant_id();
  if v_version.id is null or v_section.id is null then
    raise exception 'NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_version.status <> 'DRAFT' then
    raise exception 'VERSION_IMMUTABLE' using errcode = '55000';
  end if;

  select working_days into v_days from public.campus where id = v_version.campus_id;
  select array_agg(distinct bp.period_no order by bp.period_no) into v_periods
    from public.bell_template bt
    join public.bell_period bp on bp.bell_template_id = bt.id and bp.kind = 'TEACHING'
   where bt.campus_id = v_version.campus_id and bt.shift = v_section.shift and bt.is_default;
  if v_periods is null then
    raise exception 'NO_BELL_TEMPLATE' using errcode = '55000', hint = 'Set a default bell template for this campus and shift first.';
  end if;

  for s in
    select cs.subject_id, sub.name_en, cs.weekly_periods
      from public.class_subject cs
      join public.subject sub on sub.id = cs.subject_id
     where cs.class_level_id = v_section.class_level_id and cs.session_id = v_version.session_id
       and (cs.stream_id is null or cs.stream_id = v_section.stream_id)
       and cs.weekly_periods > 0 and cs.elective_bucket is null
     order by cs.weekly_periods desc, sub.name_en
  loop
    select count(*) into v_have from public.timetable_slot
     where timetable_version_id = p_version_id and section_id = p_section_id and subject_id = s.subject_id;
    v_need := s.weekly_periods - v_have;
    while v_need > 0 loop
      v_ok := false;
      -- The emptiest day for this subject first, then the earliest free period.
      for c in
        select d.day, p.period_no
          from unnest(v_days) as d(day)
          cross join unnest(v_periods) as p(period_no)
         where not exists (select 1 from public.timetable_slot t
                            where t.timetable_version_id = p_version_id and t.section_id = p_section_id
                              and t.weekday = d.day and t.period_no = p.period_no)
         order by (select count(*) from public.timetable_slot t
                    where t.timetable_version_id = p_version_id and t.section_id = p_section_id
                      and t.weekday = d.day and t.subject_id = s.subject_id),
                  p.period_no, d.day
      loop
        if app.fn_try_slot(p_version_id, p_section_id, c.day::smallint, c.period_no::smallint, s.subject_id,
                           (select staff_id from public.prefill_slot_defaults(p_section_id, s.subject_id)), v_section.home_room_id) then
          v_ok := true;
          exit;
        end if;
      end loop;
      exit when not v_ok;
      v_placed := v_placed + 1;
      v_need := v_need - 1;
    end loop;
    if v_need > 0 then
      v_short := v_short || jsonb_build_object('subject', s.name_en, 'missing', v_need);
    end if;
  end loop;
  return jsonb_build_object('placed', v_placed, 'unplaced', v_short);
end;
$$;
revoke execute on function public.autofill_section_timetable(uuid, uuid) from public, anon;
grant execute on function public.autofill_section_timetable(uuid, uuid) to authenticated;

-- Copies the subject pattern of one section onto another section's empty
-- cells, with the target section's own teachers and home room.
create or replace function public.copy_section_timetable(p_version_id uuid, p_from_section_id uuid, p_to_section_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room   uuid;
  v_copied int := 0;
  v_skip   int := 0;
  r record;
begin
  if p_from_section_id = p_to_section_id then
    raise exception 'SAME_SECTION' using errcode = '22023';
  end if;
  select home_room_id into v_room from public.class_section where id = p_to_section_id and tenant_id = app.auth_tenant_id();
  for r in
    select t.weekday, t.period_no, t.subject_id from public.timetable_slot t
     where t.timetable_version_id = p_version_id and t.section_id = p_from_section_id and t.tenant_id = app.auth_tenant_id()
       and not exists (select 1 from public.timetable_slot x
                        where x.timetable_version_id = p_version_id and x.section_id = p_to_section_id
                          and x.weekday = t.weekday and x.period_no = t.period_no)
     order by t.weekday, t.period_no
  loop
    if app.fn_try_slot(p_version_id, p_to_section_id, r.weekday, r.period_no, r.subject_id,
                       (select staff_id from public.prefill_slot_defaults(p_to_section_id, r.subject_id)), v_room) then
      v_copied := v_copied + 1;
    else
      v_skip := v_skip + 1;
    end if;
  end loop;
  return jsonb_build_object('copied', v_copied, 'skipped', v_skip);
end;
$$;
revoke execute on function public.copy_section_timetable(uuid, uuid, uuid) from public, anon;
grant execute on function public.copy_section_timetable(uuid, uuid, uuid) to authenticated;
