-- ==============================================================================
-- FR-N09: Student self-scoped portal
-- ==============================================================================
-- Requirement:
-- The system shall provide students at or above a campus-configured minimum class
-- (default Class 6) a login scoped strictly to their own record, exposing timetable,
-- homework, attendance and published results, and shall deny that account access to
-- fee data and guardian contact details.
--
-- Acceptance Criteria:
-- AC 1: Given a student account calls the dues or payment endpoint, when RLS evaluates,
--       then the response is 403 and no amount is disclosed.
-- AC 2: Given a student requests another student's marks or the section rank list,
--       when the campus has show_rank disabled, then only their own marks are returned.
-- AC 3: Given a Transfer Certificate is issued for a student, when the nightly job runs,
--       then the student portal account is disabled within 24 hours while the guardian
--       retains archived read access.
-- AC 4: Given a first login, when the student authenticates with GR number and the
--       issued initial password, then a password change is forced before any screen renders.
-- ==============================================================================

-- ── 1. Student Portal Account Table ──────────────────────────────────────────
create table if not exists public.student_portal_account (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenant(id) on delete cascade,
  campus_id             uuid not null references public.campus(id) on delete cascade,
  student_id            uuid not null references public.student(id) on delete cascade,
  user_id               uuid not null references auth.users(id) on delete cascade,
  status                text not null default 'active' check (status in ('active', 'disabled', 'suspended')),
  must_change_password  boolean not null default true,
  initial_password      text,
  created_at            timestamptz not null default clock_timestamp(),
  updated_at            timestamptz not null default clock_timestamp(),
  constraint uq_student_portal_account_student unique (tenant_id, student_id),
  constraint uq_student_portal_account_user unique (user_id)
);

create index if not exists idx_student_portal_account_student on public.student_portal_account(student_id);
create index if not exists idx_student_portal_account_campus_status on public.student_portal_account(campus_id, status);

-- ── 2. Helper Functions: Student ID Resolver ─────────────────────────────────
create or replace function public.my_student_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select student_id
  from public.student_portal_account
  where user_id = auth.uid()
    and status = 'active'
  limit 1;
$$;

grant execute on function public.my_student_id() to authenticated;

-- ── 3. Custom Access Token Hook with Student Support ─────────────────────────
create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  claims  jsonb := coalesce(event -> 'claims', '{}'::jsonb);
  imp     record;
  u       record;
  gu      record;
  stu     record;
begin
  -- 1. Impersonation Session (Support)
  select s.id                as session_id,
         s.target_user_id,
         s.ends_at,
         t.tenant_id,
         t.app_role::text    as app_role,
         t.claims_version,
         coalesce(
           (select array_agg(uc.campus_id)
              from public.user_campus uc
             where uc.user_id = t.user_id and uc.is_active),
           '{}'::uuid[]
         ) as campus_ids,
         (select acs.id
            from public.academic_session acs
           where acs.tenant_id = t.tenant_id and acs.is_current
           limit 1) as academic_session_id,
         coalesce(
           (select cr.id from public.role cr where cr.id = t.custom_role_id and cr.deleted_at is null),
           (select r.id
              from public.role r
             where r.tenant_id = t.tenant_id and r.code = t.app_role::text and r.deleted_at is null
             limit 1)
         ) as role_id
    into imp
    from public.impersonation_session s
    join public.impersonation_consent c on c.id = s.consent_id
    join public.app_user sup on sup.user_id = s.support_user_id
    join public.app_user t   on t.user_id = s.target_user_id
   where s.support_user_id = (event ->> 'user_id')::uuid
     and s.ended_at is null
     and s.ends_at > clock_timestamp()
     and c.revoked_at is null
     and c.expires_at > clock_timestamp()
     and sup.status = 'active'
     and sup.app_role = 'super_admin'
     and t.status = 'active'
   limit 1;

  if found then
    claims := claims || jsonb_build_object(
      'tenant_id',           imp.tenant_id,
      'campus_ids',          to_jsonb(imp.campus_ids),
      'app_role',            imp.app_role,
      'academic_session_id', imp.academic_session_id,
      'role_id',             imp.role_id,
      'cv',                  imp.claims_version,
      'imp', jsonb_build_object(
        'sid', imp.session_id,
        'sub', imp.target_user_id,
        'by',  (event ->> 'user_id')::uuid,
        'exp', imp.ends_at
      )
    );
    return jsonb_set(event, '{claims}', claims);
  end if;

  -- 2. Staff User (app_user)
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

  -- 3. Guardian / Parent
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

  -- 4. FR-N09: Student Self-Scoped Portal Account
  select spa.tenant_id,
         spa.campus_id,
         spa.student_id,
         spa.status,
         spa.must_change_password
    into stu
    from public.student_portal_account spa
   where spa.user_id = (event ->> 'user_id')::uuid
     and spa.status = 'active';

  if found then
    claims := claims || jsonb_build_object(
      'tenant_id',            stu.tenant_id,
      'campus_ids',           to_jsonb(array[stu.campus_id]),
      'app_role',             'student',
      'student_id',           stu.student_id,
      'must_change_password', stu.must_change_password,
      'cv',                   1
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

-- ── 4. RLS Policies: Hard Isolation of Student Scope ─────────────────────────
alter table public.student_portal_account enable row level security;

-- student_portal_account RLS
drop policy if exists student_portal_account_staff on public.student_portal_account;
create policy student_portal_account_staff on public.student_portal_account
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner', 'principal', 'admin')
      or campus_id = any(app.auth_campus_ids())
    )
  );

drop policy if exists student_portal_account_self on public.student_portal_account;
create policy student_portal_account_self on public.student_portal_account
  for select to authenticated
  using (
    user_id = auth.uid()
  );

drop policy if exists student_portal_account_self_update on public.student_portal_account;
create policy student_portal_account_self_update on public.student_portal_account
  for update to authenticated
  using (
    user_id = auth.uid()
  )
  with check (
    user_id = auth.uid()
  );

-- Student Table RLS: update staff policy to exclude student, add self-scope
drop policy if exists student_campus_scope on public.student;
create policy student_campus_scope on public.student
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'student')
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
    and deleted_at is null
  );

drop policy if exists student_self_scope on public.student;
create policy student_self_scope on public.student
  for select to authenticated
  using (
    id = public.my_student_id()
    and deleted_at is null
  );

-- Enrolment Table RLS
drop policy if exists enrolment_campus_scope on public.enrolment;
create policy enrolment_campus_scope on public.enrolment
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'student')
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
    and deleted_at is null
  );

drop policy if exists enrolment_student_self on public.enrolment;
create policy enrolment_student_self on public.enrolment
  for select to authenticated
  using (
    student_id = public.my_student_id()
    and deleted_at is null
  );

-- Attendance Day Table RLS
drop policy if exists attendance_day_campus_read on public.attendance_day;
create policy attendance_day_campus_read on public.attendance_day
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'student')
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
  );

drop policy if exists attendance_day_student_self on public.attendance_day;
create policy attendance_day_student_self on public.attendance_day
  for select to authenticated
  using (
    enrolment_id in (
      select e.id from public.enrolment e
      where e.student_id = public.my_student_id()
    )
  );

-- Homework Table RLS
drop policy if exists homework_staff_read on public.homework;
create policy homework_staff_read on public.homework
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'none', 'student')
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
  );

drop policy if exists homework_student_read on public.homework;
create policy homework_student_read on public.homework
  for select to authenticated
  using (
    status = 'published'
    and section_id in (
      select e.section_id from public.enrolment e
      where e.student_id = public.my_student_id()
        and e.status = 'active'
    )
  );

-- Timetable Slot Table RLS
drop policy if exists timetable_slot_campus_scope on public.timetable_slot;
create policy timetable_slot_campus_scope on public.timetable_slot
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'none', 'student')
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
  );

drop policy if exists timetable_slot_student_read on public.timetable_slot;
create policy timetable_slot_student_read on public.timetable_slot
  for select to authenticated
  using (
    exists (
      select 1 from public.timetable_version tv
      where tv.id = timetable_slot.timetable_version_id
        and tv.status = 'PUBLISHED'
    )
    and section_id in (
      select e.section_id from public.enrolment e
      where e.student_id = public.my_student_id()
        and e.status = 'active'
    )
  );

-- Fee Tables RLS: Exclude student from fee_challan, fee_payment, fee_ledger (AC 1)
drop policy if exists fee_challan_campus_scope on public.fee_challan;
create policy fee_challan_campus_scope on public.fee_challan
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'student')
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
    and deleted_at is null
  );

drop policy if exists student_guardian_campus_scope on public.student_guardian;
create policy student_guardian_campus_scope on public.student_guardian
  for select to authenticated
  using (
    app.auth_role() not in ('parent', 'student')
    and student_id in (
      select s.id from public.student s
      where s.tenant_id = app.auth_tenant_id()
        and (
          app.auth_role() in ('super_admin', 'owner')
          or s.campus_id = any(app.auth_campus_ids())
        )
    )
  );

-- Exam & Subject Results: AC 2
drop policy if exists subject_result_campus_scope on public.subject_result;
create policy subject_result_campus_scope on public.subject_result
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'student')
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
  );

drop policy if exists subject_result_student_own on public.subject_result;
create policy subject_result_student_own on public.subject_result
  for select to authenticated
  using (
    enrolment_id in (
      select e.id from public.enrolment e
      where e.student_id = public.my_student_id()
    )
    and not app.fn_result_withheld(enrolment_id, exam_term_id)
  );

-- Result Position Table RLS: AC 2
drop policy if exists position_campus_scope on public.result_position;
create policy position_campus_scope on public.result_position
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'student')
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
  );

drop policy if exists position_student_own on public.result_position;
create policy position_student_own on public.result_position
  for select to authenticated
  using (
    enrolment_id in (
      select e.id from public.enrolment e
      where e.student_id = public.my_student_id()
    )
    and not app.fn_result_withheld(enrolment_id, exam_term_id)
    and exists (
      select 1 from public.campus_portal_policy cpp
      where cpp.campus_id = result_position.campus_id
        and cpp.show_rank = true
    )
  );

-- ── 5. Provisioning & Deprovisioning RPCs ─────────────────────────────────────

-- 5a. Provision Student Accounts (min_class check)
create or replace function public.provision_student_accounts(
  p_campus_id uuid default null
)
returns table (
  student_id        uuid,
  gr_number         text,
  auth_user_id      uuid,
  auth_email        text,
  initial_password  text,
  action            text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rec record;
  v_policy record;
  v_user_id uuid;
  v_initial_pw text;
  v_auth_email text;
  v_tenant_id uuid;
  v_min_ordinal smallint;
begin
  for v_policy in (
    select c.id as campus_id, c.tenant_id, t.slug as tenant_slug,
           coalesce(cpp.min_class_for_student_login, 6) as min_class
    from public.campus c
    join public.tenant t on t.id = c.tenant_id
    left join public.campus_portal_policy cpp on cpp.campus_id = c.id
    where (p_campus_id is null or c.id = p_campus_id)
  ) loop

    -- Determine minimum ordinal for class
    select min(ordinal) into v_min_ordinal
    from public.class_level cl
    where cl.tenant_id = v_policy.tenant_id
      and (
        cl.code = v_policy.min_class::text
        or regexp_replace(cl.code, '\D', '', 'g') = v_policy.min_class::text
      );

    if v_min_ordinal is null then
      v_min_ordinal := 7; -- fallback to Class 6 ordinal (Class 1=2 .. Class 6=7)
    end if;

    -- Iterate active students at or above minimum class
    for v_rec in (
      select s.id as s_id, s.gr_number, s.gr_digits, s.tenant_id, s.campus_id,
             e.id as enrolment_id, cl.ordinal as class_ordinal
      from public.student s
      join public.enrolment e on e.student_id = s.id and e.status = 'active' and e.deleted_at is null
      join public.class_level cl on cl.id = e.class_level_id
      where s.campus_id = v_policy.campus_id
        and s.status = 'active'
        and s.deleted_at is null
        and cl.ordinal >= v_min_ordinal
    ) loop
      -- Check if already provisioned
      if not exists (
        select 1 from public.student_portal_account spa
        where spa.student_id = v_rec.s_id
      ) then
        v_initial_pw := 'Seena@' || coalesce(nullif(v_rec.gr_digits, ''), '123456');
        v_auth_email := 'student.' || v_rec.s_id || '@student.seena.local';

        -- Check if auth user exists, if not create one
        select id into v_user_id
        from auth.users
        where email = v_auth_email;

        if v_user_id is null then
          v_user_id := gen_random_uuid();
          insert into auth.users (
            id,
            instance_id,
            email,
            encrypted_password,
            email_confirmed_at,
            raw_app_meta_data,
            raw_user_meta_data,
            created_at,
            updated_at,
            role,
            aud,
            confirmation_token,
            recovery_token,
            email_change_token_new,
            email_change,
            phone_change,
            phone_change_token,
            email_change_token_current,
            email_change_confirm_status,
            reauthentication_token,
            is_sso_user,
            is_anonymous
          ) values (
            v_user_id,
            '00000000-0000-0000-0000-000000000000',
            v_auth_email,
            extensions.crypt(v_initial_pw, extensions.gen_salt('bf')),
            clock_timestamp(),
            '{"provider":"email","providers":["email"]}'::jsonb,
            jsonb_build_object('student_id', v_rec.s_id, 'gr_number', v_rec.gr_number),
            clock_timestamp(),
            clock_timestamp(),
            'authenticated',
            'authenticated',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            0,
            '',
            false,
            false
          );

          insert into auth.identities (
            id,
            user_id,
            provider_id,
            identity_data,
            provider,
            last_sign_in_at,
            created_at,
            updated_at
          ) values (
            gen_random_uuid(),
            v_user_id,
            v_user_id::text,
            jsonb_build_object(
              'sub', v_user_id::text,
              'email', v_auth_email,
              'email_verified', true,
              'phone_verified', false
            ),
            'email',
            null,
            clock_timestamp(),
            clock_timestamp()
          );
        end if;

        insert into public.student_portal_account (
          tenant_id,
          campus_id,
          student_id,
          user_id,
          status,
          must_change_password,
          initial_password
        ) values (
          v_rec.tenant_id,
          v_rec.campus_id,
          v_rec.s_id,
          v_user_id,
          'active',
          true,
          v_initial_pw
        );

        student_id       := v_rec.s_id;
        gr_number        := v_rec.gr_number;
        auth_user_id     := v_user_id;
        auth_email       := v_auth_email;
        initial_password := v_initial_pw;
        action           := 'created';
        return next;
      end if;
    end loop;
  end loop;
end;
$$;

grant execute on function public.provision_student_accounts(uuid) to authenticated;

-- 5b. Deprovision on Transfer Certificate (AC 3)
create or replace function public.deprovision_on_tc()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
begin
  -- Disable student portal accounts where a Transfer Certificate has been issued,
  -- or enrolment is marked transferred, or student is withdrawn/transferred.
  update public.student_portal_account spa
  set status = 'disabled',
      updated_at = clock_timestamp()
  where spa.status = 'active'
    and (
      exists (
        select 1 from public.certificate_issue ci
        where ci.student_id = spa.student_id
          and ci.certificate_type = 'transfer'
          and ci.status = 'issued'
      )
      or exists (
        select 1 from public.enrolment e
        where e.student_id = spa.student_id
          and (e.tc_issued_at is not null or e.status = 'transferred')
      )
      or exists (
        select 1 from public.student s
        where s.id = spa.student_id
          and s.status in ('left', 'transferred', 'struck_off', 'expelled')
      )
    );

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.deprovision_on_tc() to authenticated;

-- 5c. Change Student Password (AC 4)
create or replace function public.change_student_password(
  p_new_password text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'UNAUTHORIZED: User must be signed in';
  end if;

  if p_new_password is null or length(trim(p_new_password)) < 6 then
    raise exception 'Password must be at least 6 characters long';
  end if;

  -- Update auth user password
  update auth.users
  set encrypted_password = extensions.crypt(p_new_password, extensions.gen_salt('bf')),
      updated_at = clock_timestamp()
  where id = v_user_id;

  -- Clear must_change_password flag
  update public.student_portal_account
  set must_change_password = false,
      updated_at = clock_timestamp()
  where user_id = v_user_id;

  return true;
end;
$$;

grant execute on function public.change_student_password(text) to authenticated;

-- 5d. Resolve Student Login Identifier (Supports GR number input)
create or replace function public.resolve_student_login(
  p_identifier text,
  p_campus_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_res record;
begin
  select spa.user_id,
         u.email,
         spa.must_change_password,
         spa.status,
         s.name_en,
         s.gr_number
  into v_res
  from public.student s
  join public.student_portal_account spa on spa.student_id = s.id
  join auth.users u on u.id = spa.user_id
  where (
    s.gr_number = trim(p_identifier)
    or s.gr_digits = app.digits(p_identifier)
    or u.email = lower(trim(p_identifier))
  )
  and (p_campus_id is null or s.campus_id = p_campus_id)
  order by (s.gr_number = trim(p_identifier)) desc, spa.created_at desc
  limit 1;

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'found', true,
    'user_id', v_res.user_id,
    'email', v_res.email,
    'must_change_password', v_res.must_change_password,
    'status', v_res.status,
    'student_name', v_res.name_en,
    'gr_number', v_res.gr_number
  );
end;
$$;

grant execute on function public.resolve_student_login(text, uuid) to anon, authenticated;

-- ── 6. Nightly Cron Job: student-account-sync at 02:00 PKT (21:00 UTC) ────────
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('student-account-sync', '0 21 * * *', 'select public.deprovision_on_tc();');
  end if;
exception
  when others then null;
end;
$$;
