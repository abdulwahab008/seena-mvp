-- FR-O03: role-based borrowing limits and periods.
--
-- One row per (campus or school-wide, borrower role, optional class band, effective_from).
-- resolve_borrower_policy() picks, for a borrower on a given date, the row in force:
--   1. a class-band row beats a role-wide row (a Nursery child never inherits the six-book,
--      30-day teacher-style limit); the band is a range of class_level.ordinal;
--   2. a campus-specific row beats a school-wide row;
--   3. the latest effective_from on or before the date wins, so a rate change takes effect on its
--      date and never rewrites the past.
--
-- The resolved row is SNAPSHOT onto each loan as jsonb at issue (FR-O04). Fines are computed from
-- that snapshot, never from today's policy: re-pricing a historic loan when a rate changes would
-- leave the fine register disagreeing with receipts already printed and signed.
--
-- Borrower roles are 'student', 'teacher' (class_teacher, subject_teacher, head_of_department) and
-- 'staff' (every other staff role). Money is bigint paisa. Only principal / super_admin / owner can
-- write the table (RLS); everyone in the campus can read it, so the portal can show the rules.

create table public.library_borrower_policy (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenant(id) on delete cascade,
  campus_id             uuid references public.campus(id) on delete cascade,
  role                  text not null check (role in ('student', 'teacher', 'staff')),
  class_band_from       smallint,
  class_band_to         smallint,
  max_loans             int not null check (max_loans between 0 and 100),
  loan_days             int not null check (loan_days between 1 and 365),
  max_renewals          int not null default 0 check (max_renewals between 0 and 20),
  fine_per_day          bigint not null default 0 check (fine_per_day >= 0),
  fine_cap              bigint check (fine_cap is null or fine_cap >= 0),
  block_threshold       bigint check (block_threshold is null or block_threshold >= 0),
  count_working_days_only boolean not null default false,
  effective_from        date not null,
  created_by            uuid references public.app_user(user_id),
  created_at            timestamptz not null default now(),
  constraint chk_policy_band check ((class_band_from is null) = (class_band_to is null) and (class_band_from is null or class_band_from <= class_band_to)),
  constraint chk_policy_band_students check (class_band_from is null or role = 'student')
);

create unique index uq_library_policy_slot on public.library_borrower_policy (
  tenant_id, coalesce(campus_id, '00000000-0000-0000-0000-000000000000'::uuid), role,
  coalesce(class_band_from, -1), coalesce(class_band_to, -1), effective_from
);
create index idx_policy_lookup on public.library_borrower_policy (tenant_id, campus_id, role, effective_from desc);

create trigger library_borrower_policy_audit after insert or update or delete on public.library_borrower_policy
  for each row execute function app.tg_audit_row();

alter table public.library_borrower_policy enable row level security;
create policy library_policy_campus_read on public.library_borrower_policy for select to authenticated
  using (tenant_id = app.auth_tenant_id() and (campus_id is null or app.fn_library_campus_ok(campus_id)));
create policy library_policy_admin_write on public.library_borrower_policy for insert to authenticated
  with check (tenant_id = app.auth_tenant_id() and app.auth_role() in ('principal', 'super_admin', 'owner') and (campus_id is null or app.fn_library_campus_ok(campus_id)));
create policy library_policy_admin_update on public.library_borrower_policy for update to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('principal', 'super_admin', 'owner') and (campus_id is null or app.fn_library_campus_ok(campus_id)))
  with check (tenant_id = app.auth_tenant_id() and app.auth_role() in ('principal', 'super_admin', 'owner') and (campus_id is null or app.fn_library_campus_ok(campus_id)));
create policy library_policy_admin_delete on public.library_borrower_policy for delete to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('principal', 'super_admin', 'owner') and (campus_id is null or app.fn_library_campus_ok(campus_id)));

-- ── who is this borrower? ────────────────────────────────────────────────────
-- A borrower is a student (student.id) or a staff member (app_user.user_id).

create or replace function app.fn_library_borrower(p_borrower_id uuid)
returns table (borrower_role text, campus_id uuid, class_ordinal smallint, display_name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_s public.student%rowtype;
  v_u public.app_user%rowtype;
begin
  select * into v_s from public.student where id = p_borrower_id and tenant_id = app.auth_tenant_id();
  if found then
    return query
      select 'student'::text, v_s.campus_id,
             (select cl.ordinal from public.enrolment e join public.class_level cl on cl.id = e.class_level_id
               where e.student_id = v_s.id and e.status = 'active' order by e.joined_on desc, e.created_at desc limit 1),
             v_s.name_en;
    return;
  end if;
  select * into v_u from public.app_user where user_id = p_borrower_id and tenant_id = app.auth_tenant_id() and status = 'active';
  if found then
    return query
      select case when v_u.app_role in ('class_teacher', 'subject_teacher', 'head_of_department') then 'teacher' else 'staff' end,
             (select uc.campus_id from public.user_campus uc where uc.user_id = v_u.user_id and uc.is_active order by uc.campus_id limit 1),
             null::smallint, v_u.full_name;
  end if;
end;
$$;
revoke execute on function app.fn_library_borrower(uuid) from public, anon, authenticated;

-- ── resolution ───────────────────────────────────────────────────────────────

create or replace function public.resolve_borrower_policy(p_borrower_id uuid, p_at timestamptz default now(), p_campus_id uuid default null)
returns public.library_borrower_policy
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_b   record;
  v_pol public.library_borrower_policy%rowtype;
  v_day date := (p_at at time zone 'Asia/Karachi')::date;
begin
  select * into v_b from app.fn_library_borrower(p_borrower_id);
  if v_b.borrower_role is null then
    return v_pol;
  end if;
  select p.* into v_pol
    from public.library_borrower_policy p
   where p.tenant_id = app.auth_tenant_id()
     and p.role = v_b.borrower_role
     and p.effective_from <= v_day
     and (p.campus_id is null or p.campus_id = coalesce(p_campus_id, v_b.campus_id))
     and (p.class_band_from is null or (v_b.class_ordinal is not null and v_b.class_ordinal between p.class_band_from and p.class_band_to))
   order by (p.class_band_from is not null) desc, (p.campus_id is not null) desc, p.effective_from desc, p.created_at desc
   limit 1;
  return v_pol;
end;
$$;
revoke execute on function public.resolve_borrower_policy(uuid, timestamptz, uuid) from public, anon;
grant execute on function public.resolve_borrower_policy(uuid, timestamptz, uuid) to authenticated;

-- ── write path used by the UI ────────────────────────────────────────────────
-- Re-saving the same slot and date updates it; a new effective_from adds a new row, which is how a
-- rate change is dated.

create or replace function public.set_borrower_policy(
  p_role text, p_max_loans int, p_loan_days int, p_max_renewals int, p_fine_per_day bigint, p_effective_from date,
  p_campus_id uuid default null, p_class_band_from smallint default null, p_class_band_to smallint default null,
  p_fine_cap bigint default null, p_block_threshold bigint default null, p_count_working_days_only boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('principal', 'super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_campus_id is not null and (not app.fn_library_campus_ok(p_campus_id) or not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id())) then
    raise exception 'CAMPUS_NOT_ALLOWED' using errcode = '42501';
  end if;
  if p_role not in ('student', 'teacher', 'staff') then
    raise exception 'POLICY_INVALID' using errcode = '22023';
  end if;
  if (p_class_band_from is null) <> (p_class_band_to is null) or (p_class_band_from is not null and (p_class_band_from > p_class_band_to or p_role <> 'student')) then
    raise exception 'POLICY_BAND_INVALID' using errcode = '22023';
  end if;
  if p_effective_from is null then
    raise exception 'POLICY_INVALID' using errcode = '22023';
  end if;

  insert into public.library_borrower_policy (
    tenant_id, campus_id, role, class_band_from, class_band_to, max_loans, loan_days, max_renewals,
    fine_per_day, fine_cap, block_threshold, count_working_days_only, effective_from, created_by
  ) values (
    app.auth_tenant_id(), p_campus_id, p_role, p_class_band_from, p_class_band_to, p_max_loans, p_loan_days, p_max_renewals,
    p_fine_per_day, p_fine_cap, p_block_threshold, coalesce(p_count_working_days_only, false), p_effective_from, (select auth.uid())
  )
  on conflict (tenant_id, coalesce(campus_id, '00000000-0000-0000-0000-000000000000'::uuid), role, coalesce(class_band_from, -1), coalesce(class_band_to, -1), effective_from)
  do update set max_loans = excluded.max_loans, loan_days = excluded.loan_days, max_renewals = excluded.max_renewals,
                fine_per_day = excluded.fine_per_day, fine_cap = excluded.fine_cap, block_threshold = excluded.block_threshold,
                count_working_days_only = excluded.count_working_days_only
  returning id into v_id;
  return v_id;
exception when check_violation then
  raise exception 'POLICY_INVALID' using errcode = '22023';
end;
$$;
revoke execute on function public.set_borrower_policy(text, int, int, int, bigint, date, uuid, smallint, smallint, bigint, bigint, boolean) from public, anon;
grant execute on function public.set_borrower_policy(text, int, int, int, bigint, date, uuid, smallint, smallint, bigint, bigint, boolean) to authenticated;
