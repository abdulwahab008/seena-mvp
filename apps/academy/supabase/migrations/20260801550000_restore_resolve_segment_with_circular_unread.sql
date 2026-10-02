-- 20260801470000 (FR-M13) redefined resolve_segment() from a divergent copy:
-- it referenced a non-existent student_guardian.receives_financial column and
-- replaced the FR-M06 hardship-waiver exclusion and attendance lock cutoff
-- with different logic. Restore the FR-M06 definition (20260801400000) and
-- keep only the genuinely new FR-M13 circular_unread branch.
create or replace function public.resolve_segment(
  p_segment_id uuid,
  p_as_of date default current_date
)
returns table (
  student_id uuid,
  enrolment_id uuid,
  guardian_id uuid,
  student_name text,
  gr_number text,
  guardian_name text,
  guardian_phone text,
  dues_pkr numeric,
  attendance_status text,
  meta jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_segment record;
  v_min_dues_paisa bigint;
  v_exclude_hardship boolean;
  v_campus_cutoff time;
  v_cutoff_time time;
  v_enforce_cutoff boolean;
  v_check_time time := clock_timestamp()::time;
  v_circ_id uuid;
begin
  select id, tenant_id, campus_id, name, segment_type, definition
  into v_segment
  from public.message_segment
  where id = p_segment_id and is_active = true;

  if not found then
    raise exception 'Segment not found or inactive: %', p_segment_id using errcode = 'P0002';
  end if;

  -- ─── Segment Type: Fee Defaulters (AC 1) ──────────────────────────────────
  if v_segment.segment_type = 'defaulters' then
    v_min_dues_paisa := (coalesce((v_segment.definition->>'min_dues_pkr')::numeric, 5000) * 100)::bigint;
    v_exclude_hardship := coalesce((v_segment.definition->>'exclude_hardship')::boolean, true);

    return query
    select
      s.id as student_id,
      e.id as enrolment_id,
      g.id as guardian_id,
      s.name_en as student_name,
      s.gr_number as gr_number,
      coalesce(g.name_en, 'Parent of ' || s.name_en) as guardian_name,
      coalesce(g.phone_e164, g.alt_phone) as guardian_phone,
      round(o.outstanding_paisa / 100.0, 2) as dues_pkr,
      null::text as attendance_status,
      jsonb_build_object(
        'outstanding_paisa', o.outstanding_paisa,
        'min_dues_pkr', round(v_min_dues_paisa / 100.0, 2),
        'enrolment_roll_no', e.roll_no,
        'has_hardship_waiver', false
      ) as meta
    from public.v_student_outstanding o
    join public.enrolment e on e.id = o.enrolment_id
    join public.student s on s.id = o.student_id
    left join lateral (
      select sg.guardian_id
      from public.student_guardian sg
      where sg.student_id = s.id
      order by sg.is_primary desc, sg.receives_billing desc, sg.priority asc
      limit 1
    ) primary_sg on true
    left join public.guardian g on g.id = primary_sg.guardian_id
    where o.tenant_id = v_segment.tenant_id
      and (v_segment.campus_id is null or o.campus_id = v_segment.campus_id)
      and e.status = 'active'
      and s.status = 'active'
      and o.outstanding_paisa >= v_min_dues_paisa
      and (
        not v_exclude_hardship
        or not exists (
          select 1
          from public.concession_award ca
          left join public.concession_scheme cs on cs.id = ca.scheme_id
          where ca.enrolment_id = e.id
            and ca.status = 'approved'
            and (ca.effective_to is null or ca.effective_to >= p_as_of)
            and (ca.effective_from is null or ca.effective_from <= p_as_of)
            and (
              cs.category = 'hardship'
              or cs.code ilike '%hardship%'
              or cs.name_en ilike '%hardship%'
              or ca.rejection_reason ilike '%hardship%'
            )
        )
      )
      and coalesce(g.phone_e164, g.alt_phone) is not null;

  -- ─── Segment Type: Absent Today with Attendance Lock Cutoff (AC 2) ────────
  elsif v_segment.segment_type = 'absent_today' then
    select attendance_lock_cutoff into v_campus_cutoff
    from public.campus
    where id = v_segment.campus_id;

    v_cutoff_time := coalesce(
      (v_segment.definition->>'cutoff_time')::time,
      v_campus_cutoff,
      '11:00:00'::time
    );

    v_enforce_cutoff := coalesce((v_segment.definition->>'enforce_cutoff')::boolean, true);

    -- If cutoff is enforced and current time is prior to cutoff on today's date,
    -- guard against premature dispatches while teachers are still correcting registers.
    if v_enforce_cutoff and p_as_of = current_date and v_check_time < v_cutoff_time then
      -- Cutoff not reached yet: return empty to prevent sending unconfirmed absentee alerts
      return;
    end if;

    return query
    select
      s.id as student_id,
      e.id as enrolment_id,
      g.id as guardian_id,
      s.name_en as student_name,
      s.gr_number as gr_number,
      coalesce(g.name_en, 'Parent of ' || s.name_en) as guardian_name,
      coalesce(g.phone_e164, g.alt_phone) as guardian_phone,
      0::numeric as dues_pkr,
      ad.status::text as attendance_status,
      jsonb_build_object(
        'attendance_date', ad.attendance_date,
        'marked_at', ad.marked_at,
        'corrected', ad.corrected,
        'attendance_status', ad.status,
        'cutoff_time', v_cutoff_time
      ) as meta
    from public.attendance_day ad
    join public.enrolment e on e.id = ad.enrolment_id
    join public.student s on s.id = e.student_id
    left join lateral (
      select sg.guardian_id
      from public.student_guardian sg
      where sg.student_id = s.id
      order by sg.is_primary desc, sg.receives_academic desc, sg.priority asc
      limit 1
    ) primary_sg on true
    left join public.guardian g on g.id = primary_sg.guardian_id
    where ad.tenant_id = v_segment.tenant_id
      and (v_segment.campus_id is null or ad.campus_id = v_segment.campus_id)
      and ad.attendance_date = p_as_of
      and ad.status = 'absent'
      and e.status = 'active'
      and s.status = 'active'
      and coalesce(g.phone_e164, g.alt_phone) is not null;

  -- ─── Generic / Class Level Segment ────────────────────────────────────────
  -- ─── Segment Type: Circular Unread Export (FR-M13 AC 2) ───────────────────
  elsif v_segment.segment_type = 'custom_filter' and (v_segment.definition->>'filter_type') = 'circular_unread' then
    v_circ_id := (v_segment.definition->>'circular_id')::uuid;

    return query
    select distinct on (ug.guardian_id)
      s.id as student_id,
      e.id as enrolment_id,
      ug.guardian_id,
      s.name_en as student_name,
      s.gr_number as gr_number,
      ug.guardian_name,
      coalesce(ug.phone_e164, ug.alt_phone) as guardian_phone,
      0::numeric as dues_pkr,
      'unread'::text as attendance_status,
      jsonb_build_object('circular_id', v_circ_id, 'reason', 'unread_circular_follow_up') as meta
    from public.v_circular_unread_guardians ug
    join public.student_guardian sg on sg.guardian_id = ug.guardian_id and sg.to_date is null
    join public.student s on s.id = sg.student_id and s.status = 'active'
    join public.enrolment e on e.student_id = s.id and e.status = 'active'
    where ug.circular_id = v_circ_id
      and coalesce(ug.phone_e164, ug.alt_phone) is not null
    order by ug.guardian_id, sg.is_primary desc;

  -- ─── Generic / Class Level Segment ────────────────────────────────────────
  else
    return query
    select
      s.id as student_id,
      e.id as enrolment_id,
      g.id as guardian_id,
      s.name_en as student_name,
      s.gr_number as gr_number,
      coalesce(g.name_en, 'Parent of ' || s.name_en) as guardian_name,
      coalesce(g.phone_e164, g.alt_phone) as guardian_phone,
      0::numeric as dues_pkr,
      'enrolled'::text as attendance_status,
      jsonb_build_object('class_level_id', e.class_level_id, 'section_id', e.section_id) as meta
    from public.enrolment e
    join public.student s on s.id = e.student_id
    left join lateral (
      select sg.guardian_id
      from public.student_guardian sg
      where sg.student_id = s.id
      order by sg.is_primary desc, sg.priority asc
      limit 1
    ) primary_sg on true
    left join public.guardian g on g.id = primary_sg.guardian_id
    where e.tenant_id = v_segment.tenant_id
      and (v_segment.campus_id is null or e.campus_id = v_segment.campus_id)
      and e.status = 'active'
      and s.status = 'active'
      and (
        v_segment.definition->>'class_level_id' is null
        or e.class_level_id = (v_segment.definition->>'class_level_id')::uuid
      )
      and (
        v_segment.definition->>'section_id' is null
        or e.section_id = (v_segment.definition->>'section_id')::uuid
      )
      and coalesce(g.phone_e164, g.alt_phone) is not null;
  end if;
end;
$$;
