-- FR-I09: exam hall seating plan.
--
-- A seating plan puts every candidate of a datesheet slot in exactly one seat of
-- the slot's hall so that no two candidates of the same section sit side by side
-- (the pupils to either side on a bench are who one copies from), and, when the
-- paper is printed in several sets, adjacent seats alternate set code.
--
--   * Seats are real rows (exam_hall_seat), generated from the hall's rows x
--     seats-per-row and kept in step when the hall is resized; a broken desk is
--     marked unavailable and never used.
--   * Generation is STABLE: candidates who still qualify keep their seat; only
--     new candidates are placed (one late admission moves nobody) and anyone no
--     longer a candidate is dropped. A reshuffle on exam morning is how a school
--     abandons the feature.
--   * Placement: candidates are taken round-robin, always from the section with
--     the most pupils still to seat, and each goes to the first free seat whose
--     bench neighbours are of another section. Spare seats are used as gaps when
--     one section is too large to interleave.
--   * The set code belongs to the seat position (a checkerboard of row + seat),
--     so adjacent seats alternate sets whatever the candidate, and the seat slip
--     prints the letter of the seat it is for.
--   * Not enough seats raises capacity_shortfall: N and lists the halls that are
--     free for that time window.
--
-- exam_paper_set_group records how many sets (A, B, ...) a paper is printed in;
-- FR-I07 builds the sets themselves on top of it.

create table public.exam_hall_seat (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  hall_id      uuid not null references public.exam_hall(id) on delete cascade,
  row_no       int not null check (row_no >= 1),
  seat_no      int not null check (seat_no >= 1),
  is_available boolean not null default true,
  label        text generated always as ('R' || row_no::text || '-S' || seat_no::text) stored,
  constraint uq_exam_hall_seat unique (hall_id, row_no, seat_no)
);
create index idx_exam_hall_seat_tenant on public.exam_hall_seat (tenant_id);
create index idx_exam_hall_seat_campus on public.exam_hall_seat (campus_id);

create table public.exam_paper_set_group (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  exam_subject_id uuid not null references public.exam_subject(id) on delete cascade,
  set_count       smallint not null default 1 check (set_count between 1 and 4),
  updated_at      timestamptz not null default now(),
  constraint uq_exam_paper_set_group unique (exam_subject_id)
);
create index idx_exam_paper_set_group_tenant on public.exam_paper_set_group (tenant_id);
create index idx_exam_paper_set_group_campus on public.exam_paper_set_group (campus_id);

create table public.exam_seat_allocation (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  slot_id       uuid not null references public.datesheet_slot(id) on delete cascade,
  hall_id       uuid not null references public.exam_hall(id) on delete cascade,
  row_no        int not null,
  seat_no       int not null,
  enrolment_id  uuid not null references public.enrolment(id) on delete cascade,
  section_id    uuid not null references public.class_section(id),
  set_code      char(1) not null default 'A' check (set_code between 'A' and 'D'),
  generated_at  timestamptz not null default now(),
  constraint uq_seat_per_slot unique (slot_id, hall_id, row_no, seat_no),
  constraint fk_seat_alloc_seat foreign key (hall_id, row_no, seat_no) references public.exam_hall_seat (hall_id, row_no, seat_no)
);
-- One seat per candidate per slot; also the lookup index for "where does this pupil sit".
create unique index idx_seat_alloc_student on public.exam_seat_allocation (slot_id, enrolment_id);
create index idx_seat_alloc_tenant on public.exam_seat_allocation (tenant_id);
create index idx_seat_alloc_campus on public.exam_seat_allocation (campus_id);
create index idx_seat_alloc_enrolment on public.exam_seat_allocation (enrolment_id);
create index idx_seat_alloc_hall_seat on public.exam_seat_allocation (hall_id, row_no, seat_no);
create index idx_seat_alloc_section on public.exam_seat_allocation (section_id);

create trigger exam_paper_set_group_audit after insert or update or delete on public.exam_paper_set_group
  for each row execute function app.tg_audit_row();
create trigger exam_seat_allocation_audit after insert or update or delete on public.exam_seat_allocation
  for each row execute function app.tg_audit_row();

alter table public.exam_hall_seat enable row level security;
alter table public.exam_paper_set_group enable row level security;
alter table public.exam_seat_allocation enable row level security;
create policy seating_hall_seat_scope on public.exam_hall_seat for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy exam_paper_set_group_scope on public.exam_paper_set_group for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy seating_campus_scope on public.exam_seat_allocation for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

-- ═══════════════════════════════════════════════════════════════════════
-- Seats follow the hall
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.fn_sync_hall_seats(p_hall_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  h public.exam_hall%rowtype;
begin
  select * into h from public.exam_hall where id = p_hall_id;
  if not found then
    return;
  end if;
  if exists (select 1 from public.exam_seat_allocation a
              where a.hall_id = p_hall_id and (a.row_no > h.rows_count or a.seat_no > h.seats_per_row)) then
    raise exception 'HALL_SEATS_IN_USE' using errcode = '22023',
      detail = 'Seats being removed are allocated to candidates; regenerate those seating plans first.';
  end if;
  delete from public.exam_hall_seat where hall_id = p_hall_id and (row_no > h.rows_count or seat_no > h.seats_per_row);
  insert into public.exam_hall_seat (tenant_id, campus_id, hall_id, row_no, seat_no)
  select h.tenant_id, h.campus_id, h.id, r, s
    from generate_series(1, h.rows_count) r, generate_series(1, h.seats_per_row) s
  on conflict (hall_id, row_no, seat_no) do nothing;
end;
$$;
revoke execute on function app.fn_sync_hall_seats(uuid) from public, anon, authenticated;

create or replace function app.tg_exam_hall_sync_seats()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.fn_sync_hall_seats(new.id);
  return null;
end;
$$;
create trigger trg_exam_hall_sync_seats after insert or update of rows_count, seats_per_row on public.exam_hall
  for each row execute function app.tg_exam_hall_sync_seats();

select app.fn_sync_hall_seats(id) from public.exam_hall;

-- Marks one desk usable or not (a broken desk is never allocated).
create or replace function public.set_hall_seat_available(p_hall_id uuid, p_row_no int, p_seat_no int, p_available boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hall public.exam_hall%rowtype;
begin
  select * into v_hall from public.exam_hall where id = p_hall_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'HALL_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_hall.campus_id);
  update public.exam_hall_seat set is_available = coalesce(p_available, true) where hall_id = p_hall_id and row_no = p_row_no and seat_no = p_seat_no;
  if not found then
    raise exception 'SEAT_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.set_hall_seat_available(uuid, int, int, boolean) from public, anon;
grant execute on function public.set_hall_seat_available(uuid, int, int, boolean) to authenticated;

create or replace function public.upsert_paper_set_group(p_exam_subject_id uuid, p_set_count int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_es public.exam_subject%rowtype;
begin
  select * into v_es from public.exam_subject where id = p_exam_subject_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'EXAM_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_es.campus_id);
  if p_set_count is null or p_set_count not between 1 and 4 then
    raise exception 'SET_COUNT_INVALID' using errcode = '22023';
  end if;
  insert into public.exam_paper_set_group (tenant_id, campus_id, exam_subject_id, set_count)
  values (v_es.tenant_id, v_es.campus_id, p_exam_subject_id, p_set_count)
  on conflict (exam_subject_id) do update set set_count = excluded.set_count, updated_at = now();
end;
$$;
revoke execute on function public.upsert_paper_set_group(uuid, int) from public, anon;
grant execute on function public.upsert_paper_set_group(uuid, int) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Halls free for a slot's window
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.fn_halls_free_for_slot(p_slot_id uuid)
returns table (hall_id uuid, code text, name text, available_seats int)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_slot public.datesheet_slot%rowtype;
begin
  select * into v_slot from public.datesheet_slot where id = p_slot_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() in ('parent', 'student', 'none')
     or (app.auth_role() not in ('owner', 'super_admin') and not (v_slot.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
    select h.id, h.code, h.name, (select count(*)::int from public.exam_hall_seat s where s.hall_id = h.id and s.is_available)
      from public.exam_hall h
     where h.campus_id = v_slot.campus_id and h.is_active
       and not exists (select 1 from public.datesheet_slot o
                        where o.hall_id = h.id and o.id <> p_slot_id and tstzrange(o.start_at, o.end_at) && tstzrange(v_slot.start_at, v_slot.end_at))
     order by 4 desc, h.code;
end;
$$;
revoke execute on function public.fn_halls_free_for_slot(uuid) from public, anon;
grant execute on function public.fn_halls_free_for_slot(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Generation
-- ═══════════════════════════════════════════════════════════════════════

-- Strategies: 'interleave' (default; no bench neighbours of one section) and
-- 'sequential' (roll order, first free seat; the violation report shows what
-- that costs). Returns the number of candidates seated.
create or replace function public.fn_generate_seating_plan(p_slot_id uuid, p_strategy text default 'interleave')
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slot    public.datesheet_slot%rowtype;
  v_sets    int;
  v_avail   int;
  v_cands   int;
  v_free    text;
  v_members jsonb;
  v_sec     text;
  v_last    text;
  v_enrol   uuid;
  v_sec_id  uuid;
  v_row     int;
  v_seat    int;
  v_total   int;
  r         record;
begin
  select * into v_slot from public.datesheet_slot where id = p_slot_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_slot.campus_id);
  if p_strategy is null or p_strategy not in ('interleave', 'sequential') then
    raise exception 'STRATEGY_INVALID' using errcode = '22023';
  end if;
  if v_slot.hall_id is null then
    raise exception 'SLOT_HALL_REQUIRED' using errcode = '22023';
  end if;
  v_sets := coalesce((select g.set_count from public.exam_paper_set_group g where g.exam_subject_id = v_slot.exam_subject_id), 1);

  select count(*)::int into v_cands from app.fn_exam_subject_candidates(v_slot.exam_subject_id);
  select count(*)::int into v_avail from public.exam_hall_seat where hall_id = v_slot.hall_id and is_available;
  if v_cands > v_avail then
    select string_agg(f.name || ' (' || f.available_seats || ' seats)', ', ') into v_free
      from public.fn_halls_free_for_slot(p_slot_id) f where f.hall_id <> v_slot.hall_id;
    raise exception 'capacity_shortfall: %', v_cands - v_avail using errcode = '22023',
      detail = format('%s candidates, %s available seats in the hall. Halls free for this time window: %s', v_cands, v_avail, coalesce(v_free, 'none'));
  end if;

  -- Stability: keep every seat whose occupant still qualifies and whose seat is still usable.
  delete from public.exam_seat_allocation a
   where a.slot_id = p_slot_id
     and (a.hall_id <> v_slot.hall_id
          or not exists (select 1 from app.fn_exam_subject_candidates(v_slot.exam_subject_id) c where c.enrolment_id = a.enrolment_id)
          or not exists (select 1 from public.exam_hall_seat s where s.hall_id = a.hall_id and s.row_no = a.row_no and s.seat_no = a.seat_no and s.is_available));

  -- Unseated candidates, grouped by section, each group in roll order.
  select coalesce(jsonb_object_agg(g.section_id, g.ids), '{}'::jsonb) into v_members
    from (select c.section_id::text as section_id, jsonb_agg(c.enrolment_id order by c.roll_no nulls last, c.gr_number) as ids
            from app.fn_exam_subject_candidates(v_slot.exam_subject_id) c
           where not exists (select 1 from public.exam_seat_allocation a where a.slot_id = p_slot_id and a.enrolment_id = c.enrolment_id)
           group by c.section_id) g;

  v_last := null;
  loop
    exit when v_members = '{}'::jsonb;
    if p_strategy = 'sequential' then
      select k into v_sec from jsonb_object_keys(v_members) k order by k limit 1;
    else
      -- The section with the most still to seat, other than the one just placed.
      select k into v_sec from jsonb_each(v_members) e(k, v)
       where k is distinct from v_last or (select count(*) from jsonb_object_keys(v_members)) = 1
       order by jsonb_array_length(v) desc, k limit 1;
    end if;
    v_enrol := (v_members -> v_sec ->> 0)::uuid;
    v_sec_id := v_sec::uuid;
    if jsonb_array_length(v_members -> v_sec) = 1 then
      v_members := v_members - v_sec;
    else
      v_members := jsonb_set(v_members, array[v_sec], (v_members -> v_sec) - 0);
    end if;
    v_last := v_sec;

    v_row := null;
    select s.row_no, s.seat_no into v_row, v_seat
      from public.exam_hall_seat s
     where s.hall_id = v_slot.hall_id and s.is_available
       and not exists (select 1 from public.exam_seat_allocation a where a.slot_id = p_slot_id and a.hall_id = s.hall_id and a.row_no = s.row_no and a.seat_no = s.seat_no)
       and (p_strategy = 'sequential'
            or not exists (select 1 from public.exam_seat_allocation n
                            where n.slot_id = p_slot_id and n.hall_id = s.hall_id and n.row_no = s.row_no
                              and n.seat_no in (s.seat_no - 1, s.seat_no + 1) and n.section_id = v_sec_id))
     order by s.row_no, s.seat_no limit 1;
    if v_row is null then
      -- No conflict-free seat is left: take the first free one; the violation report will name it.
      select s.row_no, s.seat_no into v_row, v_seat
        from public.exam_hall_seat s
       where s.hall_id = v_slot.hall_id and s.is_available
         and not exists (select 1 from public.exam_seat_allocation a where a.slot_id = p_slot_id and a.hall_id = s.hall_id and a.row_no = s.row_no and a.seat_no = s.seat_no)
       order by s.row_no, s.seat_no limit 1;
    end if;
    insert into public.exam_seat_allocation (tenant_id, campus_id, slot_id, hall_id, row_no, seat_no, enrolment_id, section_id, set_code)
    values (v_slot.tenant_id, v_slot.campus_id, p_slot_id, v_slot.hall_id, v_row, v_seat, v_enrol, v_sec_id, 'A');
  end loop;

  -- The set code is a property of the seat: a checkerboard of row + seat.
  update public.exam_seat_allocation
     set set_code = chr(65 + ((row_no - 1 + seat_no - 1) % v_sets))
   where slot_id = p_slot_id;

  select count(*)::int into v_total from public.exam_seat_allocation where slot_id = p_slot_id;
  return v_total;
end;
$$;
revoke execute on function public.fn_generate_seating_plan(uuid, text) from public, anon;
grant execute on function public.fn_generate_seating_plan(uuid, text) to authenticated;

-- Bench neighbours that break the rule: same section, or (when the paper has
-- several sets) the same set. Empty when the plan is clean.
create or replace function public.fn_seating_violations(p_slot_id uuid)
returns table (seat_a text, seat_b text, reason text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_slot public.datesheet_slot%rowtype;
  v_sets int;
begin
  select * into v_slot from public.datesheet_slot where id = p_slot_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() in ('parent', 'student', 'none')
     or (app.auth_role() not in ('owner', 'super_admin') and not (v_slot.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  v_sets := coalesce((select g.set_count from public.exam_paper_set_group g where g.exam_subject_id = v_slot.exam_subject_id), 1);
  return query
    select sa.label, sb.label,
           case when a.section_id = b.section_id then 'same_section' else 'same_set' end
      from public.exam_seat_allocation a
      join public.exam_seat_allocation b
        on b.slot_id = a.slot_id and b.hall_id = a.hall_id and b.row_no = a.row_no and b.seat_no = a.seat_no + 1
      join public.exam_hall_seat sa on sa.hall_id = a.hall_id and sa.row_no = a.row_no and sa.seat_no = a.seat_no
      join public.exam_hall_seat sb on sb.hall_id = b.hall_id and sb.row_no = b.row_no and sb.seat_no = b.seat_no
     where a.slot_id = p_slot_id
       and (a.section_id = b.section_id or (v_sets > 1 and a.set_code = b.set_code))
     order by a.row_no, a.seat_no;
end;
$$;
revoke execute on function public.fn_seating_violations(uuid) from public, anon;
grant execute on function public.fn_seating_violations(uuid) to authenticated;

-- Everything the chart and the seat slips print.
create or replace function public.fn_seating_chart(p_slot_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_slot public.datesheet_slot%rowtype;
  v_out  jsonb;
begin
  select * into v_slot from public.datesheet_slot where id = p_slot_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() in ('parent', 'student', 'none')
     or (app.auth_role() not in ('owner', 'super_admin') and not (v_slot.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'slot_id', v_slot.id, 'start_at', v_slot.start_at, 'end_at', v_slot.end_at,
    'class_name', cl.name_en, 'subject_name_en', sub.name_en, 'subject_name_ur', sub.name_ur,
    'hall', case when h.id is null then null else jsonb_build_object('id', h.id, 'name', h.name, 'code', h.code, 'rows', h.rows_count, 'seats_per_row', h.seats_per_row) end,
    'set_count', coalesce((select g.set_count from public.exam_paper_set_group g where g.exam_subject_id = v_slot.exam_subject_id), 1),
    'timezone', c.timezone,
    'allocations', coalesce((
      select jsonb_agg(jsonb_build_object('row_no', a.row_no, 'seat_no', a.seat_no, 'label', s.label, 'set_code', a.set_code,
                                         'gr_number', st.gr_number, 'name_en', st.name_en, 'name_ur', st.name_ur,
                                         'section_name', sec.name, 'section_id', a.section_id, 'roll_no', e.roll_no)
                       order by a.row_no, a.seat_no)
        from public.exam_seat_allocation a
        join public.exam_hall_seat s on s.hall_id = a.hall_id and s.row_no = a.row_no and s.seat_no = a.seat_no
        join public.enrolment e on e.id = a.enrolment_id
        join public.student st on st.id = e.student_id
        join public.class_section sec on sec.id = a.section_id
       where a.slot_id = v_slot.id), '[]'::jsonb))
    into v_out
    from public.exam_subject es
    join public.class_subject cs on cs.id = es.class_subject_id
    join public.class_level cl on cl.id = cs.class_level_id
    join public.subject sub on sub.id = cs.subject_id
    join public.campus c on c.id = v_slot.campus_id
    left join public.exam_hall h on h.id = v_slot.hall_id
   where es.id = v_slot.exam_subject_id;
  return v_out;
end;
$$;
revoke execute on function public.fn_seating_chart(uuid) from public, anon;
grant execute on function public.fn_seating_chart(uuid) to authenticated;
