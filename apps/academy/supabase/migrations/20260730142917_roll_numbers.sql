-- FR-C03: roll number assignment and bulk re-sequencing.
--
-- Scope cut: the AC's "resequencing is refused when any exam in the
-- session has a published date sheet" needs Module I (Examinations), which
-- doesn't exist yet — nothing to check against. Add the guard when exam
-- date sheets exist.

create unique index uq_roll_no on public.enrolment (session_id, class_level_id, section_id, roll_no) where status = 'active';

create table public.roll_number_change_log (
  id           uuid primary key default gen_random_uuid(),
  enrolment_id uuid not null references public.enrolment(id) on delete cascade,
  old_roll_no  int,
  new_roll_no  int not null,
  strategy     text not null,
  changed_by   uuid references public.app_user(user_id),
  changed_at   timestamptz not null default now()
);

create index idx_roll_number_change_log_enrolment on public.roll_number_change_log (enrolment_id);

create or replace function public.fn_assign_next_roll_no(p_enrolment_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid;
  v_section_id uuid;
  v_session_id uuid;
  v_class_level_id uuid;
  v_next       int;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'class_teacher', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id, section_id, session_id, class_level_id
    into v_tenant_id, v_section_id, v_session_id, v_class_level_id
    from public.enrolment where id = p_enrolment_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select coalesce(max(roll_no), 0) + 1 into v_next
    from public.enrolment
   where section_id = v_section_id and session_id = v_session_id and status = 'active';

  update public.enrolment set roll_no = v_next where id = p_enrolment_id;

  return v_next;
end;
$$;

revoke execute on function public.fn_assign_next_roll_no(uuid) from public, anon;
grant execute on function public.fn_assign_next_roll_no(uuid) to authenticated;

create or replace function public.fn_set_roll_no(p_enrolment_id uuid, p_roll_no int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id into v_tenant_id from public.enrolment where id = p_enrolment_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- uq_roll_no does the actual rejection of an in-use number within the
  -- same (session, class, section) — nothing to check here beyond scope.
  update public.enrolment set roll_no = p_roll_no where id = p_enrolment_id;
end;
$$;

revoke execute on function public.fn_set_roll_no(uuid, int) from public, anon;
grant execute on function public.fn_set_roll_no(uuid, int) to authenticated;

create or replace function public.fn_resequence_roll_numbers(p_section_id uuid, p_session_id uuid, p_strategy text default 'alphabetical')
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ids       uuid[];
  v_old_rolls int[];
  v_new_roll  int := 0;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_strategy <> 'alphabetical' then
    raise exception 'UNKNOWN_STRATEGY' using errcode = '22023';
  end if;

  select array_agg(e.id order by s.name_en), array_agg(e.roll_no order by s.name_en)
    into v_ids, v_old_rolls
    from public.enrolment e
    join public.student s on s.id = e.student_id
   where e.section_id = p_section_id and e.session_id = p_session_id and e.status = 'active';

  -- Cleared first: assigning the target sequence directly, one row at a
  -- time, would transiently collide with uq_roll_no whenever a student's
  -- new roll number is still held by someone else at that instant.
  update public.enrolment set roll_no = null
   where section_id = p_section_id and session_id = p_session_id and status = 'active';

  for i in 1 .. coalesce(array_length(v_ids, 1), 0) loop
    v_new_roll := i;
    if v_old_rolls[i] is distinct from v_new_roll then
      insert into public.roll_number_change_log (enrolment_id, old_roll_no, new_roll_no, strategy, changed_by)
      values (v_ids[i], v_old_rolls[i], v_new_roll, p_strategy, auth.uid());
    end if;
    update public.enrolment set roll_no = v_new_roll where id = v_ids[i];
  end loop;

  return v_new_roll;
end;
$$;

revoke execute on function public.fn_resequence_roll_numbers(uuid, uuid, text) from public, anon;
grant execute on function public.fn_resequence_roll_numbers(uuid, uuid, text) to authenticated;

alter table public.roll_number_change_log enable row level security;

create policy roll_number_change_log_campus_scope on public.roll_number_change_log
  for select to authenticated
  using (
    enrolment_id in (
      select id from public.enrolment
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );
