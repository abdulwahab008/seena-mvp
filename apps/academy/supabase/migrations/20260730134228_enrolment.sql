-- FR-E03 (section capacity enforcement) and FR-C02 (section allotment with
-- balancing), shipped together: both describe the same `enrolment` table
-- from different angles (E03's Supabase Objects list overlaps C02's), and
-- neither is independently testable without the other's columns.
--
-- Scope cut: fn_auto_balance_sections here enrols a *given batch of
-- students* while distributing them evenly (greedy fill-the-emptiest) —
-- there's no "unassigned student pool" concept modelled anywhere yet, so
-- "auto-balance" is interpreted as the batch-enrolment operation the AC's
-- own numbers actually describe (9 students placed to turn 30/31/32 into
-- 34/34/34), not a rebalance of an existing unassigned queue.
--
-- Concurrency note: the advisory lock in trg_enrolment_capacity_check is
-- what prevents the classic read-then-write overfill race. pgTAP runs
-- single-connection, so the "20 concurrent enrolments, exactly 10 succeed"
-- AC isn't exercised here — only the sequential boundary (capacity
-- succeeds, capacity+1 fails) is, which validates the counting logic the
-- lock protects.

alter table public.class_section add column gender_restriction public.gender;

-- Widened with a trailing default-null param rather than a separate
-- setter: existing call sites are unaffected, and class_section has no
-- UPDATE policy for authenticated (all writes are function-gated), so a
-- setter would need its own auth/campus-scope checks duplicated from here.
-- A new arg count means `create or replace` would add a second overload
-- instead of replacing the original — drop it first so only one exists.
drop function if exists public.create_section(uuid, uuid, uuid, text, int, public.section_medium, public.section_shift);

create or replace function public.create_section(
  p_campus_id         uuid,
  p_session_id        uuid,
  p_class_level_id    uuid,
  p_name              text,
  p_capacity          int,
  p_medium            public.section_medium default 'ENGLISH',
  p_shift             public.section_shift default 'MORNING',
  p_gender_restriction public.gender default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_capacity < 1 or p_capacity > 200 then
    raise exception 'CAPACITY_OUT_OF_RANGE' using errcode = '23514';
  end if;

  if exists (
    select 1 from public.class_section
     where campus_id = p_campus_id and session_id = p_session_id
       and class_level_id = p_class_level_id and name = p_name
  ) then
    raise exception 'SECTION_NAME_DUPLICATE' using errcode = '23505';
  end if;

  insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity, medium, shift, gender_restriction)
  values (app.auth_tenant_id(), p_campus_id, p_session_id, p_class_level_id, p_name, p_capacity, p_medium, p_shift, p_gender_restriction)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_section(
  uuid, uuid, uuid, text, int, public.section_medium, public.section_shift, public.gender
) from public, anon;
grant execute on function public.create_section(
  uuid, uuid, uuid, text, int, public.section_medium, public.section_shift, public.gender
) to authenticated;

create type public.enrolment_status as enum ('active', 'transferred', 'left', 'graduated');

create table public.enrolment (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  session_id      uuid not null references public.academic_session(id) on delete cascade,
  student_id      uuid not null references public.student(id),
  class_level_id  uuid not null references public.class_level(id),
  section_id      uuid not null references public.class_section(id),
  roll_no         int,
  status          public.enrolment_status not null default 'active',
  joined_on       date not null default current_date,
  left_on         date,
  over_capacity   boolean not null default false,
  override_reason text,
  override_by     uuid references public.app_user(user_id),
  override_at     timestamptz,
  created_at      timestamptz not null default now(),
  unique (student_id, session_id)
);

create index idx_enrolment_section_active on public.enrolment (section_id, session_id) where status = 'active';

create table public.section_membership_history (
  id           uuid primary key default gen_random_uuid(),
  enrolment_id uuid not null references public.enrolment(id) on delete cascade,
  section_id   uuid not null references public.class_section(id),
  from_date    date not null,
  to_date      date,
  moved_by     uuid references public.app_user(user_id),
  reason       text,
  created_at   timestamptz not null default now()
);

create index idx_section_membership_enrolment on public.section_membership_history (enrolment_id);

create trigger enrolment_audit after insert or update or delete on public.enrolment
  for each row execute function app.tg_audit_row();

-- Fires on every INSERT and on any UPDATE that changes section_id or lands
-- status back to 'active' — a status change to something else, or an
-- update that touches neither, is never capacity-relevant.
create or replace function app.tg_enrolment_capacity_check()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_capacity      int;
  v_active_count  int;
  v_siblings      text;
begin
  if new.status <> 'active' then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.section_id = new.section_id and old.status = 'active' then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('section:' || new.section_id::text, 0));

  select capacity into v_capacity from public.class_section where id = new.section_id;
  select count(*) into v_active_count
    from public.enrolment
   where section_id = new.section_id and status = 'active' and id is distinct from new.id;

  if v_active_count >= v_capacity then
    if new.override_reason is null then
      select string_agg(cs.name || ' (' || (cs.capacity - coalesce(cnt.c, 0)) || ' free)', ', ')
        into v_siblings
        from public.class_section cs
        left join (select section_id, count(*) as c from public.enrolment where status = 'active' group by section_id) cnt
          on cnt.section_id = cs.id
       where cs.class_level_id = (select class_level_id from public.class_section where id = new.section_id)
         and cs.session_id = (select session_id from public.class_section where id = new.section_id)
         and cs.id <> new.section_id
         and cs.is_active
         and (cs.capacity - coalesce(cnt.c, 0)) > 0;

      raise exception 'SECTION_FULL'
        using errcode = '23514',
              detail = format('capacity=%s active=%s free_siblings=%s', v_capacity, v_active_count, coalesce(v_siblings, 'none'));
    end if;
    new.over_capacity := true;
    new.override_by := auth.uid();
    new.override_at := now();
  end if;

  return new;
end;
$$;

create trigger trg_enrolment_capacity_check
  before insert or update of section_id, status on public.enrolment
  for each row execute function app.tg_enrolment_capacity_check();

create view public.v_section_seat_availability
with (security_invoker = true) as
select
  cs.id as section_id, cs.class_level_id, cs.campus_id, cs.session_id, cs.name, cs.capacity,
  coalesce(cnt.c, 0) as active_count,
  cs.capacity - coalesce(cnt.c, 0) as seats_free
from public.class_section cs
left join (select section_id, count(*) as c from public.enrolment where status = 'active' group by section_id) cnt
  on cnt.section_id = cs.id
where cs.is_active;

create or replace function public.enrol_student(p_section_id uuid, p_student_id uuid, p_override_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_section public.class_section%rowtype;
  v_id      uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_override_reason is not null and app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'OVERRIDE_REQUIRES_PRINCIPAL' using errcode = '42501';
  end if;

  select * into v_section from public.class_section where id = p_section_id;
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_section.gender_restriction is not null
     and (select gender from public.student where id = p_student_id) <> v_section.gender_restriction then
    raise exception 'SECTION_GENDER_RESTRICTED' using errcode = '23514';
  end if;

  insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, override_reason)
  values (app.auth_tenant_id(), v_section.campus_id, v_section.session_id, p_student_id, v_section.class_level_id, p_section_id, p_override_reason)
  returning id into v_id;

  insert into public.section_membership_history (enrolment_id, section_id, from_date, moved_by, reason)
  values (v_id, p_section_id, current_date, auth.uid(), coalesce(p_override_reason, 'initial enrolment'));

  return v_id;
end;
$$;

revoke execute on function public.enrol_student(uuid, uuid, text) from public, anon;
grant execute on function public.enrol_student(uuid, uuid, text) to authenticated;

create or replace function public.fn_assign_section(
  p_enrolment_id uuid, p_section_id uuid, p_from_date date default current_date, p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid;
  v_old_section_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id, section_id into v_tenant_id, v_old_section_id from public.enrolment where id = p_enrolment_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- End-dated, not overwritten: a September attendance sheet must still
  -- resolve the section the student was actually in on that date.
  update public.section_membership_history
     set to_date = p_from_date - 1
   where enrolment_id = p_enrolment_id and section_id = v_old_section_id and to_date is null;

  update public.enrolment set section_id = p_section_id, override_reason = p_reason where id = p_enrolment_id;

  insert into public.section_membership_history (enrolment_id, section_id, from_date, moved_by, reason)
  values (p_enrolment_id, p_section_id, p_from_date, auth.uid(), p_reason);
end;
$$;

revoke execute on function public.fn_assign_section(uuid, uuid, date, text) from public, anon;
grant execute on function public.fn_assign_section(uuid, uuid, date, text) to authenticated;

create or replace function public.fn_auto_balance_sections(
  p_class_level_id uuid, p_session_id uuid, p_student_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student_id      uuid;
  v_target_section  uuid;
  v_moves           jsonb := '[]'::jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  foreach v_student_id in array p_student_ids loop
    select cs.id into v_target_section
      from public.class_section cs
      left join (select section_id, count(*) as c from public.enrolment where status = 'active' group by section_id) cnt
        on cnt.section_id = cs.id
     where cs.class_level_id = p_class_level_id and cs.session_id = p_session_id and cs.is_active
     order by (cs.capacity - coalesce(cnt.c, 0)) desc, cs.name asc
     limit 1;

    if v_target_section is null then
      raise exception 'NO_SECTIONS_FOR_CLASS' using errcode = 'P0002';
    end if;

    perform public.enrol_student(v_target_section, v_student_id);
    v_moves := v_moves || jsonb_build_object('student_id', v_student_id, 'section_id', v_target_section);
  end loop;

  return jsonb_build_object('placed', array_length(p_student_ids, 1), 'moves', v_moves);
end;
$$;

revoke execute on function public.fn_auto_balance_sections(uuid, uuid, uuid[]) from public, anon;
grant execute on function public.fn_auto_balance_sections(uuid, uuid, uuid[]) to authenticated;

alter table public.enrolment enable row level security;
alter table public.section_membership_history enable row level security;

create policy enrolment_campus_scope on public.enrolment
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy section_membership_history_campus_scope on public.section_membership_history
  for select to authenticated
  using (
    enrolment_id in (
      select id from public.enrolment
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );
