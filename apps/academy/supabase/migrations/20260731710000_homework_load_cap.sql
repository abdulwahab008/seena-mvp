-- FR-H03: daily homework load cap per section.
--
-- Advisory only, never blocking — a teacher unable to set homework
-- because a colleague published first would abandon the app and revert
-- to the paper diary (this FR's own Notes). So there is no separate
-- "confirm anyway" round trip: publish_homework() always publishes: it
-- just now also returns a warning (same jsonb-result pattern already
-- used by assign_subject_teacher/FR-D02's own extension of it) and, when
-- the section's own cap was already met before this row, records the
-- override on the row itself — nothing for the caller to re-submit.

create table public.homework_load_policy (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  session_id           uuid not null references public.academic_session(id) on delete cascade,
  max_assignments_per_day int,
  max_minutes_per_day     int,
  created_at           timestamptz not null default now(),
  constraint chk_hw_load_policy_has_a_cap check (max_assignments_per_day is not null or max_minutes_per_day is not null),
  constraint chk_hw_load_policy_positive check (
    (max_assignments_per_day is null or max_assignments_per_day > 0)
    and (max_minutes_per_day is null or max_minutes_per_day > 0)
  ),
  unique (campus_id, session_id)
);

create trigger homework_load_policy_audit after insert or update or delete on public.homework_load_policy
  for each row execute function app.tg_audit_row();

alter table public.homework_load_policy enable row level security;

create policy homework_load_policy_read on public.homework_load_policy
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'none')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create or replace function public.set_homework_load_policy(
  p_campus_id uuid, p_session_id uuid, p_max_assignments_per_day int default null, p_max_minutes_per_day int default null
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
  if p_max_assignments_per_day is null and p_max_minutes_per_day is null then
    raise exception 'AT_LEAST_ONE_CAP_REQUIRED' using errcode = '23514';
  end if;

  insert into public.homework_load_policy (tenant_id, campus_id, session_id, max_assignments_per_day, max_minutes_per_day)
  values (app.auth_tenant_id(), p_campus_id, p_session_id, p_max_assignments_per_day, p_max_minutes_per_day)
  on conflict (campus_id, session_id) do update set
    max_assignments_per_day = excluded.max_assignments_per_day,
    max_minutes_per_day = excluded.max_minutes_per_day
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.set_homework_load_policy(uuid, uuid, int, int) from public, anon;
grant execute on function public.set_homework_load_policy(uuid, uuid, int, int) to authenticated;

alter table public.homework add column load_warning_overridden boolean not null default false;
alter table public.homework add column overridden_by uuid references public.app_user(user_id);

-- AC2: the section load calendar — one row per (section, due_date) among
-- PUBLISHED homework only (a draft isn't a real commitment yet).
create or replace view public.v_section_homework_load with (security_invoker = true) as
select
  h.tenant_id,
  h.campus_id,
  h.section_id,
  h.due_date,
  count(*)::int as assignment_count,
  coalesce(sum(h.estimated_minutes), 0)::int as total_minutes
from public.homework h
where h.status = 'published'
group by h.tenant_id, h.campus_id, h.section_id, h.due_date;

-- AC1/AC3: the check a publish runs — null when no policy is configured
-- for the campus/session (caps are opt-in), or when neither cap is
-- actually exceeded by what was ALREADY published before this row.
create or replace function public.check_homework_load(p_section_id uuid, p_due_date date, p_exclude_homework_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_section  public.class_section%rowtype;
  v_policy   public.homework_load_policy%rowtype;
  v_count    int;
  v_minutes  int;
begin
  select * into v_section from public.class_section where id = p_section_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_policy from public.homework_load_policy
   where campus_id = v_section.campus_id and session_id = v_section.session_id and tenant_id = app.auth_tenant_id();
  if not found then
    return jsonb_build_object('exceeded', false);
  end if;

  select count(*)::int, coalesce(sum(estimated_minutes), 0)::int into v_count, v_minutes
    from public.homework
   where section_id = p_section_id and due_date = p_due_date and status = 'published'
     and (p_exclude_homework_id is null or id <> p_exclude_homework_id);

  if (v_policy.max_assignments_per_day is not null and v_count >= v_policy.max_assignments_per_day)
     or (v_policy.max_minutes_per_day is not null and v_minutes >= v_policy.max_minutes_per_day) then
    return jsonb_build_object(
      'exceeded', true,
      'assignment_count', v_count,
      'total_minutes', v_minutes,
      'max_assignments_per_day', v_policy.max_assignments_per_day,
      'max_minutes_per_day', v_policy.max_minutes_per_day
    );
  end if;

  return jsonb_build_object('exceeded', false, 'assignment_count', v_count, 'total_minutes', v_minutes);
end;
$$;

revoke execute on function public.check_homework_load(uuid, date, uuid) from public, anon;
grant execute on function public.check_homework_load(uuid, date, uuid) to authenticated;

drop function public.publish_homework(uuid);

create or replace function public.publish_homework(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hw          public.homework%rowtype;
  v_section     public.class_section%rowtype;
  v_class_level public.class_level%rowtype;
  v_load        jsonb;
begin
  select * into v_hw from public.homework where id = p_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'HOMEWORK_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_role() not in ('super_admin', 'owner', 'principal') and v_hw.teacher_id <> (select auth.uid()) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_hw.status = 'published' then
    raise exception 'ALREADY_PUBLISHED' using errcode = '55000';
  end if;

  update public.homework set status = 'published', published_at = now() where id = p_id;

  -- AC1: checked against what was published BEFORE this row (this row's
  -- own id is excluded) — "Class 6-A ALREADY has 3 assignments due" is a
  -- statement about the section's prior load, not the post-publish total.
  v_load := public.check_homework_load(v_hw.section_id, v_hw.due_date, p_id);

  if (v_load->>'exceeded')::boolean then
    update public.homework set load_warning_overridden = true, overridden_by = auth.uid() where id = p_id;

    select * into v_section from public.class_section where id = v_hw.section_id;
    select * into v_class_level from public.class_level where id = v_section.class_level_id;

    return jsonb_build_object(
      'warning', 'SECTION_HOMEWORK_LOAD_CAP',
      'message', format(
        '%s %s already has %s assignment(s) due on %s (est. %s min)',
        v_class_level.name_en, v_section.name, v_load->>'assignment_count', to_char(v_hw.due_date, 'DD Mon'), v_load->>'total_minutes'
      )
    );
  end if;

  return jsonb_build_object('warning', null);
end;
$$;

revoke execute on function public.publish_homework(uuid) from public, anon;
grant execute on function public.publish_homework(uuid) to authenticated;
