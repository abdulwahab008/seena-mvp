-- FR-H08: annual syllabus definition per class and subject.
--
-- A syllabus is the ordered list of units (chapters) and their topics for one
-- (campus, session, class, subject, board). The board is part of the key, so
-- FBISE and Punjab Board Class 9 Physics coexist. The sequence uniqueness is
-- DEFERRABLE INITIALLY DEFERRED: a reorder rewrites many sequence numbers in
-- one statement and would otherwise collide with itself half way through.
-- Reordering takes the complete new order and renumbers 1..n with no gaps;
-- deleting a unit closes the gap the same way.
--
-- Units and topics keep a lineage column (source_unit_id / source_topic_id)
-- when cloned to a new session, so downstream coverage tracking and the Seena
-- Exams chunk metadata can follow a chapter across years. Cloning shifts each
-- unit's target month by the distance between the two sessions' start dates.

create table public.syllabus_unit (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  session_id      uuid not null references public.academic_session(id) on delete cascade,
  class_level_id  uuid not null references public.class_level(id),
  subject_id      uuid not null references public.subject(id),
  board           public.board not null,
  sequence        int not null check (sequence > 0),
  title           text not null check (length(btrim(title)) > 0),
  title_ur        text,
  planned_periods int not null default 0 check (planned_periods >= 0 and planned_periods <= 500),
  target_month    date check (target_month is null or target_month = date_trunc('month', target_month)::date),
  source_unit_id  uuid references public.syllabus_unit(id) on delete set null,
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  constraint uq_syllabus_unit_sequence unique (campus_id, session_id, class_level_id, subject_id, board, sequence) deferrable initially deferred
);
create index idx_syllabus_lookup on public.syllabus_unit (session_id, class_level_id, subject_id, board, sequence);
create index idx_syllabus_unit_scope on public.syllabus_unit (tenant_id, campus_id);
create index idx_syllabus_unit_subject on public.syllabus_unit (subject_id);
create index idx_syllabus_unit_class on public.syllabus_unit (class_level_id);
create index idx_syllabus_unit_source on public.syllabus_unit (source_unit_id);

create table public.syllabus_topic (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  syllabus_unit_id uuid not null references public.syllabus_unit(id) on delete cascade,
  sequence         int not null check (sequence > 0),
  title            text not null check (length(btrim(title)) > 0),
  title_ur         text,
  planned_periods  int not null default 0 check (planned_periods >= 0 and planned_periods <= 100),
  source_topic_id  uuid references public.syllabus_topic(id) on delete set null,
  created_at       timestamptz not null default now(),
  constraint uq_syllabus_topic_sequence unique (syllabus_unit_id, sequence) deferrable initially deferred
);
create index idx_syllabus_topic_unit on public.syllabus_topic (syllabus_unit_id, sequence);
create index idx_syllabus_topic_tenant on public.syllabus_topic (tenant_id);
create index idx_syllabus_topic_source on public.syllabus_topic (source_topic_id);

create trigger syllabus_unit_audit after insert or update or delete on public.syllabus_unit
  for each row execute function app.tg_audit_row();

alter table public.syllabus_unit enable row level security;
alter table public.syllabus_topic enable row level security;
create policy syllabus_unit_read on public.syllabus_unit for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none', 'accountant')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy syllabus_topic_read on public.syllabus_topic for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.syllabus_unit u where u.id = syllabus_unit_id));

create or replace function app.fn_syllabus_editor(p_campus_id uuid)
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
revoke execute on function app.fn_syllabus_editor(uuid) from public, anon, authenticated;

create or replace function app.fn_syllabus_unit_for_edit(p_unit_id uuid)
returns public.syllabus_unit
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_u public.syllabus_unit%rowtype;
begin
  select * into v_u from public.syllabus_unit where id = p_unit_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'UNIT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_syllabus_editor(v_u.campus_id);
  return v_u;
end;
$$;
revoke execute on function app.fn_syllabus_unit_for_edit(uuid) from public, anon, authenticated;

create or replace function app.fn_syllabus_validate_scope(p_campus_id uuid, p_session_id uuid, p_class_level_id uuid, p_subject_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.fn_syllabus_editor(p_campus_id);
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.class_level where id = p_class_level_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CLASS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.subject where id = p_subject_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function app.fn_syllabus_validate_scope(uuid, uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public.add_syllabus_unit(
  p_campus_id uuid, p_session_id uuid, p_class_level_id uuid, p_subject_id uuid, p_board public.board,
  p_title text, p_title_ur text default null, p_planned_periods int default 0, p_target_month date default null, p_position int default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_max int;
  v_pos int;
  v_id  uuid;
begin
  perform app.fn_syllabus_validate_scope(p_campus_id, p_session_id, p_class_level_id, p_subject_id);
  select coalesce(max(sequence), 0) into v_max from public.syllabus_unit
   where campus_id = p_campus_id and session_id = p_session_id and class_level_id = p_class_level_id and subject_id = p_subject_id and board = p_board;
  v_pos := least(greatest(coalesce(p_position, v_max + 1), 1), v_max + 1);
  update public.syllabus_unit set sequence = sequence + 1
   where campus_id = p_campus_id and session_id = p_session_id and class_level_id = p_class_level_id and subject_id = p_subject_id and board = p_board and sequence >= v_pos;
  insert into public.syllabus_unit (tenant_id, campus_id, session_id, class_level_id, subject_id, board, sequence, title, title_ur, planned_periods, target_month, created_by)
  values (app.auth_tenant_id(), p_campus_id, p_session_id, p_class_level_id, p_subject_id, p_board, v_pos, btrim(p_title), nullif(btrim(p_title_ur), ''), coalesce(p_planned_periods, 0), p_target_month, (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.add_syllabus_unit(uuid, uuid, uuid, uuid, public.board, text, text, int, date, int) from public, anon;
grant execute on function public.add_syllabus_unit(uuid, uuid, uuid, uuid, public.board, text, text, int, date, int) to authenticated;

-- Creates a whole syllabus in one call: [{title, title_ur, planned_periods, target_month, topics: [{title, title_ur, planned_periods}]}]
create or replace function public.save_syllabus(
  p_campus_id uuid, p_session_id uuid, p_class_level_id uuid, p_subject_id uuid, p_board public.board, p_units jsonb
)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  u      jsonb;
  t      jsonb;
  v_n    int := 0;
  v_t    int;
  v_unit uuid;
begin
  perform app.fn_syllabus_validate_scope(p_campus_id, p_session_id, p_class_level_id, p_subject_id);
  if jsonb_typeof(p_units) <> 'array' or jsonb_array_length(p_units) = 0 or jsonb_array_length(p_units) > 100 then
    raise exception 'UNITS_MUST_BE_1_TO_100' using errcode = '22023';
  end if;
  if exists (select 1 from public.syllabus_unit where campus_id = p_campus_id and session_id = p_session_id and class_level_id = p_class_level_id and subject_id = p_subject_id and board = p_board) then
    raise exception 'SYLLABUS_ALREADY_EXISTS' using errcode = '23505';
  end if;
  for u in select * from jsonb_array_elements(p_units) loop
    v_n := v_n + 1;
    insert into public.syllabus_unit (tenant_id, campus_id, session_id, class_level_id, subject_id, board, sequence, title, title_ur, planned_periods, target_month, created_by)
    values (app.auth_tenant_id(), p_campus_id, p_session_id, p_class_level_id, p_subject_id, p_board, v_n, btrim(u ->> 'title'), nullif(btrim(u ->> 'title_ur'), ''),
            coalesce((u ->> 'planned_periods')::int, 0), nullif(u ->> 'target_month', '')::date, (select auth.uid()))
    returning id into v_unit;
    v_t := 0;
    for t in select * from jsonb_array_elements(coalesce(u -> 'topics', '[]'::jsonb)) loop
      v_t := v_t + 1;
      insert into public.syllabus_topic (tenant_id, syllabus_unit_id, sequence, title, title_ur, planned_periods)
      values (app.auth_tenant_id(), v_unit, v_t, btrim(t ->> 'title'), nullif(btrim(t ->> 'title_ur'), ''), coalesce((t ->> 'planned_periods')::int, 0));
    end loop;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.save_syllabus(uuid, uuid, uuid, uuid, public.board, jsonb) from public, anon;
grant execute on function public.save_syllabus(uuid, uuid, uuid, uuid, public.board, jsonb) to authenticated;

create or replace function public.update_syllabus_unit(p_unit_id uuid, p_title text, p_title_ur text default null, p_planned_periods int default 0, p_target_month date default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_u public.syllabus_unit%rowtype;
begin
  v_u := app.fn_syllabus_unit_for_edit(p_unit_id);
  update public.syllabus_unit set title = btrim(p_title), title_ur = nullif(btrim(p_title_ur), ''), planned_periods = coalesce(p_planned_periods, 0), target_month = p_target_month where id = p_unit_id;
end;
$$;
revoke execute on function public.update_syllabus_unit(uuid, text, text, int, date) from public, anon;
grant execute on function public.update_syllabus_unit(uuid, text, text, int, date) to authenticated;

create or replace function public.reorder_syllabus_units(p_unit_ids uuid[])
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_first public.syllabus_unit%rowtype;
  v_total int;
  v_n     int;
begin
  if p_unit_ids is null or cardinality(p_unit_ids) = 0 then
    raise exception 'UNITS_REQUIRED' using errcode = '22023';
  end if;
  if (select count(distinct x) from unnest(p_unit_ids) x) <> cardinality(p_unit_ids) then
    raise exception 'DUPLICATE_UNIT' using errcode = '22023';
  end if;
  v_first := app.fn_syllabus_unit_for_edit(p_unit_ids[1]);
  select count(*) into v_total from public.syllabus_unit
   where campus_id = v_first.campus_id and session_id = v_first.session_id and class_level_id = v_first.class_level_id and subject_id = v_first.subject_id and board = v_first.board;
  select count(*) into v_n from public.syllabus_unit u
   where u.id = any (p_unit_ids) and u.campus_id = v_first.campus_id and u.session_id = v_first.session_id and u.class_level_id = v_first.class_level_id
     and u.subject_id = v_first.subject_id and u.board = v_first.board;
  if v_n <> cardinality(p_unit_ids) or v_total <> cardinality(p_unit_ids) then
    raise exception 'ORDER_MUST_LIST_EVERY_UNIT_OF_ONE_SYLLABUS' using errcode = '22023';
  end if;
  update public.syllabus_unit u set sequence = o.ord from unnest(p_unit_ids) with ordinality as o(id, ord) where u.id = o.id;
  return v_total;
end;
$$;
revoke execute on function public.reorder_syllabus_units(uuid[]) from public, anon;
grant execute on function public.reorder_syllabus_units(uuid[]) to authenticated;

create or replace function public.delete_syllabus_unit(p_unit_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_u public.syllabus_unit%rowtype;
begin
  v_u := app.fn_syllabus_unit_for_edit(p_unit_id);
  delete from public.syllabus_unit where id = p_unit_id;
  update public.syllabus_unit set sequence = sequence - 1
   where campus_id = v_u.campus_id and session_id = v_u.session_id and class_level_id = v_u.class_level_id and subject_id = v_u.subject_id and board = v_u.board and sequence > v_u.sequence;
end;
$$;
revoke execute on function public.delete_syllabus_unit(uuid) from public, anon;
grant execute on function public.delete_syllabus_unit(uuid) to authenticated;

create or replace function public.add_syllabus_topic(p_unit_id uuid, p_title text, p_title_ur text default null, p_planned_periods int default 0, p_position int default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_u   public.syllabus_unit%rowtype;
  v_max int;
  v_pos int;
  v_id  uuid;
begin
  v_u := app.fn_syllabus_unit_for_edit(p_unit_id);
  select coalesce(max(sequence), 0) into v_max from public.syllabus_topic where syllabus_unit_id = p_unit_id;
  v_pos := least(greatest(coalesce(p_position, v_max + 1), 1), v_max + 1);
  update public.syllabus_topic set sequence = sequence + 1 where syllabus_unit_id = p_unit_id and sequence >= v_pos;
  insert into public.syllabus_topic (tenant_id, syllabus_unit_id, sequence, title, title_ur, planned_periods)
  values (v_u.tenant_id, p_unit_id, v_pos, btrim(p_title), nullif(btrim(p_title_ur), ''), coalesce(p_planned_periods, 0))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.add_syllabus_topic(uuid, text, text, int, int) from public, anon;
grant execute on function public.add_syllabus_topic(uuid, text, text, int, int) to authenticated;

create or replace function public.reorder_syllabus_topics(p_unit_id uuid, p_topic_ids uuid[])
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_u public.syllabus_unit%rowtype;
begin
  v_u := app.fn_syllabus_unit_for_edit(p_unit_id);
  if p_topic_ids is null or (select count(distinct x) from unnest(p_topic_ids) x) <> cardinality(p_topic_ids)
     or cardinality(p_topic_ids) <> (select count(*) from public.syllabus_topic where syllabus_unit_id = p_unit_id)
     or exists (select 1 from unnest(p_topic_ids) x where x not in (select id from public.syllabus_topic where syllabus_unit_id = p_unit_id)) then
    raise exception 'ORDER_MUST_LIST_EVERY_TOPIC_OF_THE_UNIT' using errcode = '22023';
  end if;
  update public.syllabus_topic t set sequence = o.ord from unnest(p_topic_ids) with ordinality as o(id, ord) where t.id = o.id;
  return cardinality(p_topic_ids);
end;
$$;
revoke execute on function public.reorder_syllabus_topics(uuid, uuid[]) from public, anon;
grant execute on function public.reorder_syllabus_topics(uuid, uuid[]) to authenticated;

create or replace function public.delete_syllabus_topic(p_topic_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_t public.syllabus_topic%rowtype;
  v_u public.syllabus_unit%rowtype;
begin
  select * into v_t from public.syllabus_topic where id = p_topic_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'TOPIC_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_u := app.fn_syllabus_unit_for_edit(v_t.syllabus_unit_id);
  delete from public.syllabus_topic where id = p_topic_id;
  update public.syllabus_topic set sequence = sequence - 1 where syllabus_unit_id = v_t.syllabus_unit_id and sequence > v_t.sequence;
end;
$$;
revoke execute on function public.delete_syllabus_topic(uuid) from public, anon;
grant execute on function public.delete_syllabus_topic(uuid) to authenticated;

create or replace function public.clone_syllabus_to_session(p_campus_id uuid, p_from_session uuid, p_to_session uuid, p_class_level_id uuid, p_subject_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from  public.academic_session%rowtype;
  v_to    public.academic_session%rowtype;
  v_shift int;
  u       record;
  v_new   uuid;
  v_n     int := 0;
begin
  perform app.fn_syllabus_validate_scope(p_campus_id, p_to_session, p_class_level_id, p_subject_id);
  select * into v_from from public.academic_session where id = p_from_session and tenant_id = app.auth_tenant_id();
  select * into v_to from public.academic_session where id = p_to_session and tenant_id = app.auth_tenant_id();
  if v_from.id is null or v_to.id is null or v_from.id = v_to.id then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.syllabus_unit where campus_id = p_campus_id and session_id = p_from_session and class_level_id = p_class_level_id and subject_id = p_subject_id) then
    raise exception 'NOTHING_TO_CLONE' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.syllabus_unit where campus_id = p_campus_id and session_id = p_to_session and class_level_id = p_class_level_id and subject_id = p_subject_id) then
    raise exception 'TARGET_SYLLABUS_EXISTS' using errcode = '23505';
  end if;
  v_shift := (extract(year from v_to.starts_on) * 12 + extract(month from v_to.starts_on) - extract(year from v_from.starts_on) * 12 - extract(month from v_from.starts_on))::int;

  for u in
    select * from public.syllabus_unit
     where campus_id = p_campus_id and session_id = p_from_session and class_level_id = p_class_level_id and subject_id = p_subject_id
     order by board, sequence
  loop
    insert into public.syllabus_unit (tenant_id, campus_id, session_id, class_level_id, subject_id, board, sequence, title, title_ur, planned_periods, target_month, source_unit_id, created_by)
    values (u.tenant_id, u.campus_id, p_to_session, u.class_level_id, u.subject_id, u.board, u.sequence, u.title, u.title_ur, u.planned_periods,
            case when u.target_month is null then null else (u.target_month + make_interval(months => v_shift))::date end, u.id, (select auth.uid()))
    returning id into v_new;
    insert into public.syllabus_topic (tenant_id, syllabus_unit_id, sequence, title, title_ur, planned_periods, source_topic_id)
    select t.tenant_id, v_new, t.sequence, t.title, t.title_ur, t.planned_periods, t.id from public.syllabus_topic t where t.syllabus_unit_id = u.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.clone_syllabus_to_session(uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.clone_syllabus_to_session(uuid, uuid, uuid, uuid, uuid) to authenticated;
