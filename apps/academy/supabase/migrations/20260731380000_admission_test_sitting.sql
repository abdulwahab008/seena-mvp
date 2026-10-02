-- FR-B11: schedule admission test sittings and allocate conflict-free
-- seats.
--
-- Scope cuts:
--   * Edge Function render-roll-slips and the admission-print bucket are
--     not built — same "data layer only" pattern as FR-K11/K17/K29/E10/
--     E11/B09. fn_build_roll_slip_payload() hands a future renderer the
--     exact jsonb it needs (seat_no, application_no, child_name, ordered
--     by seat), same shape as build_challan_render_payload().
--
-- Seat numbering is a plain monotonically-increasing counter per
-- sitting (max(seat_no)+1), not a gap-filling renumber on cancellation:
-- the AC's "seat numbers contiguous from 1 to 60" describes 60 straight
-- allocations with no cancellations in between, which this already
-- guarantees; re-numbering live seat assignments every time someone
-- withdraws is a real feature nobody asked for here.
--
-- fn_allocate_test_seat()'s advisory lock is keyed on the TARGET sitting
-- only — the AC's own concurrency scenario ("two officers allocate the
-- last seat simultaneously... exactly one succeeds") is exactly what
-- that serializes. A narrower, unaddressed edge case: the same
-- application reallocated to two DIFFERENT sittings at the exact same
-- instant by two racing calls isn't independently locked against each
-- other — the same class of untestable-in-single-connection-pgTAP
-- caveat already documented elsewhere in this codebase (FR-K10, FR-K16,
-- FR-B07).

create type public.test_attendance as enum ('pending', 'present', 'absent');

create table public.admission_test_sitting (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  session_id     uuid not null references public.academic_session(id) on delete cascade,
  class_level_id uuid not null references public.class_level(id),
  starts_at      timestamptz not null,
  venue          text,
  capacity       int not null,
  created_at     timestamptz not null default now(),
  constraint chk_sitting_capacity check (capacity > 0)
);

create index idx_test_sitting_campus_session on public.admission_test_sitting (campus_id, session_id);

create trigger test_sitting_audit after insert or update or delete on public.admission_test_sitting
  for each row execute function app.tg_audit_row();

create table public.admission_test_candidate (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  sitting_id       uuid not null references public.admission_test_sitting(id) on delete cascade,
  application_id   uuid not null references public.admission_application(id) on delete cascade,
  seat_no          int not null,
  attendance       public.test_attendance not null default 'pending',
  allocated_at     timestamptz not null default clock_timestamp(),
  cancelled_at     timestamptz,
  cancelled_reason text
);

-- AC: exactly one active allocation per application, across ALL
-- sittings — allocating to a new sitting is what cancels the old one,
-- not a second concurrent active row.
create unique index uq_test_candidate_app_active on public.admission_test_candidate (application_id) where cancelled_at is null;
create unique index uq_test_candidate_seat_active on public.admission_test_candidate (sitting_id, seat_no) where cancelled_at is null;

create trigger test_candidate_audit after insert or update or delete on public.admission_test_candidate
  for each row execute function app.tg_audit_row();

create or replace function public.create_test_sitting(
  p_campus_id uuid, p_session_id uuid, p_class_level_id uuid, p_starts_at timestamptz, p_capacity int, p_venue text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = v_tenant_id) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.class_level where id = p_class_level_id and tenant_id = v_tenant_id) then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_capacity < 1 then
    raise exception 'CAPACITY_MUST_BE_POSITIVE' using errcode = '23514';
  end if;

  insert into public.admission_test_sitting (tenant_id, campus_id, session_id, class_level_id, starts_at, capacity, venue)
  values (v_tenant_id, p_campus_id, p_session_id, p_class_level_id, p_starts_at, p_capacity, p_venue)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_test_sitting(uuid, uuid, uuid, timestamptz, int, text) from public, anon;
grant execute on function public.create_test_sitting(uuid, uuid, uuid, timestamptz, int, text) to authenticated;

-- AC: capacity check and seat-number assignment sit inside the same
-- locked transaction — a naive count-then-insert oversells the sitting
-- the instant two officers allocate at once.
create or replace function public.fn_allocate_test_seat(p_sitting_id uuid, p_application_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id    uuid := app.auth_tenant_id();
  v_sitting      public.admission_test_sitting%rowtype;
  v_active_count int;
  v_seat_no      int;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_sitting from public.admission_test_sitting where id = p_sitting_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'SITTING_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.admission_application where id = p_application_id and tenant_id = v_tenant_id) then
    raise exception 'APPLICATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('test-sitting:' || p_sitting_id::text, 0));

  -- AC: allocating to a new sitting supersedes any existing allocation
  -- for the same application (any sitting) rather than creating a
  -- second active row.
  update public.admission_test_candidate
     set cancelled_at = clock_timestamp(), cancelled_reason = 'Reallocated to a different sitting'
   where application_id = p_application_id and cancelled_at is null;

  select count(*) into v_active_count from public.admission_test_candidate where sitting_id = p_sitting_id and cancelled_at is null;
  if v_active_count >= v_sitting.capacity then
    raise exception 'SITTING_FULL' using errcode = '23514', detail = format('Sitting full - %s/%s', v_active_count, v_sitting.capacity);
  end if;

  select coalesce(max(seat_no), 0) + 1 into v_seat_no from public.admission_test_candidate where sitting_id = p_sitting_id;

  insert into public.admission_test_candidate (tenant_id, sitting_id, application_id, seat_no)
  values (v_tenant_id, p_sitting_id, p_application_id, v_seat_no);

  return v_seat_no;
end;
$$;

revoke execute on function public.fn_allocate_test_seat(uuid, uuid) from public, anon;
grant execute on function public.fn_allocate_test_seat(uuid, uuid) to authenticated;

-- Everything a future PDF renderer needs: the sitting's own details plus
-- every active candidate in seat order — same "build_*_payload" pattern
-- as build_challan_render_payload() (FR-K11).
create or replace function public.fn_build_roll_slip_payload(p_sitting_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_sitting    public.admission_test_sitting%rowtype;
  v_candidates jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_sitting from public.admission_test_sitting where id = p_sitting_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'SITTING_NOT_FOUND' using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'seat_no', tc.seat_no, 'application_no', aa.application_no, 'child_name', ae.child_name
         ) order by tc.seat_no), '[]'::jsonb)
    into v_candidates
    from public.admission_test_candidate tc
    join public.admission_application aa on aa.id = tc.application_id
    join public.admission_enquiry ae on ae.id = aa.enquiry_id
   where tc.sitting_id = p_sitting_id and tc.cancelled_at is null;

  return jsonb_build_object(
    'sitting_id', p_sitting_id, 'venue', v_sitting.venue, 'starts_at', v_sitting.starts_at,
    'capacity', v_sitting.capacity, 'candidates', v_candidates
  );
end;
$$;

revoke execute on function public.fn_build_roll_slip_payload(uuid) from public, anon;
grant execute on function public.fn_build_roll_slip_payload(uuid) to authenticated;

alter table public.admission_test_sitting enable row level security;
alter table public.admission_test_candidate enable row level security;

create policy test_sitting_campus_scope on public.admission_test_sitting
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy test_candidate_tenant_read on public.admission_test_candidate
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or sitting_id in (select id from public.admission_test_sitting where campus_id = any(app.auth_campus_ids()))
    )
  );
