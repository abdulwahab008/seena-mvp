-- Bugfix, latent since FR-A14: app.tg_audit_row() had no path for a
-- legitimately tenant-less row. It was never exercised because the only
-- prior tenant_id=null write (role_catalogue.sql's global-template insert)
-- ran BEFORE audit_log_hardening.sql attached the trigger to `role` — the
-- backfill insert below is the first tenant_id=null write to happen after
-- the trigger exists, and it surfaced the gap immediately.
-- `create or replace` on the existing function, not an edit to the
-- already-shipped FR-A14 migration file.
create or replace function app.tg_audit_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_row_id    uuid;
  v_changed   text[];
  v_before    jsonb;
  v_after     jsonb;
  v_redacted  text[];
begin
  v_tenant_id := coalesce(
    (to_jsonb(new)->>'tenant_id')::uuid,
    (to_jsonb(old)->>'tenant_id')::uuid,
    -- tenant itself has no tenant_id column — its own id is the scope.
    case when tg_table_name = 'tenant' then coalesce((to_jsonb(new)->>'id')::uuid, (to_jsonb(old)->>'id')::uuid) end
  );

  -- A row that is legitimately tenant-less (e.g. a global role template,
  -- tenant_id IS NULL by design) has nothing to attribute a tenant-scoped
  -- audit row to. Skip logging rather than violate audit_log's NOT NULL
  -- constraint — this is platform-level reference data, not tenant data.
  if v_tenant_id is null and tg_table_name <> 'tenant' then
    return coalesce(new, old);
  end if;

  -- app_user's primary key is user_id, not id — fall back to it generically
  -- rather than special-casing the table name.
  v_row_id := coalesce(
    (to_jsonb(new)->>'id')::uuid, (to_jsonb(old)->>'id')::uuid,
    (to_jsonb(new)->>'user_id')::uuid, (to_jsonb(old)->>'user_id')::uuid
  );

  if tg_op = 'UPDATE' then
    select array_agg(key) into v_changed
      from jsonb_each(to_jsonb(new))
     where to_jsonb(new)->key is distinct from to_jsonb(old)->key;
  end if;

  select array_agg(column_name) into v_redacted
    from public.audit_redacted_column where table_name = tg_table_name;

  v_before := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end;
  v_after  := case when tg_op in ('UPDATE', 'INSERT') then to_jsonb(new) else null end;

  if v_redacted is not null then
    if v_before is not null then
      select jsonb_object_agg(t.k, case when t.k = any(v_redacted) then to_jsonb('[redacted]'::text) else t.v end)
        into v_before from jsonb_each(v_before) as t(k, v);
    end if;
    if v_after is not null then
      select jsonb_object_agg(t.k, case when t.k = any(v_redacted) then to_jsonb('[redacted]'::text) else t.v end)
        into v_after from jsonb_each(v_after) as t(k, v);
    end if;
  end if;

  insert into public.audit_log (
    tenant_id, actor_user_id, actor_role, action, table_name, row_id,
    before, after, changed_columns
  ) values (
    v_tenant_id,
    (select auth.uid()),
    nullif(app.auth_role(), 'none')::public.app_role,
    lower(tg_op)::public.audit_action,
    tg_table_name,
    v_row_id,
    v_before,
    v_after,
    v_changed
  );

  return coalesce(new, old);
end;
$$;

-- Backfill: FR-A10's role_catalogue migration seeded one global template
-- role per app_role enum value at THAT migration's apply time (16 values,
-- before 'nurse' existed) — it doesn't re-run when the enum later gains a
-- value, so the new value needs its own catch-up row here.
insert into public.role (tenant_id, code, name, is_system)
select null, e.role_code::text, initcap(replace(e.role_code::text, '_', ' ')), true
  from unnest(enum_range(null::public.app_role)) as e(role_code)
 where not exists (select 1 from public.role r where r.tenant_id is null and r.code = e.role_code::text);

-- FR-C05: medical and disability data, restrictively.
--
-- Design choices, not oversights:
--   * student_medical is its own table, not columns on student — so the
--     ordinary student SELECT policy (any campus-scoped staff) stays
--     simple and broad without ever being able to leak a health field.
--   * student_medical has NO SELECT policy for authenticated at all —
--     "restricting in the UI only is not sufficient" (the FR's own
--     words), so even a well-behaved client asking PostgREST directly for
--     this table gets zero rows. The only read path is
--     fn_get_student_medical(), which authorizes AND logs to
--     phi_access_log in the same call — RLS alone can't log a read as a
--     side effect, which is exactly why this one table breaks from the
--     "RLS read policy + SECURITY DEFINER write function" pattern used
--     everywhere else in this schema and gates reads through a function
--     too.
--   * No generic app.tg_audit_row() trigger here, unlike every other
--     table: that trigger stores full before/after JSONB in audit_log,
--     which is readable by any Owner/Principal/Super Admin — a second,
--     less-carefully-scoped copy of the same PHI (missing the "current
--     class teacher" and "nurse" read paths' precision). updated_by/
--     updated_at plus phi_access_log is the accountability trail instead.

create type public.disability_type as enum (
  'none', 'visual_impairment', 'hearing_impairment', 'physical_disability',
  'learning_disability', 'speech_impairment', 'autism_spectrum', 'other'
);

create table public.student_medical (
  student_id              uuid primary key references public.student(id) on delete cascade,
  tenant_id               uuid not null references public.tenant(id) on delete cascade,
  campus_id               uuid not null references public.campus(id) on delete cascade,
  allergies               text[] not null default '{}',
  conditions              text[] not null default '{}',
  medications             text[] not null default '{}',
  disability_type         public.disability_type not null default 'none',
  has_critical_allergy    boolean not null default false,
  accommodations          jsonb not null default '{}'::jsonb,
  emergency_contact_name  text,
  emergency_contact_phone text,
  updated_at              timestamptz not null default now(),
  updated_by              uuid references public.app_user(user_id)
);

create table public.phi_access_log (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null references public.student(id) on delete cascade,
  accessed_by uuid references public.app_user(user_id),
  accessed_at timestamptz not null default now()
);

create index idx_phi_access_log_student on public.phi_access_log (student_id, accessed_at desc);

create or replace function public.fn_upsert_student_medical(
  p_student_id             uuid,
  p_allergies              text[] default '{}',
  p_conditions             text[] default '{}',
  p_medications            text[] default '{}',
  p_disability_type        public.disability_type default 'none',
  p_has_critical_allergy   boolean default false,
  p_accommodations         jsonb default '{}'::jsonb,
  p_emergency_contact_name text default null,
  p_emergency_contact_phone text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student public.student%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'nurse') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_student from public.student where id = p_student_id;
  if not found or v_student.tenant_id <> app.auth_tenant_id() then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.student_medical (
    student_id, tenant_id, campus_id, allergies, conditions, medications, disability_type,
    has_critical_allergy, accommodations, emergency_contact_name, emergency_contact_phone, updated_by
  ) values (
    p_student_id, v_student.tenant_id, v_student.campus_id, p_allergies, p_conditions, p_medications, p_disability_type,
    p_has_critical_allergy, p_accommodations, p_emergency_contact_name, p_emergency_contact_phone, auth.uid()
  )
  on conflict (student_id) do update set
    allergies = excluded.allergies,
    conditions = excluded.conditions,
    medications = excluded.medications,
    disability_type = excluded.disability_type,
    has_critical_allergy = excluded.has_critical_allergy,
    accommodations = excluded.accommodations,
    emergency_contact_name = excluded.emergency_contact_name,
    emergency_contact_phone = excluded.emergency_contact_phone,
    updated_at = now(),
    updated_by = auth.uid();
end;
$$;

revoke execute on function public.fn_upsert_student_medical(
  uuid, text[], text[], text[], public.disability_type, boolean, jsonb, text, text
) from public, anon;
grant execute on function public.fn_upsert_student_medical(
  uuid, text[], text[], text[], public.disability_type, boolean, jsonb, text, text
) to authenticated;

create or replace function public.fn_get_student_medical(p_student_id uuid)
returns public.student_medical
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student    public.student%rowtype;
  v_result     public.student_medical%rowtype;
  v_authorized boolean := false;
begin
  select * into v_student from public.student where id = p_student_id;
  if not found or v_student.tenant_id <> app.auth_tenant_id() then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_role() in ('super_admin', 'owner', 'principal', 'nurse') then
    v_authorized := true;
  elsif app.auth_role() = 'class_teacher' then
    -- "current" class teacher only: the allocation range from FR-E08 must
    -- cover today, not just any allocation that ever existed.
    v_authorized := exists (
      select 1 from public.enrolment e
        join public.section_class_teacher sct on sct.section_id = e.section_id
       where e.student_id = p_student_id and e.status = 'active'
         and sct.staff_id = auth.uid() and sct.validity @> current_date
    );
  elsif app.auth_role() = 'parent' then
    v_authorized := exists (
      select 1 from public.student_guardian sg
        join public.guardian g on g.id = sg.guardian_id
       where sg.student_id = p_student_id and sg.to_date is null and g.auth_user_id = auth.uid()
    );
  end if;

  if not v_authorized then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.phi_access_log (student_id, accessed_by) values (p_student_id, auth.uid());

  select * into v_result from public.student_medical where student_id = p_student_id;
  return v_result;
end;
$$;

revoke execute on function public.fn_get_student_medical(uuid) from public, anon;
grant execute on function public.fn_get_student_medical(uuid) to authenticated;

-- The "red badge, no detail" surface: broadly readable by any campus-
-- scoped staff (e.g. a subject teacher marking attendance), unlike
-- fn_get_student_medical's much narrower authorization — safe only
-- because it returns nothing but a boolean, never the underlying detail.
create or replace function public.fn_student_medical_flags(p_campus_id uuid default null)
returns table(student_id uuid, has_critical_allergy boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select sm.student_id, sm.has_critical_allergy
    from public.student_medical sm
    join public.student s on s.id = sm.student_id
   where s.tenant_id = app.auth_tenant_id()
     and (app.auth_role() in ('super_admin', 'owner') or s.campus_id = any(app.auth_campus_ids()))
     and (p_campus_id is null or s.campus_id = p_campus_id);
$$;

revoke execute on function public.fn_student_medical_flags(uuid) from public, anon;
grant execute on function public.fn_student_medical_flags(uuid) to authenticated;

alter table public.student_medical enable row level security;
alter table public.phi_access_log enable row level security;

-- Deliberately no SELECT policy on student_medical for authenticated —
-- see the migration header. phi_access_log gets a narrow read policy so
-- Principal/Owner can audit who has looked at a record.
create policy phi_access_log_read_principal_or_owner on public.phi_access_log
  for select to authenticated
  using (
    app.auth_role() in ('super_admin', 'owner', 'principal')
    and student_id in (select id from public.student where tenant_id = app.auth_tenant_id())
  );
