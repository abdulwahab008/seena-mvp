-- FR-P05: pickup and drop boarding attendance.
--
-- A trip leg is one route, one date, pickup or drop, run by the crew assigned
-- to the route that day. The conductor marks the manifest on a phone and
-- submits ONE batch per leg (sync_boarding_batch), never a request per student.
--
-- Idempotent by construction: every event carries a client-generated
-- device_event_id (a UUID minted when the mark is made). A unique index on it
-- means a batch retried after a 25-minute offline spell stores exactly one event
-- per student; keying on a server timestamp would duplicate on retry. A second
-- unique index (leg, student) keeps one current state per student per leg, and
-- an event older than the stored one (out of order) is ignored.
--
-- A committed boarded/dropped event enqueues a parent SMS in the same
-- transaction, in the guardian's chosen language, naming the stop and time.
-- The 15:45 exception job raises an alert to the Transport Manager for every
-- student who boarded in the morning but was never marked dropped.
-- Crew sign in with a staff account: transport_crew.staff_id -> staff.user_id.

create type public.transport_leg_type as enum ('pickup', 'drop');
create type public.transport_boarding_state as enum ('boarded', 'absent', 'dropped');

create table public.transport_trip_leg (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  route_id      uuid not null references public.transport_route(id) on delete cascade,
  assignment_id uuid not null references public.transport_trip_assignment(id),
  vehicle_id    uuid not null references public.transport_vehicle(id),
  driver_id     uuid not null references public.transport_crew(id),
  leg_date      date not null,
  leg_type      public.transport_leg_type not null,
  status        text not null default 'open' check (status in ('open', 'completed')),
  opened_by     uuid references auth.users(id),
  completed_at  timestamptz,
  created_at    timestamptz not null default now(),
  constraint uq_trip_leg unique (route_id, leg_date, leg_type)
);
create index idx_trip_leg_scope on public.transport_trip_leg (tenant_id, campus_id, leg_date);
create index idx_trip_leg_assignment on public.transport_trip_leg (assignment_id);
create index idx_trip_leg_vehicle on public.transport_trip_leg (vehicle_id);
create index idx_trip_leg_driver on public.transport_trip_leg (driver_id);

create table public.transport_boarding_event (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  trip_leg_id     uuid not null references public.transport_trip_leg(id) on delete cascade,
  student_id      uuid not null references public.student(id),
  state           public.transport_boarding_state not null,
  marked_at       timestamptz not null,
  marked_by       uuid references auth.users(id),
  device_event_id uuid not null,
  created_at      timestamptz not null default now(),
  constraint uq_boarding_event unique (trip_leg_id, student_id),
  constraint uq_boarding_device_event unique (device_event_id)
);
create index idx_boarding_scope on public.transport_boarding_event (tenant_id, campus_id);
create index idx_boarding_student on public.transport_boarding_event (student_id, marked_at desc);

create table public.transport_exception_alert (
  boarding_event_id uuid primary key references public.transport_boarding_event(id) on delete cascade,
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  raised_at         timestamptz not null default now()
);
create index idx_exception_alert_tenant on public.transport_exception_alert (tenant_id);

create trigger transport_trip_leg_audit after insert or update or delete on public.transport_trip_leg
  for each row execute function app.tg_audit_row();

-- Is the signed-in user one of the crew assigned to this leg?
create or replace function app.fn_is_leg_crew(p_leg_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.transport_trip_leg l
      join public.transport_trip_assignment a on a.id = l.assignment_id
      join public.transport_crew c on c.id in (a.driver_id, a.conductor_id, a.attendant_id)
      join public.staff s on s.id = c.staff_id
     where l.id = p_leg_id and l.tenant_id = app.auth_tenant_id() and s.user_id = (select auth.uid())
  );
$$;
revoke execute on function app.fn_is_leg_crew(uuid) from public, anon;
grant execute on function app.fn_is_leg_crew(uuid) to authenticated;

alter table public.transport_trip_leg enable row level security;
alter table public.transport_boarding_event enable row level security;
alter table public.transport_exception_alert enable row level security;
create policy transport_trip_leg_campus_scope on public.transport_trip_leg for select to authenticated
  using ((app.fn_campus_scope(tenant_id, campus_id) and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager'))
         or app.fn_is_leg_crew(id));
create policy transport_boarding_crew_read on public.transport_boarding_event for select to authenticated
  using ((app.fn_campus_scope(tenant_id, campus_id) and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager'))
         or app.fn_is_leg_crew(trip_leg_id));
create policy transport_boarding_parent_read on public.transport_boarding_event for select to authenticated
  using (tenant_id = app.auth_tenant_id() and (student_id = any (app.auth_guardian_student_ids()) or student_id = public.my_student_id()));
create policy transport_trip_leg_parent_read on public.transport_trip_leg for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.transport_boarding_event e where e.trip_leg_id = id));
-- transport_exception_alert: no policy, service role only.

-- Opens (or returns) today's leg for a route. The crew assigned that day may
-- open it, as may the transport office.
create or replace function public.open_trip_leg(p_route_id uuid, p_date date, p_leg_type public.transport_leg_type)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a  public.transport_trip_assignment%rowtype;
  v_id uuid;
  v_ok boolean;
begin
  select a.* into v_a from public.transport_trip_assignment a
   where a.route_id = p_route_id and a.tenant_id = app.auth_tenant_id() and a.effective_from <= p_date and (a.effective_to is null or a.effective_to >= p_date)
   limit 1;
  if not found then
    raise exception 'NO_ASSIGNMENT' using errcode = 'P0002';
  end if;
  v_ok := (app.fn_campus_scope(v_a.tenant_id, v_a.campus_id) and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager'))
       or exists (select 1 from public.transport_crew c join public.staff s on s.id = c.staff_id
                   where c.id in (v_a.driver_id, v_a.conductor_id, v_a.attendant_id) and s.user_id = (select auth.uid()));
  if not v_ok then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.transport_trip_leg (tenant_id, campus_id, route_id, assignment_id, vehicle_id, driver_id, leg_date, leg_type, opened_by)
  values (v_a.tenant_id, v_a.campus_id, p_route_id, v_a.id, v_a.vehicle_id, v_a.driver_id, p_date, p_leg_type, (select auth.uid()))
  on conflict (route_id, leg_date, leg_type) do nothing;
  select id into v_id from public.transport_trip_leg where route_id = p_route_id and leg_date = p_date and leg_type = p_leg_type;
  return v_id;
end;
$$;
revoke execute on function public.open_trip_leg(uuid, date, public.transport_leg_type) from public, anon;
grant execute on function public.open_trip_leg(uuid, date, public.transport_leg_type) to authenticated;

-- The list a conductor caches on the phone before the bus leaves the gate.
create or replace function public.get_leg_manifest(p_leg_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_l public.transport_trip_leg%rowtype;
begin
  select * into v_l from public.transport_trip_leg where id = p_leg_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'LEG_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not ((app.fn_campus_scope(v_l.tenant_id, v_l.campus_id) and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager')) or app.fn_is_leg_crew(p_leg_id)) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'student_id', st.id, 'name', st.name_en, 'gr_number', st.gr_number,
             'stop', sp.name, 'stop_seq', sp.seq,
             'state', e.state, 'boarded_at_pickup', exists (
               select 1 from public.transport_boarding_event pe join public.transport_trip_leg pl on pl.id = pe.trip_leg_id
                where pe.student_id = st.id and pl.route_id = v_l.route_id and pl.leg_date = v_l.leg_date and pl.leg_type = 'pickup' and pe.state = 'boarded'))
           order by sp.seq, st.name_en)
      from public.transport_allocation a
      join public.student st on st.id = a.student_id
      join public.transport_stop sp on sp.id = case when v_l.leg_type = 'pickup' then a.pickup_stop_id else a.drop_stop_id end
      left join public.transport_boarding_event e on e.trip_leg_id = p_leg_id and e.student_id = st.id
     where a.route_id = v_l.route_id and a.starts_on <= v_l.leg_date and (a.ends_on is null or a.ends_on >= v_l.leg_date)
  ), '[]'::jsonb);
end;
$$;
revoke execute on function public.get_leg_manifest(uuid) from public, anon;
grant execute on function public.get_leg_manifest(uuid) to authenticated;

-- Parent SMS for a committed boarded/dropped event, in the guardian's language.
create or replace function app.fn_notify_boarding(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  e       public.transport_boarding_event%rowtype;
  v_leg   public.transport_trip_leg%rowtype;
  v_name  text;
  v_name_ur text;
  v_stop  text;
  v_stop_ur text;
  v_time  text;
  g       record;
  v_body  text;
begin
  select * into e from public.transport_boarding_event where id = p_event_id;
  if e.state = 'absent' then
    return;
  end if;
  select * into v_leg from public.transport_trip_leg where id = e.trip_leg_id;
  select st.name_en, coalesce(st.name_ur, st.name_en) into v_name, v_name_ur from public.student st where st.id = e.student_id;
  select sp.name, coalesce(sp.name_ur, sp.name) into v_stop, v_stop_ur
    from public.transport_allocation a
    join public.transport_stop sp on sp.id = case when v_leg.leg_type = 'pickup' then a.pickup_stop_id else a.drop_stop_id end
   where a.student_id = e.student_id and a.route_id = v_leg.route_id and a.starts_on <= v_leg.leg_date and (a.ends_on is null or a.ends_on >= v_leg.leg_date)
   limit 1;
  v_time := to_char(e.marked_at at time zone 'Asia/Karachi', 'HH24:MI');
  for g in
    select gu.id, gu.phone_e164, gu.preferred_language
      from public.student_guardian sg
      join public.guardian gu on gu.id = sg.guardian_id and gu.phone_e164 is not null
     where sg.student_id = e.student_id and sg.to_date is null and sg.receives_academic
     order by sg.is_primary desc, sg.priority limit 2
  loop
    if coalesce(g.preferred_language, 'en') = 'ur' then
      v_body := case e.state when 'boarded' then v_name_ur || ' ' || v_time || ' بجے ' || coalesce(v_stop_ur, '') || ' اسٹاپ پر بس میں سوار ہو گیا۔'
                              else v_name_ur || ' کو ' || v_time || ' بجے ' || coalesce(v_stop_ur, '') || ' اسٹاپ پر اتار دیا گیا۔' end;
    else
      v_body := case e.state when 'boarded' then v_name || ' boarded the bus at ' || coalesce(v_stop, 'the stop') || ' at ' || v_time || '.'
                              else v_name || ' was dropped at ' || coalesce(v_stop, 'the stop') || ' at ' || v_time || '.' end;
    end if;
    insert into public.message (tenant_id, campus_id, recipient_type, recipient_id, recipient_phone, channel, body, status, idempotency_key, message_class, metadata)
    values (e.tenant_id, e.campus_id, 'guardian', g.id, g.phone_e164, 'sms', v_body, 'queued',
            'boarding:' || e.id || ':' || e.state || ':' || g.id, 'transactional',
            jsonb_build_object('kind', 'transport_boarding', 'event_id', e.id, 'state', e.state, 'lang', coalesce(g.preferred_language, 'en')))
    on conflict do nothing;
  end loop;
end;
$$;
revoke execute on function app.fn_notify_boarding(uuid) from public, anon, authenticated;

-- One batched call per leg. p_events is a JSON array of
-- {device_event_id, trip_leg_id, student_id, state, marked_at}.
create or replace function public.sync_boarding_batch(p_events jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ev        jsonb;
  v_leg     public.transport_trip_leg%rowtype;
  v_state   public.transport_boarding_state;
  v_dev     uuid;
  v_student uuid;
  v_marked  timestamptz;
  v_old     public.transport_boarding_event%rowtype;
  v_id      uuid;
  v_ins int := 0; v_upd int := 0; v_dup int := 0; v_rej int := 0; v_stale int := 0;
  v_allowed uuid[] := '{}';
begin
  if jsonb_typeof(p_events) <> 'array' then
    raise exception 'EVENTS_INVALID' using errcode = '22023';
  end if;
  if jsonb_array_length(p_events) > 300 then
    raise exception 'BATCH_TOO_LARGE' using errcode = '22023';
  end if;
  for ev in select * from jsonb_array_elements(p_events) loop
    begin
      v_dev := (ev ->> 'device_event_id')::uuid;
      v_student := (ev ->> 'student_id')::uuid;
      v_state := (ev ->> 'state')::public.transport_boarding_state;
      v_marked := (ev ->> 'marked_at')::timestamptz;
    exception when others then
      v_rej := v_rej + 1;
      continue;
    end;
    if exists (select 1 from public.transport_boarding_event where device_event_id = v_dev) then
      v_dup := v_dup + 1;
      continue;
    end if;
    select * into v_leg from public.transport_trip_leg where id = (ev ->> 'trip_leg_id')::uuid and tenant_id = app.auth_tenant_id();
    if not found then
      v_rej := v_rej + 1;
      continue;
    end if;
    if not (v_leg.id = any (v_allowed)) then
      if not ((app.fn_campus_scope(v_leg.tenant_id, v_leg.campus_id) and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager')) or app.fn_is_leg_crew(v_leg.id)) then
        raise exception 'FORBIDDEN' using errcode = '42501';
      end if;
      v_allowed := v_allowed || v_leg.id;
    end if;
    if (v_leg.leg_type = 'pickup' and v_state = 'dropped') or (v_leg.leg_type = 'drop' and v_state = 'boarded')
       or v_marked > now() + interval '10 minutes'
       or not exists (select 1 from public.transport_allocation a where a.student_id = v_student and a.route_id = v_leg.route_id
                       and a.starts_on <= v_leg.leg_date and (a.ends_on is null or a.ends_on >= v_leg.leg_date)) then
      v_rej := v_rej + 1;
      continue;
    end if;
    select * into v_old from public.transport_boarding_event where trip_leg_id = v_leg.id and student_id = v_student for update;
    if found then
      if v_old.marked_at > v_marked then
        v_stale := v_stale + 1;
        continue;
      end if;
      update public.transport_boarding_event set state = v_state, marked_at = v_marked, marked_by = (select auth.uid()), device_event_id = v_dev where id = v_old.id;
      v_id := v_old.id;
      v_upd := v_upd + 1;
      if v_old.state is distinct from v_state then
        perform app.fn_notify_boarding(v_id);
      end if;
    else
      begin
        insert into public.transport_boarding_event (tenant_id, campus_id, trip_leg_id, student_id, state, marked_at, marked_by, device_event_id)
        values (v_leg.tenant_id, v_leg.campus_id, v_leg.id, v_student, v_state, v_marked, (select auth.uid()), v_dev)
        returning id into v_id;
      exception when unique_violation then
        v_dup := v_dup + 1;
        continue;
      end;
      v_ins := v_ins + 1;
      perform app.fn_notify_boarding(v_id);
    end if;
  end loop;
  return jsonb_build_object('inserted', v_ins, 'updated', v_upd, 'duplicates', v_dup, 'stale', v_stale, 'rejected', v_rej);
end;
$$;
revoke execute on function public.sync_boarding_batch(jsonb) from public, anon;
grant execute on function public.sync_boarding_batch(jsonb) to authenticated;

create or replace function public.complete_trip_leg(p_leg_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_l public.transport_trip_leg%rowtype;
begin
  select * into v_l from public.transport_trip_leg where id = p_leg_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'LEG_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not ((app.fn_campus_scope(v_l.tenant_id, v_l.campus_id) and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager')) or app.fn_is_leg_crew(p_leg_id)) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.transport_trip_leg set status = 'completed', completed_at = coalesce(completed_at, now()) where id = p_leg_id;
end;
$$;
revoke execute on function public.complete_trip_leg(uuid) from public, anon;
grant execute on function public.complete_trip_leg(uuid) to authenticated;

-- 15:45 PKT job: a student marked boarded at pickup and never marked dropped
-- raises one alert (student, stop, vehicle) to the campus's Transport Managers.
create or replace function public.transport_drop_exception_check(p_date date default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_date date := coalesce(p_date, app.fn_karachi_today());
  r      record;
  v_n    int := 0;
begin
  for r in
    select e.id as event_id, e.tenant_id, e.campus_id, st.name_en, st.gr_number, l.route_id, veh.reg_no,
           coalesce((select sp.name from public.transport_allocation a join public.transport_stop sp on sp.id = a.pickup_stop_id
                      where a.student_id = e.student_id and a.route_id = l.route_id and a.starts_on <= l.leg_date and (a.ends_on is null or a.ends_on >= l.leg_date) limit 1), 'unknown stop') as stop_name
      from public.transport_boarding_event e
      join public.transport_trip_leg l on l.id = e.trip_leg_id and l.leg_type = 'pickup' and l.leg_date = v_date
      join public.student st on st.id = e.student_id
      join public.transport_vehicle veh on veh.id = l.vehicle_id
     where e.state = 'boarded'
       and not exists (select 1 from public.transport_boarding_event d join public.transport_trip_leg dl on dl.id = d.trip_leg_id
                        where d.student_id = e.student_id and dl.leg_date = v_date and dl.leg_type = 'drop' and d.state = 'dropped')
       and not exists (select 1 from public.transport_exception_alert x where x.boarding_event_id = e.id)
  loop
    insert into public.transport_exception_alert (boarding_event_id, tenant_id) values (r.event_id, r.tenant_id);
    insert into public.user_notification (tenant_id, user_id, kind, title, body, link)
    select r.tenant_id, au.user_id, 'transport_drop_exception', 'Not dropped: ' || r.name_en,
           r.name_en || ' (GR ' || r.gr_number || ') boarded at ' || r.stop_name || ' on vehicle ' || r.reg_no || ' but has not been marked dropped.', '/transport/boarding'
      from public.app_user au
      join public.user_campus uc on uc.user_id = au.user_id and uc.campus_id = r.campus_id
     where au.tenant_id = r.tenant_id and au.app_role = 'transport_manager' and au.status = 'active';
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.transport_drop_exception_check(date) from public, anon, authenticated;
grant execute on function public.transport_drop_exception_check(date) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('transport_drop_exception_check', '45 10 * * *', 'select public.transport_drop_exception_check();');
  end if;
exception
  when others then null;
end;
$$;
