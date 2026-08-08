-- FR-G13: unmarked register escalation to Principal.
--
--   * "Partially marked" is the real failure mode this FR's own Notes
--     call out — reusing FR-G12's section_register_submitted() boolean
--     would collapse "0 of 40 marked" and "12 of 40 marked" into the
--     same flag, losing exactly the distinction AC4 asks for. So this
--     migration counts enrolled vs marked directly instead of reusing
--     that helper, even though both ultimately key off the same
--     attendance_day/enrolment shape.
--   * AC3 (a section already flagged for a date must never reappear,
--     even checked again days later) is satisfied by attendance_gap_log's
--     own UNIQUE(section_id, attendance_date) — run_unmarked_attendance_
--     check() excludes anything already logged for that exact date
--     before building this run's notification content, so a re-run for
--     an old date returns an empty "sections" list once every gap from
--     that date has already been logged once.
--   * No pg_cron locally, same as every other System-actor function this
--     session has built (FR-B05, FR-D12, FR-G09, FR-G12): a real, tested,
--     service_role-grantable function a daily 11:00 PKT cron would call,
--     not actually scheduled. "The Principal receives one notification"
--     (AC1) is this function's own single jsonb return value, listing
--     every gap section found in that one call — there's no separate
--     per-recipient fan-out table the way FR-G12's SMS notifications
--     needed one, since a digest has exactly one intended reader.

create table public.attendance_gap_log (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  section_id      uuid not null references public.class_section(id) on delete cascade,
  attendance_date date not null,
  enrolled_count  int not null,
  marked_count    int not null,
  notified_at     timestamptz not null default clock_timestamp(),
  constraint uq_attendance_gap_log unique (section_id, attendance_date)
);

create index idx_att_gap_log_campus_date on public.attendance_gap_log (campus_id, attendance_date);

create trigger attendance_gap_log_audit after insert or update or delete on public.attendance_gap_log
  for each row execute function app.tg_audit_row();

alter table public.attendance_gap_log enable row level security;

create policy attendance_gap_log_read on public.attendance_gap_log
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- Every active section whose attendance_day row count for p_date falls
-- short of its own actually-active-on-that-date enrolment count —
-- enrolled_count/marked_count are both surfaced raw so the caller (or a
-- test) can tell "unmarked" (marked_count = 0) apart from "partially
-- marked" (0 < marked_count < enrolled_count) without re-deriving it.
create or replace function public.check_unmarked_attendance(p_campus_id uuid, p_date date default current_date)
returns table (
  section_id         uuid,
  section_label       text,
  class_teacher_name text,
  enrolled_count      int,
  marked_count        int
)
language sql
stable
security definer
set search_path = ''
as $$
  select t.section_id, t.section_label, t.class_teacher_name, t.enrolled_count, t.marked_count
    from (
      select
        cs.id as section_id,
        cl.name_en || ' · ' || cs.name as section_label,
        coalesce(au.full_name, 'Unassigned') as class_teacher_name,
        (
          select count(*)::int from public.enrolment e
            join public.student s on s.id = e.student_id
           where e.section_id = cs.id
             and e.joined_on <= p_date and (e.left_on is null or e.left_on >= p_date)
             and s.status = 'active'
        ) as enrolled_count,
        (
          select count(*)::int from public.attendance_day ad
           where ad.section_id = cs.id and ad.attendance_date = p_date
        ) as marked_count
        from public.class_section cs
        join public.class_level cl on cl.id = cs.class_level_id
        left join public.section_class_teacher sct on sct.section_id = cs.id and sct.validity @> p_date
        left join public.app_user au on au.user_id = sct.staff_id
       where cs.campus_id = p_campus_id
         and cs.is_active
         and (app.auth_tenant_id() is null or cs.tenant_id = app.auth_tenant_id())
         and (app.auth_tenant_id() is null or app.auth_role() in ('super_admin', 'owner') or cs.campus_id = any(app.auth_campus_ids()))
    ) t
   where t.marked_count < t.enrolled_count;
$$;

revoke execute on function public.check_unmarked_attendance(uuid, date) from public, anon;
grant execute on function public.check_unmarked_attendance(uuid, date) to authenticated, service_role;

create or replace function public.run_unmarked_attendance_check(p_campus_id uuid, p_date date default current_date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_holiday   text;
  v_row       record;
  v_sections  jsonb := '[]'::jsonb;
begin
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id into v_tenant_id from public.campus where id = p_campus_id;
  if v_tenant_id is null or (app.auth_tenant_id() is not null and v_tenant_id <> app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- AC2: a declared holiday skips the check entirely — no rows logged,
  -- no notification content produced.
  v_holiday := public.resolve_attendance_holiday(p_campus_id, p_date);
  if v_holiday is not null then
    return jsonb_build_object('skipped', true, 'reason', v_holiday, 'sections', '[]'::jsonb);
  end if;

  for v_row in
    select u.* from public.check_unmarked_attendance(p_campus_id, p_date) u
     where not exists (
       select 1 from public.attendance_gap_log g
        where g.section_id = u.section_id and g.attendance_date = p_date
     )
  loop
    insert into public.attendance_gap_log (tenant_id, campus_id, section_id, attendance_date, enrolled_count, marked_count)
    values (v_tenant_id, p_campus_id, v_row.section_id, p_date, v_row.enrolled_count, v_row.marked_count)
    on conflict (section_id, attendance_date) do nothing;

    v_sections := v_sections || jsonb_build_array(jsonb_build_object(
      'section_id', v_row.section_id,
      'section_label', v_row.section_label,
      'class_teacher_name', v_row.class_teacher_name,
      'enrolled_count', v_row.enrolled_count,
      'marked_count', v_row.marked_count,
      'status', case when v_row.marked_count = 0 then 'unmarked' else format('partially marked (%s/%s)', v_row.marked_count, v_row.enrolled_count) end
    ));
  end loop;

  return jsonb_build_object('skipped', false, 'sections', v_sections);
end;
$$;

revoke execute on function public.run_unmarked_attendance_check(uuid, date) from public, anon;
grant execute on function public.run_unmarked_attendance_check(uuid, date) to authenticated, service_role;
