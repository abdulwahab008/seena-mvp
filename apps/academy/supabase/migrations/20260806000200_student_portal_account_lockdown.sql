-- Student portal accounts: close the credential exposure and the open provisioning call.
--
-- 1. student_portal_account_staff was FOR ALL with `campus_id = any(auth_campus_ids())` and no
--    role test. Guardian and student tokens carry campus_ids too, so every parent, every
--    student and every staff role could read all of a campus's accounts - including
--    initial_password, kept in clear text and never cleared - and write to any row. The
--    self-update policy let a student flip must_change_password off and skip the forced
--    password change (FR-N09 AC4).
--      * Reads: the student reads their own row; school leadership (super admin, owner,
--        principal) reads its own school's rows. Nobody else.
--      * Writes: none through the API. Every write already goes through a SECURITY DEFINER
--        function (provisioning, deprovisioning, change_student_password, language).
--      * initial_password: not readable by anon or authenticated at all.
--
-- 2. provision_student_accounts() was SECURITY DEFINER with no check, executable by anon, and
--    with p_campus_id = null it created accounts for every student of every school and
--    returned the passwords. It now refuses everyone but school leadership (own school only)
--    and the platform (service role or a database session).
--
-- 3. The first password was 'Seena@' + the GR number's digits, and GR numbers are sequential,
--    so anyone could log in as a student who had not yet activated. New accounts get a random
--    password (app.fn_generate_initial_password). change_student_password() now also clears
--    the stored initial password, and passwords of accounts already activated are cleared here.
--    Accounts that were created but never activated keep the password they were issued.
--
-- 4. resolve_student_login() (name, GR number, auth email and "still on first password" for any
--    GR number, to anon) and deprovision_on_tc() (a global UPDATE) are used only by the backend,
--    which calls them with the service role. They are no longer executable by anyone else.

-- ── 1. Row-level security and privileges ─────────────────────────────────────

drop policy if exists student_portal_account_staff on public.student_portal_account;
drop policy if exists student_portal_account_self_update on public.student_portal_account;

create policy student_portal_account_leadership_read on public.student_portal_account
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

revoke all on table public.student_portal_account from anon, authenticated;
grant select (id, tenant_id, campus_id, student_id, user_id, status, must_change_password,
              created_at, updated_at, preferred_language)
  on public.student_portal_account to authenticated;

update public.student_portal_account set initial_password = null where must_change_password = false;

-- ── 2. Random first passwords ────────────────────────────────────────────────

create or replace function app.fn_generate_initial_password()
returns text
language sql
volatile
security definer
set search_path = ''
as $$
  -- 10 characters from an alphabet without look-alikes (no 0/O, 1/l/I), drawn from the
  -- database's cryptographic generator.
  select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789',
                           1 + (get_byte(r.b, i) % 54), 1), '')
    from (select extensions.gen_random_bytes(10) as b) r, generate_series(0, 9) i;
$$;
revoke execute on function app.fn_generate_initial_password() from public, anon, authenticated;

-- ── 3. provisioning is gated and school-scoped ───────────────────────────────

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
  v_caller_tenant uuid := app.auth_tenant_id();
  v_caller_role   text := app.auth_role();
  -- The platform itself: the service-role key (backend jobs) or a database session.
  v_platform      boolean := coalesce(auth.role(), '') = 'service_role'
                             or session_user in ('postgres', 'supabase_admin');
begin
  -- This function creates login accounts and hands back their first passwords, so
  -- it must not be open to whoever holds the public key. A school session may run
  -- it for its own school only, and only school leadership; the platform may run it
  -- for every school (p_campus_id = null).
  if v_caller_tenant is not null then
    if v_caller_role not in ('super_admin', 'owner', 'principal') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  elsif not v_platform then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  for v_policy in (
    select c.id as campus_id, c.tenant_id, t.slug as tenant_slug,
           coalesce(cpp.min_class_for_student_login, 6) as min_class
    from public.campus c
    join public.tenant t on t.id = c.tenant_id
    left join public.campus_portal_policy cpp on cpp.campus_id = c.id
    where (p_campus_id is null or c.id = p_campus_id)
      and (v_caller_tenant is null or c.tenant_id = v_caller_tenant)
      and (v_caller_tenant is null or v_caller_role in ('super_admin', 'owner') or c.id = any(app.auth_campus_ids()))
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
        v_initial_pw := app.fn_generate_initial_password();
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

revoke execute on function public.provision_student_accounts(uuid) from public, anon;
grant execute on function public.provision_student_accounts(uuid) to authenticated, service_role;

-- ── 4. Clearing the first password once it has been replaced ─────────────────

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
      initial_password = null,
      updated_at = clock_timestamp()
  where user_id = v_user_id;

  return true;
end;
$$;

-- ── 5. Backend-only functions ────────────────────────────────────────────────

revoke execute on function public.resolve_student_login(text, uuid) from public, anon, authenticated;
grant execute on function public.resolve_student_login(text, uuid) to service_role;
revoke execute on function public.deprovision_on_tc() from public, anon, authenticated;
grant execute on function public.deprovision_on_tc() to service_role;
