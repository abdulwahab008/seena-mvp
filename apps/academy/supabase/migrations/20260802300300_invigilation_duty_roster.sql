-- FR-I10: invigilation duty roster.
--
-- Invigilators are assigned per datesheet slot, automatically and fairly:
--
--   * nobody invigilates a paper of a subject they teach to that class;
--   * nobody exceeds the campus cap on duties for the term (exam_settings
--     .invigilation_max_duties, default 5);
--   * nobody is placed on two papers whose windows overlap;
--   * staff on approved leave that day, or on the manual exclusion list, are out.
--
-- Fairness is the product: the pool member with the FEWEST duties so far is
-- picked first, so the spread between the busiest and the least busy member is
-- as small as the constraints allow (1 when nothing forces otherwise), and the
-- most constrained slots are filled first so a scarce slot is not starved by an
-- easy one. A slot that still cannot be filled is REPORTED with the reason
-- breakdown; nothing is silently under-assigned.
--
-- HR leave data (Phase 5) is read from leave_application when it exists. Until
-- schools record leave there, the manual exclusion list (invigilation_constraint)
-- does the same job, so the roster never refuses to run for lack of HR data.
-- When approved leave lands on a date that already carries a duty, the duty is
-- flagged and a substitution task is raised.
--
-- Roster notification: the in-app notice is real (user_notification). The
-- SMS / WhatsApp fan-out (Phase 4) is the same adapter seam as every other
-- outbound channel and is not wired here.

create table public.invigilation_duty (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant(id) on delete cascade,
  campus_id          uuid not null references public.campus(id) on delete cascade,
  exam_term_id       uuid not null references public.exam_term(id) on delete cascade,
  datesheet_slot_id  uuid not null references public.datesheet_slot(id) on delete cascade,
  staff_id           uuid not null references public.app_user(user_id) on delete cascade,
  status             text not null default 'assigned' check (status in ('assigned', 'substitution_needed', 'cancelled')),
  assigned_by        uuid references auth.users(id),
  assigned_at        timestamptz not null default now(),
  notified_at        timestamptz
);
create unique index uq_duty_slot_staff on public.invigilation_duty (datesheet_slot_id, staff_id) where status <> 'cancelled';
create index idx_duty_staff_term on public.invigilation_duty (staff_id, exam_term_id);
create index idx_duty_slot on public.invigilation_duty (datesheet_slot_id);
create index idx_duty_campus_term on public.invigilation_duty (campus_id, exam_term_id);
create index idx_duty_tenant on public.invigilation_duty (tenant_id);

-- The manual exclusion list: a staff member unavailable on a date (all papers
-- that day) or for one specific slot.
create table public.invigilation_constraint (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  exam_term_id  uuid not null references public.exam_term(id) on delete cascade,
  staff_id      uuid not null references public.app_user(user_id) on delete cascade,
  exclude_date  date,
  slot_id       uuid references public.datesheet_slot(id) on delete cascade,
  reason        text not null check (char_length(btrim(reason)) between 1 and 300),
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  constraint chk_invigilation_constraint_target check ((exclude_date is not null) <> (slot_id is not null))
);
create index idx_invigilation_constraint_staff on public.invigilation_constraint (staff_id, exam_term_id);
create index idx_invigilation_constraint_scope on public.invigilation_constraint (tenant_id, campus_id);
create index idx_invigilation_constraint_term on public.invigilation_constraint (exam_term_id);
create index idx_invigilation_constraint_slot on public.invigilation_constraint (slot_id);

create table public.invigilation_substitution_task (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  duty_id              uuid not null references public.invigilation_duty(id) on delete cascade,
  reason               text not null check (reason in ('staff_on_leave', 'excluded')),
  status               text not null default 'open' check (status in ('open', 'resolved')),
  replacement_staff_id uuid references public.app_user(user_id),
  created_at           timestamptz not null default now(),
  resolved_at          timestamptz
);
create unique index uq_substitution_task_open on public.invigilation_substitution_task (duty_id) where status = 'open';
create index idx_substitution_task_scope on public.invigilation_substitution_task (tenant_id, campus_id, status);
create index idx_substitution_task_duty on public.invigilation_substitution_task (duty_id);

create trigger invigilation_duty_audit after insert or update or delete on public.invigilation_duty
  for each row execute function app.tg_audit_row();
create trigger invigilation_constraint_audit after insert or update or delete on public.invigilation_constraint
  for each row execute function app.tg_audit_row();
create trigger invigilation_substitution_task_audit after insert or update or delete on public.invigilation_substitution_task
  for each row execute function app.tg_audit_row();

alter table public.invigilation_duty enable row level security;
alter table public.invigilation_constraint enable row level security;
alter table public.invigilation_substitution_task enable row level security;
create policy duty_campus_scope on public.invigilation_duty for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'exam_controller', 'hr_manager')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy duty_self_read on public.invigilation_duty for select to authenticated
  using (tenant_id = app.auth_tenant_id() and staff_id = (select auth.uid()));
create policy constraint_campus_scope on public.invigilation_constraint for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'exam_controller', 'hr_manager')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy substitution_task_campus_scope on public.invigilation_substitution_task for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'exam_controller', 'hr_manager')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

-- ═══════════════════════════════════════════════════════════════════════
-- The pool, evaluated for one slot
-- ═══════════════════════════════════════════════════════════════════════

-- Every active staff member of the campus with a login, and the first reason
-- (if any) they cannot take this slot. blocked_by is null for an eligible
-- candidate. The same function backs the assignment, the manual add and the
-- under-staffed report, so they cannot disagree.
create or replace function app.fn_invigilator_evaluate(p_slot_id uuid)
returns table (user_id uuid, staff_id uuid, full_name text, duty_count int, blocked_by text)
language sql
stable
security definer
set search_path = ''
as $$
  with slot as (
    select s.id, s.tenant_id, s.campus_id, s.start_at, s.end_at, ds.exam_term_id, ds.session_id,
           cs.subject_id, cs.class_level_id,
           (s.start_at at time zone coalesce(c.timezone, 'Asia/Karachi'))::date as local_date,
           coalesce((select x.invigilation_max_duties from public.exam_settings x where x.campus_id = s.campus_id), 5) as max_duties
      from public.datesheet_slot s
      join public.datesheet ds on ds.id = s.datesheet_id
      join public.exam_subject es on es.id = s.exam_subject_id
      join public.class_subject cs on cs.id = es.class_subject_id
      join public.campus c on c.id = s.campus_id
     where s.id = p_slot_id
  )
  select st.user_id, st.id, st.full_name, d.cnt::int,
         case
           when exists (select 1 from public.section_subject_teacher t
                          join public.class_section sec on sec.id = t.section_id
                         where t.staff_id = st.user_id and t.subject_id = slot.subject_id
                           and sec.class_level_id = slot.class_level_id and sec.session_id = slot.session_id
                           and t.validity @> slot.local_date) then 'own_subject'
           when exists (select 1 from public.leave_application l
                         where l.staff_id = st.id and l.status = 'approved'
                           and slot.local_date between l.from_date and l.to_date) then 'on_leave'
           when exists (select 1 from public.invigilation_constraint k
                         where k.staff_id = st.user_id and k.exam_term_id = slot.exam_term_id
                           and (k.exclude_date = slot.local_date or k.slot_id = slot.id)) then 'excluded'
           when exists (select 1 from public.invigilation_duty d2
                          join public.datesheet_slot s2 on s2.id = d2.datesheet_slot_id
                         where d2.staff_id = st.user_id and d2.status = 'assigned'
                           and tstzrange(s2.start_at, s2.end_at) && tstzrange(slot.start_at, slot.end_at)) then 'overlapping_duty'
           when d.cnt >= slot.max_duties then 'max_duties'
           else null
         end
    from slot
    join public.staff st
      on st.tenant_id = slot.tenant_id and st.user_id is not null and st.employment_status = 'active'
     and (st.campus_id = slot.campus_id
          or exists (select 1 from public.staff_campus sc where sc.staff_id = st.id and sc.campus_id = slot.campus_id))
    cross join lateral (
      select count(*) as cnt from public.invigilation_duty dd
       where dd.staff_id = st.user_id and dd.exam_term_id = slot.exam_term_id and dd.status = 'assigned'
    ) d;
$$;
revoke execute on function app.fn_invigilator_evaluate(uuid) from public, anon, authenticated;

-- Assigns the fewest-duties candidates until the slot has p_count invigilators.
-- Returns how many were added.
create or replace function app.fn_assign_slot(p_slot_id uuid, p_count int)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slot   public.datesheet_slot%rowtype;
  v_term   uuid;
  v_have   int;
  v_added  int := 0;
  v_pick   uuid;
  v_duty   uuid;
begin
  select * into v_slot from public.datesheet_slot where id = p_slot_id;
  select exam_term_id into v_term from public.datesheet where id = v_slot.datesheet_id;
  select count(*)::int into v_have from public.invigilation_duty where datesheet_slot_id = p_slot_id and status = 'assigned';
  while v_have + v_added < p_count loop
    select e.user_id into v_pick
      from app.fn_invigilator_evaluate(p_slot_id) e
     where e.blocked_by is null
     order by e.duty_count, md5(e.user_id::text || p_slot_id::text)
     limit 1;
    exit when v_pick is null;
    insert into public.invigilation_duty (tenant_id, campus_id, exam_term_id, datesheet_slot_id, staff_id, assigned_by)
    values (v_slot.tenant_id, v_slot.campus_id, v_term, p_slot_id, v_pick, (select auth.uid()))
    returning id into v_duty;
    -- A freed place on a slot that carried an open substitution task is filled by this duty.
    update public.invigilation_substitution_task t
       set status = 'resolved', resolved_at = now(), replacement_staff_id = v_pick
     where t.id = (select t2.id from public.invigilation_substitution_task t2
                     join public.invigilation_duty d2 on d2.id = t2.duty_id
                    where d2.datesheet_slot_id = p_slot_id and t2.status = 'open' order by t2.created_at limit 1);
    v_added := v_added + 1;
  end loop;
  return v_added;
end;
$$;
revoke execute on function app.fn_assign_slot(uuid, int) from public, anon, authenticated;

create or replace function public.fn_assign_invigilators(p_slot_id uuid, p_count int)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slot public.datesheet_slot%rowtype;
begin
  select * into v_slot from public.datesheet_slot where id = p_slot_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_slot.campus_id);
  if p_count is null or p_count not between 1 and 50 then
    raise exception 'INVIGILATORS_INVALID' using errcode = '22023';
  end if;
  return app.fn_assign_slot(p_slot_id, p_count);
end;
$$;
revoke execute on function public.fn_assign_invigilators(uuid, int) from public, anon;
grant execute on function public.fn_assign_invigilators(uuid, int) to authenticated;

-- Duties of staff who have since gone on approved leave (or been excluded) are
-- flagged and a substitution task raised for each. Idempotent.
create or replace function public.flag_invigilation_conflicts(p_datesheet_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ds  public.datesheet%rowtype;
  v_n   int := 0;
  r     record;
begin
  select * into v_ds from public.datesheet where id = p_datesheet_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'DATESHEET_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_ds.campus_id);
  for r in
    select d.id as duty_id,
           case when exists (select 1 from public.staff st join public.leave_application l on l.staff_id = st.id
                              where st.user_id = d.staff_id and l.status = 'approved'
                                and (s.start_at at time zone coalesce(c.timezone, 'Asia/Karachi'))::date between l.from_date and l.to_date)
                then 'staff_on_leave' else 'excluded' end as reason
      from public.invigilation_duty d
      join public.datesheet_slot s on s.id = d.datesheet_slot_id
      join public.campus c on c.id = s.campus_id
     where s.datesheet_id = p_datesheet_id and d.status = 'assigned'
       and (exists (select 1 from public.staff st join public.leave_application l on l.staff_id = st.id
                     where st.user_id = d.staff_id and l.status = 'approved'
                       and (s.start_at at time zone coalesce(c.timezone, 'Asia/Karachi'))::date between l.from_date and l.to_date)
            or exists (select 1 from public.invigilation_constraint k
                        where k.staff_id = d.staff_id and k.exam_term_id = d.exam_term_id
                          and (k.exclude_date = (s.start_at at time zone coalesce(c.timezone, 'Asia/Karachi'))::date or k.slot_id = s.id)))
  loop
    update public.invigilation_duty set status = 'substitution_needed' where id = r.duty_id;
    insert into public.invigilation_substitution_task (tenant_id, campus_id, duty_id, reason)
    values (v_ds.tenant_id, v_ds.campus_id, r.duty_id, r.reason)
    on conflict (duty_id) where status = 'open' do nothing;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.flag_invigilation_conflicts(uuid) from public, anon;
grant execute on function public.flag_invigilation_conflicts(uuid) to authenticated;

-- Runs the whole datesheet. Returns
--   {assigned_now, substitution_tasks, understaffed: [{slot_id, required, assigned, shortfall, blocked}],
--    slots: [...], spread: {min, max}}
-- It never raises for a shortfall: the under-staffed slots ARE the answer.
create or replace function public.assign_invigilation(p_datesheet_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ds      public.datesheet%rowtype;
  v_flagged int;
  v_now     int := 0;
  r         record;
  v_have    int;
  v_slots   jsonb := '[]'::jsonb;
  v_under   jsonb := '[]'::jsonb;
  v_block   jsonb;
  v_min     int;
  v_max     int;
begin
  select * into v_ds from public.datesheet where id = p_datesheet_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'DATESHEET_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_ds.campus_id);
  v_flagged := public.flag_invigilation_conflicts(p_datesheet_id);

  -- Most constrained slots first, so a scarce slot is not starved by an easy one.
  for r in
    select s.id, s.invigilators_required,
           (select count(*) from app.fn_invigilator_evaluate(s.id) e where e.blocked_by is null) as candidates
      from public.datesheet_slot s
     where s.datesheet_id = p_datesheet_id
     order by candidates, s.start_at, s.id
  loop
    v_now := v_now + app.fn_assign_slot(r.id, r.invigilators_required);
  end loop;

  for r in
    select s.id, s.start_at, s.invigilators_required from public.datesheet_slot s where s.datesheet_id = p_datesheet_id order by s.start_at, s.id
  loop
    select count(*)::int into v_have from public.invigilation_duty where datesheet_slot_id = r.id and status = 'assigned';
    v_slots := v_slots || jsonb_build_array(jsonb_build_object('slot_id', r.id, 'required', r.invigilators_required, 'assigned', v_have));
    if v_have < r.invigilators_required then
      select coalesce(jsonb_object_agg(b, n), '{}'::jsonb) into v_block
        from (select coalesce(e.blocked_by, 'available') as b, count(*) as n from app.fn_invigilator_evaluate(r.id) e group by 1) x;
      v_under := v_under || jsonb_build_array(jsonb_build_object('slot_id', r.id, 'required', r.invigilators_required, 'assigned', v_have,
                                                                 'shortfall', r.invigilators_required - v_have, 'pool', v_block));
    end if;
  end loop;

  select min(cnt), max(cnt) into v_min, v_max
    from (select count(d.id) filter (where d.status = 'assigned') as cnt
            from public.staff st
            left join public.invigilation_duty d on d.staff_id = st.user_id and d.exam_term_id = v_ds.exam_term_id
           where st.tenant_id = v_ds.tenant_id and st.user_id is not null and st.employment_status = 'active'
             and (st.campus_id = v_ds.campus_id or exists (select 1 from public.staff_campus sc where sc.staff_id = st.id and sc.campus_id = v_ds.campus_id))
           group by st.id) q;

  return jsonb_build_object('assigned_now', v_now, 'substitution_tasks', v_flagged, 'understaffed', v_under, 'slots', v_slots,
                            'spread', jsonb_build_object('min', coalesce(v_min, 0), 'max', coalesce(v_max, 0)));
end;
$$;
revoke execute on function public.assign_invigilation(uuid) from public, anon;
grant execute on function public.assign_invigilation(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Manual adjustments
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.add_invigilation_duty(p_slot_id uuid, p_staff_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slot   public.datesheet_slot%rowtype;
  v_eval   record;
  v_term   uuid;
  v_duty   uuid;
begin
  select * into v_slot from public.datesheet_slot where id = p_slot_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_slot.campus_id);
  select * into v_eval from app.fn_invigilator_evaluate(p_slot_id) e where e.user_id = p_staff_user_id;
  if not found then
    raise exception 'STAFF_NOT_IN_POOL' using errcode = 'P0002';
  end if;
  if v_eval.blocked_by is not null then
    raise exception 'STAFF_NOT_ELIGIBLE: %', v_eval.blocked_by using errcode = '23514';
  end if;
  select exam_term_id into v_term from public.datesheet where id = v_slot.datesheet_id;
  insert into public.invigilation_duty (tenant_id, campus_id, exam_term_id, datesheet_slot_id, staff_id, assigned_by)
  values (v_slot.tenant_id, v_slot.campus_id, v_term, p_slot_id, p_staff_user_id, (select auth.uid()))
  returning id into v_duty;
  update public.invigilation_substitution_task t
     set status = 'resolved', resolved_at = now(), replacement_staff_id = p_staff_user_id
   where t.id = (select t2.id from public.invigilation_substitution_task t2
                   join public.invigilation_duty d2 on d2.id = t2.duty_id
                  where d2.datesheet_slot_id = p_slot_id and t2.status = 'open' order by t2.created_at limit 1);
  return v_duty;
end;
$$;
revoke execute on function public.add_invigilation_duty(uuid, uuid) from public, anon;
grant execute on function public.add_invigilation_duty(uuid, uuid) to authenticated;

create or replace function public.remove_invigilation_duty(p_duty_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_duty public.invigilation_duty%rowtype;
begin
  select * into v_duty from public.invigilation_duty where id = p_duty_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'DUTY_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_duty.campus_id);
  update public.invigilation_duty set status = 'cancelled' where id = p_duty_id;
  update public.invigilation_substitution_task set status = 'resolved', resolved_at = now() where duty_id = p_duty_id and status = 'open';
end;
$$;
revoke execute on function public.remove_invigilation_duty(uuid) from public, anon;
grant execute on function public.remove_invigilation_duty(uuid) to authenticated;

create or replace function public.add_invigilation_exclusion(
  p_exam_term_id uuid, p_staff_user_id uuid, p_date date, p_reason text, p_slot_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_term public.exam_term%rowtype;
  v_id   uuid;
begin
  select * into v_term from public.exam_term where id = p_exam_term_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_term.campus_id);
  if not exists (select 1 from public.staff where user_id = p_staff_user_id and tenant_id = v_term.tenant_id) then
    raise exception 'STAFF_NOT_IN_POOL' using errcode = 'P0002';
  end if;
  if (p_date is null) = (p_slot_id is null) then
    raise exception 'EXCLUSION_TARGET_INVALID' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;
  insert into public.invigilation_constraint (tenant_id, campus_id, exam_term_id, staff_id, exclude_date, slot_id, reason, created_by)
  values (v_term.tenant_id, v_term.campus_id, p_exam_term_id, p_staff_user_id, p_date, p_slot_id, btrim(p_reason), (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.add_invigilation_exclusion(uuid, uuid, date, text, uuid) from public, anon;
grant execute on function public.add_invigilation_exclusion(uuid, uuid, date, text, uuid) to authenticated;

create or replace function public.remove_invigilation_exclusion(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_k public.invigilation_constraint%rowtype;
begin
  select * into v_k from public.invigilation_constraint where id = p_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'EXCLUSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_k.campus_id);
  delete from public.invigilation_constraint where id = p_id;
end;
$$;
revoke execute on function public.remove_invigilation_exclusion(uuid) from public, anon;
grant execute on function public.remove_invigilation_exclusion(uuid) to authenticated;

-- In-app roster notice to every staff member with a duty that has not been
-- notified yet. Returns how many people were notified.
create or replace function public.notify_duty_roster(p_datesheet_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ds public.datesheet%rowtype;
  v_n  int := 0;
  r    record;
begin
  select * into v_ds from public.datesheet where id = p_datesheet_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'DATESHEET_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_ds.campus_id);
  for r in
    select d.staff_id,
           string_agg(to_char(s.start_at at time zone 'Asia/Karachi', 'Dy DD Mon HH24:MI') || ' ' || sub.name_en, '; ' order by s.start_at) as lines,
           array_agg(d.id) as duty_ids
      from public.invigilation_duty d
      join public.datesheet_slot s on s.id = d.datesheet_slot_id
      join public.exam_subject es on es.id = s.exam_subject_id
      join public.class_subject cs on cs.id = es.class_subject_id
      join public.subject sub on sub.id = cs.subject_id
     where s.datesheet_id = p_datesheet_id and d.status = 'assigned' and d.notified_at is null
     group by d.staff_id
  loop
    insert into public.user_notification (tenant_id, user_id, kind, title, body, link)
    values (v_ds.tenant_id, r.staff_id, 'invigilation_roster', 'Your invigilation duties', r.lines, '/exams/invigilation');
    update public.invigilation_duty set notified_at = now() where id = any (r.duty_ids);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.notify_duty_roster(uuid) from public, anon;
grant execute on function public.notify_duty_roster(uuid) to authenticated;
