-- FR-C11: invite and activate guardian portal accounts.
--
-- Design: the invite LINK (guardian_invite, single-use, 72h) and the OTP
-- CODE are two different things. The code itself is never generated or
-- stored by this app — it's Supabase Auth's own native phone-OTP mechanism
-- (auth.signInWithOtp / auth.verifyOtp), exactly the delivery mechanism
-- FR-A08 already built and explicitly deferred self-serve signup on
-- ("Self-serve parent signup via OTP is out of scope until Module C/N
-- exist for a brand-new account to land in" — see otp_auth.sql). This FR is
-- that deferred piece: shouldCreateUser:true, gated by a guardian_invite
-- token instead of an existing app_user row.
--
-- Print channel: guardian_invite.token_hash is the same secret whichever
-- channel it went out on — a printed slip shows the same token (formatted
-- for hand-typing) a WhatsApp/SMS link would carry, not a second code.
--
-- Scope cut: guardian self-read of their own guardian row (a "my profile"
-- page) isn't part of this FR's ACs or Supabase Objects list — only
-- parent_read_own_children on student/enrolment/fee_challan/attendance.

create table public.guardian_invite (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  guardian_id  uuid not null references public.guardian(id) on delete cascade,
  token_hash   text not null,
  sent_channel text not null check (sent_channel in ('whatsapp', 'sms', 'print')),
  expires_at   timestamptz not null,
  consumed_at  timestamptz,
  created_by   uuid references auth.users(id),
  created_at   timestamptz not null default now()
);

create unique index uq_guardian_invite_token_hash on public.guardian_invite (token_hash);
create index idx_guardian_invite_guardian on public.guardian_invite (guardian_id);

create trigger guardian_invite_audit after insert or update or delete on public.guardian_invite
  for each row execute function app.tg_audit_row();

-- Lockout bookkeeping only (mirrors otp_attempt from FR-A08) — GoTrue does
-- its own OTP verification; this just tracks outcomes so is_guardian_otp_
-- locked() can enforce this FR's own "5 wrong in 15 min -> 30 min lock"
-- rule, which is stricter and differently-shaped than FR-A08's "burn the
-- code" model and needs to survive past the 15-minute counting window.
create table public.guardian_otp_attempt (
  id          uuid primary key default gen_random_uuid(),
  seq         bigserial not null,
  guardian_id uuid not null references public.guardian(id) on delete cascade,
  kind        text not null check (kind in ('verify_failed', 'verify_succeeded')),
  created_at  timestamptz not null default now()
);

create index idx_guardian_otp_attempt_guardian on public.guardian_otp_attempt (guardian_id, created_at desc);

-- No RLS policies on either new security-log-ish table beyond tenant read
-- below — every write goes through the SECURITY DEFINER functions.
alter table public.guardian_invite enable row level security;
alter table public.guardian_otp_attempt enable row level security;

create policy guardian_invite_tenant_read on public.guardian_invite
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

-- AC: the lockout must be visible to the Admissions Officer — joined
-- through guardian since the attempt row itself carries no tenant_id.
create policy guardian_otp_attempt_tenant_read on public.guardian_otp_attempt
  for select to authenticated
  using (
    guardian_id in (select id from public.guardian where tenant_id = app.auth_tenant_id())
  );

create or replace function public.is_guardian_otp_locked(p_guardian_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with recent as (
    select created_at, row_number() over (order by created_at desc) as rn
      from public.guardian_otp_attempt
     where guardian_id = p_guardian_id and kind = 'verify_failed'
  )
  select exists (
    select 1
      from recent r5
      join recent r1 on r1.rn = 1
     where r5.rn = 5
       and r5.created_at > now() - interval '30 minutes'
       and r5.created_at > r1.created_at - interval '15 minutes'
  );
$$;

revoke execute on function public.is_guardian_otp_locked(uuid) from public;
grant execute on function public.is_guardian_otp_locked(uuid) to authenticated;

-- ── send_guardian_invite: staff-facing, creates the link ─────────────────

create or replace function public.send_guardian_invite(p_guardian_id uuid, p_channel text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_guardian  record;
  v_token     text;
  v_invite_id uuid;
  v_expires   timestamptz := now() + interval '72 hours';
begin
  if app.auth_role() not in ('admissions_officer', 'owner', 'principal', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_channel not in ('whatsapp', 'sms', 'print') then
    raise exception 'CHANNEL_INVALID' using errcode = '22023';
  end if;

  select * into v_guardian from public.guardian where id = p_guardian_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'GUARDIAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_guardian.phone_e164 is null then
    raise exception 'GUARDIAN_PHONE_MISSING' using errcode = '22023';
  end if;
  if v_guardian.auth_user_id is not null then
    raise exception 'GUARDIAN_ALREADY_ACTIVE' using errcode = '55000';
  end if;

  -- A fresh invite supersedes any prior outstanding one for this guardian,
  -- same reasoning as invite_user's own superseding delete.
  delete from public.guardian_invite where guardian_id = p_guardian_id and consumed_at is null;

  v_token := encode(extensions.gen_random_bytes(24), 'hex');

  insert into public.guardian_invite (tenant_id, guardian_id, token_hash, sent_channel, expires_at, created_by)
  values (v_tenant_id, p_guardian_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), p_channel, v_expires, (select auth.uid()))
  returning id into v_invite_id;

  return jsonb_build_object(
    'invite_id', v_invite_id,
    'token', v_token,
    'phone_e164', v_guardian.phone_e164,
    'guardian_name', v_guardian.name_en,
    'expires_at', v_expires
  );
end;
$$;

revoke execute on function public.send_guardian_invite(uuid, text) from public, anon;
grant execute on function public.send_guardian_invite(uuid, text) to authenticated;

-- ── get_guardian_invite_preview: public, token is the secret ─────────────

create or replace function public.get_guardian_invite_preview(p_token text)
returns table (tenant_name text, guardian_name text, phone_e164 text, valid boolean, locked boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select t.name,
         g.name_en,
         g.phone_e164,
         (i.consumed_at is null and i.expires_at > now() and g.auth_user_id is null) as valid,
         public.is_guardian_otp_locked(g.id) as locked
    from public.guardian_invite i
    join public.guardian g on g.id = i.guardian_id
    join public.tenant t on t.id = i.tenant_id
   where i.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
$$;

revoke execute on function public.get_guardian_invite_preview(text) from public;
grant execute on function public.get_guardian_invite_preview(text) to anon, authenticated;

-- ── register_guardian_otp_attempt: ground truth for the lockout ──────────

create or replace function public.register_guardian_otp_attempt(p_token text, p_kind text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.guardian_otp_attempt (guardian_id, kind)
  select i.guardian_id, p_kind
    from public.guardian_invite i
   where i.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
$$;

revoke execute on function public.register_guardian_otp_attempt(text, text) from public;
grant execute on function public.register_guardian_otp_attempt(text, text) to anon, authenticated;

-- ── activate_guardian_account: runs as the just-verified guardian ────────

create or replace function public.activate_guardian_account(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invite record;
  v_uid    uuid := (select auth.uid());
  v_phone  text;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;

  select i.id, i.consumed_at, i.expires_at, i.guardian_id, g.phone_e164 as guardian_phone, g.auth_user_id as guardian_auth_user_id
    into v_invite
    from public.guardian_invite i
    join public.guardian g on g.id = i.guardian_id
   where i.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');

  if not found then
    raise exception 'INVITE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_invite.consumed_at is not null then
    raise exception 'INVITE_ALREADY_USED' using errcode = '55000';
  end if;
  if v_invite.expires_at <= now() then
    raise exception 'INVITE_EXPIRED' using errcode = '55000';
  end if;
  if v_invite.guardian_auth_user_id is not null then
    raise exception 'GUARDIAN_ALREADY_ACTIVE' using errcode = '55000';
  end if;

  select phone into v_phone from auth.users where id = v_uid;
  -- GoTrue stores bare-digit phone (no leading "+") — same +92-E.164 vs
  -- bare-digit boundary toGoTruePhone() already crosses in app/login/otp.
  if v_phone is distinct from ltrim(v_invite.guardian_phone, '+') then
    raise exception 'INVITE_PHONE_MISMATCH' using errcode = '55000';
  end if;

  update public.guardian set auth_user_id = v_uid where id = v_invite.guardian_id;
  update public.guardian_invite set consumed_at = now() where id = v_invite.id;

  return v_invite.guardian_id;
end;
$$;

revoke execute on function public.activate_guardian_account(text) from public, anon;
grant execute on function public.activate_guardian_account(text) to authenticated;

-- ── custom_access_token_hook: add the parent branch ───────────────────────
-- Additive to the existing staff (app_user) branch — a user_id can only
-- ever match one or the other, never both, so this changes nothing about
-- staff claims. Parents get no academic_session_id/role_id (they aren't
-- scoped to one session the way a staff member's UI is) and campus_ids
-- drawn from their currently-linked children's active enrolments, not from
-- a user_campus row (guardians have none).

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
         (select r.id
            from public.role r
           where r.tenant_id = au.tenant_id and r.code = au.app_role::text and r.deleted_at is null
           limit 1) as role_id
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

  -- Neither an active staff member nor an activated guardian: tenant_id =
  -- null makes every tenant-fence policy evaluate to NULL, which RLS
  -- treats as deny — same fail-closed shape as the original branch.
  return jsonb_set(event, '{claims}',
    claims || jsonb_build_object('tenant_id', null, 'app_role', 'none', 'cv', 0));
end;
$$;

-- ── parent_read_own_children: harden the 4 existing campus-scoped SELECT
-- policies (campus_ids alone is NOT family-safe for a parent — two
-- families at the same campus must never see each other's children) and
-- add the actual own-children policies.

-- SECURITY DEFINER, unlike every other app.auth_*() helper: this one is
-- the only one that queries real tables (guardian, student_guardian)
-- rather than just parsing the JWT, and those tables' own RLS policies
-- recurse right back into student/enrolment/etc — which now call this
-- function from their own policies. Running as the function owner bypasses
-- RLS on guardian/student_guardian entirely, which breaks that cycle
-- (confirmed via "stack depth limit exceeded" on every RLS-protected table
-- before this was added — non-negotiable, not just a style choice).
create or replace function app.auth_guardian_student_ids()
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select array_agg(sg.student_id)
       from public.guardian g
       join public.student_guardian sg on sg.guardian_id = g.id and sg.to_date is null
      where g.auth_user_id = (select auth.uid())),
    '{}'::uuid[]
  );
$$;

grant execute on function app.auth_guardian_student_ids() to authenticated;

drop policy student_campus_scope on public.student;
create policy student_campus_scope on public.student
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() <> 'parent'
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy student_parent_read_own_children on public.student
  for select to authenticated
  using (id = any(app.auth_guardian_student_ids()));

drop policy enrolment_campus_scope on public.enrolment;
create policy enrolment_campus_scope on public.enrolment
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() <> 'parent'
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy enrolment_parent_read_own_children on public.enrolment
  for select to authenticated
  using (student_id = any(app.auth_guardian_student_ids()));

drop policy fee_challan_campus_scope on public.fee_challan;
create policy fee_challan_campus_scope on public.fee_challan
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() <> 'parent'
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy fee_challan_parent_read_own_children on public.fee_challan
  for select to authenticated
  using (
    enrolment_id in (
      select id from public.enrolment where student_id = any(app.auth_guardian_student_ids())
    )
  );

drop policy attendance_day_campus_read on public.attendance_day;
create policy attendance_day_campus_read on public.attendance_day
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() <> 'parent'
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy attendance_day_parent_read_own_children on public.attendance_day
  for select to authenticated
  using (
    enrolment_id in (
      select id from public.enrolment where student_id = any(app.auth_guardian_student_ids())
    )
  );
