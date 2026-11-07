-- Student discipline log: incidents a teacher or the office records against a
-- student (behaviour, bullying, uniform, cheating, damage...), what was done
-- about it, and whether the parent was told.
--
-- Staff of the student's campus read and write; parents and students never see
-- the table. Entries are corrected by adding a new one, not edited, so the
-- history a principal relies on in a parent meeting cannot quietly change.

create table public.student_incident (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  student_id      uuid not null references public.student(id) on delete cascade,
  occurred_on     date not null,
  category        text not null check (category in ('behaviour', 'bullying', 'attendance', 'uniform', 'academic_dishonesty', 'property_damage', 'other')),
  severity        text not null check (severity in ('minor', 'moderate', 'serious')),
  description     text not null check (length(btrim(description)) between 1 and 2000),
  action_taken    text check (action_taken is null or length(action_taken) <= 1000),
  parent_informed boolean not null default false,
  recorded_by     uuid not null default auth.uid() references auth.users(id),
  created_at      timestamptz not null default now()
);

create index idx_student_incident_student on public.student_incident (student_id, occurred_on desc);
create index idx_student_incident_scope on public.student_incident (tenant_id, campus_id, occurred_on desc);

alter table public.student_incident enable row level security;

create policy student_incident_read on public.student_incident
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'student', 'none')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

select app.fn_block_portal_roles('public.student_incident');

create trigger student_incident_audit after insert or update or delete on public.student_incident
  for each row execute function app.tg_audit_row();

create or replace function public.record_student_incident(
  p_student_id      uuid,
  p_occurred_on     date,
  p_category        text,
  p_severity        text,
  p_description     text,
  p_action_taken    text default null,
  p_parent_informed boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_campus    uuid;
  v_id        uuid;
begin
  if v_tenant_id is null or app.auth_role() in ('parent', 'student', 'none') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select campus_id into v_campus from public.student where id = p_student_id and tenant_id = v_tenant_id and deleted_at is null;
  if v_campus is null then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_campus = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501', detail = 'campus outside your scope';
  end if;
  if p_occurred_on is null or p_occurred_on > current_date then
    raise exception 'DATE_INVALID' using errcode = '22023', hint = 'An incident cannot be in the future.';
  end if;

  insert into public.student_incident (tenant_id, campus_id, student_id, occurred_on, category, severity, description, action_taken, parent_informed)
  values (v_tenant_id, v_campus, p_student_id, p_occurred_on, p_category, p_severity, btrim(p_description), nullif(btrim(p_action_taken), ''), coalesce(p_parent_informed, false))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.record_student_incident(uuid, date, text, text, text, text, boolean) from public, anon;
grant execute on function public.record_student_incident(uuid, date, text, text, text, text, boolean) to authenticated;
