-- FR-A11: custom role creation.
--
-- ── What a custom role is (and is not) in this schema ────────────────────
--
-- public.app_role is a 16-value ENUM. It is what app.auth_role() reads and
-- what several hundred RLS policies and SECURITY DEFINER gates across ~145
-- migrations actually test (`app.auth_role() in ('owner', 'principal', …)`).
-- Nothing here adds enum values at runtime, and nothing here can make one of
-- those hardcoded gates recognise a name it was not written with.
--
-- So a custom role in this codebase is NOT a new kind of user. It is a
-- tenant-scoped, named bundle of permission codes that a user carries
-- *alongside* their base app_role, and it is enforced at exactly one place:
-- app.has_permission(). Concretely:
--
--   * app_user.app_role (the enum) is unchanged when a custom role is
--     assigned. It remains the user's base role and the hard ceiling on
--     everything the existing enum-gated policies allow.
--   * app.effective_permissions() resolves the holder's permission set as
--     custom_role_permissions ∩ base_system_role_permissions. The
--     intersection is the load-bearing part: a custom role can only ever
--     *narrow* what its base enum role already permits. It cannot invent a
--     capability, because a capability that the base role's enum gates deny
--     would be inert anyway — better that has_permission() says so honestly
--     than that the picker sells a permission the RLS layer will ignore.
--   * FR-A11's user story ("do not over-grant Principal access") is
--     therefore served by assigning the *narrowest* base app_role that
--     still clears the enum gates the post needs, and using the custom role
--     to subtract from there. It is not served by inventing a Coordinator
--     that the enum gates have never heard of; that is not buildable
--     against this schema without rewriting every one of those policies.
--
-- Everything FR-A10 (20260729171840_role_catalogue.sql) built is reused:
-- permission, role, role_permission, the role_id JWT claim, app.auth_role_id()
-- and app.has_permission(). FR-A10 left public.permission *empty* and noted
-- has_permission() had no callers; this migration seeds the catalogue, maps
-- every system role to it, and gives has_permission() its first callers.
--
-- ── Claims freshness (FR-A13 interaction) ────────────────────────────────
--
-- A role's permission list never rides in the JWT — only role_id does. So
-- AC3 ("edit a role to remove student.delete → the permission is gone on the
-- affected user's next request, within 60s, without logging out") needs no
-- token invalidation at all: app.has_permission() reads role_permission live
-- on every call, so a removal takes effect on the very next statement. That
-- is the "revocation epoch column" option from the FR's Notes, already paid
-- for by FR-A13 — not the "short JWT lifetime" one.
--
-- What DOES go stale is role_id itself, so assigning or clearing a custom
-- role bumps app_user.claims_version exactly like an app_role or campus
-- change already does (20260731750000_jwt_claim_epoch_and_fail_closed.sql).

-- ── 1. Permission catalogue ─────────────────────────────────────────────
-- A custom role is assembled from "the published permission catalogue"
-- (FR-A11 requirement text). FR-A10 created the table and published nothing
-- into it, which makes both the picker and the superset assertion vacuous.

insert into public.permission (code, module, label) values
  ('tenant.settings.manage',      'Foundation',   'Manage school settings'),
  ('tenant.billing.manage',       'Foundation',   'Manage subscription and billing'),
  ('role.manage',                 'Foundation',   'Create and edit roles'),
  ('campus.manage',               'Foundation',   'Manage campuses'),
  ('user.manage',                 'Foundation',   'Manage user accounts'),
  ('student.read',                'Students',     'View students'),
  ('student.create',              'Students',     'Admit students'),
  ('student.update',              'Students',     'Edit student records'),
  ('student.delete',              'Students',     'Delete students'),
  ('admission.read',              'Admissions',   'View admissions'),
  ('admission.manage',            'Admissions',   'Manage the admissions pipeline'),
  ('attendance.read',             'Attendance',   'View attendance'),
  ('attendance.mark',             'Attendance',   'Mark attendance'),
  ('attendance.correct',          'Attendance',   'Approve attendance corrections'),
  ('exam.read',                   'Exams',        'View exams and results'),
  ('exam.mark.enter',             'Exams',        'Enter marks'),
  ('exam.mark.approve',           'Exams',        'Approve marks'),
  ('exam.result.publish',         'Exams',        'Publish results'),
  ('fee.read',                    'Fees',         'View fees'),
  ('fee.collect',                 'Fees',         'Collect payments'),
  ('fee.structure.manage',        'Fees',         'Manage fee structures'),
  ('fee.concession.approve',      'Fees',         'Approve concessions'),
  ('expense.submit',              'Expenses',     'Submit expense vouchers'),
  ('expense.approve',             'Expenses',     'Approve expense vouchers'),
  ('certificate.issue',           'Certificates', 'Issue certificates'),
  ('certificate.template.manage', 'Certificates', 'Manage certificate templates'),
  ('staff.read',                  'Staff',        'View staff'),
  ('staff.manage',                'Staff',        'Manage staff records'),
  ('leave.approve',               'Staff',        'Approve leave'),
  ('homework.manage',             'Academics',    'Set and publish homework'),
  ('audit.export',                'Compliance',   'Export the audit trail');

-- System role → permission map, applied to the global template rows. It is
-- deliberately the same shape as the enum gates already scattered through
-- the migrations: this table is a description of what each app_role can
-- already do, not a new grant of anything.
--
-- 'parent' and 'student' hold nothing: the portal is gated by
-- app.auth_guardian_student_ids()/enrolment, never by has_permission().
insert into public.role_permission (role_id, permission_code)
select r.id, p.code
  from public.role r
  join lateral (
    select unnest(m.codes) as code
      from (values
        ('super_admin',        (select array_agg(code) from public.permission)),
        ('owner',              (select array_agg(code) from public.permission)),
        ('principal',          (select array_agg(code) from public.permission
                                 where code <> 'tenant.billing.manage')),
        ('vice_principal',     array['student.read','student.create','student.update',
                                     'admission.read','admission.manage',
                                     'attendance.read','attendance.correct',
                                     'exam.read','exam.mark.approve','exam.result.publish',
                                     'staff.read','leave.approve','homework.manage',
                                     'certificate.issue']),
        ('admissions_officer', array['student.read','student.create','student.update',
                                     'admission.read','admission.manage','staff.read']),
        ('accountant',         array['student.read','fee.read','fee.collect',
                                     'fee.structure.manage','fee.concession.approve',
                                     'expense.submit','expense.approve']),
        ('exam_controller',    array['student.read','attendance.read','exam.read',
                                     'exam.mark.enter','exam.mark.approve',
                                     'exam.result.publish','certificate.issue',
                                     'certificate.template.manage']),
        ('head_of_department', array['student.read','attendance.read','exam.read',
                                     'exam.mark.approve','staff.read','homework.manage']),
        ('class_teacher',      array['student.read','attendance.read','attendance.mark',
                                     'exam.read','exam.mark.enter','homework.manage']),
        ('subject_teacher',    array['student.read','attendance.read','attendance.mark',
                                     'exam.read','exam.mark.enter','homework.manage']),
        ('hr_manager',         array['staff.read','staff.manage','leave.approve','user.manage']),
        ('librarian',          array['student.read']),
        ('transport_manager',  array['student.read']),
        ('receptionist',       array['student.read','admission.read','staff.read']),
        ('parent',             array[]::text[]),
        ('student',            array[]::text[])
      ) as m(role_code, codes)
     where m.role_code = r.code
  ) p on true
 where r.tenant_id is null;

-- Tenants provisioned before this migration were seeded from templates that
-- had no permission rows, so backfill them from the (now populated)
-- templates. seed_tenant_roles() already does this for new tenants.
insert into public.role_permission (role_id, permission_code)
select tr.id, tmpl_rp.permission_code
  from public.role tr
  join public.role tmpl on tmpl.tenant_id is null and tmpl.code = tr.code
  join public.role_permission tmpl_rp on tmpl_rp.role_id = tmpl.id
 where tr.tenant_id is not null
on conflict do nothing;

-- ── 2. Schema: role code uniqueness, holder column, change log ───────────

-- FR-A11 asks for role_code_uniq on (tenant_id, lower(code)) where
-- deleted_at is null. FR-A10's index is case-sensitive and spans
-- soft-deleted rows, which would let 'coordinator' and 'Coordinator'
-- coexist and would block re-creating a role that was deleted last term.
drop index public.role_tenant_code_uniq;
create unique index role_code_uniq
  on public.role (tenant_id, lower(code))
  where deleted_at is null;

alter table public.role add column updated_at timestamptz;

-- The holder link. app_role stays exactly as it was — this is additive, and
-- deliberately so: the enum is what the existing policies gate on.
alter table public.app_user
  add column custom_role_id uuid references public.role(id);
create index app_user_custom_role_idx on public.app_user (custom_role_id)
  where custom_role_id is not null;

create table public.role_change_log (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  role_id    uuid not null references public.role(id) on delete cascade,
  changed_by uuid references auth.users(id),
  action     text not null check (action in ('create', 'update', 'delete', 'reassign')),
  added      jsonb not null default '[]'::jsonb,
  removed    jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

create index role_change_log_role_idx on public.role_change_log (role_id, created_at desc);
create index role_change_log_tenant_idx on public.role_change_log (tenant_id, created_at desc);

-- A custom_role_id must point at a live, non-system role in the same tenant.
-- app_user has no UPDATE policy for `authenticated` (foundation.sql ships
-- SELECT only), so every legitimate write already comes through the
-- SECURITY DEFINER functions below — this trigger is the backstop for the
-- service_role paths that bypass them.
create or replace function app.tg_validate_custom_role()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.custom_role_id is null then
    return new;
  end if;

  if not exists (
    select 1 from public.role r
     where r.id = new.custom_role_id
       and r.tenant_id = new.tenant_id
       and not r.is_system
       and r.deleted_at is null
  ) then
    raise exception 'ROLE_NOT_FOUND' using errcode = '23503';
  end if;

  return new;
end;
$$;

create trigger app_user_validate_custom_role
  before insert or update of custom_role_id, tenant_id on public.app_user
  for each row execute function app.tg_validate_custom_role();

-- ── 3. Claims: role_id follows the custom role; assignment bumps the epoch ─

-- FR-A13's bump trigger covered app_role and status. custom_role_id changes
-- the role_id claim exactly as much as an app_role change does, so it has to
-- bump the same epoch or a reassigned user keeps their old permission bundle
-- until their token happens to expire.
create or replace function app.tg_bump_claims_version()
returns trigger
language plpgsql
as $$
begin
  if new.app_role is distinct from old.app_role
     or new.status is distinct from old.status
     or new.custom_role_id is distinct from old.custom_role_id then
    new.claims_version := old.claims_version + 1;
  end if;
  return new;
end;
$$;

drop trigger app_user_bump_claims_version on public.app_user;
create trigger app_user_bump_claims_version
  before update of app_role, status, custom_role_id on public.app_user
  for each row execute function app.tg_bump_claims_version();

-- Hook: role_id now prefers the assigned custom role, falling back to the
-- system role for the user's app_role. Body is otherwise byte-identical to
-- 20260731750000_jwt_claim_epoch_and_fail_closed.sql.
create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  claims  jsonb := coalesce(event -> 'claims', '{}'::jsonb);
  u       record;
  gu      record;
begin
  select au.tenant_id,
         au.app_role::text as app_role,
         au.claims_version,
         coalesce(
           (select array_agg(uc.campus_id)
              from public.user_campus uc
             where uc.user_id = au.user_id and uc.is_active),
           '{}'::uuid[]
         ) as campus_ids,
         (select s.id
            from public.academic_session s
           where s.tenant_id = au.tenant_id and s.is_current
           limit 1) as academic_session_id,
         coalesce(
           (select cr.id
              from public.role cr
             where cr.id = au.custom_role_id and cr.deleted_at is null),
           (select r.id
              from public.role r
             where r.tenant_id = au.tenant_id and r.code = au.app_role::text and r.deleted_at is null
             limit 1)
         ) as role_id
    into u
    from public.app_user au
   where au.user_id = (event ->> 'user_id')::uuid
     and au.status = 'active';

  if found then
    claims := claims || jsonb_build_object(
      'tenant_id',           u.tenant_id,
      'campus_ids',          to_jsonb(u.campus_ids),
      'app_role',            u.app_role,
      'academic_session_id', u.academic_session_id,
      'role_id',             u.role_id,
      'cv',                  u.claims_version
    );
    return jsonb_set(event, '{claims}', claims);
  end if;

  select g.tenant_id,
         coalesce(
           (select array_agg(distinct e.campus_id)
              from public.student_guardian sg
              join public.enrolment e on e.student_id = sg.student_id and e.status = 'active'
             where sg.guardian_id = g.id and sg.to_date is null),
           '{}'::uuid[]
         ) as campus_ids
    into gu
    from public.guardian g
   where g.auth_user_id = (event ->> 'user_id')::uuid;

  if found then
    claims := claims || jsonb_build_object(
      'tenant_id',  gu.tenant_id,
      'campus_ids', to_jsonb(gu.campus_ids),
      'app_role',   'parent',
      'cv',         1
    );
    return jsonb_set(event, '{claims}', claims);
  end if;

  return jsonb_set(event, '{claims}',
    claims || jsonb_build_object('tenant_id', null, 'app_role', 'none', 'cv', 0));
exception
  when others then
    return jsonb_build_object(
      'error', jsonb_build_object(
        'http_code', 500,
        'message', 'AUTH_CLAIMS_UNAVAILABLE'
      )
    );
end;
$$;

grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;

-- ── 4. Effective permissions ────────────────────────────────────────────
--
-- SECURITY DEFINER for the same reason app.assert_claims_fresh() is: it is
-- called from role/role_permission's own RLS policies, and an invoker-rights
-- read of those tables from inside their own policy recurses. Visibility is
-- filtered explicitly — by the caller's own role_id and tenant_id claims,
-- never by "whatever the definer can see".

create or replace function app.role_permission_codes(p_role_id uuid)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(permission_code order by permission_code), '{}')
    from public.role_permission
   where role_id = p_role_id;
$$;

create or replace function app.effective_permissions()
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  -- custom bundle ∩ base system role. When role_id already IS the base
  -- system role (the no-custom-role case) the intersection is a no-op, so
  -- there is one code path rather than two.
  select coalesce(array_agg(code order by code), '{}')
    from (
      select unnest(app.role_permission_codes(app.auth_role_id())) as code
      intersect
      select unnest(app.role_permission_codes((
        select r.id
          from public.role r
         where r.tenant_id = app.auth_tenant_id()
           and r.code = app.auth_role()
           and r.is_system
           and r.deleted_at is null
         limit 1
      ))) as code
    ) t;
$$;

-- Unchanged signature, new body: reads through effective_permissions() so
-- the ∩ base-role rule applies everywhere, not just in the new RPCs.
create or replace function app.has_permission(p_code text)
returns boolean
language sql
stable
as $$
  select p_code = any (app.effective_permissions());
$$;

grant execute on function app.role_permission_codes(uuid) to authenticated;
grant execute on function app.effective_permissions() to authenticated;
grant execute on function app.has_permission(text) to authenticated;

-- PostgREST only exposes `public`, and the UI needs the caller's own set to
-- build the permission picker out of exactly what they may grant.
create or replace function public.my_effective_permissions()
returns text[]
language sql
stable
as $$
  select app.effective_permissions();
$$;

revoke execute on function public.my_effective_permissions() from public, anon;
grant execute on function public.my_effective_permissions() to authenticated;

-- ── 5. Custom role RPCs ─────────────────────────────────────────────────

create or replace function app.role_code_from_name(p_name text)
returns text
language sql
immutable
as $$
  select trim(both '_' from regexp_replace(lower(trim(p_name)), '[^a-z0-9]+', '_', 'g'));
$$;

-- The superset assertion. Evaluated server-side against the caller's live
-- effective permissions at execution time, per the FR's Notes — the picker
-- filtering the list is a convenience, not the control.
create or replace function app.assert_permission_superset(p_codes text[])
returns void
language plpgsql
stable
as $$
declare
  v_missing text[];
begin
  select array_agg(c order by c) into v_missing
    from unnest(coalesce(p_codes, '{}')) as c
   where not (c = any (app.effective_permissions()));

  if v_missing is not null then
    raise exception 'PERMISSION_ESCALATION'
      using errcode = '42501', detail = array_to_string(v_missing, ',');
  end if;
end;
$$;

grant execute on function app.assert_permission_superset(text[]) to authenticated;

create or replace function app.assert_custom_role_writable(p_role_id uuid)
returns public.role
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role public.role;
begin
  select * into v_role
    from public.role
   where id = p_role_id
     and tenant_id = app.auth_tenant_id()
     and deleted_at is null;

  if not found then
    raise exception 'ROLE_NOT_FOUND' using errcode = '42501';
  end if;

  if v_role.is_system then
    raise exception 'ROLE_IMMUTABLE' using errcode = '42501';
  end if;

  return v_role;
end;
$$;

create or replace function public.create_custom_role(
  p_name             text,
  p_permission_codes text[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_code      text := app.role_code_from_name(p_name);
  v_codes     text[] := coalesce(p_permission_codes, '{}');
  v_unknown   text[];
  v_role_id   uuid;
begin
  if v_tenant_id is null or not app.has_permission('role.manage') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if v_code is null or length(v_code) < 2 or length(trim(p_name)) > 60 then
    raise exception 'ROLE_NAME_INVALID' using errcode = '22023';
  end if;

  -- A custom role whose code collides with an app_role value would shadow
  -- the system role the JWT hook falls back to.
  if v_code = any (select e::text from unnest(enum_range(null::public.app_role)) as e) then
    raise exception 'ROLE_CODE_RESERVED' using errcode = '23505';
  end if;

  select array_agg(c order by c) into v_unknown
    from unnest(v_codes) as c
   where not exists (select 1 from public.permission p where p.code = c);

  if v_unknown is not null then
    raise exception 'PERMISSION_UNKNOWN'
      using errcode = '23503', detail = array_to_string(v_unknown, ',');
  end if;

  perform app.assert_permission_superset(v_codes);

  if exists (
    select 1 from public.role
     where tenant_id = v_tenant_id and lower(code) = v_code and deleted_at is null
  ) then
    raise exception 'ROLE_CODE_TAKEN' using errcode = '23505';
  end if;

  insert into public.role (tenant_id, code, name, is_system)
  values (v_tenant_id, v_code, trim(p_name), false)
  returning id into v_role_id;

  insert into public.role_permission (role_id, permission_code)
  select v_role_id, c from unnest(v_codes) as c;

  insert into public.role_change_log (tenant_id, role_id, changed_by, action, added)
  values (v_tenant_id, v_role_id, (select auth.uid()), 'create', to_jsonb(v_codes));

  return v_role_id;
end;
$$;

create or replace function public.update_custom_role(
  p_role_id          uuid,
  p_name             text,
  p_permission_codes text[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role    public.role;
  v_codes   text[] := coalesce(p_permission_codes, '{}');
  v_current text[];
  v_added   text[];
  v_removed text[];
begin
  if not app.has_permission('role.manage') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  v_role := app.assert_custom_role_writable(p_role_id);

  -- The whole target set, not just the additions: asserting only on the
  -- delta would let a caller keep a permission an earlier, more privileged
  -- editor put there while adding nothing themselves.
  perform app.assert_permission_superset(v_codes);

  v_current := app.role_permission_codes(p_role_id);

  select array_agg(c order by c) into v_added
    from unnest(v_codes) as c where not (c = any (v_current));
  select array_agg(c order by c) into v_removed
    from unnest(v_current) as c where not (c = any (v_codes));

  delete from public.role_permission
   where role_id = p_role_id and not (permission_code = any (v_codes));

  insert into public.role_permission (role_id, permission_code)
  select p_role_id, c from unnest(v_codes) as c
  on conflict do nothing;

  if p_name is not null and trim(p_name) <> '' and trim(p_name) <> v_role.name then
    if length(trim(p_name)) > 60 then
      raise exception 'ROLE_NAME_INVALID' using errcode = '22023';
    end if;
    update public.role set name = trim(p_name), updated_at = now() where id = p_role_id;
  else
    update public.role set updated_at = now() where id = p_role_id;
  end if;

  insert into public.role_change_log (tenant_id, role_id, changed_by, action, added, removed)
  values (
    v_role.tenant_id, p_role_id, (select auth.uid()), 'update',
    to_jsonb(coalesce(v_added, '{}'::text[])),
    to_jsonb(coalesce(v_removed, '{}'::text[]))
  );
end;
$$;

-- Holder count, for the "ROLE_IN_USE listing 7" message and for the UI's
-- reassignment prompt.
create or replace function public.custom_role_holder_count(p_role_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int
    from public.app_user au
   where au.custom_role_id = p_role_id
     and au.tenant_id = app.auth_tenant_id();
$$;

-- p_to_role_id defaults to null (= back to the base app_role) from the
-- outset: adding the default later would create a distinct overload.
create or replace function public.reassign_role_holders(
  p_from_role_id uuid,
  p_to_role_id   uuid default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from  public.role;
  v_count integer;
begin
  if not app.has_permission('role.manage') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  v_from := app.assert_custom_role_writable(p_from_role_id);

  -- p_to_role_id null puts holders back on their base app_role. A non-null
  -- target is superset-checked too: bulk-moving people onto a richer role
  -- than the caller holds is the same escalation as creating one.
  if p_to_role_id is not null then
    perform app.assert_custom_role_writable(p_to_role_id);
    perform app.assert_permission_superset(app.role_permission_codes(p_to_role_id));
  end if;

  update public.app_user
     set custom_role_id = p_to_role_id
   where custom_role_id = p_from_role_id
     and tenant_id = v_from.tenant_id;

  get diagnostics v_count = row_count;

  insert into public.role_change_log (tenant_id, role_id, changed_by, action)
  values (v_from.tenant_id, p_from_role_id, (select auth.uid()), 'reassign');

  return v_count;
end;
$$;

create or replace function public.delete_custom_role(p_role_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role  public.role;
  v_count integer;
begin
  if not app.has_permission('role.manage') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  v_role := app.assert_custom_role_writable(p_role_id);

  select count(*)::int into v_count
    from public.app_user
   where custom_role_id = p_role_id and tenant_id = v_role.tenant_id;

  if v_count > 0 then
    raise exception 'ROLE_IN_USE'
      using errcode = '42501',
            detail = v_count::text,
            hint = 'Reassign the ' || v_count || ' holder(s) to another role first.';
  end if;

  update public.role set deleted_at = now() where id = p_role_id;

  insert into public.role_change_log (tenant_id, role_id, changed_by, action, removed)
  values (
    v_role.tenant_id, p_role_id, (select auth.uid()), 'delete',
    to_jsonb(app.role_permission_codes(p_role_id))
  );
end;
$$;

create or replace function public.assign_custom_role(
  p_user_id uuid,
  p_role_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  if v_tenant_id is null or not app.has_permission('role.manage') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_role_id is not null then
    perform app.assert_custom_role_writable(p_role_id);
    perform app.assert_permission_superset(app.role_permission_codes(p_role_id));
  end if;

  update public.app_user
     set custom_role_id = p_role_id
   where user_id = p_user_id
     and tenant_id = v_tenant_id;

  if not found then
    raise exception 'USER_NOT_FOUND' using errcode = '42501';
  end if;
end;
$$;

revoke execute on function public.create_custom_role(text, text[]) from public, anon;
revoke execute on function public.update_custom_role(uuid, text, text[]) from public, anon;
revoke execute on function public.delete_custom_role(uuid) from public, anon;
revoke execute on function public.assign_custom_role(uuid, uuid) from public, anon;
revoke execute on function public.reassign_role_holders(uuid, uuid) from public, anon;
revoke execute on function public.custom_role_holder_count(uuid) from public, anon;
grant execute on function public.create_custom_role(text, text[]) to authenticated;
grant execute on function public.update_custom_role(uuid, text, text[]) to authenticated;
grant execute on function public.delete_custom_role(uuid) to authenticated;
grant execute on function public.assign_custom_role(uuid, uuid) to authenticated;
grant execute on function public.reassign_role_holders(uuid, uuid) to authenticated;
grant execute on function public.custom_role_holder_count(uuid) to authenticated;

-- ── 6. RLS ──────────────────────────────────────────────────────────────

alter table public.role_change_log enable row level security;

-- FR-A11's role_write_requires_role_manage. The RPCs above are the intended
-- path (they carry the superset assertion); this is what stops a direct
-- PostgREST write from skipping it. is_system is excluded here as well as by
-- role_block_system_write, and template rows (tenant_id null) are never
-- writable because tenant_id = app.auth_tenant_id() is false for them.
create policy role_write_requires_role_manage on public.role
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and not is_system
    and app.has_permission('role.manage')
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and not is_system
    and app.has_permission('role.manage')
  );

create policy role_permission_write_requires_role_manage on public.role_permission
  for all to authenticated
  using (
    app.has_permission('role.manage')
    and role_id in (
      select id from public.role
       where tenant_id = app.auth_tenant_id() and not is_system
    )
  )
  with check (
    app.has_permission('role.manage')
    and role_id in (
      select id from public.role
       where tenant_id = app.auth_tenant_id() and not is_system
    )
  );

-- Read-only to the tenant's role managers; every write goes through the
-- SECURITY DEFINER functions, so there is no INSERT policy on purpose.
create policy role_change_log_read on public.role_change_log
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.has_permission('role.manage'));
