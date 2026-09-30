-- FR-N01: Guardian portal access claim.
--
-- A parent activates their own portal account from a phone with nothing but
-- the school code, their child's GR number and the last six digits of their
-- CNIC. Activation itself reuses FR-C11 (guardian_invite + Supabase phone OTP);
-- this migration adds the anonymous front door and its defences.
--
-- Design decisions that matter:
--  * start_guardian_claim() is service_role-only. The Next.js server action
--    derives the device key (cookie + IP), so a client cannot mint its own
--    device id per request to dodge the lockout.
--  * Every failure returns the same {"status":"not_found"} — which half of
--    the input was wrong is never revealed (GR numbers are sequential and
--    guessable, so a discriminating message would scrape the student list).
--  * Failures are also counted per (school, GR) across ALL devices. Six CNIC
--    digits are a 1-in-a-million guess; ten tries an hour per GR makes
--    distributed guessing pointless, and because unknown GRs are counted the
--    same way the lock cannot be used as an "is this GR real" oracle.
--  * The phone a code goes to is never client-supplied; it is the one on the
--    guardian record. A stale number -> manual review by the office.
--  * A claim activates ONE student. Siblings stay hidden (portal_access =
--    false) until their own claim or an office-side grant.

-- ── 1. per-link portal visibility ─────────────────────────────────────────

alter table public.student_guardian
  add column if not exists portal_access boolean not null default true;

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
       join public.student_guardian sg on sg.guardian_id = g.id and sg.to_date is null and sg.portal_access
      where g.auth_user_id = (select auth.uid())),
    '{}'::uuid[]
  );
$$;

-- ── 2. claim invites are their own channel ────────────────────────────────

alter table public.guardian_invite drop constraint if exists guardian_invite_sent_channel_check;
alter table public.guardian_invite
  add constraint guardian_invite_sent_channel_check
  check (sent_channel in ('whatsapp', 'sms', 'print', 'claim'));

-- ── 3. tables ─────────────────────────────────────────────────────────────

create table public.guardian_claim_attempt (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid references public.tenant(id) on delete cascade,
  gr_digits   text,
  device_hash text not null,
  outcome     text not null check (outcome in ('failed', 'locked', 'matched')),
  created_at  timestamptz not null default clock_timestamp()
);

create index idx_claim_attempt_device on public.guardian_claim_attempt (device_hash, created_at desc)
  where outcome = 'failed';
create index idx_claim_attempt_gr on public.guardian_claim_attempt (tenant_id, gr_digits, created_at desc)
  where outcome = 'failed';

create table public.guardian_claim (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  student_id   uuid not null references public.student(id) on delete cascade,
  guardian_id  uuid not null references public.guardian(id) on delete cascade,
  status       text not null check (status in ('pending_otp', 'manual_review', 'approved', 'rejected', 'activated', 'expired')),
  device_hash  text not null,
  invite_id    uuid references public.guardian_invite(id) on delete set null,
  review_reason text,
  review_note  text,
  resolved_by  uuid references auth.users(id),
  resolved_at  timestamptz,
  expires_at   timestamptz not null,
  created_at   timestamptz not null default clock_timestamp()
);

create unique index uq_guardian_claim_open on public.guardian_claim (student_id, guardian_id)
  where status in ('pending_otp', 'manual_review', 'approved');
create index idx_guardian_claim_scope on public.guardian_claim (tenant_id, campus_id, status);
create index idx_guardian_claim_invite on public.guardian_claim (invite_id);

create trigger guardian_claim_audit after insert or update or delete on public.guardian_claim
  for each row execute function app.tg_audit_row();

alter table public.guardian_claim_attempt enable row level security;
alter table public.guardian_claim enable row level security;

create policy guardian_claim_attempt_staff_read on public.guardian_claim_attempt
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('admissions_officer', 'principal', 'vice_principal', 'owner', 'super_admin')
  );

create policy guardian_claim_staff_read on public.guardian_claim
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('admissions_officer', 'principal', 'vice_principal', 'owner', 'super_admin')
    and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids()))
  );

-- ── 4. lock helpers ───────────────────────────────────────────────────────

-- 3 failures from one device within 10 minutes lock it for 30 minutes from
-- the most recent failure. Lock-time attempts are logged as 'locked', not
-- 'failed', so hammering a locked device does not extend the lock.
create or replace function app.fn_claim_device_locked(p_device_hash text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with recent as (
    select created_at, row_number() over (order by created_at desc, id) as rn
      from public.guardian_claim_attempt
     where device_hash = p_device_hash and outcome = 'failed'
       and created_at > clock_timestamp() - interval '30 minutes'
  )
  select exists (
    select 1
      from recent r3
      join recent r1 on r1.rn = 1
     where r3.rn = 3 and r1.created_at - r3.created_at <= interval '10 minutes'
  );
$$;

create or replace function app.fn_claim_gr_locked(p_tenant_id uuid, p_gr_digits text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select count(*) >= 10
    from public.guardian_claim_attempt
   where tenant_id = p_tenant_id and gr_digits = p_gr_digits and outcome = 'failed'
     and created_at > clock_timestamp() - interval '1 hour';
$$;

create or replace function app.fn_mask_phone(p_phone text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_phone is null or length(p_phone) < 6 then null
              else left(p_phone, 3) || repeat('*', length(p_phone) - 5) || right(p_phone, 2) end;
$$;

revoke execute on function app.fn_claim_device_locked(text) from public, anon, authenticated;
revoke execute on function app.fn_claim_gr_locked(uuid, text) from public, anon, authenticated;

-- Shared invite minting: the raw token exists only in the return value.
create or replace function app.fn_issue_guardian_invite(p_guardian_id uuid, p_tenant_id uuid, p_channel text, p_ttl interval, p_created_by uuid)
returns table (invite_id uuid, token text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text := encode(extensions.gen_random_bytes(24), 'hex');
  v_id    uuid;
begin
  delete from public.guardian_invite where guardian_id = p_guardian_id and consumed_at is null;
  insert into public.guardian_invite (tenant_id, guardian_id, token_hash, sent_channel, expires_at, created_by)
  values (p_tenant_id, p_guardian_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), p_channel, now() + p_ttl, p_created_by)
  returning id into v_id;
  invite_id := v_id;
  token := v_token;
  return next;
end;
$$;

revoke execute on function app.fn_issue_guardian_invite(uuid, uuid, text, interval, uuid) from public, anon, authenticated;

-- ── 5. start_guardian_claim (service_role only) ───────────────────────────

create or replace function public.start_guardian_claim(
  p_school_code text,
  p_gr_no       text,
  p_cnic_last6  text,
  p_device_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_device      text := nullif(btrim(p_device_hash), '');
  v_tenant_id   uuid;
  v_gr          text := regexp_replace(coalesce(p_gr_no, ''), '\D', '', 'g');
  v_cnic6       text := right(regexp_replace(coalesce(p_cnic_last6, ''), '\D', '', 'g'), 6);
  v_student_id  uuid;
  v_campus_id   uuid;
  v_guardian_id uuid;
  v_phone       text;
  v_active      boolean;
  v_invite_id   uuid;
  v_token       text;
  v_claim_id    uuid;
begin
  if v_device is null or length(v_device) < 16 then
    raise exception 'DEVICE_REQUIRED' using errcode = '22023';
  end if;

  select id into v_tenant_id from public.tenant where slug = lower(btrim(coalesce(p_school_code, '')));

  if app.fn_claim_device_locked(v_device)
     or (v_tenant_id is not null and app.fn_claim_gr_locked(v_tenant_id, v_gr)) then
    insert into public.guardian_claim_attempt (tenant_id, gr_digits, device_hash, outcome)
    values (v_tenant_id, nullif(v_gr, ''), v_device, 'locked');
    return jsonb_build_object('status', 'locked');
  end if;

  if v_tenant_id is not null and v_gr <> '' and length(v_cnic6) = 6 then
    select s.id, s.campus_id into v_student_id, v_campus_id
      from public.student s
     where s.tenant_id = v_tenant_id and s.gr_digits = v_gr and s.deleted_at is null and s.status = 'active';

    if v_student_id is not null then
      select g.id, g.phone_e164, (g.auth_user_id is not null)
        into v_guardian_id, v_phone, v_active
        from public.student_guardian sg
        join public.guardian g on g.id = sg.guardian_id
       where sg.student_id = v_student_id and sg.to_date is null
         and g.cnic_digits is not null and right(g.cnic_digits, 6) = v_cnic6
       order by sg.is_primary desc
       limit 1;
    end if;
  end if;

  if v_guardian_id is null then
    insert into public.guardian_claim_attempt (tenant_id, gr_digits, device_hash, outcome)
    values (v_tenant_id, nullif(v_gr, ''), v_device, 'failed');
    return jsonb_build_object('status', 'not_found');
  end if;

  insert into public.guardian_claim_attempt (tenant_id, gr_digits, device_hash, outcome)
  values (v_tenant_id, v_gr, v_device, 'matched');

  if v_active then
    return jsonb_build_object('status', 'already_active');
  end if;

  update public.guardian_claim
     set status = 'expired'
   where student_id = v_student_id and guardian_id = v_guardian_id
     and status in ('pending_otp', 'manual_review', 'approved');

  if v_phone is null then
    insert into public.guardian_claim (tenant_id, campus_id, student_id, guardian_id, status, device_hash, review_reason, expires_at)
    values (v_tenant_id, v_campus_id, v_student_id, v_guardian_id, 'manual_review', v_device, 'NO_PHONE', now() + interval '14 days')
    returning id into v_claim_id;
    return jsonb_build_object('status', 'manual_review', 'claim_id', v_claim_id);
  end if;

  select i.invite_id, i.token into v_invite_id, v_token
    from app.fn_issue_guardian_invite(v_guardian_id, v_tenant_id, 'claim', interval '5 minutes', null) i;

  insert into public.guardian_claim (tenant_id, campus_id, student_id, guardian_id, status, device_hash, invite_id, expires_at)
  values (v_tenant_id, v_campus_id, v_student_id, v_guardian_id, 'pending_otp', v_device, v_invite_id, now() + interval '5 minutes')
  returning id into v_claim_id;

  return jsonb_build_object(
    'status', 'otp',
    'claim_id', v_claim_id,
    'token', v_token,
    'phone_masked', app.fn_mask_phone(v_phone)
  );
end;
$$;

revoke execute on function public.start_guardian_claim(text, text, text, text) from public, anon, authenticated;
grant execute on function public.start_guardian_claim(text, text, text, text) to service_role;

-- ── 6. "I can't receive the code" -> manual review (token is the secret) ──

create or replace function public.request_claim_manual_review(p_token text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text := encode(extensions.digest(p_token, 'sha256'), 'hex');
  v_claim_id uuid;
begin
  update public.guardian_claim c
     set status = 'manual_review', review_reason = 'PHONE_UNREACHABLE', expires_at = now() + interval '14 days'
    from public.guardian_invite i
   where c.invite_id = i.id and i.token_hash = v_hash
     and c.status = 'pending_otp' and i.consumed_at is null
  returning c.id into v_claim_id;

  if v_claim_id is null then
    return false;
  end if;

  update public.guardian_invite set consumed_at = now() where token_hash = v_hash;
  return true;
end;
$$;

revoke execute on function public.request_claim_manual_review(text) from public;
grant execute on function public.request_claim_manual_review(text) to anon, authenticated;

-- ── 7. office resolves a manual-review claim ──────────────────────────────

create or replace function public.resolve_guardian_claim(p_claim_id uuid, p_approve boolean, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_claim     record;
  v_phone     text;
  v_name      text;
  v_invite_id uuid;
  v_token     text;
begin
  if app.auth_role() not in ('admissions_officer', 'principal', 'vice_principal', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_claim from public.guardian_claim where id = p_claim_id and tenant_id = v_tenant_id for update;
  if not found then
    raise exception 'CLAIM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_claim.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_claim.status <> 'manual_review' then
    raise exception 'CLAIM_NOT_PENDING_REVIEW' using errcode = '55000';
  end if;

  if not p_approve then
    update public.guardian_claim
       set status = 'rejected', review_note = p_note, resolved_by = (select auth.uid()), resolved_at = now()
     where id = p_claim_id;
    return jsonb_build_object('status', 'rejected');
  end if;

  select phone_e164, name_en into v_phone, v_name from public.guardian where id = v_claim.guardian_id;
  if v_phone is null then
    raise exception 'PHONE_REQUIRED' using errcode = '22023';
  end if;

  select i.invite_id, i.token into v_invite_id, v_token
    from app.fn_issue_guardian_invite(v_claim.guardian_id, v_tenant_id, 'claim', interval '72 hours', (select auth.uid())) i;

  update public.guardian_claim
     set status = 'approved', invite_id = v_invite_id, review_note = p_note,
         resolved_by = (select auth.uid()), resolved_at = now()
   where id = p_claim_id;

  return jsonb_build_object('status', 'approved', 'token', v_token, 'phone_e164', v_phone, 'guardian_name', v_name);
end;
$$;

revoke execute on function public.resolve_guardian_claim(uuid, boolean, text) from public, anon;
grant execute on function public.resolve_guardian_claim(uuid, boolean, text) to authenticated;

-- ── 8. three wrong OTPs burn a claim invite ───────────────────────────────

create or replace function public.register_guardian_otp_attempt(p_token text, p_kind text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invite record;
begin
  select i.id, i.guardian_id, i.sent_channel, i.created_at into v_invite
    from public.guardian_invite i
   where i.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  if not found then
    return;
  end if;

  insert into public.guardian_otp_attempt (guardian_id, kind) values (v_invite.guardian_id, p_kind);

  if p_kind = 'verify_failed' and v_invite.sent_channel = 'claim'
     and (select count(*) from public.guardian_otp_attempt
           where guardian_id = v_invite.guardian_id and kind = 'verify_failed' and created_at >= v_invite.created_at) >= 3 then
    update public.guardian_invite set consumed_at = now() where id = v_invite.id and consumed_at is null;
    update public.guardian_claim set status = 'expired' where invite_id = v_invite.id and status = 'pending_otp';
  end if;
end;
$$;

revoke execute on function public.register_guardian_otp_attempt(text, text) from public;
grant execute on function public.register_guardian_otp_attempt(text, text) to anon, authenticated;

-- ── 9. activation: a claim links only the claimed student ─────────────────

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
  v_claim_student uuid;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;

  select i.id, i.consumed_at, i.expires_at, i.guardian_id, i.sent_channel,
         g.phone_e164 as guardian_phone, g.auth_user_id as guardian_auth_user_id
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
  if v_phone is distinct from ltrim(v_invite.guardian_phone, '+') then
    raise exception 'INVITE_PHONE_MISMATCH' using errcode = '55000';
  end if;

  update public.guardian set auth_user_id = v_uid where id = v_invite.guardian_id;
  update public.guardian_invite set consumed_at = now() where id = v_invite.id;

  if v_invite.sent_channel = 'claim' then
    select student_id into v_claim_student from public.guardian_claim where invite_id = v_invite.id;
    if v_claim_student is not null then
      update public.student_guardian
         set portal_access = (student_id = v_claim_student)
       where guardian_id = v_invite.guardian_id and to_date is null;
      update public.guardian_claim set status = 'activated', resolved_at = now() where invite_id = v_invite.id;
    end if;
  end if;

  return v_invite.guardian_id;
end;
$$;

revoke execute on function public.activate_guardian_account(text) from public, anon;
grant execute on function public.activate_guardian_account(text) to authenticated;

-- ── 10. siblings: own claim (signed in) or office-side grant ──────────────

create or replace function public.claim_additional_student(p_gr_no text, p_cnic_last6 text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid         uuid := (select auth.uid());
  v_device      text := 'uid:' || coalesce((select auth.uid())::text, '');
  v_gr          text := regexp_replace(coalesce(p_gr_no, ''), '\D', '', 'g');
  v_cnic6       text := right(regexp_replace(coalesce(p_cnic_last6, ''), '\D', '', 'g'), 6);
  v_guardian_id uuid;
  v_tenant_id   uuid;
  v_student_id  uuid;
begin
  if v_uid is null or app.auth_role() <> 'parent' then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select id, tenant_id into v_guardian_id, v_tenant_id from public.guardian where auth_user_id = v_uid;
  if v_guardian_id is null then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if app.fn_claim_device_locked(v_device) or app.fn_claim_gr_locked(v_tenant_id, v_gr) then
    insert into public.guardian_claim_attempt (tenant_id, gr_digits, device_hash, outcome)
    values (v_tenant_id, nullif(v_gr, ''), v_device, 'locked');
    return jsonb_build_object('status', 'locked');
  end if;

  select sg.student_id into v_student_id
    from public.student_guardian sg
    join public.student s on s.id = sg.student_id
    join public.guardian g on g.id = sg.guardian_id
   where sg.guardian_id = v_guardian_id and sg.to_date is null
     and s.tenant_id = v_tenant_id and s.gr_digits = v_gr and s.deleted_at is null
     and g.cnic_digits is not null and right(g.cnic_digits, 6) = v_cnic6;

  if v_student_id is null or v_gr = '' then
    insert into public.guardian_claim_attempt (tenant_id, gr_digits, device_hash, outcome)
    values (v_tenant_id, nullif(v_gr, ''), v_device, 'failed');
    return jsonb_build_object('status', 'not_found');
  end if;

  update public.student_guardian set portal_access = true
   where guardian_id = v_guardian_id and student_id = v_student_id and to_date is null;
  insert into public.guardian_claim_attempt (tenant_id, gr_digits, device_hash, outcome)
  values (v_tenant_id, v_gr, v_device, 'matched');

  return jsonb_build_object('status', 'linked', 'student_id', v_student_id);
end;
$$;

revoke execute on function public.claim_additional_student(text, text) from public, anon;
grant execute on function public.claim_additional_student(text, text) to authenticated;

create or replace function public.set_guardian_portal_access(p_student_id uuid, p_guardian_id uuid, p_allowed boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_campus_id uuid;
begin
  if app.auth_role() not in ('admissions_officer', 'principal', 'vice_principal', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select campus_id into v_campus_id from public.student where id = p_student_id and tenant_id = v_tenant_id;
  if v_campus_id is null then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.student_guardian set portal_access = p_allowed
   where student_id = p_student_id and guardian_id = p_guardian_id and to_date is null;
  if not found then
    raise exception 'LINK_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function public.set_guardian_portal_access(uuid, uuid, boolean) from public, anon;
grant execute on function public.set_guardian_portal_access(uuid, uuid, boolean) to authenticated;

-- ── 11. the preview must not hand a claimant the guardian's full phone ────
-- GR + six CNIC digits are two weak factors; the full number on the
-- activation page would be PII for anyone who guessed them. Office-sent
-- invites keep showing the full number (the school chose to send it there).

drop function if exists public.get_guardian_invite_preview(text);
create function public.get_guardian_invite_preview(p_token text)
returns table (tenant_name text, guardian_name text, phone_e164 text, valid boolean, locked boolean, is_claim boolean, phone_masked text)
language sql
stable
security definer
set search_path = ''
as $$
  select t.name,
         g.name_en,
         g.phone_e164,
         (i.consumed_at is null and i.expires_at > now() and g.auth_user_id is null) as valid,
         public.is_guardian_otp_locked(g.id) as locked,
         (i.sent_channel = 'claim') as is_claim,
         app.fn_mask_phone(g.phone_e164) as phone_masked
    from public.guardian_invite i
    join public.guardian g on g.id = i.guardian_id
    join public.tenant t on t.id = i.tenant_id
   where i.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
$$;

revoke execute on function public.get_guardian_invite_preview(text) from public;
grant execute on function public.get_guardian_invite_preview(text) to anon, authenticated;
