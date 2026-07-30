-- FR-E08 (class teacher allocation) and FR-E09 (subject teacher
-- allocation), shipped together: both are the same date-ranged,
-- overlap-excluded allocation pattern applied to two different keys, and
-- reviewing the pattern once against two uses catches more than reviewing
-- it twice in isolation.
--
-- Scope cuts:
--   * "staff_id" references app_user(user_id) directly — there is no
--     separate Module D staff/HR table yet, and app_user already carries
--     role + campus scoping for anyone who could plausibly be a class or
--     subject teacher. A real Module D staff table (employment history,
--     etc.) is a substantially larger, separate piece of work.
--   * E09's COMPETENCY_MISMATCH check needs FR-E07 (teacher competency
--     registry), which doesn't exist — there is no competency data to
--     compare against, so the allocation simply always saves without that
--     warning.
--   * No UI: the AC's "8/8 allocated" setup screen and "publish blocked,
--     3 pairs listed" flow both belong to the timetable module (F), which
--     doesn't exist. v_unallocated_section_subject is the query that
--     screen would run — DB layer, no screen yet.

create extension if not exists btree_gist;

-- ── E08: section_class_teacher ───────────────────────────────────────

create table public.section_class_teacher (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  session_id     uuid not null references public.academic_session(id) on delete cascade,
  section_id     uuid not null references public.class_section(id) on delete cascade,
  staff_id       uuid not null references public.app_user(user_id),
  effective_from date not null,
  effective_to   date,
  validity       daterange generated always as (daterange(effective_from, effective_to, '[]')) stored,
  created_at     timestamptz not null default now(),
  constraint ex_class_teacher_no_overlap exclude using gist (section_id with =, validity with &&)
);

create index idx_class_teacher_staff_validity on public.section_class_teacher (staff_id, validity);
create index idx_class_teacher_section on public.section_class_teacher (section_id);

create trigger section_class_teacher_audit after insert or update or delete on public.section_class_teacher
  for each row execute function app.tg_audit_row();

create or replace function public.assign_class_teacher(p_section_id uuid, p_staff_id uuid, p_effective_from date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_section        public.class_section%rowtype;
  v_id             uuid;
  v_already_class_teacher boolean;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_section from public.class_section where id = p_section_id;
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  select exists (
    select 1 from public.section_class_teacher sct
     where sct.staff_id = p_staff_id and sct.session_id = v_section.session_id
       and sct.section_id <> p_section_id and sct.effective_to is null
  ) into v_already_class_teacher;

  -- Auto-close the open-ended predecessor the day before the new range
  -- starts — never overwritten, so a report card signed against the old
  -- teacher's range still resolves correctly no matter when it's reprinted.
  update public.section_class_teacher
     set effective_to = p_effective_from - 1
   where section_id = p_section_id and effective_to is null and effective_from < p_effective_from;

  insert into public.section_class_teacher (tenant_id, campus_id, session_id, section_id, staff_id, effective_from)
  values (app.auth_tenant_id(), v_section.campus_id, v_section.session_id, p_section_id, p_staff_id, p_effective_from)
  returning id into v_id;

  -- One teacher holding two class-teacher posts is unusual but legitimate
  -- (small schools) — warn, never block.
  return jsonb_build_object('id', v_id, 'warning', case when v_already_class_teacher then 'DUAL_CLASS_TEACHER' else null end);
end;
$$;

revoke execute on function public.assign_class_teacher(uuid, uuid, date) from public, anon;
grant execute on function public.assign_class_teacher(uuid, uuid, date) to authenticated;

alter table public.section_class_teacher enable row level security;

create policy class_teacher_campus_scope on public.section_class_teacher
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()) or staff_id = auth.uid())
  );

-- ── E09: section_subject_teacher ─────────────────────────────────────

create type public.allocation_role as enum ('primary', 'assistant');

create table public.section_subject_teacher (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  session_id     uuid not null references public.academic_session(id) on delete cascade,
  section_id     uuid not null references public.class_section(id) on delete cascade,
  subject_id     uuid not null references public.subject(id),
  staff_id       uuid not null references public.app_user(user_id),
  role           public.allocation_role not null default 'primary',
  effective_from date not null,
  effective_to   date,
  validity       daterange generated always as (daterange(effective_from, effective_to, '[]')) stored,
  created_at     timestamptz not null default now(),
  -- Scoped to role = 'primary': co-teaching (an assistant alongside the
  -- primary) is modelled as a second row with the same section+subject+
  -- range, not a conflict — every load/clash calculation counts the
  -- primary once and the assistant separately, never double-counting one
  -- allocation as two.
  constraint ex_subject_teacher_no_overlap
    exclude using gist (section_id with =, subject_id with =, validity with &&) where (role = 'primary')
);

create index idx_subject_teacher_staff_session on public.section_subject_teacher (staff_id, session_id);
create index idx_subject_teacher_section_subject on public.section_subject_teacher (section_id, subject_id);

create trigger section_subject_teacher_audit after insert or update or delete on public.section_subject_teacher
  for each row execute function app.tg_audit_row();

create or replace function public.assign_subject_teacher(
  p_section_id uuid, p_subject_id uuid, p_staff_id uuid, p_effective_from date, p_role public.allocation_role default 'primary'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_section public.class_section%rowtype;
  v_id      uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_section from public.class_section where id = p_section_id;
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_role = 'primary' then
    update public.section_subject_teacher
       set effective_to = p_effective_from - 1
     where section_id = p_section_id and subject_id = p_subject_id and role = 'primary'
       and effective_to is null and effective_from < p_effective_from;
  end if;

  insert into public.section_subject_teacher (tenant_id, campus_id, session_id, section_id, subject_id, staff_id, role, effective_from)
  values (app.auth_tenant_id(), v_section.campus_id, v_section.session_id, p_section_id, p_subject_id, p_staff_id, p_role, p_effective_from)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.assign_subject_teacher(uuid, uuid, uuid, date, public.allocation_role) from public, anon;
grant execute on function public.assign_subject_teacher(uuid, uuid, uuid, date, public.allocation_role) to authenticated;

alter table public.section_subject_teacher enable row level security;

create policy subject_teacher_campus_scope on public.section_subject_teacher
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()) or staff_id = auth.uid())
  );

-- Cross-joins every active section of a class level against every subject
-- mapped to that class level (class_subject is class-level-wide, sections
-- are per-section) and keeps only pairs with no open-ended primary.
create view public.v_unallocated_section_subject
with (security_invoker = true) as
select cs.id as class_subject_id, cs.campus_id, cs.session_id, cs.class_level_id, cs.subject_id,
       sec.id as section_id, sec.name as section_name
  from public.class_subject cs
  join public.class_section sec
    on sec.class_level_id = cs.class_level_id and sec.session_id = cs.session_id and sec.campus_id = cs.campus_id and sec.is_active
 where not exists (
   select 1 from public.section_subject_teacher sst
    where sst.section_id = sec.id and sst.subject_id = cs.subject_id and sst.role = 'primary' and sst.effective_to is null
 );
