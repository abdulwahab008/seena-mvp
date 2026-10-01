-- FR-H13: syllabus coverage report for parents.
--
-- A parent sees which chapters of their child's class have been covered
-- (with the completion date) and which are pending. Two things are guarded:
--
--   1. Per-campus consent. Schools that are behind schedule will not enable
--      this, so it is a campus_feature_flag ('parent_syllabus_visibility'),
--      off until the Principal turns it on. Off means zero rows.
--   2. Nothing about the teacher. A parent who can see periods_used, who last
--      updated a row or the variance can build a case against one teacher,
--      which is precisely why schools resist the feature. The exclusion is in
--      the DATABASE, not the client: the view exposes only the chapter's
--      sequence, titles, a covered/pending flag and the completion date.
--
-- How the exclusion is enforced. v_parent_syllabus_coverage is a
-- security_invoker view, but it does not read syllabus_coverage directly: it
-- selects from app.fn_parent_syllabus_rows(), a SECURITY DEFINER function that
-- resolves the signed-in guardian's own children, checks the campus flag, and
-- returns ONLY the safe columns. Giving parents a row-level policy on
-- syllabus_coverage itself (the obvious alternative) would let any parent
-- request ?select=periods_used,updated_by from the table API -- row-level
-- security cannot hide columns -- so parents are deliberately given no access
-- to the base tables at all.
--
-- in_progress is reported as 'pending': a parent is told a chapter is covered
-- or not yet, never that a teacher has half-started it.

create table public.campus_feature_flag (
  campus_id  uuid not null references public.campus(id) on delete cascade,
  flag_key   text not null check (flag_key ~ '^[a-z][a-z0-9_]{2,63}$'),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  enabled    boolean not null default false,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  primary key (campus_id, flag_key)
);
create index idx_campus_feature_flag_tenant on public.campus_feature_flag (tenant_id);
create trigger campus_feature_flag_audit after insert or update or delete on public.campus_feature_flag
  for each row execute function app.tg_audit_row();

alter table public.campus_feature_flag enable row level security;
create policy campus_feature_flag_staff_read on public.campus_feature_flag for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

create or replace function public.set_campus_feature_flag(p_campus_id uuid, p_flag_key text, p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  select tenant_id into v_tenant from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id();
  if v_tenant is null then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin', 'principal')
     or (app.auth_role() not in ('owner', 'super_admin') and not (p_campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.campus_feature_flag (campus_id, flag_key, tenant_id, enabled, updated_by)
  values (p_campus_id, p_flag_key, v_tenant, p_enabled, (select auth.uid()))
  on conflict (campus_id, flag_key) do update set enabled = excluded.enabled, updated_by = excluded.updated_by, updated_at = now();
end;
$$;
revoke execute on function public.set_campus_feature_flag(uuid, text, boolean) from public, anon;
grant execute on function public.set_campus_feature_flag(uuid, text, boolean) to authenticated;

create or replace function app.fn_campus_flag(p_campus_id uuid, p_flag_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select enabled from public.campus_feature_flag where campus_id = p_campus_id and flag_key = p_flag_key), false);
$$;
revoke execute on function app.fn_campus_flag(uuid, text) from public, anon, authenticated;

create or replace function app.fn_parent_syllabus_rows()
returns table (
  student_id      uuid,
  subject_id      uuid,
  subject_name_en text,
  subject_name_ur text,
  unit_sequence   int,
  title           text,
  title_ur        text,
  status          text,
  completed_on    date
)
language sql
stable
security definer
set search_path = ''
as $$
  select e.student_id, sub.id, sub.name_en, sub.name_ur, u.sequence, u.title, u.title_ur,
         case when c.status = 'completed' then 'covered' else 'pending' end,
         case when c.status = 'completed' then c.completed_on end
    from public.enrolment e
    join public.class_section s on s.id = e.section_id
    join (select distinct x.class_level_id, x.session_id, x.campus_id, x.subject_id from public.syllabus_unit x) pairs
      on pairs.class_level_id = s.class_level_id and pairs.session_id = s.session_id and pairs.campus_id = s.campus_id
    join public.subject sub on sub.id = pairs.subject_id
    join public.syllabus_unit u
      on u.class_level_id = pairs.class_level_id and u.session_id = pairs.session_id and u.campus_id = pairs.campus_id and u.subject_id = pairs.subject_id
     and u.board = app.fn_section_board(s.id, pairs.subject_id)
    left join public.syllabus_coverage c on c.syllabus_unit_id = u.id and c.section_id = s.id and c.subject_id = pairs.subject_id
   where e.student_id = any (app.auth_guardian_student_ids())
     and e.status = 'active'
     and app.fn_campus_flag(s.campus_id, 'parent_syllabus_visibility');
$$;
revoke execute on function app.fn_parent_syllabus_rows() from public, anon;
grant execute on function app.fn_parent_syllabus_rows() to authenticated;

create view public.v_parent_syllabus_coverage with (security_invoker = true) as
select student_id, subject_id, subject_name_en, subject_name_ur, unit_sequence, title, title_ur, status, completed_on
  from app.fn_parent_syllabus_rows();
grant select on public.v_parent_syllabus_coverage to authenticated;

-- Lets the portal say "This information is not shared by your school"
-- instead of an ambiguous empty list.
create or replace function public.my_children_syllabus_visibility()
returns table (student_id uuid, enabled boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select e.student_id, app.fn_campus_flag(e.campus_id, 'parent_syllabus_visibility')
    from public.enrolment e
   where e.student_id = any (app.auth_guardian_student_ids()) and e.status = 'active';
$$;
revoke execute on function public.my_children_syllabus_visibility() from public, anon;
grant execute on function public.my_children_syllabus_visibility() to authenticated;
