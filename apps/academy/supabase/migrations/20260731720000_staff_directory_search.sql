-- FR-D19: searchable staff directory.
--
-- Scope cuts:
--   * The 'staff-photos' storage bucket named in the FR's own Supabase
--     Objects has no AC referencing it at all (every AC is about name,
--     campus scope, and which columns are visible to which role) — no
--     photo-upload UI exists anywhere yet to populate it, so shipping an
--     empty bucket nobody can fill would be dead infrastructure. Add it
--     alongside whichever FR actually builds staff photo upload.
--   * idx_staff_name_normalised (the FR's second named index) is just a
--     plain lower(full_name) btree — cheap, named in the spec, added
--     below for exact/prefix fallback alongside the GIN trigram index
--     that does the real fuzzy matching.
--   * search_staff() is the only supported read path for mobile/identity
--     document exposure (SECURITY DEFINER, decides column visibility
--     itself) — staff_private_contact's own RLS below is a defense-in-
--     depth boundary for a direct table read, not the primary gate.

create index idx_staff_name_trgm on public.staff using gin (full_name gin_trgm_ops);
create index idx_staff_name_ur_trgm on public.staff using gin ((coalesce(full_name_ur, '')) gin_trgm_ops);
create index idx_staff_name_normalised on public.staff (lower(full_name));

create table public.staff_private_contact (
  staff_id          uuid primary key references public.staff(id) on delete cascade,
  mobile            text,
  alt_mobile        text,
  address           text,
  emergency_contact text,
  updated_at        timestamptz not null default now()
);

alter table public.staff_private_contact enable row level security;

create policy staff_contact_privileged_read on public.staff_private_contact
  for select to authenticated
  using (
    app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager')
    and exists (
      select 1 from public.staff s
       where s.id = staff_private_contact.staff_id
         and s.tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or s.campus_id = any(app.auth_campus_ids()))
    )
  );

create policy staff_contact_self_read on public.staff_private_contact
  for select to authenticated
  using (exists (select 1 from public.staff s where s.id = staff_private_contact.staff_id and s.user_id = auth.uid()));

-- AC: <800ms trigram lookup, campus-scoped, exited staff hidden unless
-- asked for, mobile/identity document number only for privileged roles.
create or replace function public.search_staff(p_q text default null, p_include_former boolean default false)
returns table (
  staff_id                  uuid,
  employee_code             text,
  full_name                 text,
  full_name_ur              text,
  designation               text,
  department                text,
  gender                    public.gender,
  employment_status         public.employment_status,
  is_former                 boolean,
  mobile                    text,
  identity_document_number  text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_privileged boolean;
  v_q          text := nullif(trim(p_q), '');
begin
  if app.auth_role() = 'none' then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  v_privileged := app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager');

  return query
  select
    s.id,
    s.employee_code,
    s.full_name,
    s.full_name_ur,
    d.name_en,
    dep.name_en,
    s.gender,
    s.employment_status,
    (s.employment_status = 'exited'),
    case when v_privileged then pc.mobile else null end,
    case when v_privileged then coalesce(s.cnic, s.passport_no) else null end
  from public.staff s
  left join public.designation d on d.id = s.designation_id
  left join public.department dep on dep.id = s.department_id
  left join public.staff_private_contact pc on pc.staff_id = s.id
  where s.tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or s.campus_id = any(app.auth_campus_ids()))
    and (p_include_former or s.employment_status <> 'exited')
    and (
      v_q is null
      or s.employee_code = v_q
      or public.word_similarity(v_q, s.full_name) > 0.4
      or public.word_similarity(v_q, coalesce(s.full_name_ur, '')) > 0.4
    )
  order by greatest(public.word_similarity(coalesce(v_q, ''), s.full_name), public.word_similarity(coalesce(v_q, ''), coalesce(s.full_name_ur, ''))) desc, s.full_name
  limit 50;
end;
$$;

revoke execute on function public.search_staff(text, boolean) from public, anon;
grant execute on function public.search_staff(text, boolean) to authenticated;
