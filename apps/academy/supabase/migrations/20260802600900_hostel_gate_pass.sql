-- FR-Q03: student gate pass with return tracking.
--
-- Releasing a boarder to an unverified adult is the highest-liability action in
-- the product, so the gate pass is a controlled record:
--   * the collecting adult's CNIC must match a guardian of the student who may
--     collect the child; if it matches none, the pass can be issued ONLY by a
--     Principal-level user with a typed reason (override_reason, override_by), and
--     the warden alone is refused (GUARDIAN_NOT_VERIFIED);
--   * a student can have only one pass out at a time: a partial unique index on
--     open and overdue passes gives PASS_ALREADY_OPEN even under a race;
--   * the row is immutable: identity, purpose, times, collector and override can
--     never be edited or deleted. Only status and returned_at move, and only through
--     close_gate_pass / cancel_gate_pass / the overdue job;
--   * a pass that is still out after expected_back_at flips to overdue on the
--     15-minute job and alerts the warden (in-app) and the guardian by SMS and
--     WhatsApp (queued in the message outbox);
--   * the printed pass shows photo, GR number, serial and a QR code resolving to
--     /hostel/gate-passes/<id>, which a signed-in gate user sees on scan.
-- Serials are per campus and year (GP-2026-00001).

create type public.hostel_pass_status as enum ('open', 'returned', 'overdue', 'cancelled');

create table public.hostel_gate_pass_counter (
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  year       int not null,
  last_value int not null default 0,
  primary key (tenant_id, campus_id, year)
);
alter table public.hostel_gate_pass_counter enable row level security;
-- no policy: written only by issue_gate_pass

create table public.hostel_gate_pass (
  id                        uuid primary key default gen_random_uuid(),
  tenant_id                 uuid not null references public.tenant(id) on delete cascade,
  campus_id                 uuid not null references public.campus(id) on delete cascade,
  student_id                uuid not null references public.student(id),
  serial                    text not null,
  purpose                   text not null check (char_length(btrim(purpose)) between 3 and 200),
  destination               text check (destination is null or char_length(destination) <= 200),
  departs_at                timestamptz not null,
  expected_back_at          timestamptz not null,
  returned_at               timestamptz,
  approved_by               uuid not null references auth.users(id),
  collector_name            text not null check (char_length(btrim(collector_name)) between 2 and 120),
  collector_cnic            text not null check (collector_cnic ~ '^[0-9]{5}-[0-9]{7}-[0-9]$'),
  released_to_guardian_id   uuid references public.guardian(id),
  override_reason           text check (override_reason is null or char_length(btrim(override_reason)) >= 10),
  override_by               uuid references auth.users(id),
  status                    public.hostel_pass_status not null default 'open',
  cancel_reason             text check (cancel_reason is null or char_length(cancel_reason) <= 300),
  overdue_notified_at       timestamptz,
  created_at                timestamptz not null default now(),
  constraint chk_pass_times check (expected_back_at > departs_at),
  constraint chk_pass_verified check (released_to_guardian_id is not null or (override_reason is not null and override_by is not null))
);
create unique index uq_gate_pass_serial on public.hostel_gate_pass (tenant_id, campus_id, serial);
create unique index uq_open_pass_per_student on public.hostel_gate_pass (student_id) where status in ('open', 'overdue');
create index idx_gate_pass_scope on public.hostel_gate_pass (tenant_id, campus_id, status);
create index idx_gate_pass_guardian on public.hostel_gate_pass (released_to_guardian_id);
create index idx_gate_pass_due on public.hostel_gate_pass (expected_back_at) where status = 'open';

create trigger trg_audit_gate_pass after insert or update or delete on public.hostel_gate_pass
  for each row execute function app.tg_audit_row();

-- Only status, returned_at, cancel_reason and overdue_notified_at may ever change; no deletes.
create or replace function app.tg_gate_pass_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'GATE_PASS_IMMUTABLE' using errcode = '42501';
  end if;
  if (to_jsonb(new) - 'status' - 'returned_at' - 'cancel_reason' - 'overdue_notified_at') is distinct from
     (to_jsonb(old) - 'status' - 'returned_at' - 'cancel_reason' - 'overdue_notified_at') then
    raise exception 'GATE_PASS_IMMUTABLE' using errcode = '42501';
  end if;
  if old.status in ('returned', 'cancelled') and new.status is distinct from old.status then
    raise exception 'GATE_PASS_CLOSED' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger trg_gate_pass_immutable before update or delete on public.hostel_gate_pass
  for each row execute function app.tg_gate_pass_immutable();

alter table public.hostel_gate_pass enable row level security;
create policy hostel_gate_pass_campus_scope on public.hostel_gate_pass for select to authenticated
  using (app.fn_hostel_staff(tenant_id, campus_id));
create policy hostel_gate_pass_parent_read on public.hostel_gate_pass for select to authenticated
  using (tenant_id = app.auth_tenant_id() and (student_id = any (app.auth_guardian_student_ids()) or student_id = public.my_student_id()));

-- ── Issue ───────────────────────────────────────────────────────────────────
create or replace function public.issue_gate_pass(
  p_student_id uuid, p_purpose text, p_departs_at timestamptz, p_expected_back_at timestamptz,
  p_collector_name text, p_collector_cnic text, p_destination text default null, p_override_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stud   public.student%rowtype;
  v_tenant uuid;
  v_digits text := regexp_replace(coalesce(p_collector_cnic, ''), '\D', '', 'g');
  v_cnic   text;
  v_guard  uuid;
  v_year   int := extract(year from (p_departs_at at time zone 'Asia/Karachi'))::int;
  v_seq    int;
  v_id     uuid;
  v_super  boolean := app.auth_role() in ('owner', 'super_admin', 'principal');
  v_reason text := nullif(btrim(coalesce(p_override_reason, '')), '');
begin
  select * into v_stud from public.student where id = p_student_id and tenant_id = app.auth_tenant_id() and deleted_at is null;
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_tenant := app.fn_hostel_assert_staff(v_stud.campus_id);
  if not exists (select 1 from public.hostel_allocation a where a.student_id = p_student_id and a.starts_on <= (p_departs_at at time zone 'Asia/Karachi')::date
                  and (a.ends_on is null or a.ends_on >= (p_departs_at at time zone 'Asia/Karachi')::date)) then
    raise exception 'NOT_A_BOARDER' using errcode = '22023';
  end if;
  if length(v_digits) <> 13 then
    raise exception 'CNIC_INVALID' using errcode = '22023';
  end if;
  v_cnic := substr(v_digits, 1, 5) || '-' || substr(v_digits, 6, 7) || '-' || substr(v_digits, 13, 1);
  if p_expected_back_at <= p_departs_at then
    raise exception 'SPAN_INVALID' using errcode = '22023';
  end if;
  if exists (select 1 from public.hostel_gate_pass where student_id = p_student_id and status in ('open', 'overdue')) then
    raise exception 'PASS_ALREADY_OPEN' using errcode = '23505';
  end if;

  select g.id into v_guard
    from public.student_guardian sg join public.guardian g on g.id = sg.guardian_id
   where sg.student_id = p_student_id and sg.to_date is null and sg.may_collect_child and g.cnic_digits = v_digits
   limit 1;
  if v_guard is null then
    if not v_super then
      raise exception 'GUARDIAN_NOT_VERIFIED' using errcode = '42501', detail = 'Only a Principal can release a student to someone who is not a recorded guardian';
    end if;
    if v_reason is null or length(v_reason) < 10 then
      raise exception 'OVERRIDE_REASON_REQUIRED' using errcode = '23514';
    end if;
  end if;

  insert into public.hostel_gate_pass_counter (tenant_id, campus_id, year, last_value)
  values (v_tenant, v_stud.campus_id, v_year, 1)
  on conflict (tenant_id, campus_id, year) do update set last_value = public.hostel_gate_pass_counter.last_value + 1
  returning last_value into v_seq;

  insert into public.hostel_gate_pass (tenant_id, campus_id, student_id, serial, purpose, destination, departs_at, expected_back_at, approved_by,
                                       collector_name, collector_cnic, released_to_guardian_id, override_reason, override_by)
  values (v_tenant, v_stud.campus_id, p_student_id, 'GP-' || v_year || '-' || lpad(v_seq::text, 5, '0'), btrim(p_purpose), nullif(btrim(p_destination), ''),
          p_departs_at, p_expected_back_at, (select auth.uid()), btrim(p_collector_name), v_cnic, v_guard,
          case when v_guard is null then v_reason end, case when v_guard is null then (select auth.uid()) end)
  returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'PASS_ALREADY_OPEN' using errcode = '23505';
end;
$$;
revoke execute on function public.issue_gate_pass(uuid, text, timestamptz, timestamptz, text, text, text, text) from public, anon;
grant execute on function public.issue_gate_pass(uuid, text, timestamptz, timestamptz, text, text, text, text) to authenticated;

create or replace function public.close_gate_pass(p_pass_id uuid, p_returned_at timestamptz default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p public.hostel_gate_pass%rowtype;
begin
  select * into v_p from public.hostel_gate_pass where id = p_pass_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'PASS_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_hostel_assert_staff(v_p.campus_id);
  if v_p.status not in ('open', 'overdue') then
    raise exception 'GATE_PASS_CLOSED' using errcode = '22023';
  end if;
  update public.hostel_gate_pass set status = 'returned', returned_at = coalesce(p_returned_at, now()) where id = p_pass_id;
end;
$$;
revoke execute on function public.close_gate_pass(uuid, timestamptz) from public, anon;
grant execute on function public.close_gate_pass(uuid, timestamptz) to authenticated;

create or replace function public.cancel_gate_pass(p_pass_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p public.hostel_gate_pass%rowtype;
begin
  select * into v_p from public.hostel_gate_pass where id = p_pass_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'PASS_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_hostel_assert_staff(v_p.campus_id);
  if v_p.status <> 'open' then
    raise exception 'GATE_PASS_CLOSED' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 5 then
    raise exception 'REASON_REQUIRED' using errcode = '23514';
  end if;
  update public.hostel_gate_pass set status = 'cancelled', cancel_reason = btrim(p_reason) where id = p_pass_id;
end;
$$;
revoke execute on function public.cancel_gate_pass(uuid, text) from public, anon;
grant execute on function public.cancel_gate_pass(uuid, text) to authenticated;

-- ── Overdue job (every 15 minutes) ──────────────────────────────────────────
create or replace function public.hostel_gate_pass_overdue_check(p_now timestamptz default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  r     record;
  g     record;
  v_n   int := 0;
  v_body text;
  ch    text;
begin
  for r in
    select p.id, p.tenant_id, p.campus_id, p.serial, p.expected_back_at, p.student_id, p.released_to_guardian_id, st.name_en, st.gr_number
      from public.hostel_gate_pass p join public.student st on st.id = p.student_id
     where p.status = 'open' and p.expected_back_at < v_now
     for update of p skip locked
  loop
    update public.hostel_gate_pass set status = 'overdue', overdue_notified_at = v_now where id = r.id;
    v_n := v_n + 1;

    insert into public.user_notification (tenant_id, user_id, kind, title, body, link)
    select distinct r.tenant_id, uid, 'hostel_gate_pass_overdue', 'Gate pass overdue: ' || r.name_en,
           r.name_en || ' (GR ' || r.gr_number || ') was due back at ' || to_char(r.expected_back_at at time zone 'Asia/Karachi', 'HH24:MI DD Mon') || ' on pass ' || r.serial || '.',
           '/hostel/gate-passes/' || r.id
      from (
        select s.user_id as uid from public.hostel_block b join public.staff s on s.id = b.warden_staff_id
         where b.tenant_id = r.tenant_id and b.campus_id = r.campus_id and s.user_id is not null
        union
        select au.user_id from public.app_user au join public.user_campus uc on uc.user_id = au.user_id and uc.campus_id = r.campus_id
         where au.tenant_id = r.tenant_id and au.app_role = 'principal' and au.status = 'active'
      ) w;

    for g in
      select gu.id, gu.phone_e164, gu.preferred_language
        from public.guardian gu
       where gu.phone_e164 is not null
         and (gu.id = r.released_to_guardian_id
              or gu.id in (select sg.guardian_id from public.student_guardian sg where sg.student_id = r.student_id and sg.to_date is null and sg.is_primary))
    loop
      v_body := case when coalesce(g.preferred_language, 'en') = 'ur'
                     then r.name_en || ' کو ' || to_char(r.expected_back_at at time zone 'Asia/Karachi', 'HH24:MI') || ' بجے ہاسٹل واپس آنا تھا مگر اب تک واپس نہیں آیا۔ پاس نمبر ' || r.serial || '۔ براہِ کرم ہاسٹل سے رابطہ کریں۔'
                     else r.name_en || ' was due back at the hostel at ' || to_char(r.expected_back_at at time zone 'Asia/Karachi', 'HH24:MI') || ' (pass ' || r.serial || ') and has not returned. Please contact the hostel.' end;
      foreach ch in array array['sms', 'whatsapp'] loop
        insert into public.message (tenant_id, campus_id, recipient_type, recipient_id, recipient_phone, channel, body, status, idempotency_key, message_class, metadata)
        values (r.tenant_id, r.campus_id, 'guardian', g.id, g.phone_e164, ch::public.comm_channel, v_body, 'queued',
                'gatepass-overdue:' || r.id || ':' || ch || ':' || g.id, 'emergency',
                jsonb_build_object('kind', 'hostel_gate_pass_overdue', 'pass_id', r.id))
        on conflict do nothing;
      end loop;
    end loop;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.hostel_gate_pass_overdue_check(timestamptz) from public, anon, authenticated;
grant execute on function public.hostel_gate_pass_overdue_check(timestamptz) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('hostel_gate_pass_overdue_check', '*/15 * * * *', 'select public.hostel_gate_pass_overdue_check();');
  end if;
exception
  when others then null;
end;
$$;
