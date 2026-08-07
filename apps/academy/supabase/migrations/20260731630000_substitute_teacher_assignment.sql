-- FR-D13: substitute teacher assignment for absences.
--
-- Design notes:
--   * No timetable_version resolution. This module has no publish workflow
--     yet (bell_template.sql and timetable_draft_slot_assignment.sql both
--     defer it explicitly), so there is no single "the live timetable"
--     version per campus — every non-cancelled timetable_slot the absent
--     teacher owns, on the matching weekday, is treated as their schedule
--     for that date. Consolidating parallel DRAFT versions into one active
--     schedule is that future publish FR's problem, not this one's.
--   * A substitution is a date-scoped row in its own table, never a write
--     to timetable_slot — the FR's own Notes calls editing the master row
--     "the single most common data-loss defect in school ERPs". Every
--     function here only ever inserts/updates timetable_substitution.
--   * create_substitution() re-validates the chosen substitute is free at
--     write time (SUBSTITUTE_CLASH), reusing F05's v_slot_clock_time
--     overlap check plus a same-day cross-substitution check — the same
--     "don't just trust client-side filtering for a hard invariant"
--     discipline already applied to TEACHER_CLASH and TEACH_SCOPE_VIOLATION.
--     Serialized per (substitute, date) with an advisory lock, matching
--     upsert_timetable_slot's own per-teacher lock.
--   * cancel_leave_application() is a small enabling piece, not a full
--     leave-lifecycle FR: it only flips an APPROVED application to
--     'cancelled' and reverses its ledger consumption. It deliberately
--     does NOT revert the staff_attendance rows fn_decide_leave_application
--     already wrote (retroactively fixing attendance is a future FR's
--     job) — the one thing AC4 actually needs is that any substitutions
--     already built against the cancelled dates surface for review
--     instead of vanishing, which trg_flag_substitution_on_leave_cancel
--     handles regardless of attendance history.
--   * trg_validate_substitution_teacher, named in FR-D03's own Supabase
--     Objects spec as a trigger on this table, is not built as a BEFORE
--     trigger: create_substitution() is the only write path (no RLS
--     insert/update policy for `authenticated`), so a trigger would
--     duplicate a check with no additional coverage — same reasoning as
--     every other function-gated write this module uses.

create type public.substitution_reason as enum ('leave', 'official_duty', 'suspension', 'other');
create type public.substitution_status as enum ('active', 'review');

create table public.timetable_substitution (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  campus_id           uuid not null references public.campus(id) on delete cascade,
  slot_id             uuid not null references public.timetable_slot(id) on delete cascade,
  sub_date            date not null,
  absent_staff_id     uuid not null references public.app_user(user_id),
  substitute_staff_id uuid not null references public.app_user(user_id),
  reason              public.substitution_reason not null,
  status              public.substitution_status not null default 'active',
  created_by          uuid references public.app_user(user_id),
  created_at          timestamptz not null default now(),
  unique (slot_id, sub_date)
);

create index idx_substitution_campus_date on public.timetable_substitution (campus_id, sub_date);
create index idx_substitution_substitute_date on public.timetable_substitution (substitute_staff_id, sub_date);
create index idx_substitution_absent_date on public.timetable_substitution (absent_staff_id, sub_date);

create trigger substitution_audit after insert or update or delete on public.timetable_substitution
  for each row execute function app.tg_audit_row();

alter publication supabase_realtime add table public.timetable_substitution;

-- A slot's full substitution history: one row per (slot, a substitution it
-- has ever had), plus a single sub_date-is-null row for a slot that has
-- never been substituted for at all. Deliberately NOT scoped to "just
-- today" — a plain view has no date parameter, and a slot whose only
-- substitution is on some OTHER date would otherwise vanish from a
-- naive "sub_date = today OR sub_date IS NULL" filter (that row exists,
-- just for the wrong date, so neither side of the OR matches and the row
-- — and the slot — disappears). The substitutions screen's own "uncovered
-- periods today" query works around this the straightforward way: read
-- timetable_slot and timetable_substitution separately and merge in code,
-- rather than force that shape out of this view.
create or replace view public.v_daily_timetable with (security_invoker = true) as
select
  ts.id as slot_id, ts.tenant_id, ts.campus_id, ts.timetable_version_id, ts.section_id,
  ts.weekday, ts.period_no, ts.subject_id, ts.staff_id as regular_staff_id, ts.room_id,
  sub.id as substitution_id, sub.sub_date, sub.substitute_staff_id, sub.status as substitution_status, sub.reason as substitution_reason
from public.timetable_slot ts
left join public.timetable_substitution sub on sub.slot_id = ts.id;

-- AC: ranked candidate list per period — free (no overlapping regular slot
-- or active substitution elsewhere today) first, then subject-qualified
-- (can_teach), then the fairness term (fewest periods already covered
-- today) breaks ties so the same obliging teachers don't absorb every
-- substitution.
create or replace function public.suggest_substitutes(p_slot_id uuid, p_sub_date date)
returns table (
  staff_id uuid, full_name text, is_free boolean, can_teach_subject boolean, periods_covered_today int
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid := app.auth_tenant_id();
  v_slot           public.timetable_slot%rowtype;
  v_shift          public.section_shift;
  v_class_level_id uuid;
  v_stream_id      uuid;
  v_self_start     time;
  v_self_end       time;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_slot from public.timetable_slot where id = p_slot_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if extract(dow from p_sub_date)::smallint <> v_slot.weekday then
    raise exception 'SUB_DATE_WEEKDAY_MISMATCH' using errcode = '23514';
  end if;

  select tv.shift into v_shift from public.timetable_version tv where tv.id = v_slot.timetable_version_id;
  select cs.class_level_id, cs.stream_id into v_class_level_id, v_stream_id
    from public.class_section cs where cs.id = v_slot.section_id;

  select bp.start_time, bp.end_time into v_self_start, v_self_end
    from public.bell_period bp
   where bp.bell_template_id = public.resolve_bell_template_for_weekday(v_slot.campus_id, v_shift, v_slot.weekday)
     and bp.period_no = v_slot.period_no;

  return query
    select
      au.user_id,
      au.full_name,
      (
        v_self_start is null
        or (
          not exists (
            select 1 from public.v_slot_clock_time vct
             where vct.tenant_id = v_tenant_id and vct.staff_id = au.user_id and vct.weekday = v_slot.weekday
               and vct.slot_id <> v_slot.id
               and public.timerange(vct.start_time, vct.end_time) && public.timerange(v_self_start, v_self_end)
          )
          and not exists (
            select 1
              from public.timetable_substitution other_sub
              join public.v_slot_clock_time other_vct on other_vct.slot_id = other_sub.slot_id
             where other_sub.substitute_staff_id = au.user_id
               and other_sub.sub_date = p_sub_date
               and other_sub.status = 'active'
               and other_sub.slot_id <> p_slot_id
               and public.timerange(other_vct.start_time, other_vct.end_time) && public.timerange(v_self_start, v_self_end)
          )
        )
      ) as is_free,
      public.can_teach(au.user_id, v_slot.subject_id, v_class_level_id, v_stream_id) as can_teach_subject,
      (
        select count(*)::int from public.timetable_substitution ts2
         where ts2.substitute_staff_id = au.user_id and ts2.sub_date = p_sub_date and ts2.status = 'active'
      ) as periods_covered_today
    from public.app_user au
   where au.tenant_id = v_tenant_id
     and au.app_role in ('subject_teacher', 'class_teacher', 'head_of_department')
     and (v_slot.staff_id is null or au.user_id <> v_slot.staff_id)
    order by 3 desc, 4 desc, 5 asc, au.full_name asc;
end;
$$;

revoke execute on function public.suggest_substitutes(uuid, date) from public, anon;
grant execute on function public.suggest_substitutes(uuid, date) to authenticated;

-- AC: fillable in 2 taps (period, then candidate) and re-fillable the same
-- way — on_conflict re-targets the same (slot, date) cell rather than
-- accumulating duplicate rows, and reactivates a 'review'-flagged row.
create or replace function public.create_substitution(
  p_slot_id uuid, p_sub_date date, p_substitute_staff_id uuid, p_reason public.substitution_reason default 'other'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_slot       public.timetable_slot%rowtype;
  v_shift      public.section_shift;
  v_self_start time;
  v_self_end   time;
  v_clash      boolean;
  v_id         uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_slot from public.timetable_slot where id = p_slot_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_slot.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_slot.staff_id is null then
    raise exception 'SLOT_HAS_NO_TEACHER' using errcode = '23514';
  end if;
  if extract(dow from p_sub_date)::smallint <> v_slot.weekday then
    raise exception 'SUB_DATE_WEEKDAY_MISMATCH' using errcode = '23514';
  end if;
  if p_substitute_staff_id = v_slot.staff_id then
    raise exception 'SUBSTITUTE_IS_ABSENT_TEACHER' using errcode = '23514';
  end if;

  -- Same reasoning as upsert_timetable_slot's per-teacher lock: serializes
  -- two racing assignments of the same substitute so neither's clash check
  -- runs against a snapshot that doesn't yet see the other's insert.
  perform pg_advisory_xact_lock(hashtextextended('substitution:' || p_substitute_staff_id::text || p_sub_date::text, 0));

  select tv.shift into v_shift from public.timetable_version tv where tv.id = v_slot.timetable_version_id;

  select bp.start_time, bp.end_time into v_self_start, v_self_end
    from public.bell_period bp
   where bp.bell_template_id = public.resolve_bell_template_for_weekday(v_slot.campus_id, v_shift, v_slot.weekday)
     and bp.period_no = v_slot.period_no;

  if v_self_start is not null then
    select
      exists (
        select 1 from public.v_slot_clock_time vct
         where vct.tenant_id = v_tenant_id and vct.staff_id = p_substitute_staff_id and vct.weekday = v_slot.weekday
           and vct.slot_id <> v_slot.id
           and public.timerange(vct.start_time, vct.end_time) && public.timerange(v_self_start, v_self_end)
      )
      or exists (
        select 1
          from public.timetable_substitution other_sub
          join public.v_slot_clock_time other_vct on other_vct.slot_id = other_sub.slot_id
         where other_sub.substitute_staff_id = p_substitute_staff_id
           and other_sub.sub_date = p_sub_date
           and other_sub.status = 'active'
           and other_sub.slot_id <> p_slot_id
           and public.timerange(other_vct.start_time, other_vct.end_time) && public.timerange(v_self_start, v_self_end)
      )
      into v_clash;

    if v_clash then
      raise exception 'SUBSTITUTE_CLASH' using errcode = '23514';
    end if;
  end if;

  insert into public.timetable_substitution (
    tenant_id, campus_id, slot_id, sub_date, absent_staff_id, substitute_staff_id, reason, status, created_by
  )
  values (
    v_tenant_id, v_slot.campus_id, p_slot_id, p_sub_date, v_slot.staff_id, p_substitute_staff_id, p_reason, 'active', auth.uid()
  )
  on conflict (slot_id, sub_date) do update set
    substitute_staff_id = excluded.substitute_staff_id,
    reason = excluded.reason,
    status = 'active',
    created_by = excluded.created_by
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_substitution(uuid, date, uuid, public.substitution_reason) from public, anon;
grant execute on function public.create_substitution(uuid, date, uuid, public.substitution_reason) to authenticated;

-- AC: a leave cancellation must never silently delete a substitution built
-- against it — it surfaces on the review worklist instead.
create or replace function app.tg_flag_substitution_on_leave_cancel()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_staff_user_id uuid;
begin
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    select user_id into v_staff_user_id from public.staff where id = new.staff_id;
    if v_staff_user_id is not null then
      update public.timetable_substitution
         set status = 'review'
       where absent_staff_id = v_staff_user_id
         and sub_date between new.from_date and new.to_date
         and status = 'active';
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_flag_substitution_on_leave_cancel after update on public.leave_application
  for each row execute function app.tg_flag_substitution_on_leave_cancel();

-- Narrow enabling piece: FR-D11/D12 never built a way to cancel an already-
-- approved application (only apply/decide). AC4 needs exactly this much of
-- it — see the migration header for what's deliberately left out.
create or replace function public.cancel_leave_application(p_application_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app public.leave_application%rowtype;
begin
  select * into v_app from public.leave_application where id = p_application_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'APPLICATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager')
     and not exists (select 1 from public.staff where id = v_app.staff_id and user_id = auth.uid()) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_app.status <> 'approved' then
    raise exception 'APPLICATION_NOT_APPROVED' using errcode = '55000';
  end if;

  update public.leave_application set status = 'cancelled' where id = p_application_id;

  insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
  values (v_app.tenant_id, v_app.staff_id, v_app.leave_type_id, 'hold_release', v_app.working_days, p_application_id, auth.uid());
end;
$$;

revoke execute on function public.cancel_leave_application(uuid) from public, anon;
grant execute on function public.cancel_leave_application(uuid) to authenticated;

alter table public.timetable_substitution enable row level security;

-- Combines the spec's substitution_campus_scope and substitution_self_read
-- into one policy, the same "campus-tier OR the affected person themselves"
-- shape staff_attendance_campus_scope already uses.
create policy substitution_read_scope on public.timetable_substitution
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())
      or absent_staff_id = auth.uid() or substitute_staff_id = auth.uid()
    )
  );
