-- FR-I03: datesheet clash detection.
--
-- A datesheet is the dated list of papers (exam_subject rows) of one exam term
-- at one campus. A slot is one paper on one date and time window, optionally in
-- one exam hall. Saving a slot is where the clash is caught, not at publication:
--
--   * a STUDENT clash (the same pupil is a candidate of two papers whose
--     windows overlap) blocks the save and names the affected GR numbers;
--   * a hall double-booking is refused by an exclusion constraint on
--     (hall_id, time window) - structural, so no code path can skip it;
--   * hall capacity short and a Friday paper running past the campus Jummah
--     cut-off are NON-blocking warnings returned with the saved slot.
--
-- Who is a candidate is resolved through enrolment and elective selection, never
-- through class membership: Class 9 Pre-Engineering Physics and Class 9 Computer
-- Science are both Class 9 papers, and only the pupils registered for both
-- clash. app.fn_exam_subject_candidates() is that one resolver; FR-I09 (seating)
-- and FR-I10 (invigilation) reuse it.
--
-- exam_settings is the per-campus exam office configuration (Jummah cut-off now;
-- the question cooldown, moderation caps, paper release offset and invigilation
-- duty cap are used by later exam FRs and live on the same row so a campus has
-- one place to set them). It is created idempotently.

create extension if not exists btree_gist;

-- ═══════════════════════════════════════════════════════════════════════
-- exam_settings: one row per campus, seeded with defaults
-- ═══════════════════════════════════════════════════════════════════════

create table if not exists public.exam_settings (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  campus_id   uuid not null references public.campus(id) on delete cascade,
  created_at  timestamptz not null default now(),
  constraint uq_exam_settings_campus unique (campus_id)
);
alter table public.exam_settings add column if not exists jummah_cutoff time not null default '12:00';
alter table public.exam_settings add column if not exists question_cooldown_terms int not null default 4;
alter table public.exam_settings add column if not exists cooldown_mode text not null default 'warn';
alter table public.exam_settings add column if not exists max_moderation_delta numeric(6,2) not null default 5;
alter table public.exam_settings add column if not exists max_moderation_pct numeric(5,2);
alter table public.exam_settings add column if not exists paper_release_offset_minutes int not null default 120;
alter table public.exam_settings add column if not exists invigilation_max_duties int not null default 5;
alter table public.exam_settings add column if not exists updated_at timestamptz not null default now();
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'chk_exam_settings_cooldown_mode') then
    alter table public.exam_settings add constraint chk_exam_settings_cooldown_mode check (cooldown_mode in ('warn', 'block'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'chk_exam_settings_ranges') then
    alter table public.exam_settings add constraint chk_exam_settings_ranges check (
      question_cooldown_terms between 0 and 40
      and max_moderation_delta between 0 and 100
      and (max_moderation_pct is null or max_moderation_pct between 0 and 100)
      and paper_release_offset_minutes between 0 and 1440
      and invigilation_max_duties between 1 and 100);
  end if;
end $$;
create index if not exists idx_exam_settings_tenant on public.exam_settings (tenant_id);

alter table public.exam_settings enable row level security;
drop policy if exists exam_settings_campus_scope on public.exam_settings;
create policy exam_settings_campus_scope on public.exam_settings for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

drop trigger if exists exam_settings_audit on public.exam_settings;
create trigger exam_settings_audit after insert or update or delete on public.exam_settings
  for each row execute function app.tg_audit_row();

create or replace function app.tg_seed_exam_settings()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.exam_settings (tenant_id, campus_id) values (new.tenant_id, new.id) on conflict (campus_id) do nothing;
  return new;
end;
$$;
drop trigger if exists campus_seed_exam_settings on public.campus;
create trigger campus_seed_exam_settings after insert on public.campus
  for each row execute function app.tg_seed_exam_settings();
insert into public.exam_settings (tenant_id, campus_id) select tenant_id, id from public.campus on conflict (campus_id) do nothing;

-- The exam office: who may write the exam schedule, papers and settings of a
-- campus. Raises, so callers are one line.
create or replace function app.fn_exam_office(p_campus_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (p_campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function app.fn_exam_office(uuid) from public, anon, authenticated;

create or replace function public.save_exam_settings(p_campus_id uuid, p_settings jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text;
begin
  perform app.fn_exam_office(p_campus_id);
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then
    raise exception 'SETTINGS_INVALID' using errcode = '22023';
  end if;
  for v_key in select jsonb_object_keys(p_settings) loop
    if v_key not in ('jummah_cutoff', 'question_cooldown_terms', 'cooldown_mode', 'max_moderation_delta', 'max_moderation_pct', 'paper_release_offset_minutes', 'invigilation_max_duties') then
      raise exception 'SETTING_UNKNOWN: %', v_key using errcode = '22023';
    end if;
  end loop;
  insert into public.exam_settings (tenant_id, campus_id) values (app.auth_tenant_id(), p_campus_id) on conflict (campus_id) do nothing;
  begin
    update public.exam_settings s set
      jummah_cutoff = coalesce((p_settings ->> 'jummah_cutoff')::time, s.jummah_cutoff),
      question_cooldown_terms = coalesce((p_settings ->> 'question_cooldown_terms')::int, s.question_cooldown_terms),
      cooldown_mode = coalesce(p_settings ->> 'cooldown_mode', s.cooldown_mode),
      max_moderation_delta = coalesce((p_settings ->> 'max_moderation_delta')::numeric, s.max_moderation_delta),
      max_moderation_pct = case when p_settings ? 'max_moderation_pct' then (p_settings ->> 'max_moderation_pct')::numeric else s.max_moderation_pct end,
      paper_release_offset_minutes = coalesce((p_settings ->> 'paper_release_offset_minutes')::int, s.paper_release_offset_minutes),
      invigilation_max_duties = coalesce((p_settings ->> 'invigilation_max_duties')::int, s.invigilation_max_duties),
      updated_at = now()
     where s.campus_id = p_campus_id;
  exception when check_violation or invalid_text_representation or numeric_value_out_of_range then
    raise exception 'SETTINGS_INVALID' using errcode = '22023';
  end;
end;
$$;
revoke execute on function public.save_exam_settings(uuid, jsonb) from public, anon;
grant execute on function public.save_exam_settings(uuid, jsonb) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Halls, datesheets, slots
-- ═══════════════════════════════════════════════════════════════════════

create table public.exam_hall (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  code           text not null check (length(btrim(code)) > 0),
  name           text not null check (length(btrim(name)) > 0),
  rows_count     int not null check (rows_count between 1 and 100),
  seats_per_row  int not null check (seats_per_row between 1 and 100),
  capacity       int generated always as (rows_count * seats_per_row) stored,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);
create unique index uq_exam_hall_code on public.exam_hall (campus_id, upper(code));
create index idx_exam_hall_tenant on public.exam_hall (tenant_id);

create table public.datesheet (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  session_id      uuid not null references public.academic_session(id) on delete cascade,
  exam_term_id    uuid not null references public.exam_term(id) on delete cascade,
  title           text not null check (length(btrim(title)) > 0),
  status          text not null default 'draft' check (status in ('draft', 'published')),
  current_version int not null default 0,
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  constraint uq_datesheet_term unique (campus_id, exam_term_id)
);
create index idx_datesheet_tenant on public.datesheet (tenant_id);
create index idx_datesheet_session on public.datesheet (session_id);
create index idx_datesheet_term on public.datesheet (exam_term_id);

create table public.datesheet_slot (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenant(id) on delete cascade,
  campus_id             uuid not null references public.campus(id) on delete cascade,
  datesheet_id          uuid not null references public.datesheet(id) on delete cascade,
  exam_subject_id       uuid not null references public.exam_subject(id) on delete cascade,
  start_at              timestamptz not null,
  end_at                timestamptz not null,
  hall_id               uuid references public.exam_hall(id) on delete set null,
  invigilators_required int not null default 1 check (invigilators_required between 1 and 50),
  created_at            timestamptz not null default now(),
  constraint chk_datesheet_slot_window check (end_at > start_at),
  constraint uq_datesheet_slot_paper unique (datesheet_id, exam_subject_id),
  -- Two papers cannot hold the same hall over overlapping windows. The
  -- constraint's own GiST index on (hall_id, tstzrange) is the lookup index
  -- the spec calls idx_slot_window.
  constraint ex_datesheet_slot_hall_window exclude using gist (hall_id with =, tstzrange(start_at, end_at) with &&) where (hall_id is not null)
);
create index idx_datesheet_slot_datesheet on public.datesheet_slot (datesheet_id);
create index idx_datesheet_slot_subject on public.datesheet_slot (exam_subject_id);
create index idx_datesheet_slot_hall on public.datesheet_slot (hall_id);
create index idx_datesheet_slot_campus_window on public.datesheet_slot (campus_id, start_at);
create index idx_datesheet_slot_tenant on public.datesheet_slot (tenant_id);

create trigger exam_hall_audit after insert or update or delete on public.exam_hall
  for each row execute function app.tg_audit_row();
create trigger datesheet_audit after insert or update or delete on public.datesheet
  for each row execute function app.tg_audit_row();
create trigger datesheet_slot_audit after insert or update or delete on public.datesheet_slot
  for each row execute function app.tg_audit_row();

alter table public.exam_hall enable row level security;
alter table public.datesheet enable row level security;
alter table public.datesheet_slot enable row level security;
create policy exam_hall_campus_scope on public.exam_hall for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy datesheet_campus_scope on public.datesheet for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy datesheet_slot_campus_scope on public.datesheet_slot for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

-- ═══════════════════════════════════════════════════════════════════════
-- Candidate resolution: enrolment + elective selection, not class membership
-- ═══════════════════════════════════════════════════════════════════════

-- The candidates of one exam paper. An active enrolment of the paper's class and
-- session qualifies when the subject is not an elective, or when the pupil chose
-- it in student_elective_choice; a stream-specific subject also needs the pupil's
-- section to belong to that stream.
create or replace function app.fn_exam_subject_candidates(p_exam_subject_id uuid)
returns table (enrolment_id uuid, student_id uuid, section_id uuid, gr_number text, roll_no int)
language sql
stable
security definer
set search_path = ''
as $$
  select e.id, e.student_id, e.section_id, st.gr_number, e.roll_no
    from public.exam_subject es
    join public.class_subject cs on cs.id = es.class_subject_id
    join public.enrolment e
      on e.campus_id = cs.campus_id and e.session_id = cs.session_id and e.class_level_id = cs.class_level_id
     and e.status = 'active' and e.deleted_at is null
    join public.class_section sec on sec.id = e.section_id
    join public.student st on st.id = e.student_id and st.deleted_at is null
   where es.id = p_exam_subject_id
     and (cs.stream_id is null or sec.stream_id = cs.stream_id)
     and (cs.elective_bucket is null
          or exists (select 1 from public.student_elective_choice c
                      where c.student_id = e.student_id and c.session_id = cs.session_id
                        and c.class_level_id = cs.class_level_id and c.elective_bucket = cs.elective_bucket
                        and c.subject_id = cs.subject_id));
$$;
revoke execute on function app.fn_exam_subject_candidates(uuid) from public, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Clash detection
-- ═══════════════════════════════════════════════════════════════════════

-- Every pair of overlapping slots (one of them on this datesheet, the other on
-- any datesheet of the same campus) with the pupils they share. A pair inside
-- the datesheet is reported once.
create or replace function public.fn_detect_datesheet_clash(p_datesheet_id uuid)
returns table (slot_a uuid, slot_b uuid, affected_count int, affected_gr_numbers text[])
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ds public.datesheet%rowtype;
begin
  select * into v_ds from public.datesheet where id = p_datesheet_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'DATESHEET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() in ('parent', 'student', 'none')
     or (app.auth_role() not in ('owner', 'super_admin') and not (v_ds.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
    with pairs as (
      select a.id as sa, b.id as sb, a.exam_subject_id as ea, b.exam_subject_id as eb
        from public.datesheet_slot a
        join public.datesheet_slot b
          on b.campus_id = a.campus_id and b.id <> a.id
         and tstzrange(a.start_at, a.end_at) && tstzrange(b.start_at, b.end_at)
       where a.datesheet_id = p_datesheet_id
         and (b.datesheet_id <> p_datesheet_id or a.id < b.id)
    )
    select p.sa, p.sb, count(*)::int, array_agg(shared.gr_number order by shared.gr_number)
      from pairs p
      cross join lateral (
        select ca.gr_number
          from app.fn_exam_subject_candidates(p.ea) ca
          join app.fn_exam_subject_candidates(p.eb) cb on cb.student_id = ca.student_id
      ) shared
     group by p.sa, p.sb;
end;
$$;
revoke execute on function public.fn_detect_datesheet_clash(uuid) from public, anon;
grant execute on function public.fn_detect_datesheet_clash(uuid) to authenticated;

-- Non-blocking warnings for one slot, as a jsonb array. A hall that fits yields
-- a plain note rather than nothing, so the controller sees the headroom.
create or replace function app.fn_slot_warnings(p_slot_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_slot   public.datesheet_slot%rowtype;
  v_hall   public.exam_hall%rowtype;
  v_tz     text;
  v_cutoff time;
  v_local_start timestamp;
  v_local_end   timestamp;
  v_cands  int;
  v_out    jsonb := '[]'::jsonb;
begin
  select * into v_slot from public.datesheet_slot where id = p_slot_id;
  if not found then
    return v_out;
  end if;
  select timezone into v_tz from public.campus where id = v_slot.campus_id;
  v_cutoff := coalesce((select jummah_cutoff from public.exam_settings where campus_id = v_slot.campus_id), time '12:00');
  v_local_start := v_slot.start_at at time zone coalesce(v_tz, 'Asia/Karachi');
  v_local_end := v_slot.end_at at time zone coalesce(v_tz, 'Asia/Karachi');

  if v_slot.hall_id is not null then
    select * into v_hall from public.exam_hall where id = v_slot.hall_id;
    select count(*)::int into v_cands from app.fn_exam_subject_candidates(v_slot.exam_subject_id);
    if v_cands > v_hall.capacity then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'code', 'capacity_short', 'severity', 'warning', 'candidates', v_cands, 'capacity', v_hall.capacity,
        'short_by', v_cands - v_hall.capacity, 'message', format('capacity short by %s', v_cands - v_hall.capacity)));
    else
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'code', 'hall_capacity', 'severity', 'note', 'candidates', v_cands, 'capacity', v_hall.capacity,
        'message', format('%s candidates in a hall of %s', v_cands, v_hall.capacity)));
    end if;
  end if;

  -- Friday, and the paper is still running when the Jummah cut-off passes.
  if extract(isodow from v_local_start) = 5 and v_local_end::time > v_cutoff and v_local_end::date = v_local_start::date then
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'code', 'jummah_conflict', 'severity', 'warning', 'cutoff', to_char(v_cutoff, 'HH24:MI'),
      'message', format('Jummah conflict: the paper runs until %s on a Friday, past the %s cut-off', to_char(v_local_end, 'HH24:MI'), to_char(v_cutoff, 'HH24:MI'))));
  end if;
  return v_out;
end;
$$;
revoke execute on function app.fn_slot_warnings(uuid) from public, anon, authenticated;

create or replace function public.fn_datesheet_warnings(p_datesheet_id uuid)
returns table (slot_id uuid, warnings jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ds public.datesheet%rowtype;
begin
  select * into v_ds from public.datesheet where id = p_datesheet_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'DATESHEET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() in ('parent', 'student', 'none')
     or (app.auth_role() not in ('owner', 'super_admin') and not (v_ds.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query select s.id, app.fn_slot_warnings(s.id) from public.datesheet_slot s where s.datesheet_id = p_datesheet_id;
end;
$$;
revoke execute on function public.fn_datesheet_warnings(uuid) from public, anon;
grant execute on function public.fn_datesheet_warnings(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Writers
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.save_exam_hall(
  p_campus_id uuid, p_code text, p_name text, p_rows_count int, p_seats_per_row int, p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.fn_exam_office(p_campus_id);
  if p_rows_count is null or p_rows_count not between 1 and 100 or p_seats_per_row is null or p_seats_per_row not between 1 and 100 then
    raise exception 'HALL_SIZE_INVALID' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_code, ''))) = 0 or length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'HALL_NAME_REQUIRED' using errcode = '22023';
  end if;
  insert into public.exam_hall (tenant_id, campus_id, code, name, rows_count, seats_per_row, is_active)
  values (app.auth_tenant_id(), p_campus_id, btrim(p_code), btrim(p_name), p_rows_count, p_seats_per_row, coalesce(p_is_active, true))
  on conflict (campus_id, upper(code)) do update
    set name = excluded.name, rows_count = excluded.rows_count, seats_per_row = excluded.seats_per_row, is_active = excluded.is_active
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.save_exam_hall(uuid, text, text, int, int, boolean) from public, anon;
grant execute on function public.save_exam_hall(uuid, text, text, int, int, boolean) to authenticated;

create or replace function public.create_datesheet(p_campus_id uuid, p_exam_term_id uuid, p_title text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_term public.exam_term%rowtype;
  v_id   uuid;
begin
  perform app.fn_exam_office(p_campus_id);
  select * into v_term from public.exam_term where id = p_exam_term_id and tenant_id = app.auth_tenant_id() and campus_id = p_campus_id;
  if not found then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if length(btrim(coalesce(p_title, ''))) = 0 then
    raise exception 'TITLE_REQUIRED' using errcode = '22023';
  end if;
  insert into public.datesheet (tenant_id, campus_id, session_id, exam_term_id, title, created_by)
  values (v_term.tenant_id, p_campus_id, v_term.session_id, p_exam_term_id, btrim(p_title), (select auth.uid()))
  returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'DATESHEET_EXISTS' using errcode = '23505';
end;
$$;
revoke execute on function public.create_datesheet(uuid, uuid, text) from public, anon;
grant execute on function public.create_datesheet(uuid, uuid, text) to authenticated;

-- Saves (inserts or moves) the slot of one paper. Returns {slot_id, warnings}.
-- A student clash raises DATESHEET_CLASH, with the affected GR numbers in the
-- DETAIL, and the save is rolled back with the statement: nothing is stored.
create or replace function public.save_datesheet_slot(
  p_datesheet_id uuid, p_exam_subject_id uuid, p_exam_date date, p_start_time time, p_end_time time,
  p_hall_id uuid default null, p_invigilators int default 1
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ds     public.datesheet%rowtype;
  v_tz     text;
  v_start  timestamptz;
  v_end    timestamptz;
  v_slot   uuid;
  v_gr     text[];
  v_count  int;
begin
  select * into v_ds from public.datesheet where id = p_datesheet_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'DATESHEET_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_ds.campus_id);
  if v_ds.status <> 'draft' then
    raise exception 'DATESHEET_READONLY' using errcode = '22023';
  end if;
  if not exists (select 1 from public.exam_subject where id = p_exam_subject_id and exam_term_id = v_ds.exam_term_id and campus_id = v_ds.campus_id) then
    raise exception 'EXAM_SUBJECT_NOT_IN_TERM' using errcode = 'P0002';
  end if;
  if p_hall_id is not null and not exists (select 1 from public.exam_hall where id = p_hall_id and campus_id = v_ds.campus_id and is_active) then
    raise exception 'HALL_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_exam_date is null or p_start_time is null or p_end_time is null or p_end_time <= p_start_time then
    raise exception 'SLOT_TIME_INVALID' using errcode = '22023';
  end if;
  if coalesce(p_invigilators, 1) not between 1 and 50 then
    raise exception 'INVIGILATORS_INVALID' using errcode = '22023';
  end if;
  select timezone into v_tz from public.campus where id = v_ds.campus_id;
  v_start := (p_exam_date + p_start_time) at time zone coalesce(v_tz, 'Asia/Karachi');
  v_end := (p_exam_date + p_end_time) at time zone coalesce(v_tz, 'Asia/Karachi');

  begin
    insert into public.datesheet_slot (tenant_id, campus_id, datesheet_id, exam_subject_id, start_at, end_at, hall_id, invigilators_required)
    values (v_ds.tenant_id, v_ds.campus_id, p_datesheet_id, p_exam_subject_id, v_start, v_end, p_hall_id, coalesce(p_invigilators, 1))
    on conflict (datesheet_id, exam_subject_id) do update
      set start_at = excluded.start_at, end_at = excluded.end_at, hall_id = excluded.hall_id, invigilators_required = excluded.invigilators_required
    returning id into v_slot;
  exception when exclusion_violation then
    raise exception 'HALL_DOUBLE_BOOKED' using errcode = '23P01';
  end;

  select count(distinct g)::int, coalesce(array_agg(distinct g order by g), '{}'::text[])
    into v_count, v_gr
    from public.fn_detect_datesheet_clash(p_datesheet_id) c, unnest(c.affected_gr_numbers) g
   where c.slot_a = v_slot or c.slot_b = v_slot;
  if v_count > 0 then
    raise exception 'DATESHEET_CLASH' using errcode = '23P01',
      detail = format('%s candidates sit both papers: %s', v_count, array_to_string(v_gr, ', '));
  end if;

  return jsonb_build_object('slot_id', v_slot, 'warnings', app.fn_slot_warnings(v_slot));
end;
$$;
revoke execute on function public.save_datesheet_slot(uuid, uuid, date, time, time, uuid, int) from public, anon;
grant execute on function public.save_datesheet_slot(uuid, uuid, date, time, time, uuid, int) to authenticated;

create or replace function public.delete_datesheet_slot(p_slot_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slot public.datesheet_slot%rowtype;
  v_status text;
begin
  select * into v_slot from public.datesheet_slot where id = p_slot_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_slot.campus_id);
  select status into v_status from public.datesheet where id = v_slot.datesheet_id for update;
  if v_status <> 'draft' then
    raise exception 'DATESHEET_READONLY' using errcode = '22023';
  end if;
  delete from public.datesheet_slot where id = p_slot_id;
end;
$$;
revoke execute on function public.delete_datesheet_slot(uuid) from public, anon;
grant execute on function public.delete_datesheet_slot(uuid) to authenticated;
