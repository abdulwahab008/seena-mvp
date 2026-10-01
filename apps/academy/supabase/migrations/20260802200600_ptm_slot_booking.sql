-- FR-N11: parent-teacher meeting (PTM) slot booking.
--
-- A Principal opens a PTM event for a campus, generates 10-minute slots for the
-- class teachers (and subject teachers) taking part, and parents book a slot
-- for their child with that teacher from the portal.
--
-- The double-booking race is closed in the database, not the client. PTM
-- booking opens to the whole campus at one announced minute, so hundreds of
-- parents hit the same slots in the same second on slow connections where the
-- list they are looking at is already stale. Three layers:
--
--   1. uq_ptm_booking_slot -- a unique index on slot_id over confirmed
--      bookings. Whatever the application does, two confirmed bookings for one
--      slot cannot exist.
--   2. book_ptm_slot() takes the slot row FOR UPDATE, so concurrent attempts
--      queue behind the winner and the loser sees the booking and answers
--      'slot just taken' together with a REFRESHED slot list in the same
--      response (the client does not have to ask again).
--   3. uq_ptm_booking_pair -- one confirmed booking per (event, teacher,
--      child), so a guardian with three children may hold one slot per
--      child-teacher pair but never a second slot with the same teacher for
--      the same child.
--
-- Cancelling keeps the row (status 'cancelled') and frees the slot at once
-- because the unique index is partial. The first guardian on the slot's
-- waiting list is told (an SMS through the FR-M01 outbox) that it is open.
-- Booking confirmations go through the same outbox.
--
-- Business refusals (slot taken, past the cutoff, not open yet, pair already
-- booked) come back as { ok: false, code, message, ... } so the screen can show
-- the cutoff time or the refreshed list; authorisation failures raise.

create table public.ptm_event (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  title             text not null check (length(btrim(title)) > 0),
  event_date        date not null,
  starts_at         timestamptz not null,
  booking_opens_at  timestamptz,
  booking_cutoff_at timestamptz not null,
  slot_minutes      int not null default 10 check (slot_minutes between 5 and 60),
  status            text not null default 'open' check (status in ('open', 'cancelled')),
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  constraint chk_ptm_window check (booking_opens_at is null or booking_opens_at < booking_cutoff_at)
);
create index idx_ptm_event_campus on public.ptm_event (campus_id, event_date);
create index idx_ptm_event_tenant on public.ptm_event (tenant_id);

create table public.ptm_slot (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  event_id     uuid not null references public.ptm_event(id) on delete cascade,
  teacher_id   uuid not null references public.app_user(user_id),
  starts_at    timestamptz not null,
  duration_min int not null default 10 check (duration_min between 5 and 60),
  constraint uq_ptm_slot unique (event_id, teacher_id, starts_at)
);
create index idx_ptm_slot_lookup on public.ptm_slot (event_id, teacher_id, starts_at);
create index idx_ptm_slot_tenant on public.ptm_slot (tenant_id);
create index idx_ptm_slot_teacher on public.ptm_slot (teacher_id);

create table public.ptm_booking (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  event_id     uuid not null references public.ptm_event(id) on delete cascade,
  slot_id      uuid not null references public.ptm_slot(id) on delete cascade,
  teacher_id   uuid not null references public.app_user(user_id),
  student_id   uuid not null references public.student(id) on delete cascade,
  guardian_id  uuid not null references public.guardian(id),
  status       text not null default 'confirmed' check (status in ('confirmed', 'cancelled')),
  booked_at    timestamptz not null default clock_timestamp(),
  cancelled_at timestamptz,
  cancelled_by uuid references auth.users(id),
  constraint chk_ptm_booking_cancel check ((status = 'cancelled') = (cancelled_at is not null))
);
create unique index uq_ptm_booking_slot on public.ptm_booking (slot_id) where status = 'confirmed';
create unique index uq_ptm_booking_pair on public.ptm_booking (event_id, teacher_id, student_id) where status = 'confirmed';
create index idx_ptm_booking_student on public.ptm_booking (student_id);
create index idx_ptm_booking_guardian on public.ptm_booking (guardian_id);
create index idx_ptm_booking_teacher on public.ptm_booking (teacher_id, event_id);
create index idx_ptm_booking_event on public.ptm_booking (event_id);
create index idx_ptm_booking_tenant on public.ptm_booking (tenant_id, campus_id);

create table public.ptm_waitlist (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  slot_id     uuid not null references public.ptm_slot(id) on delete cascade,
  student_id  uuid not null references public.student(id) on delete cascade,
  guardian_id uuid not null references public.guardian(id),
  created_at  timestamptz not null default clock_timestamp(),
  notified_at timestamptz,
  constraint uq_ptm_waitlist unique (slot_id, student_id)
);
create index idx_ptm_waitlist_slot on public.ptm_waitlist (slot_id, created_at);
create index idx_ptm_waitlist_tenant on public.ptm_waitlist (tenant_id);
create index idx_ptm_waitlist_student on public.ptm_waitlist (student_id);
create index idx_ptm_waitlist_guardian on public.ptm_waitlist (guardian_id);

create trigger ptm_event_audit after insert or update or delete on public.ptm_event
  for each row execute function app.tg_audit_row();
create trigger ptm_booking_audit after insert or update or delete on public.ptm_booking
  for each row execute function app.tg_audit_row();

alter table public.ptm_event enable row level security;
alter table public.ptm_slot enable row level security;
alter table public.ptm_booking enable row level security;
alter table public.ptm_waitlist enable row level security;

-- Staff of the campus, and guardians of a child at that campus, see the event and its slots.
create policy ptm_event_read on public.ptm_event for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())
              or exists (select 1 from public.student s where s.campus_id = ptm_event.campus_id and s.id = any (app.auth_guardian_student_ids()))));
create policy ptm_slot_read on public.ptm_slot for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.ptm_event e where e.id = event_id));
-- A guardian reads only their own children's bookings; a teacher their own; leadership the campus.
create policy ptm_booking_guardian_scope on public.ptm_booking for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (student_id = any (app.auth_guardian_student_ids())
              or teacher_id = (select auth.uid())
              or (app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal')
                  and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())))));
create policy ptm_waitlist_read on public.ptm_waitlist for select to authenticated
  using (tenant_id = app.auth_tenant_id() and student_id = any (app.auth_guardian_student_ids()));

-- ── message templates (FR-M01 outbox) ────────────────────────────────────
create or replace function app.fn_ensure_ptm_templates(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_t    uuid;
begin
  foreach v_code in array array['ptm_booking_confirmed', 'ptm_slot_available'] loop
    insert into public.message_template (tenant_id, code, channel, name, audience_entity, category)
    values (p_tenant_id, v_code, 'sms', case v_code when 'ptm_booking_confirmed' then 'PTM booking confirmed' else 'PTM slot available' end, 'guardian', 'ptm')
    on conflict do nothing;
    select id into v_t from public.message_template where tenant_id = p_tenant_id and code = v_code;
    if not exists (select 1 from public.message_template_version where template_id = v_t) then
      insert into public.message_template_version (template_id, version_no, message_class, body_en, body_ur, is_published, published_at)
      values (v_t, 1, 'transactional',
        case v_code
          when 'ptm_booking_confirmed' then 'Dear {{guardian_name}}, your parent-teacher meeting for {{student_name}} with {{teacher_name}} is confirmed for {{slot_time}}.'
          else 'Dear {{guardian_name}}, a PTM slot with {{teacher_name}} for {{student_name}} at {{slot_time}} is now available. Open the parent portal to book it.' end,
        case v_code
          when 'ptm_booking_confirmed' then 'محترم {{guardian_name}}، {{student_name}} کے لیے {{teacher_name}} کے ساتھ والدین اساتذہ ملاقات {{slot_time}} پر طے ہو گئی ہے۔'
          else 'محترم {{guardian_name}}، {{teacher_name}} کے ساتھ {{student_name}} کے لیے {{slot_time}} کا وقت اب دستیاب ہے۔ بکنگ کے لیے پیرنٹ پورٹل کھولیں۔' end,
        true, now());
    end if;
  end loop;
end;
$$;
revoke execute on function app.fn_ensure_ptm_templates(uuid) from public, anon, authenticated;

create or replace function app.fn_ptm_enqueue(p_template text, p_booking_id uuid, p_guardian_id uuid, p_student_id uuid, p_slot_id uuid, p_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_g     public.guardian%rowtype;
  v_slot  public.ptm_slot%rowtype;
  v_ev    public.ptm_event%rowtype;
  v_ver   uuid;
  v_body  text;
  v_tname text;
  v_sname text;
begin
  select * into v_g from public.guardian where id = p_guardian_id;
  if v_g.phone_e164 is null then
    return;
  end if;
  select * into v_slot from public.ptm_slot where id = p_slot_id;
  select * into v_ev from public.ptm_event where id = v_slot.event_id;
  select full_name into v_tname from public.app_user where user_id = v_slot.teacher_id;
  select name_en into v_sname from public.student where id = p_student_id;
  perform app.fn_ensure_ptm_templates(v_ev.tenant_id);
  select v.id into v_ver from public.message_template t join public.message_template_version v on v.template_id = t.id
   where t.tenant_id = v_ev.tenant_id and t.code = p_template and v.is_published order by v.version_no desc limit 1;
  v_body := public.render_template(v_ver, jsonb_build_object('guardian_name', v_g.name_en, 'student_name', v_sname, 'teacher_name', coalesce(v_tname, 'the teacher'),
              'slot_time', to_char(v_slot.starts_at at time zone 'Asia/Karachi', 'DD-MM-YYYY HH24:MI')), coalesce(v_g.preferred_language, 'en'));
  insert into public.message (tenant_id, campus_id, recipient_type, recipient_id, recipient_phone, channel, body, status, idempotency_key, template_version_id, message_class, metadata)
  values (v_ev.tenant_id, v_ev.campus_id, 'guardian', v_g.id, v_g.phone_e164, 'sms', v_body, 'queued', p_key, v_ver, 'transactional',
          jsonb_build_object('ptm_event_id', v_ev.id, 'ptm_slot_id', p_slot_id, 'ptm_booking_id', p_booking_id))
  on conflict do nothing;
end;
$$;
revoke execute on function app.fn_ptm_enqueue(text, uuid, uuid, uuid, uuid, text) from public, anon, authenticated;

create or replace function app.tg_ptm_booking_confirmation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'confirmed' then
    perform app.fn_ptm_enqueue('ptm_booking_confirmed', new.id, new.guardian_id, new.student_id, new.slot_id, 'ptm_confirm:' || new.id);
  end if;
  return new;
end;
$$;
create trigger trg_ptm_booking_confirmation after insert on public.ptm_booking
  for each row execute function app.tg_ptm_booking_confirmation();

-- ── staff: events and slots ──────────────────────────────────────────────
create or replace function public.create_ptm_event(
  p_campus_id uuid, p_title text, p_event_date date, p_start_time time, p_cutoff_hours int default 24,
  p_opens_at timestamptz default null, p_slot_minutes int default 10
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_start  timestamptz := ((p_event_date + p_start_time) at time zone 'Asia/Karachi');
  v_id     uuid;
begin
  select tenant_id into v_tenant from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id();
  if v_tenant is null then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal')
     or (app.auth_role() not in ('owner', 'super_admin') and not (p_campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_cutoff_hours < 0 or p_cutoff_hours > 24 * 14 then
    raise exception 'CUTOFF_OUT_OF_RANGE' using errcode = '22023';
  end if;
  insert into public.ptm_event (tenant_id, campus_id, title, event_date, starts_at, booking_opens_at, booking_cutoff_at, slot_minutes, created_by)
  values (v_tenant, p_campus_id, btrim(p_title), p_event_date, v_start, p_opens_at, v_start - make_interval(hours => p_cutoff_hours), p_slot_minutes, (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.create_ptm_event(uuid, text, date, time, int, timestamptz, int) from public, anon;
grant execute on function public.create_ptm_event(uuid, text, date, time, int, timestamptz, int) to authenticated;

create or replace function public.generate_ptm_slots(p_event_id uuid, p_teacher_ids uuid[], p_start_time time, p_end_time time)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e     public.ptm_event%rowtype;
  v_t     uuid;
  v_n     int := 0;
  v_from  timestamptz;
  v_to    timestamptz;
  v_at    timestamptz;
  v_added int;
begin
  select * into v_e from public.ptm_event where id = p_event_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal')
     or (app.auth_role() not in ('owner', 'super_admin') and not (v_e.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_end_time <= p_start_time then
    raise exception 'END_BEFORE_START' using errcode = '22023';
  end if;
  if p_teacher_ids is null or cardinality(p_teacher_ids) = 0 or cardinality(p_teacher_ids) > 100 then
    raise exception 'TEACHERS_MUST_BE_1_TO_100' using errcode = '22023';
  end if;
  v_from := ((v_e.event_date + p_start_time) at time zone 'Asia/Karachi');
  v_to := ((v_e.event_date + p_end_time) at time zone 'Asia/Karachi');
  foreach v_t in array p_teacher_ids loop
    if not exists (select 1 from public.app_user where user_id = v_t and tenant_id = v_e.tenant_id) then
      raise exception 'TEACHER_NOT_FOUND' using errcode = 'P0002';
    end if;
    v_at := v_from;
    while v_at + make_interval(mins => v_e.slot_minutes) <= v_to loop
      insert into public.ptm_slot (tenant_id, event_id, teacher_id, starts_at, duration_min)
      values (v_e.tenant_id, p_event_id, v_t, v_at, v_e.slot_minutes) on conflict do nothing;
      get diagnostics v_added = row_count;
      v_n := v_n + v_added;
      v_at := v_at + make_interval(mins => v_e.slot_minutes);
    end loop;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.generate_ptm_slots(uuid, uuid[], time, time) from public, anon;
grant execute on function public.generate_ptm_slots(uuid, uuid[], time, time) to authenticated;

-- ── guardian: who, which slots, book, cancel ─────────────────────────────
create or replace function app.fn_ptm_guardian_for(p_student_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_g uuid;
begin
  if not (p_student_id = any (app.auth_guardian_student_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select g.id into v_g from public.guardian g join public.student_guardian sg on sg.guardian_id = g.id and sg.to_date is null
   where g.auth_user_id = (select auth.uid()) and sg.student_id = p_student_id limit 1;
  return v_g;
end;
$$;
revoke execute on function app.fn_ptm_guardian_for(uuid) from public, anon, authenticated;

-- The teachers a child can meet: the section's class teacher and its subject teachers on the day.
create or replace function app.fn_ptm_teacher_ok(p_student_id uuid, p_teacher_id uuid, p_on date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.enrolment e
     where e.student_id = p_student_id and e.status = 'active'
       and (exists (select 1 from public.section_class_teacher ct where ct.section_id = e.section_id and ct.staff_id = p_teacher_id and ct.validity @> p_on)
            or exists (select 1 from public.section_subject_teacher st where st.section_id = e.section_id and st.staff_id = p_teacher_id and st.validity @> p_on)));
$$;
revoke execute on function app.fn_ptm_teacher_ok(uuid, uuid, date) from public, anon, authenticated;

create or replace function app.fn_ptm_slot_rows(p_event_id uuid, p_student_id uuid, p_teacher_id uuid default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'slot_id', s.id, 'teacher_id', s.teacher_id, 'teacher_name', u.full_name, 'starts_at', s.starts_at, 'duration_min', s.duration_min,
           'available', not exists (select 1 from public.ptm_booking b where b.slot_id = s.id and b.status = 'confirmed'),
           'mine', exists (select 1 from public.ptm_booking b where b.slot_id = s.id and b.status = 'confirmed' and b.student_id = p_student_id))
         order by u.full_name, s.starts_at), '[]'::jsonb)
    from public.ptm_slot s
    join public.ptm_event e on e.id = s.event_id
    join public.app_user u on u.user_id = s.teacher_id
   where s.event_id = p_event_id and (p_teacher_id is null or s.teacher_id = p_teacher_id)
     and app.fn_ptm_teacher_ok(p_student_id, s.teacher_id, e.event_date);
$$;
revoke execute on function app.fn_ptm_slot_rows(uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public.ptm_slot_list(p_event_id uuid, p_student_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.fn_ptm_guardian_for(p_student_id);
  if not exists (select 1 from public.ptm_event e join public.student s on s.campus_id = e.campus_id
                  where e.id = p_event_id and e.tenant_id = app.auth_tenant_id() and s.id = p_student_id) then
    raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  return app.fn_ptm_slot_rows(p_event_id, p_student_id);
end;
$$;
revoke execute on function public.ptm_slot_list(uuid, uuid) from public, anon;
grant execute on function public.ptm_slot_list(uuid, uuid) to authenticated;

create or replace function public.book_ptm_slot(p_slot_id uuid, p_student_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_guardian uuid := app.fn_ptm_guardian_for(p_student_id);
  v_slot     public.ptm_slot%rowtype;
  v_ev       public.ptm_event%rowtype;
  v_stu      public.student%rowtype;
  v_id       uuid;
  v_now      timestamptz := clock_timestamp();
begin
  -- The slot row is the serialisation point: concurrent attempts queue here.
  select * into v_slot from public.ptm_slot where id = p_slot_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into v_ev from public.ptm_event where id = v_slot.event_id;
  select * into v_stu from public.student where id = p_student_id;
  if v_ev.campus_id <> v_stu.campus_id or v_ev.status <> 'open' then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app.fn_ptm_teacher_ok(p_student_id, v_slot.teacher_id, v_ev.event_date) then
    raise exception 'TEACHER_NOT_FOR_STUDENT' using errcode = '42501';
  end if;
  if v_ev.booking_opens_at is not null and v_now < v_ev.booking_opens_at then
    return jsonb_build_object('ok', false, 'code', 'not_open', 'message', 'Booking has not opened yet', 'opens_at', v_ev.booking_opens_at);
  end if;
  if v_now >= v_ev.booking_cutoff_at then
    return jsonb_build_object('ok', false, 'code', 'cutoff_passed', 'message', 'Booking closed at ' || to_char(v_ev.booking_cutoff_at at time zone 'Asia/Karachi', 'DD-MM-YYYY HH24:MI'),
                              'cutoff_at', v_ev.booking_cutoff_at);
  end if;
  if exists (select 1 from public.ptm_booking where slot_id = p_slot_id and status = 'confirmed') then
    return jsonb_build_object('ok', false, 'code', 'slot_taken', 'message', 'slot just taken',
                              'slots', app.fn_ptm_slot_rows(v_slot.event_id, p_student_id, v_slot.teacher_id));
  end if;
  if exists (select 1 from public.ptm_booking where event_id = v_slot.event_id and teacher_id = v_slot.teacher_id and student_id = p_student_id and status = 'confirmed') then
    return jsonb_build_object('ok', false, 'code', 'pair_already_booked', 'message', 'You already hold a slot with this teacher for this child',
                              'slots', app.fn_ptm_slot_rows(v_slot.event_id, p_student_id, v_slot.teacher_id));
  end if;
  begin
    insert into public.ptm_booking (tenant_id, campus_id, event_id, slot_id, teacher_id, student_id, guardian_id)
    values (v_slot.tenant_id, v_ev.campus_id, v_slot.event_id, p_slot_id, v_slot.teacher_id, p_student_id, v_guardian)
    returning id into v_id;
  exception when unique_violation then
    -- The backstop: another transaction won between the check and the insert.
    return jsonb_build_object('ok', false, 'code', 'slot_taken', 'message', 'slot just taken',
                              'slots', app.fn_ptm_slot_rows(v_slot.event_id, p_student_id, v_slot.teacher_id));
  end;
  delete from public.ptm_waitlist where slot_id = p_slot_id and student_id = p_student_id;
  return jsonb_build_object('ok', true, 'booking_id', v_id, 'starts_at', v_slot.starts_at);
end;
$$;
revoke execute on function public.book_ptm_slot(uuid, uuid) from public, anon;
grant execute on function public.book_ptm_slot(uuid, uuid) to authenticated;

create or replace function public.join_ptm_waitlist(p_slot_id uuid, p_student_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_guardian uuid := app.fn_ptm_guardian_for(p_student_id);
  v_slot     public.ptm_slot%rowtype;
begin
  select * into v_slot from public.ptm_slot where id = p_slot_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into public.ptm_waitlist (tenant_id, slot_id, student_id, guardian_id)
  values (v_slot.tenant_id, p_slot_id, p_student_id, v_guardian) on conflict do nothing;
end;
$$;
revoke execute on function public.join_ptm_waitlist(uuid, uuid) from public, anon;
grant execute on function public.join_ptm_waitlist(uuid, uuid) to authenticated;

create or replace function public.cancel_ptm_booking(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b  public.ptm_booking%rowtype;
  v_w  public.ptm_waitlist%rowtype;
begin
  select * into v_b from public.ptm_booking where id = p_booking_id and tenant_id = app.auth_tenant_id() and status = 'confirmed' for update;
  if not found then
    raise exception 'BOOKING_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not (v_b.student_id = any (app.auth_guardian_student_ids()))
     and not (app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal')
              and (app.auth_role() in ('owner', 'super_admin') or v_b.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.ptm_booking set status = 'cancelled', cancelled_at = clock_timestamp(), cancelled_by = (select auth.uid()) where id = p_booking_id;
  -- The slot is bookable again from this moment; offer it to the first guardian waiting.
  select * into v_w from public.ptm_waitlist w
   where w.slot_id = v_b.slot_id and w.notified_at is null
     and not exists (select 1 from public.ptm_booking x where x.event_id = v_b.event_id and x.teacher_id = v_b.teacher_id and x.student_id = w.student_id and x.status = 'confirmed')
   order by w.created_at limit 1 for update skip locked;
  if found then
    perform app.fn_ptm_enqueue('ptm_slot_available', p_booking_id, v_w.guardian_id, v_w.student_id, v_b.slot_id, 'ptm_offer:' || v_w.id);
    update public.ptm_waitlist set notified_at = clock_timestamp() where id = v_w.id;
  end if;
end;
$$;
revoke execute on function public.cancel_ptm_booking(uuid) from public, anon;
grant execute on function public.cancel_ptm_booking(uuid) to authenticated;
