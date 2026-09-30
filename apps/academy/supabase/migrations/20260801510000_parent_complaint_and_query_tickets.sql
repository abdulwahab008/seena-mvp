-- ==============================================================================
-- Migration: FR-N10 Parent complaint and query tickets
--
-- Acceptance Criteria:
-- 1. Given a ticket is created in category transport, when it is saved,
--    then it receives a human-readable per-campus number such as MAIN-2026-000123
--    that is unique and gap-free within the campus and year.
-- 2. Given a campus SLA of 48 working hours and a ticket raised on Friday afternoon,
--    when working hours are computed, then weekend and calendar-holiday hours are
--    excluded and no false breach is raised.
-- 3. Given the SLA elapses without a staff reply, when the escalation job runs,
--    then the ticket is flagged breached and the Principal is notified within 1 hour.
-- 4. Given a resolved ticket is reopened within 7 days, when it reopens,
--    then it keeps the same ticket number and retains the full prior thread.
-- ==============================================================================

-- ── 1. Types & Enums ─────────────────────────────────────────────────────────

do $$
begin
  if not exists (select 1 from pg_type where typname = 'ticket_category') then
    create type public.ticket_category as enum (
      'fee',
      'transport',
      'teaching',
      'discipline',
      'other'
    );
  end if;
end;
$$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'ticket_status') then
    create type public.ticket_status as enum (
      'open',
      'in_progress',
      'resolved',
      'closed'
    );
  end if;
end;
$$;

-- ── 2. Tables ────────────────────────────────────────────────────────────────

-- Counter for gap-free human-readable ticket serials
create table if not exists public.ticket_counter (
  campus_id   uuid not null references public.campus(id) on delete cascade,
  year        int not null,
  last_no     bigint not null default 0,
  primary key (campus_id, year)
);

-- Support Tickets
create table if not exists public.support_ticket (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenant(id) on delete cascade,
  campus_id             uuid not null references public.campus(id) on delete cascade,
  ticket_no             text not null,
  category              public.ticket_category not null default 'other',
  status                public.ticket_status not null default 'open',
  subject               text not null check (length(trim(subject)) >= 3),
  description           text not null,
  student_id            uuid references public.student(id) on delete set null,
  creator_user_id       uuid not null references auth.users(id),
  assigned_to           uuid references public.app_user(user_id) on delete set null,
  sla_hours             int not null default 48 check (sla_hours > 0),
  sla_due_at            timestamptz not null,
  first_staff_reply_at  timestamptz,
  breached_at           timestamptz,
  resolved_at           timestamptz,
  closed_at             timestamptz,
  created_at            timestamptz not null default clock_timestamp(),
  updated_at            timestamptz not null default clock_timestamp(),
  constraint uq_support_ticket_no unique (campus_id, ticket_no)
);

create index if not exists idx_support_ticket_campus_status on public.support_ticket(campus_id, status);
create index if not exists idx_support_ticket_creator on public.support_ticket(creator_user_id);
create index if not exists idx_support_ticket_student on public.support_ticket(student_id);
create index if not exists idx_support_ticket_sla on public.support_ticket(status, sla_due_at) where first_staff_reply_at is null and breached_at is null;

-- Ticket Messages / Thread
create table if not exists public.ticket_message (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  ticket_id   uuid not null references public.support_ticket(id) on delete cascade,
  author_id   uuid not null references auth.users(id),
  body        text not null check (length(trim(body)) > 0),
  is_internal boolean not null default false,
  created_at  timestamptz not null default clock_timestamp()
);

create index if not exists idx_ticket_message_ticket on public.ticket_message(ticket_id, created_at asc);

-- Ticket Attachments (max 3 per message, 5 MB each)
create table if not exists public.ticket_attachment (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  ticket_id     uuid not null references public.support_ticket(id) on delete cascade,
  message_id    uuid not null references public.ticket_message(id) on delete cascade,
  file_path     text not null,
  file_name     text not null,
  file_size     int not null check (file_size > 0 and file_size <= 5242880),
  content_type  text not null,
  created_at    timestamptz not null default clock_timestamp()
);

create index if not exists idx_ticket_attachment_msg on public.ticket_attachment(message_id);

-- Ticket Escalation Notifications (AC 3)
create table if not exists public.ticket_escalation_notification (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  ticket_id     uuid not null references public.support_ticket(id) on delete cascade,
  recipient_id  uuid not null references auth.users(id) on delete cascade,
  ticket_no     text not null,
  subject       text not null,
  category      public.ticket_category not null,
  is_read       boolean not null default false,
  created_at    timestamptz not null default clock_timestamp()
);

create index if not exists idx_ticket_notif_recipient on public.ticket_escalation_notification(recipient_id, is_read);

-- Storage bucket for tickets
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'tickets',
  'tickets',
  false,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'application/pdf', 'text/plain']
)
on conflict (id) do update
  set file_size_limit = 5242880,
      allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'application/pdf', 'text/plain'];

-- ── 3. Functions ─────────────────────────────────────────────────────────────

-- 3a. Gap-free Ticket Number Generator (AC 1)
create or replace function public.next_ticket_no(p_campus_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campus_code text;
  v_year int := extract(year from clock_timestamp())::int;
  v_next_val bigint;
begin
  select coalesce(nullif(trim(code), ''), 'MAIN') into v_campus_code
  from public.campus
  where id = p_campus_id;

  if v_campus_code is null then
    v_campus_code := 'CAMPUS';
  end if;

  insert into public.ticket_counter (campus_id, year, last_no)
  values (p_campus_id, v_year, 1)
  on conflict (campus_id, year) do update
    set last_no = ticket_counter.last_no + 1
  returning last_no into v_next_val;

  -- Format: MAIN-2026-000123
  return v_campus_code || '-' || v_year::text || '-' || lpad(v_next_val::text, 6, '0');
end;
$$;

grant execute on function public.next_ticket_no(uuid) to authenticated;

-- 3b. Calendar-aware Working Hours SLA Calculator (AC 2)
create or replace function public.sla_due(
  p_campus_id uuid,
  p_from timestamptz,
  p_hours int default 48
)
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_curr timestamptz := p_from;
  v_remaining_hours numeric := coalesce(p_hours, 48)::numeric;
  v_curr_date date;
  v_curr_time time;
  v_hour_start time := '08:00:00'::time;
  v_hour_end time := '16:00:00'::time;
  v_available_today numeric;
  v_safety_counter int := 0;
begin
  if v_remaining_hours <= 0 then
    return p_from;
  end if;

  while v_remaining_hours > 0 and v_safety_counter < 1000 loop
    v_safety_counter := v_safety_counter + 1;
    v_curr_date := (v_curr at time zone 'Asia/Karachi')::date;
    v_curr_time := (v_curr at time zone 'Asia/Karachi')::time;

    -- Non-working day: Sunday (dow=0), Saturday (dow=6), or calendar holiday
    if extract(dow from v_curr_date) in (0, 6) or not public.is_working_day(p_campus_id, v_curr_date) then
      v_curr := ((v_curr_date + interval '1 day')::date + v_hour_start) at time zone 'Asia/Karachi';
      continue;
    end if;

    -- Before working hours: jump to start of working hours on same day
    if v_curr_time < v_hour_start then
      v_curr := (v_curr_date + v_hour_start) at time zone 'Asia/Karachi';
      v_curr_time := v_hour_start;
    end if;

    -- After working hours: advance to next working day 08:00
    if v_curr_time >= v_hour_end then
      v_curr := ((v_curr_date + interval '1 day')::date + v_hour_start) at time zone 'Asia/Karachi';
      continue;
    end if;

    -- Working day & working time: calculate available hours until 16:00
    v_available_today := extract(epoch from (v_hour_end - v_curr_time)) / 3600.0;

    if v_remaining_hours <= v_available_today then
      v_curr := v_curr + (v_remaining_hours || ' hours')::interval;
      v_remaining_hours := 0;
    else
      v_remaining_hours := v_remaining_hours - v_available_today;
      v_curr := ((v_curr_date + interval '1 day')::date + v_hour_start) at time zone 'Asia/Karachi';
    end if;
  end loop;

  return v_curr;
end;
$$;

grant execute on function public.sla_due(uuid, timestamptz, int) to authenticated;

-- 3c. Create Support Ticket RPC
create or replace function public.create_support_ticket(
  p_campus_id   uuid,
  p_category    public.ticket_category,
  p_subject     text,
  p_description text,
  p_student_id  uuid default null,
  p_sla_hours   int default 48
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_ticket_id uuid := gen_random_uuid();
  v_msg_id uuid := gen_random_uuid();
  v_ticket_no text;
  v_sla_due timestamptz;
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Authentication required to create a support ticket';
  end if;

  select tenant_id into v_tenant_id
  from public.campus
  where id = p_campus_id;

  if v_tenant_id is null then
    raise exception 'Invalid campus specified';
  end if;

  -- Generate human-readable gap-free number
  v_ticket_no := public.next_ticket_no(p_campus_id);

  -- Calculate calendar-aware SLA
  v_sla_due := public.sla_due(p_campus_id, clock_timestamp(), coalesce(p_sla_hours, 48));

  insert into public.support_ticket (
    id,
    tenant_id,
    campus_id,
    ticket_no,
    category,
    status,
    subject,
    description,
    student_id,
    creator_user_id,
    sla_hours,
    sla_due_at,
    created_at,
    updated_at
  ) values (
    v_ticket_id,
    v_tenant_id,
    p_campus_id,
    v_ticket_no,
    p_category,
    'open',
    trim(p_subject),
    trim(p_description),
    p_student_id,
    v_user_id,
    coalesce(p_sla_hours, 48),
    v_sla_due,
    clock_timestamp(),
    clock_timestamp()
  );

  -- Initial message in thread
  insert into public.ticket_message (
    id,
    tenant_id,
    ticket_id,
    author_id,
    body,
    is_internal,
    created_at
  ) values (
    v_msg_id,
    v_tenant_id,
    v_ticket_id,
    v_user_id,
    trim(p_description),
    false,
    clock_timestamp()
  );

  return jsonb_build_object(
    'id', v_ticket_id,
    'ticket_no', v_ticket_no,
    'category', p_category,
    'status', 'open',
    'sla_due_at', v_sla_due
  );
end;
$$;

grant execute on function public.create_support_ticket(uuid, public.ticket_category, text, text, uuid, int) to authenticated;

-- 3d. Add Ticket Message RPC
create or replace function public.add_ticket_message(
  p_ticket_id   uuid,
  p_body        text,
  p_is_internal boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket record;
  v_user_id uuid := auth.uid();
  v_is_staff boolean;
  v_msg_id uuid := gen_random_uuid();
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select t.* into v_ticket
  from public.support_ticket t
  where t.id = p_ticket_id;

  if not found then
    raise exception 'Ticket not found';
  end if;

  -- Check if user is staff
  select exists (
    select 1 from public.app_user au
    where au.user_id = v_user_id
      and au.status = 'active'
  ) into v_is_staff;

  -- Parents/Students cannot create internal messages
  if p_is_internal and not v_is_staff then
    raise exception 'Internal notes can only be authored by school staff';
  end if;

  insert into public.ticket_message (
    id,
    tenant_id,
    ticket_id,
    author_id,
    body,
    is_internal,
    created_at
  ) values (
    v_msg_id,
    v_ticket.tenant_id,
    p_ticket_id,
    v_user_id,
    trim(p_body),
    coalesce(p_is_internal, false),
    clock_timestamp()
  );

  -- If staff replied publicly, record first_staff_reply_at and advance to in_progress
  if v_is_staff and not coalesce(p_is_internal, false) then
    update public.support_ticket
    set first_staff_reply_at = coalesce(first_staff_reply_at, clock_timestamp()),
        status = case when status = 'open' then 'in_progress' else status end,
        updated_at = clock_timestamp()
    where id = p_ticket_id;
  else
    update public.support_ticket
    set updated_at = clock_timestamp()
    where id = p_ticket_id;
  end if;

  return v_msg_id;
end;
$$;

grant execute on function public.add_ticket_message(uuid, text, boolean) to authenticated;

-- 3e. Resolve Ticket RPC
create or replace function public.resolve_ticket(
  p_ticket_id uuid,
  p_resolution_note text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket record;
  v_user_id uuid;
begin
  select * into v_ticket
  from public.support_ticket
  where id = p_ticket_id;

  if not found then
    raise exception 'Ticket not found';
  end if;

  v_user_id := coalesce(auth.uid(), v_ticket.assigned_to, v_ticket.creator_user_id);

  update public.support_ticket
  set status = 'resolved',
      resolved_at = clock_timestamp(),
      updated_at = clock_timestamp()
  where id = p_ticket_id;

  if p_resolution_note is not null and length(trim(p_resolution_note)) > 0 then
    insert into public.ticket_message (
      tenant_id,
      ticket_id,
      author_id,
      body,
      is_internal,
      created_at
    ) values (
      v_ticket.tenant_id,
      p_ticket_id,
      v_user_id,
      'Resolution: ' || trim(p_resolution_note),
      false,
      clock_timestamp()
    );
  end if;

  return true;
end;
$$;

grant execute on function public.resolve_ticket(uuid, text) to authenticated;

-- 3f. Reopen Ticket RPC (AC 4: within 7 days keeps same ticket number & full thread)
create or replace function public.reopen_ticket(
  p_ticket_id uuid,
  p_reason    text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket record;
  v_user_id uuid;
begin
  select * into v_ticket
  from public.support_ticket
  where id = p_ticket_id;

  if not found then
    raise exception 'Ticket not found';
  end if;

  v_user_id := coalesce(auth.uid(), v_ticket.creator_user_id);

  if v_ticket.status not in ('resolved', 'closed') then
    raise exception 'Ticket is already open or in progress';
  end if;

  if v_ticket.resolved_at is not null and v_ticket.resolved_at < clock_timestamp() - interval '7 days' then
    raise exception 'Tickets resolved more than 7 days ago cannot be reopened. Please open a new ticket.';
  end if;

  update public.support_ticket
  set status = 'open',
      resolved_at = null,
      closed_at = null,
      updated_at = clock_timestamp()
  where id = p_ticket_id;

  insert into public.ticket_message (
    tenant_id,
    ticket_id,
    author_id,
    body,
    is_internal,
    created_at
  ) values (
    v_ticket.tenant_id,
    p_ticket_id,
    v_user_id,
    'Reopened: ' || trim(p_reason),
    false,
    clock_timestamp()
  );

  return true;
end;
$$;

grant execute on function public.reopen_ticket(uuid, text) to authenticated;

-- 3g. Hourly Escalation Job (AC 3)
create or replace function public.escalate_tickets()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int := 0;
  v_ticket record;
  v_principal_user_id uuid;
begin
  for v_ticket in
    select t.id, t.tenant_id, t.campus_id, t.ticket_no, t.subject, t.category
    from public.support_ticket t
    where t.status in ('open', 'in_progress')
      and t.first_staff_reply_at is null
      and t.breached_at is null
      and t.sla_due_at < clock_timestamp()
    for update skip locked
  loop
    update public.support_ticket
    set breached_at = clock_timestamp(),
        updated_at = clock_timestamp()
    where id = v_ticket.id;

    v_count := v_count + 1;

    -- Lookup campus principal
    select au.user_id into v_principal_user_id
    from public.app_user au
    join public.user_campus uc on uc.user_id = au.user_id
    where au.tenant_id = v_ticket.tenant_id
      and uc.campus_id = v_ticket.campus_id
      and au.app_role = 'principal'
      and au.status = 'active'
    limit 1;

    if v_principal_user_id is not null then
      insert into public.ticket_escalation_notification (
        tenant_id,
        campus_id,
        ticket_id,
        recipient_id,
        ticket_no,
        subject,
        category,
        is_read
      ) values (
        v_ticket.tenant_id,
        v_ticket.campus_id,
        v_ticket.id,
        v_principal_user_id,
        v_ticket.ticket_no,
        v_ticket.subject,
        v_ticket.category,
        false
      );
    end if;
  end loop;

  return v_count;
end;
$$;

grant execute on function public.escalate_tickets() to authenticated;

-- ── 4. Row Level Security Policies ───────────────────────────────────────────

alter table public.support_ticket enable row level security;
alter table public.ticket_counter enable row level security;
alter table public.ticket_message enable row level security;
alter table public.ticket_attachment enable row level security;
alter table public.ticket_escalation_notification enable row level security;

drop policy if exists ticket_notif_recipient on public.ticket_escalation_notification;
create policy ticket_notif_recipient on public.ticket_escalation_notification
  for select to authenticated
  using (
    recipient_id = auth.uid()
    or (
      tenant_id = app.auth_tenant_id()
      and app.auth_role() in ('super_admin', 'owner', 'principal')
      and campus_id = any(app.auth_campus_ids())
    )
  );

-- 4a. Support Ticket Scope
drop policy if exists ticket_participant_scope on public.support_ticket;
create policy ticket_participant_scope on public.support_ticket
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      -- Staff campus scope
      (
        app.auth_role() not in ('parent', 'student')
        and (
          app.auth_role() in ('super_admin', 'owner')
          or campus_id = any(app.auth_campus_ids())
        )
      )
      -- Parent creator or parent of linked student
      or (
        creator_user_id = auth.uid()
        or (student_id is not null and student_id = any(app.auth_guardian_student_ids()))
      )
      -- Student creator
      or (
        creator_user_id = auth.uid()
      )
    )
  );

drop policy if exists ticket_creator_insert on public.support_ticket;
create policy ticket_creator_insert on public.support_ticket
  for insert to authenticated
  with check (
    tenant_id = app.auth_tenant_id()
    and creator_user_id = auth.uid()
  );

drop policy if exists ticket_staff_update on public.support_ticket;
create policy ticket_staff_update on public.support_ticket
  for update to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
  );

-- 4b. Ticket Message Scope (Internal notes restricted to staff)
drop policy if exists ticket_message_scope on public.ticket_message;
create policy ticket_message_scope on public.ticket_message
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      not is_internal
      or app.auth_role() not in ('parent', 'student')
    )
    and exists (
      select 1 from public.support_ticket st
      where st.id = ticket_message.ticket_id
    )
  );

drop policy if exists ticket_message_insert on public.ticket_message;
create policy ticket_message_insert on public.ticket_message
  for insert to authenticated
  with check (
    tenant_id = app.auth_tenant_id()
    and author_id = auth.uid()
    and (
      not is_internal
      or app.auth_role() not in ('parent', 'student')
    )
  );

-- 4c. Ticket Attachment Scope
drop policy if exists ticket_attachment_scope on public.ticket_attachment;
create policy ticket_attachment_scope on public.ticket_attachment
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and exists (
      select 1 from public.ticket_message tm
      where tm.id = ticket_attachment.message_id
    )
  );

drop policy if exists ticket_attachment_insert on public.ticket_attachment;
create policy ticket_attachment_insert on public.ticket_attachment
  for insert to authenticated
  with check (
    tenant_id = app.auth_tenant_id()
    and exists (
      select 1 from public.ticket_message tm
      where tm.id = ticket_attachment.message_id
        and tm.author_id = auth.uid()
    )
  );

-- 4d. Storage Policies for 'tickets' bucket
drop policy if exists "tickets_storage_select" on storage.objects;
create policy "tickets_storage_select" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'tickets'
    and (
      app.auth_role() not in ('parent', 'student')
      or exists (
        select 1 from public.ticket_attachment ta
        where ta.file_path = storage.objects.name
      )
    )
  );

drop policy if exists "tickets_storage_insert" on storage.objects;
create policy "tickets_storage_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'tickets'
  );

-- ── 5. Hourly Escalation Cron ────────────────────────────────────────────────
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('escalate-tickets', '0 * * * *', 'select public.escalate_tickets();');
  end if;
exception
  when others then null;
end;
$$;
