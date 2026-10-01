-- FR-T06: bonafide certificate self-service.
--
-- Bonafide certificates are the highest-volume certificate (passport season). A
-- guardian requests one from the portal for a stated purpose; an officer
-- approves; the PDF is issued through the same issuing core, serial series and
-- register as every other certificate; and the guardian is told over WhatsApp
-- with a short-lived link that opens the PDF without a login wall.
--
--   * Privacy: a guardian asking for a student they are not linked to gets ZERO
--     ROWS, not an error. submit_certificate_request is SECURITY INVOKER, so
--     the insert runs under RLS (cert_request_parent_own) and is written as an
--     INSERT ... SELECT that simply selects nothing for a stranger's child; no
--     message differs between "no such student" and "not your student".
--   * Quota: at most 3 requests per user per rolling 24 hours, enforced by a
--     BEFORE INSERT trigger (not the function) so no path can skip it. The 4th
--     is rejected with "daily limit of 3 requests reached".
--   * Purpose: chosen from certificate_request_purpose, which carries Urdu
--     labels. "Other" requires a justification of at least 15 characters (a CHECK
--     on the table).
--   * Delivery: share links are opaque random tokens stored only as a hash, valid
--     for 7 days, resolved by the public /api/certificates/share route. The
--     WhatsApp message is written to the FR-M01 outbox (public.message) for the
--     existing dispatcher. Stubbed: the WhatsApp provider call itself, which the
--     outbox's worker owns; this feature enqueues, it does not send.
--
-- The request is approved by approve_certificate_request, which issues the
-- certificate (status 'approved'); once the PDF is stored the application calls
-- mark_certificate_request_issued ('issued') and queue_certificate_ready_message.
-- If rendering fails the issue is voided, and approving again issues a fresh one.

create table public.certificate_request_purpose (
  code                   text primary key,
  label_en               text not null,
  label_ur               text not null,
  requires_justification boolean not null default false,
  sort_order             int not null
);
insert into public.certificate_request_purpose (code, label_en, label_ur, requires_justification, sort_order) values
  ('passport',         'Passport application',      'پاسپورٹ کے لیے',          false, 1),
  ('bank',             'Bank account',              'بینک اکاؤنٹ کے لیے',       false, 2),
  ('embassy/visa',     'Embassy or visa',           'سفارت خانہ یا ویزا کے لیے', false, 3),
  ('school_admission', 'Admission to another school', 'دوسرے اسکول میں داخلے کے لیے', false, 4),
  ('scholarship',      'Scholarship',               'وظیفے کے لیے',            false, 5),
  ('other',            'Other',                     'کوئی اور وجہ',            true,  6);
alter table public.certificate_request_purpose enable row level security;
create policy certificate_request_purpose_read on public.certificate_request_purpose for select to authenticated using (true);
revoke insert, update, delete, truncate on public.certificate_request_purpose from anon, authenticated;

create type public.certificate_request_status as enum ('pending', 'approved', 'rejected', 'issued');

create table public.certificate_request (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  student_id           uuid not null references public.student(id),
  requested_by_user    uuid not null references auth.users(id),
  certificate_type     public.certificate_type not null default 'bonafide' check (certificate_type = 'bonafide'),
  purpose              text not null references public.certificate_request_purpose(code),
  justification        text,
  status               public.certificate_request_status not null default 'pending',
  decided_by           uuid references public.app_user(user_id),
  decided_at           timestamptz,
  reject_reason        text,
  certificate_issue_id uuid references public.certificate_issue(id),
  created_at           timestamptz not null default clock_timestamp(),
  constraint chk_cert_request_other_justification check (purpose <> 'other' or char_length(btrim(coalesce(justification, ''))) >= 15),
  constraint chk_cert_request_reject_reason check (status <> 'rejected' or char_length(btrim(coalesce(reject_reason, ''))) > 0)
);
create index idx_cert_request_pending on public.certificate_request (campus_id, status) where status = 'pending';
create index idx_cert_request_user on public.certificate_request (requested_by_user, created_at desc);
create index idx_cert_request_student on public.certificate_request (student_id);
create index idx_cert_request_tenant on public.certificate_request (tenant_id);
create index idx_cert_request_issue on public.certificate_request (certificate_issue_id);

create trigger certificate_request_audit after insert or update or delete on public.certificate_request
  for each row execute function app.tg_audit_row();

create table public.certificate_share_link (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  issue_id    uuid not null references public.certificate_issue(id) on delete cascade,
  token_hash  text not null unique,
  expires_at  timestamptz not null,
  created_by  uuid references public.app_user(user_id),
  created_at  timestamptz not null default clock_timestamp(),
  last_opened_at timestamptz
);
create index idx_cert_share_link_issue on public.certificate_share_link (issue_id);
create index idx_cert_share_link_tenant on public.certificate_share_link (tenant_id);

alter table public.certificate_request enable row level security;
alter table public.certificate_share_link enable row level security;
revoke insert, update, delete, truncate on public.certificate_request from anon, authenticated;
revoke all on public.certificate_share_link from anon, authenticated;
grant insert (tenant_id, campus_id, student_id, requested_by_user, purpose, justification) on public.certificate_request to authenticated;

-- A guardian reads and creates only their own requests, and only for children they are linked to.
create policy cert_request_parent_own on public.certificate_request for select to authenticated
  using (requested_by_user = (select auth.uid()) and student_id = any (app.auth_guardian_student_ids()));
create policy cert_request_parent_insert on public.certificate_request for insert to authenticated
  with check (requested_by_user = (select auth.uid()) and student_id = any (app.auth_guardian_student_ids()) and status = 'pending');
create policy cert_request_staff_scope on public.certificate_request for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'admissions_officer')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

-- ── quota ──────────────────────────────────────────────────────────────

create or replace function public.check_request_quota(p_user uuid, p_window interval default interval '24 hours')
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.certificate_request r where r.requested_by_user = p_user and r.created_at > clock_timestamp() - p_window;
$$;
revoke execute on function public.check_request_quota(uuid, interval) from public, anon;
grant execute on function public.check_request_quota(uuid, interval) to authenticated;

create or replace function app.tg_cert_request_quota()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- tenant and campus always come from the student, whatever the caller sent
  select s.tenant_id, s.campus_id into new.tenant_id, new.campus_id from public.student s where s.id = new.student_id;
  if public.check_request_quota(new.requested_by_user, interval '24 hours') >= 3 then
    raise exception 'daily limit of 3 requests reached' using errcode = '53400', hint = 'DAILY_LIMIT';
  end if;
  return new;
end;
$$;
revoke execute on function app.tg_cert_request_quota() from public, anon, authenticated;
create trigger trg_cert_request_quota before insert on public.certificate_request
  for each row execute function app.tg_cert_request_quota();

-- ── the guardian's request ─────────────────────────────────────────────
-- SECURITY INVOKER on purpose: RLS decides. A child the caller is not linked to
-- yields zero rows, indistinguishable from a child that does not exist.

create or replace function public.submit_certificate_request(p_student_id uuid, p_purpose text, p_justification text default null)
returns setof uuid
language plpgsql
security invoker
set search_path = ''
as $$
begin
  return query
  with ins as (
    insert into public.certificate_request (tenant_id, campus_id, student_id, requested_by_user, purpose, justification)
    select s.tenant_id, s.campus_id, s.id, (select auth.uid()), p_purpose, nullif(btrim(p_justification), '')
      from public.student s
     where s.id = p_student_id and s.id = any (app.auth_guardian_student_ids())
    returning id
  )
  select id from ins;
end;
$$;
revoke execute on function public.submit_certificate_request(uuid, text, text) from public, anon;
grant execute on function public.submit_certificate_request(uuid, text, text) to authenticated;

-- ── deciding ───────────────────────────────────────────────────────────

create or replace function public.approve_certificate_request(p_request_id uuid, p_language public.certificate_language default 'en')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_role   text := app.auth_role();
  v_r      public.certificate_request%rowtype;
  v_label  text;
  v_status text;
  v_out    jsonb;
begin
  if v_role not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_r from public.certificate_request where id = p_request_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_r.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_r.status = 'approved' and v_r.certificate_issue_id is not null
     and (select ci.status from public.certificate_issue ci where ci.id = v_r.certificate_issue_id) = 'void' then
    null;  -- the previous attempt's PDF failed and was voided: issue afresh
  elsif v_r.status <> 'pending' then
    raise exception 'REQUEST_NOT_PENDING' using errcode = '55000', detail = format('status=%s', v_r.status);
  end if;
  select status::text into v_status from public.student where id = v_r.student_id;
  if v_status <> 'active' then
    raise exception 'STUDENT_NOT_ENROLLED' using errcode = '55000', hint = 'A bonafide certificate is for a currently enrolled student.';
  end if;

  select case when p.requires_justification then btrim(v_r.justification) else p.label_en end into v_label
    from public.certificate_request_purpose p where p.code = v_r.purpose;

  v_out := app.fn_issue_certificate_core(v_r.student_id, null, 'bonafide'::public.certificate_type,
             jsonb_build_object('bonafide.purpose', v_label), null, p_language);
  update public.certificate_request
     set status = 'approved', decided_by = (select auth.uid()), decided_at = clock_timestamp(), certificate_issue_id = (v_out ->> 'issue_id')::uuid
   where id = p_request_id;
  return v_out || jsonb_build_object('request_id', p_request_id);
end;
$$;
revoke execute on function public.approve_certificate_request(uuid, public.certificate_language) from public, anon;
grant execute on function public.approve_certificate_request(uuid, public.certificate_language) to authenticated;

create or replace function public.reject_certificate_request(p_request_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r public.certificate_request%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'REASON_REQUIRED' using errcode = '23514';
  end if;
  select * into v_r from public.certificate_request where id = p_request_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_r.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_r.status <> 'pending' then
    raise exception 'REQUEST_NOT_PENDING' using errcode = '55000';
  end if;
  update public.certificate_request
     set status = 'rejected', reject_reason = btrim(p_reason), decided_by = (select auth.uid()), decided_at = clock_timestamp()
   where id = p_request_id;
end;
$$;
revoke execute on function public.reject_certificate_request(uuid, text) from public, anon;
grant execute on function public.reject_certificate_request(uuid, text) to authenticated;

create or replace function public.mark_certificate_request_issued(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r public.certificate_request%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_r from public.certificate_request where id = p_request_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_r.status <> 'approved' or v_r.certificate_issue_id is null
     or (select ci.status from public.certificate_issue ci where ci.id = v_r.certificate_issue_id) <> 'issued' then
    raise exception 'REQUEST_NOT_APPROVED' using errcode = '55000';
  end if;
  update public.certificate_request set status = 'issued' where id = p_request_id;
end;
$$;
revoke execute on function public.mark_certificate_request_issued(uuid) from public, anon;
grant execute on function public.mark_certificate_request_issued(uuid) to authenticated;

-- ── WhatsApp notification with a 7-day link ────────────────────────────
-- p_base_url is the public origin the link is served from (the application knows
-- it; the database does not). The token is returned once and only its hash is kept.

create or replace function public.queue_certificate_ready_message(p_request_id uuid, p_base_url text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r      public.certificate_request%rowtype;
  v_token  text;
  v_expiry timestamptz := clock_timestamp() + interval '7 days';
  v_phone  text;
  v_name   text;
  v_serial text;
  v_url    text;
  v_msg    uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_base_url !~ '^https?://[A-Za-z0-9.:-]+$' then
    raise exception 'BASE_URL_INVALID' using errcode = '22023';
  end if;
  select * into v_r from public.certificate_request where id = p_request_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_r.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_r.status <> 'issued' then
    raise exception 'REQUEST_NOT_ISSUED' using errcode = '55000';
  end if;

  select g.phone_e164 into v_phone
    from public.guardian g where g.auth_user_id = v_r.requested_by_user and g.tenant_id = v_r.tenant_id;
  select name_en into v_name from public.student where id = v_r.student_id;
  select serial_no into v_serial from public.certificate_issue where id = v_r.certificate_issue_id;
  if v_phone is null then
    return jsonb_build_object('queued', false, 'reason', 'NO_GUARDIAN_PHONE');
  end if;

  v_token := translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/=', '-_');
  insert into public.certificate_share_link (tenant_id, issue_id, token_hash, expires_at, created_by)
  values (v_r.tenant_id, v_r.certificate_issue_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), v_expiry, (select auth.uid()));
  v_url := p_base_url || '/api/certificates/share/' || v_token;

  insert into public.message (tenant_id, campus_id, recipient_type, recipient_id, recipient_phone, channel, subject, body, status, idempotency_key, metadata)
  values (v_r.tenant_id, v_r.campus_id, 'guardian', v_r.requested_by_user, v_phone, 'whatsapp', 'Bonafide certificate ready',
          format('Assalam o Alaikum. The bonafide certificate for %s (%s) is ready. Open it here (valid for 7 days): %s', v_name, v_serial, v_url),
          'queued', 'cert-ready:' || p_request_id::text,
          jsonb_build_object('template', 'certificate_ready', 'request_id', p_request_id, 'link_expires_at', v_expiry))
  on conflict (tenant_id, idempotency_key) where idempotency_key is not null do nothing
  returning id into v_msg;
  return jsonb_build_object('queued', v_msg is not null, 'message_id', v_msg, 'url', v_url, 'expires_at', v_expiry);
end;
$$;
revoke execute on function public.queue_certificate_ready_message(uuid, text) from public, anon;
grant execute on function public.queue_certificate_ready_message(uuid, text) to authenticated;

-- Used by the share route (service role) to turn an opaque token into the stored PDF path.
create or replace function public.resolve_certificate_share_link(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_l public.certificate_share_link%rowtype;
  v_i public.certificate_issue%rowtype;
begin
  select * into v_l from public.certificate_share_link where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if not found or v_l.expires_at < clock_timestamp() then
    return null;
  end if;
  select * into v_i from public.certificate_issue where id = v_l.issue_id;
  if v_i.status <> 'issued' then
    return null;
  end if;
  update public.certificate_share_link set last_opened_at = clock_timestamp() where id = v_l.id;
  return jsonb_build_object('pdf_path', v_i.pdf_path, 'serial_no', v_i.serial_no, 'pdf_sha256', v_i.pdf_sha256);
end;
$$;
revoke execute on function public.resolve_certificate_share_link(text) from public, anon, authenticated;
grant execute on function public.resolve_certificate_share_link(text) to service_role;
