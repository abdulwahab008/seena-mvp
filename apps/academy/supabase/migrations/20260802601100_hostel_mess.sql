-- FR-Q05: weekly mess menu and mess-off days.
--
-- The menu is 21 slots a week (7 days x breakfast, lunch, dinner), English and
-- Urdu. A week is visible to parents and students only once it is PUBLISHED, and
-- publishing needs all 21 slots; the publish timestamp is shown with the menu.
--
-- A mess-off is a date range a boarder is away and will not eat. A parent (or the
-- student) requests it; hostel staff approve it (or record it directly, already
-- approved). A parent request must be made at least hostel.mess_notice_hours
-- (default 24) before the start date (midnight PKT), else NOTICE_PERIOD_NOT_MET.
-- Two mess-offs for the same student cannot overlap: an exclusion constraint over
-- the inclusive date range (rejected requests are excluded from the rule so the
-- dates can be asked for again).
--
-- billable_mess_days(student, month) is the one place the count comes from: the
-- days of the month the student holds a bed, minus the days of approved mess-offs,
-- and (when the tenant setting hostel.mess_holidays_billable is false) minus
-- campus holidays. Every rupee on the challan can be explained from it.

create type public.hostel_meal as enum ('breakfast', 'lunch', 'dinner');
create type public.hostel_mess_off_status as enum ('pending', 'approved', 'rejected');

create table public.hostel_mess_menu (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  week_start   date not null check (extract(isodow from week_start) = 1),
  day_of_week  int not null check (day_of_week between 1 and 7),
  meal         public.hostel_meal not null,
  items        text not null check (char_length(btrim(items)) between 1 and 300),
  items_ur     text check (items_ur is null or char_length(items_ur) <= 300),
  published_at timestamptz,
  published_by uuid references auth.users(id),
  constraint uq_mess_slot unique (campus_id, week_start, day_of_week, meal)
);
create index idx_mess_menu_scope on public.hostel_mess_menu (tenant_id, campus_id, week_start);

create table public.hostel_mess_off (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  student_id   uuid not null references public.student(id),
  starts_on    date not null,
  ends_on      date not null,
  reason       text check (reason is null or char_length(reason) <= 300),
  status       public.hostel_mess_off_status not null default 'pending',
  requested_by uuid references auth.users(id),
  approved_by  uuid references auth.users(id),
  approved_at  timestamptz,
  created_at   timestamptz not null default now(),
  constraint chk_mess_off_span check (ends_on >= starts_on and ends_on - starts_on <= 120),
  constraint chk_mess_off_approved check (status <> 'approved' or (approved_by is not null and approved_at is not null)),
  constraint ex_mess_off_no_overlap exclude using gist (student_id with =, daterange(starts_on, ends_on, '[]') with &&) where (status <> 'rejected')
);
create index idx_mess_off_scope on public.hostel_mess_off (tenant_id, campus_id, starts_on);
create index idx_mess_off_student on public.hostel_mess_off (student_id);

create trigger hostel_mess_menu_audit after insert or update or delete on public.hostel_mess_menu
  for each row execute function app.tg_audit_row();
create trigger hostel_mess_off_audit after insert or update or delete on public.hostel_mess_off
  for each row execute function app.tg_audit_row();

-- Campuses of the signed-in parent's or student's own children.
create or replace function app.fn_family_campus_ids()
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct s.campus_id), '{}'::uuid[])
    from public.student s
   where s.tenant_id = app.auth_tenant_id() and (s.id = any (app.auth_guardian_student_ids()) or s.id = public.my_student_id());
$$;
revoke execute on function app.fn_family_campus_ids() from public, anon;
grant execute on function app.fn_family_campus_ids() to authenticated;

alter table public.hostel_mess_menu enable row level security;
alter table public.hostel_mess_off enable row level security;
create policy hostel_mess_menu_campus_read on public.hostel_mess_menu for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (app.fn_hostel_staff(tenant_id, campus_id)
              or (published_at is not null and (campus_id = any (app.auth_campus_ids()) or campus_id = any (app.fn_family_campus_ids())))));
create policy hostel_mess_off_campus_scope on public.hostel_mess_off for select to authenticated
  using (app.fn_hostel_staff(tenant_id, campus_id)
         or (tenant_id = app.auth_tenant_id() and (student_id = any (app.auth_guardian_student_ids()) or student_id = public.my_student_id())));

-- ── Menu ────────────────────────────────────────────────────────────────────
-- p_slots: [{day: 1..7, meal: breakfast|lunch|dinner, items, items_ur?}]. Replaces the draft of that week.
create or replace function public.save_mess_menu(p_campus_id uuid, p_week_start date, p_slots jsonb)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.fn_hostel_assert_staff(p_campus_id);
  v_week   date := date_trunc('week', p_week_start)::date;
  s        jsonb;
  v_n      int := 0;
begin
  if jsonb_typeof(p_slots) <> 'array' then
    raise exception 'SLOTS_INVALID' using errcode = '22023';
  end if;
  if exists (select 1 from public.hostel_mess_menu where campus_id = p_campus_id and week_start = v_week and published_at is not null) then
    raise exception 'MENU_PUBLISHED' using errcode = '22023';
  end if;
  for s in select * from jsonb_array_elements(p_slots) loop
    if nullif(btrim(s ->> 'items'), '') is null then
      continue;
    end if;
    insert into public.hostel_mess_menu (tenant_id, campus_id, week_start, day_of_week, meal, items, items_ur)
    values (v_tenant, p_campus_id, v_week, (s ->> 'day')::int, (s ->> 'meal')::public.hostel_meal, btrim(s ->> 'items'), nullif(btrim(s ->> 'items_ur'), ''))
    on conflict (campus_id, week_start, day_of_week, meal) do update set items = excluded.items, items_ur = excluded.items_ur;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.save_mess_menu(uuid, date, jsonb) from public, anon;
grant execute on function public.save_mess_menu(uuid, date, jsonb) to authenticated;

create or replace function public.publish_mess_menu(p_campus_id uuid, p_week_start date)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_week date := date_trunc('week', p_week_start)::date;
  v_at   timestamptz := clock_timestamp();
begin
  perform app.fn_hostel_assert_staff(p_campus_id);
  if (select count(*) from public.hostel_mess_menu where campus_id = p_campus_id and week_start = v_week) <> 21 then
    raise exception 'MENU_INCOMPLETE' using errcode = '23514', detail = 'All 21 meal slots (7 days x 3 meals) must be filled';
  end if;
  update public.hostel_mess_menu set published_at = coalesce(published_at, v_at), published_by = coalesce(published_by, (select auth.uid()))
   where campus_id = p_campus_id and week_start = v_week;
  return v_at;
end;
$$;
revoke execute on function public.publish_mess_menu(uuid, date) from public, anon;
grant execute on function public.publish_mess_menu(uuid, date) to authenticated;

-- ── Mess-off ────────────────────────────────────────────────────────────────
create or replace function app.fn_mess_notice_ok(p_tenant uuid, p_starts_on date, p_now timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_now <= ((p_starts_on::timestamp at time zone 'Asia/Karachi')
                   - make_interval(hours => coalesce((app.fn_transport_setting(p_tenant, 'hostel.mess_notice_hours', '24'::jsonb))::text::int, 24)));
$$;
revoke execute on function app.fn_mess_notice_ok(uuid, date, timestamptz) from public, anon, authenticated;

create or replace function app.fn_mess_off_insert(p_stud public.student, p_from date, p_to date, p_reason text, p_status public.hostel_mess_off_status)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if p_to < p_from or p_to - p_from > 120 then
    raise exception 'SPAN_INVALID' using errcode = '22023';
  end if;
  insert into public.hostel_mess_off (tenant_id, campus_id, student_id, starts_on, ends_on, reason, status, requested_by, approved_by, approved_at)
  values (p_stud.tenant_id, p_stud.campus_id, p_stud.id, p_from, p_to, nullif(btrim(p_reason), ''), p_status, (select auth.uid()),
          case when p_status = 'approved' then (select auth.uid()) end, case when p_status = 'approved' then now() end)
  returning id into v_id;
  return v_id;
exception when exclusion_violation then
  raise exception 'MESS_OFF_OVERLAP' using errcode = '23P01';
end;
$$;
revoke execute on function app.fn_mess_off_insert(public.student, date, date, text, public.hostel_mess_off_status) from public, anon, authenticated;

-- A parent or the student asks to be off the mess. Needs the tenant's notice period.
create or replace function public.request_mess_off(p_student_id uuid, p_from date, p_to date, p_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stud public.student%rowtype;
begin
  select * into v_stud from public.student
   where id = p_student_id and tenant_id = app.auth_tenant_id() and deleted_at is null
     and (id = any (app.auth_guardian_student_ids()) or id = public.my_student_id());
  if not found then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.hostel_allocation a where a.student_id = p_student_id and (a.ends_on is null or a.ends_on >= p_from) and a.starts_on <= p_to) then
    raise exception 'NOT_A_BOARDER' using errcode = '22023';
  end if;
  if not app.fn_mess_notice_ok(v_stud.tenant_id, p_from, now()) then
    raise exception 'NOTICE_PERIOD_NOT_MET' using errcode = '23514';
  end if;
  return app.fn_mess_off_insert(v_stud, p_from, p_to, p_reason, 'pending');
end;
$$;
revoke execute on function public.request_mess_off(uuid, date, date, text) from public, anon;
grant execute on function public.request_mess_off(uuid, date, date, text) to authenticated;

-- Hostel staff record an away period directly (already approved, no notice rule).
create or replace function public.record_mess_off(p_student_id uuid, p_from date, p_to date, p_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stud public.student%rowtype;
begin
  select * into v_stud from public.student where id = p_student_id and tenant_id = app.auth_tenant_id() and deleted_at is null;
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_hostel_assert_staff(v_stud.campus_id);
  return app.fn_mess_off_insert(v_stud, p_from, p_to, p_reason, 'approved');
end;
$$;
revoke execute on function public.record_mess_off(uuid, date, date, text) from public, anon;
grant execute on function public.record_mess_off(uuid, date, date, text) to authenticated;

create or replace function public.decide_mess_off(p_mess_off_id uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m public.hostel_mess_off%rowtype;
begin
  select * into v_m from public.hostel_mess_off where id = p_mess_off_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'MESS_OFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_hostel_assert_staff(v_m.campus_id);
  if v_m.status <> 'pending' then
    raise exception 'ALREADY_DECIDED' using errcode = '22023';
  end if;
  update public.hostel_mess_off
     set status = case when p_approve then 'approved'::public.hostel_mess_off_status else 'rejected'::public.hostel_mess_off_status end,
         approved_by = case when p_approve then (select auth.uid()) end, approved_at = case when p_approve then now() end
   where id = p_mess_off_id;
end;
$$;
revoke execute on function public.decide_mess_off(uuid, boolean) from public, anon;
grant execute on function public.decide_mess_off(uuid, boolean) to authenticated;

-- ── The count ───────────────────────────────────────────────────────────────
create or replace function app.fn_billable_mess_days(p_student_id uuid, p_month date)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int
    from generate_series(date_trunc('month', p_month)::date, (date_trunc('month', p_month) + interval '1 month - 1 day')::date, interval '1 day') g(d)
    join public.student st on st.id = p_student_id
   where exists (select 1 from public.hostel_allocation a where a.student_id = p_student_id and a.starts_on <= g.d::date and (a.ends_on is null or a.ends_on >= g.d::date))
     and not exists (select 1 from public.hostel_mess_off m where m.student_id = p_student_id and m.status = 'approved' and g.d::date between m.starts_on and m.ends_on)
     and (coalesce((app.fn_transport_setting(st.tenant_id, 'hostel.mess_holidays_billable', 'true'::jsonb))::text::boolean, true)
          or not exists (select 1 from public.holiday_calendar h where h.tenant_id = st.tenant_id and (h.campus_id is null or h.campus_id = st.campus_id) and h.holiday_date = g.d::date));
$$;
revoke execute on function app.fn_billable_mess_days(uuid, date) from public, anon, authenticated;

create or replace function public.billable_mess_days(p_student_id uuid, p_month date)
returns int
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.student s where s.id = p_student_id and s.tenant_id = app.auth_tenant_id()) then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  return app.fn_billable_mess_days(p_student_id, p_month);
end;
$$;
revoke execute on function public.billable_mess_days(uuid, date) from public, anon;
grant execute on function public.billable_mess_days(uuid, date) to authenticated, service_role;

-- The settings function now also knows the mess holiday rule.
create or replace function public.set_hostel_setting(p_key text, p_value jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_key = 'hostel.visiting_close' and (jsonb_typeof(p_value) <> 'string' or (p_value #>> '{}') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$') then
    raise exception 'SETTING_INVALID' using errcode = '22023';
  elsif p_key = 'hostel.visitor_retention_days' and (jsonb_typeof(p_value) <> 'number' or (p_value)::text::numeric < 7 or (p_value)::text::numeric > 3650 or (p_value)::text::numeric <> trunc((p_value)::text::numeric)) then
    raise exception 'SETTING_INVALID' using errcode = '22023';
  elsif p_key = 'hostel.mess_notice_hours' and (jsonb_typeof(p_value) <> 'number' or (p_value)::text::numeric < 0 or (p_value)::text::numeric > 720 or (p_value)::text::numeric <> trunc((p_value)::text::numeric)) then
    raise exception 'SETTING_INVALID' using errcode = '22023';
  elsif p_key = 'hostel.mess_holidays_billable' and jsonb_typeof(p_value) <> 'boolean' then
    raise exception 'SETTING_INVALID' using errcode = '22023';
  elsif p_key not in ('hostel.visiting_close', 'hostel.visitor_retention_days', 'hostel.mess_notice_hours', 'hostel.mess_holidays_billable') then
    raise exception 'SETTING_UNKNOWN' using errcode = '22023';
  end if;
  insert into public.tenant_setting (tenant_id, key, value) values (app.auth_tenant_id(), p_key, p_value)
  on conflict (tenant_id, key) do update set value = excluded.value;
end;
$$;
revoke execute on function public.set_hostel_setting(text, jsonb) from public, anon;
grant execute on function public.set_hostel_setting(text, jsonb) to authenticated;
