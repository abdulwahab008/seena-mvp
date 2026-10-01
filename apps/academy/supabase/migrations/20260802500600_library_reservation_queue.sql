-- FR-O06: FIFO reservation queue with hold expiry.
--
-- A borrower reserves a title whose copies are all out (library_reservation). Queue position is
-- DERIVED from queued_at (then id) per title and campus, never stored: a stored position forces a
-- renumbering write across the whole queue on every lapse, and two concurrent lapses on one title
-- would deadlock on it. v_library_queue exposes the derived position.
--
-- The moment a copy becomes available again (a return, a repair restored, a lost copy found, a
-- new copy registered, a hold released) the trigger trg_library_copy_promote calls
-- promote_reservation(title, campus). It parks the copy in reserved_hold for the head of the queue
-- (status held, hold_expires_at = now + 48 h, configurable through tenant_setting
-- 'library.hold_hours') and queues the notification. A walk-in borrower scanning a reserved_hold
-- copy is refused with COPY_NOT_AVAILABLE; only the borrower it is held for can collect it.
--
-- expire_reservation_holds() (pg_cron every 30 minutes) lapses holds that were not collected,
-- releases the copy (which promotes the next in line with a fresh hold) and notifies. A lapsed
-- reservation is not a loan, so it never counts against the borrower's loan limit; collecting a
-- held copy goes through issue_copy and so IS subject to the limit (LIMIT_EXCEEDED) like any
-- loan. Reserving while at the limit is accepted.
--
-- Notifications: a row in public.message (the SMS / WhatsApp outbox of FR-M01, honouring quiet
-- hours) to the student's primary guardian, plus in-app user_notification rows for the portal
-- accounts concerned. Actual delivery is the outbox worker's job.
--
-- Also here: renew_loan(), which needs the queue (a loan with a waiting reservation cannot renew).

create type public.library_reservation_status as enum ('waiting', 'held', 'collected', 'lapsed', 'cancelled');

create table public.library_reservation (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  title_id        uuid not null references public.library_title(id),
  borrower_id     uuid not null,
  borrower_role   text not null check (borrower_role in ('student', 'teacher', 'staff')),
  queued_at       timestamptz not null default clock_timestamp(),
  status          public.library_reservation_status not null default 'waiting',
  held_copy_id    uuid references public.library_copy(id),
  held_at         timestamptz,
  hold_expires_at timestamptz,
  resolved_at     timestamptz,
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  constraint chk_reservation_held check ((status = 'held') = (held_copy_id is not null and hold_expires_at is not null) or status in ('collected', 'lapsed', 'cancelled'))
);

create unique index uq_active_reservation on public.library_reservation (title_id, borrower_id) where status in ('waiting', 'held');
create index idx_library_reservation_queue on public.library_reservation (title_id, campus_id, queued_at, id) where status = 'waiting';
create index idx_library_reservation_hold on public.library_reservation (hold_expires_at) where status = 'held';
create index idx_library_reservation_borrower on public.library_reservation (borrower_id);
create index idx_library_reservation_campus on public.library_reservation (tenant_id, campus_id, status);

create trigger library_reservation_audit after insert or update or delete on public.library_reservation
  for each row execute function app.tg_audit_row();

alter table public.library_reservation enable row level security;
revoke insert, update, delete on public.library_reservation from authenticated, anon;
create policy library_reservation_campus_scope on public.library_reservation for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_library_staff() and app.fn_library_campus_ok(campus_id));
create policy library_reservation_self_read on public.library_reservation for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (borrower_id = (select auth.uid()) or borrower_id = public.my_student_id() or borrower_id = any (app.auth_guardian_student_ids())));

create view public.v_library_queue with (security_invoker = true) as
select r.id, r.tenant_id, r.campus_id, r.title_id, r.borrower_id, r.status, r.queued_at, r.held_copy_id, r.hold_expires_at,
       case when r.status = 'waiting'
            then row_number() over (partition by r.title_id, r.campus_id, (r.status = 'waiting') order by r.queued_at, r.id)::int
       end as queue_position
  from public.library_reservation r
 where r.status in ('waiting', 'held');
grant select on public.v_library_queue to authenticated;

-- ── notifications ────────────────────────────────────────────────────────────

create or replace function app.fn_library_notify(p_tenant uuid, p_campus uuid, p_borrower uuid, p_kind text, p_title text, p_body text, p_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student public.student%rowtype;
  v_g       record;
  v_now     timestamptz := clock_timestamp();
  v_sched   timestamptz;
begin
  select * into v_student from public.student where id = p_borrower and tenant_id = p_tenant;
  if found then
    insert into public.user_notification (tenant_id, user_id, kind, title, body, link)
    select p_tenant, spa.user_id, p_kind, p_title, p_body, '/library/titles'
      from public.student_portal_account spa where spa.student_id = v_student.id and spa.status = 'active';
    select g.id, g.phone_e164, g.auth_user_id into v_g
      from public.student_guardian sg join public.guardian g on g.id = sg.guardian_id
     where sg.student_id = v_student.id and sg.to_date is null and sg.receives_academic
     order by sg.is_primary desc, sg.priority asc limit 1;
    if v_g.id is not null then
      if v_g.auth_user_id is not null then
        insert into public.user_notification (tenant_id, user_id, kind, title, body, link) values (p_tenant, v_g.auth_user_id, p_kind, p_title, p_body, '/library/titles');
      end if;
      if v_g.phone_e164 is not null then
        v_sched := case when public.is_quiet_now(p_tenant, v_now) then public.get_next_quiet_window_end(p_tenant, v_now) else v_now end;
        insert into public.message (tenant_id, campus_id, recipient_type, recipient_id, recipient_phone, channel, body, status, scheduled_at, idempotency_key, message_class, metadata)
        values (p_tenant, p_campus, 'guardian', v_g.id, v_g.phone_e164, 'sms', p_title || '. ' || p_body, 'queued', v_sched, p_key, 'reminder', jsonb_build_object('library', p_kind, 'student_id', v_student.id))
        on conflict do nothing;
      end if;
    end if;
  elsif exists (select 1 from public.app_user where user_id = p_borrower and tenant_id = p_tenant) then
    insert into public.user_notification (tenant_id, user_id, kind, title, body, link) values (p_tenant, p_borrower, p_kind, p_title, p_body, '/library/titles');
  end if;
end;
$$;
revoke execute on function app.fn_library_notify(uuid, uuid, uuid, text, text, text, text) from public, anon, authenticated;

-- ── promotion ────────────────────────────────────────────────────────────────

create or replace function public.promote_reservation(p_title_id uuid, p_campus_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_copy  public.library_copy%rowtype;
  v_res   public.library_reservation%rowtype;
  v_hours int;
  v_n     int := 0;
  v_title text;
begin
  select t.title into v_title from public.library_title t where t.id = p_title_id;
  loop
    select c.* into v_copy from public.library_copy c
     where c.title_id = p_title_id and c.campus_id = p_campus_id and c.status = 'available'
     order by c.accession_no limit 1 for update skip locked;
    exit when not found;
    select r.* into v_res from public.library_reservation r
     where r.title_id = p_title_id and r.campus_id = p_campus_id and r.status = 'waiting'
     order by r.queued_at, r.id limit 1 for update skip locked;
    exit when not found;

    select coalesce((select (s.value #>> '{}')::int from public.tenant_setting s where s.tenant_id = v_copy.tenant_id and s.key = 'library.hold_hours'), 48) into v_hours;
    update public.library_copy set status = 'reserved_hold' where id = v_copy.id;
    update public.library_reservation
       set status = 'held', held_copy_id = v_copy.id, held_at = clock_timestamp(), hold_expires_at = clock_timestamp() + make_interval(hours => v_hours)
     where id = v_res.id;
    perform app.fn_library_notify(v_res.tenant_id, v_res.campus_id, v_res.borrower_id, 'library_hold',
                                  'Your reserved book is ready',
                                  v_title || ' is being held for you at the library for ' || v_hours || ' hours.',
                                  'library_hold:' || v_res.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.promote_reservation(uuid, uuid) from public, anon, authenticated;
grant execute on function public.promote_reservation(uuid, uuid) to service_role;

create or replace function app.tg_library_copy_promote()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.promote_reservation(new.title_id, new.campus_id);
  return null;
end;
$$;
create trigger trg_library_copy_promote_ins after insert on public.library_copy
  for each row when (new.status = 'available')
  execute function app.tg_library_copy_promote();
create trigger trg_library_copy_promote after update of status on public.library_copy
  for each row when (new.status = 'available' and old.status is distinct from 'available')
  execute function app.tg_library_copy_promote();

-- ── hold expiry ──────────────────────────────────────────────────────────────

create or replace function public.expire_reservation_holds()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r       record;
  v_n     int := 0;
  v_title text;
begin
  for r in
    select * from public.library_reservation where status = 'held' and hold_expires_at <= clock_timestamp()
     order by hold_expires_at, id for update skip locked
  loop
    update public.library_reservation set status = 'lapsed', resolved_at = clock_timestamp() where id = r.id;
    select t.title into v_title from public.library_title t where t.id = r.title_id;
    perform app.fn_library_notify(r.tenant_id, r.campus_id, r.borrower_id, 'library_hold_lapsed', 'Your book hold has expired',
                                  'The hold on ' || v_title || ' was not collected in time and has been released to the next reader.', 'library_lapse:' || r.id);
    -- releasing the copy fires trg_library_copy_promote: the next in line gets a fresh hold
    update public.library_copy set status = 'available' where id = r.held_copy_id and status = 'reserved_hold';
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.expire_reservation_holds() from public, anon, authenticated;
grant execute on function public.expire_reservation_holds() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('library_reservation_expiry', '*/30 * * * *', 'select public.expire_reservation_holds();');
  end if;
exception
  when others then null;
end;
$$;

-- ── reserve / cancel ─────────────────────────────────────────────────────────
-- Library staff may reserve for anyone; a student, teacher or staff member reserves for themselves;
-- a parent for one of their children (p_borrower_id required unless they have exactly one).

create or replace function public.reserve_title(p_title_id uuid, p_borrower_id uuid default null, p_campus_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant   uuid := app.auth_tenant_id();
  v_role     text := app.auth_role();
  v_borrower uuid := p_borrower_id;
  v_b        record;
  v_campus   uuid;
  v_id       uuid;
  v_pos      int;
  v_kids     uuid[];
begin
  if v_tenant is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;
  if not exists (select 1 from public.library_title where id = p_title_id and tenant_id = v_tenant) then
    raise exception 'TITLE_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.fn_library_staff() then
    if v_borrower is null then
      raise exception 'BORROWER_NOT_FOUND' using errcode = 'P0002';
    end if;
  elsif v_role = 'parent' then
    v_kids := app.auth_guardian_student_ids();
    if v_borrower is null and cardinality(v_kids) = 1 then
      v_borrower := v_kids[1];
    end if;
    if v_borrower is null or not (v_borrower = any (v_kids)) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  elsif v_role = 'student' then
    if v_borrower is not null and v_borrower is distinct from public.my_student_id() then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    v_borrower := public.my_student_id();
  else
    if v_borrower is not null and v_borrower is distinct from (select auth.uid()) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    v_borrower := (select auth.uid());
  end if;

  select * into v_b from app.fn_library_borrower(v_borrower);
  if v_b.borrower_role is null then
    raise exception 'BORROWER_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_campus := coalesce(case when v_b.borrower_role = 'student' then v_b.campus_id end, p_campus_id, v_b.campus_id, (select (app.auth_campus_ids())[1]));
  if v_campus is null or not exists (select 1 from public.library_copy c where c.title_id = p_title_id and c.campus_id = v_campus and c.status <> 'written_off') then
    raise exception 'NO_COPIES_AT_CAMPUS' using errcode = 'P0002';
  end if;
  if app.fn_library_staff() and not app.fn_library_campus_ok(v_campus) then
    raise exception 'CAMPUS_NOT_ALLOWED' using errcode = '42501';
  end if;
  if exists (select 1 from public.library_copy c where c.title_id = p_title_id and c.campus_id = v_campus and c.status = 'available') then
    raise exception 'COPIES_AVAILABLE' using errcode = '55000';
  end if;

  insert into public.library_reservation (tenant_id, campus_id, title_id, borrower_id, borrower_role, created_by)
  values (v_tenant, v_campus, p_title_id, v_borrower, v_b.borrower_role, (select auth.uid()))
  returning id into v_id;

  select count(*)::int into v_pos from public.library_reservation r
   where r.title_id = p_title_id and r.campus_id = v_campus and r.status = 'waiting'
     and (r.queued_at, r.id) <= (select q.queued_at, q.id from public.library_reservation q where q.id = v_id);
  return jsonb_build_object('reservation_id', v_id, 'queue_position', v_pos);
exception when unique_violation then
  raise exception 'DUPLICATE_RESERVATION' using errcode = '23505';
end;
$$;
revoke execute on function public.reserve_title(uuid, uuid, uuid) from public, anon;
grant execute on function public.reserve_title(uuid, uuid, uuid) to authenticated;

create or replace function public.cancel_reservation(p_reservation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r public.library_reservation%rowtype;
begin
  select * into v_r from public.library_reservation where id = p_reservation_id and tenant_id = app.auth_tenant_id() for update;
  if not found or v_r.status not in ('waiting', 'held') then
    raise exception 'RESERVATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not (
       (app.fn_library_staff() and app.fn_library_campus_ok(v_r.campus_id))
    or v_r.borrower_id = (select auth.uid()) or v_r.borrower_id = public.my_student_id() or v_r.borrower_id = any (app.auth_guardian_student_ids())
  ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.library_reservation set status = 'cancelled', resolved_at = clock_timestamp() where id = v_r.id;
  if v_r.status = 'held' then
    update public.library_copy set status = 'available' where id = v_r.held_copy_id and status = 'reserved_hold';
  end if;
end;
$$;
revoke execute on function public.cancel_reservation(uuid) from public, anon;
grant execute on function public.cancel_reservation(uuid) to authenticated;

-- ── issue_copy, now reservation-aware ────────────────────────────────────────
-- Same contract as FR-O04, plus: a reserved_hold copy can be collected only by the borrower it is
-- held for (and only before the hold expires); collecting marks the reservation collected; issuing
-- an available copy to someone with a waiting reservation for the title fulfils that reservation.

create or replace function public.issue_copy(p_barcode text, p_borrower_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant  uuid := app.auth_tenant_id();
  v_copy    public.library_copy%rowtype;
  v_b       record;
  v_pol     public.library_borrower_policy%rowtype;
  v_res     public.library_reservation%rowtype;
  v_open    int;
  v_out     bigint;
  v_due     date;
  v_loan    uuid;
  v_title   text;
begin
  if not app.fn_library_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_copy from public.library_copy where tenant_id = v_tenant and barcode = btrim(p_barcode) for update;
  if not found then
    raise exception 'COPY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app.fn_library_campus_ok(v_copy.campus_id) then
    raise exception 'CAMPUS_NOT_ALLOWED' using errcode = '42501';
  end if;

  if v_copy.status = 'reserved_hold' then
    select * into v_res from public.library_reservation
     where held_copy_id = v_copy.id and status = 'held' and borrower_id = p_borrower_id and hold_expires_at > clock_timestamp() for update;
    if not found then
      raise exception 'COPY_NOT_AVAILABLE' using errcode = '55000';
    end if;
  elsif v_copy.status <> 'available' then
    raise exception 'COPY_NOT_AVAILABLE' using errcode = '55000';
  end if;

  select * into v_b from app.fn_library_borrower(p_borrower_id);
  if v_b.borrower_role is null or (v_b.borrower_role = 'student' and not exists (select 1 from public.student s where s.id = p_borrower_id and s.status = 'active')) then
    raise exception 'BORROWER_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_pol := public.resolve_borrower_policy(p_borrower_id, clock_timestamp(), case when v_b.borrower_role = 'student' then null else v_copy.campus_id end);
  if v_pol.id is null then
    raise exception 'NO_POLICY' using errcode = '55000';
  end if;

  v_out := app.fn_library_outstanding(p_borrower_id);
  if v_pol.block_threshold is not null and v_out >= v_pol.block_threshold then
    raise exception 'BORROWER_BLOCKED' using errcode = '55000', detail = v_out::text;
  end if;

  select count(*) into v_open from public.library_loan where tenant_id = v_tenant and borrower_id = p_borrower_id and returned_at is null;
  if v_open >= v_pol.max_loans then
    raise exception 'LIMIT_EXCEEDED' using errcode = '55000', detail = v_open || ' of ' || v_pol.max_loans;
  end if;

  v_due := app.fn_library_next_open_day(v_copy.campus_id, app.fn_karachi_today() + v_pol.loan_days);

  insert into public.library_loan (tenant_id, campus_id, copy_id, borrower_id, borrower_role, issued_by, due_on, policy_snapshot)
  values (v_tenant, v_copy.campus_id, v_copy.id, p_borrower_id, v_b.borrower_role, (select auth.uid()), v_due, to_jsonb(v_pol))
  returning id into v_loan;
  update public.library_copy set status = 'issued' where id = v_copy.id;

  update public.library_reservation set status = 'collected', resolved_at = clock_timestamp()
   where tenant_id = v_tenant and borrower_id = p_borrower_id and title_id = v_copy.title_id and campus_id = v_copy.campus_id and status in ('waiting', 'held');

  select t.title into v_title from public.library_title t where t.id = v_copy.title_id;
  return jsonb_build_object('loan_id', v_loan, 'due_on', v_due, 'copy_id', v_copy.id, 'accession_no', v_copy.accession_no, 'title', v_title,
                            'borrower_name', v_b.display_name, 'borrower_role', v_b.borrower_role, 'open_loans', v_open + 1, 'max_loans', v_pol.max_loans);
exception when unique_violation then
  raise exception 'COPY_NOT_AVAILABLE' using errcode = '55000';
end;
$$;
revoke execute on function public.issue_copy(text, uuid) from public, anon;
grant execute on function public.issue_copy(text, uuid) to authenticated;

-- ── renew ────────────────────────────────────────────────────────────────────
-- Staff (or the borrower) renew an open loan: within the snapshot's max_renewals, not overdue and
-- with nobody waiting in the queue for the title. The new due date counts from today, rolled past
-- off-days like an issue.

create or replace function public.renew_loan(p_loan_id uuid)
returns date
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_l   public.library_loan%rowtype;
  v_c   public.library_copy%rowtype;
  v_due date;
begin
  select * into v_l from public.library_loan where id = p_loan_id and tenant_id = app.auth_tenant_id() for update;
  if not found or v_l.returned_at is not null then
    raise exception 'NO_OPEN_LOAN' using errcode = 'P0002';
  end if;
  if not (
       (app.fn_library_staff() and app.fn_library_campus_ok(v_l.campus_id))
    or v_l.borrower_id = (select auth.uid()) or v_l.borrower_id = public.my_student_id() or v_l.borrower_id = any (app.auth_guardian_student_ids())
  ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_l.renewal_count >= coalesce((v_l.policy_snapshot ->> 'max_renewals')::int, 0) then
    raise exception 'RENEWAL_LIMIT' using errcode = '55000';
  end if;
  if v_l.due_on < app.fn_karachi_today() then
    raise exception 'RENEWAL_BLOCKED' using errcode = '55000', detail = 'overdue';
  end if;
  select * into v_c from public.library_copy where id = v_l.copy_id;
  if exists (select 1 from public.library_reservation r where r.title_id = v_c.title_id and r.campus_id = v_c.campus_id and r.status = 'waiting') then
    raise exception 'RENEWAL_BLOCKED' using errcode = '55000', detail = 'reserved';
  end if;
  v_due := app.fn_library_next_open_day(v_l.campus_id, app.fn_karachi_today() + coalesce((v_l.policy_snapshot ->> 'loan_days')::int, 14));
  update public.library_loan set due_on = v_due, renewal_count = renewal_count + 1 where id = v_l.id;
  return v_due;
end;
$$;
revoke execute on function public.renew_loan(uuid) from public, anon;
grant execute on function public.renew_loan(uuid) to authenticated;
