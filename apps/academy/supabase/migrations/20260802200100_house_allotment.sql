-- FR-C06: allot house with sibling affinity.
--
-- A house is a campus-level team (Iqbal, Jinnah, ...) that students compete
-- for in inter-house sports and discipline tables. Three rules shape the
-- design:
--
--   1. Houses are DATE-EFFECTIVE. student.house_id is the current house for
--      fast reads, but every change is also a student_house_history row with
--      a from_date / to_date. Sports points are stamped with the house the
--      student belonged to on the day they were earned (house_point.house_id
--      is resolved from history at award time and never rewritten), so moving
--      a child on 1 February cannot silently rewrite November's league table.
--   2. A house that anybody has ever belonged to cannot be deleted: both
--      student.house_id and student_house_history.house_id are ON DELETE
--      RESTRICT. delete_house() turns the FK failure into HOUSE_IN_USE.
--   3. Auto-assignment prefers siblings: a student whose family_group_id
--      already has a housed member joins that house (reason 'sibling_match').
--      Everyone else goes to the least-populated house (reason 'balanced') so
--      house sizes stay within a few students of each other. A campus can
--      switch capacity balancing off, in which case non-siblings are spread by
--      a stable hash of their id instead (reason 'spread').

create table public.house (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  name       text not null check (length(btrim(name)) > 0),
  colour_hex text not null default '#3b82f6' check (colour_hex ~ '^#[0-9a-fA-F]{6}$'),
  motto      text,
  created_at timestamptz not null default now(),
  constraint uq_house_campus_name unique (campus_id, name)
);
create index idx_house_tenant on public.house (tenant_id);

create table public.house_setting (
  campus_id          uuid primary key references public.campus(id) on delete cascade,
  tenant_id          uuid not null references public.tenant(id) on delete cascade,
  capacity_balancing boolean not null default true,
  updated_at         timestamptz not null default now()
);
create index idx_house_setting_tenant on public.house_setting (tenant_id);

-- Existing rows (there should be none) must satisfy the new FK.
update public.student set house_id = null where house_id is not null;
alter table public.student
  add constraint student_house_fk foreign key (house_id) references public.house(id) on delete restrict;
create index idx_student_house on public.student (house_id);

create table public.student_house_history (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  student_id uuid not null references public.student(id) on delete cascade,
  house_id   uuid not null references public.house(id) on delete restrict,
  from_date  date not null,
  to_date    date,
  reason     text not null check (reason in ('sibling_match', 'balanced', 'spread', 'manual', 'transfer')),
  assigned_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint chk_house_history_dates check (to_date is null or to_date >= from_date)
);
create unique index uq_house_history_open on public.student_house_history (student_id) where to_date is null;
create index idx_house_history_student on public.student_house_history (student_id, from_date);
create index idx_house_history_house on public.student_house_history (house_id);
create index idx_house_history_tenant on public.student_house_history (tenant_id, campus_id);

create table public.house_point (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  student_id uuid not null references public.student(id) on delete cascade,
  house_id   uuid not null references public.house(id) on delete restrict,
  awarded_on date not null,
  points     int not null check (points between -100 and 1000 and points <> 0),
  category   text not null default 'sports' check (category in ('sports', 'academic', 'discipline', 'other')),
  note       text check (note is null or char_length(note) <= 200),
  awarded_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index idx_house_point_house on public.house_point (house_id, awarded_on);
create index idx_house_point_student on public.house_point (student_id);
create index idx_house_point_tenant on public.house_point (tenant_id, campus_id);

create trigger house_audit after insert or update or delete on public.house
  for each row execute function app.tg_audit_row();
create trigger student_house_history_audit after insert or update or delete on public.student_house_history
  for each row execute function app.tg_audit_row();

alter table public.house enable row level security;
alter table public.house_setting enable row level security;
alter table public.student_house_history enable row level security;
alter table public.house_point enable row level security;

create policy house_campus_scope on public.house for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())
              or exists (select 1 from public.student s where s.house_id = house.id and s.id = any (app.auth_guardian_student_ids()))));
create policy house_write_principal on public.house for all to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'principal')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())))
  with check (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'principal')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy house_setting_read on public.house_setting for select to authenticated
  using (tenant_id = app.auth_tenant_id() and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy house_history_read on public.student_house_history for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (student_id = any (app.auth_guardian_student_ids())
              or (app.auth_role() not in ('parent', 'student', 'none') and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())))));
create policy house_point_read on public.house_point for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (student_id = any (app.auth_guardian_student_ids())
              or (app.auth_role() not in ('parent', 'student', 'none') and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())))));

-- Who may allot houses: school leadership and class teachers of the campus.
create or replace function app.fn_house_staff(p_campus_id uuid, p_principal_only boolean default false)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  select tenant_id into v_tenant from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id();
  if v_tenant is null then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_principal_only then
    if app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  elsif app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (p_campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return v_tenant;
end;
$$;
revoke execute on function app.fn_house_staff(uuid, boolean) from public, anon, authenticated;

create or replace function public.create_house(p_campus_id uuid, p_name text, p_colour_hex text default '#3b82f6', p_motto text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.fn_house_staff(p_campus_id, true);
  v_id     uuid;
begin
  insert into public.house (tenant_id, campus_id, name, colour_hex, motto)
  values (v_tenant, p_campus_id, btrim(p_name), coalesce(p_colour_hex, '#3b82f6'), nullif(btrim(p_motto), ''))
  returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'HOUSE_NAME_DUPLICATE' using errcode = '23505';
end;
$$;
revoke execute on function public.create_house(uuid, text, text, text) from public, anon;
grant execute on function public.create_house(uuid, text, text, text) to authenticated;

create or replace function public.delete_house(p_house_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_h public.house%rowtype;
begin
  select * into v_h from public.house where id = p_house_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'HOUSE_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_house_staff(v_h.campus_id, true);
  delete from public.house where id = p_house_id;
exception when foreign_key_violation then
  raise exception 'HOUSE_IN_USE' using errcode = '23503';
end;
$$;
revoke execute on function public.delete_house(uuid) from public, anon;
grant execute on function public.delete_house(uuid) to authenticated;

create or replace function public.set_house_capacity_balancing(p_campus_id uuid, p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.fn_house_staff(p_campus_id, true);
begin
  insert into public.house_setting (campus_id, tenant_id, capacity_balancing) values (p_campus_id, v_tenant, p_enabled)
  on conflict (campus_id) do update set capacity_balancing = excluded.capacity_balancing, updated_at = now();
end;
$$;
revoke execute on function public.set_house_capacity_balancing(uuid, boolean) from public, anon;
grant execute on function public.set_house_capacity_balancing(uuid, boolean) to authenticated;

-- The one place that moves a student: closes the open history row the day
-- before the new one starts and keeps student.house_id in step.
create or replace function app.fn_house_place(p_student public.student, p_house_id uuid, p_from date, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_open public.student_house_history%rowtype;
begin
  select * into v_open from public.student_house_history where student_id = p_student.id and to_date is null for update;
  if found then
    if v_open.house_id = p_house_id then
      return;
    end if;
    if p_from <= v_open.from_date then
      raise exception 'EFFECTIVE_DATE_BEFORE_CURRENT_HOUSE' using errcode = '22023', detail = format('current_from=%s', v_open.from_date);
    end if;
    update public.student_house_history set to_date = p_from - 1 where id = v_open.id;
  end if;
  insert into public.student_house_history (tenant_id, campus_id, student_id, house_id, from_date, reason, assigned_by)
  values (p_student.tenant_id, p_student.campus_id, p_student.id, p_house_id, p_from, p_reason, (select auth.uid()));
  update public.student set house_id = p_house_id where id = p_student.id;
end;
$$;
revoke execute on function app.fn_house_place(public.student, uuid, date, text) from public, anon, authenticated;

create or replace function public.set_student_house(p_student_id uuid, p_house_id uuid, p_effective_date date default null, p_reason text default 'manual')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s public.student%rowtype;
  v_h public.house%rowtype;
begin
  select * into v_s from public.student where id = p_student_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_house_staff(v_s.campus_id);
  select * into v_h from public.house where id = p_house_id and tenant_id = v_s.tenant_id and campus_id = v_s.campus_id;
  if not found then
    raise exception 'HOUSE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_reason not in ('manual', 'transfer') then
    raise exception 'REASON_INVALID' using errcode = '22023';
  end if;
  perform app.fn_house_place(v_s, p_house_id, coalesce(p_effective_date, app.fn_karachi_today()), p_reason);
end;
$$;
revoke execute on function public.set_student_house(uuid, uuid, date, text) from public, anon;
grant execute on function public.set_student_house(uuid, uuid, date, text) to authenticated;

-- The house a student belonged to on a given day, from history.
create or replace function public.house_on_date(p_student_id uuid, p_on date)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select h.house_id from public.student_house_history h
   where h.student_id = p_student_id and h.tenant_id = app.auth_tenant_id() and h.from_date <= p_on and (h.to_date is null or h.to_date >= p_on)
   order by h.from_date desc limit 1;
$$;
revoke execute on function public.house_on_date(uuid, date) from public, anon;
grant execute on function public.house_on_date(uuid, date) to authenticated;

-- Auto-assignment for every active, un-housed student enrolled in the session.
-- Siblings first (they follow a housed family member, including one placed a
-- moment ago in this same run), then least-populated.
create or replace function public.auto_assign_houses(p_campus_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant   uuid := app.fn_house_staff(p_campus_id);
  v_balance  boolean;
  v_n_houses int;
  v_sib      int := 0;
  v_bal      int := 0;
  v_spr      int := 0;
  v_s        public.student%rowtype;
  v_house    uuid;
  v_reason   text;
  v_ids      uuid[];
  v_today    date := app.fn_karachi_today();
  r          record;
begin
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = v_tenant) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  select count(*) into v_n_houses from public.house where campus_id = p_campus_id;
  if v_n_houses = 0 then
    raise exception 'NO_HOUSES_DEFINED' using errcode = '55000';
  end if;
  select coalesce((select capacity_balancing from public.house_setting where campus_id = p_campus_id), true) into v_balance;
  -- One allotment run per campus at a time: counts must not move under us.
  perform pg_advisory_xact_lock(hashtextextended('auto_assign_houses:' || p_campus_id::text, 0));

  select array_agg(h.id order by h.name) into v_ids from public.house h where h.campus_id = p_campus_id;

  for r in
    select s.id
      from public.student s
      join public.enrolment e on e.student_id = s.id and e.session_id = p_session_id and e.status = 'active'
     where s.campus_id = p_campus_id and s.tenant_id = v_tenant and s.house_id is null and s.status = 'active'
     order by s.family_group_id nulls last, s.created_at, s.id
  loop
    select * into v_s from public.student where id = r.id for update;
    v_house := null;
    if v_s.family_group_id is not null then
      select sib.house_id into v_house from public.student sib
       where sib.family_group_id = v_s.family_group_id and sib.id <> v_s.id and sib.house_id is not null and sib.campus_id = p_campus_id
       order by sib.created_at limit 1;
    end if;
    if v_house is not null then
      v_reason := 'sibling_match';
      v_sib := v_sib + 1;
    elsif v_balance then
      select h.id into v_house from public.house h
       where h.campus_id = p_campus_id
       order by (select count(*) from public.student x where x.house_id = h.id), h.name limit 1;
      v_reason := 'balanced';
      v_bal := v_bal + 1;
    else
      v_house := v_ids[1 + (abs(hashtextextended(v_s.id::text, 0)) % v_n_houses)::int];
      v_reason := 'spread';
      v_spr := v_spr + 1;
    end if;
    perform app.fn_house_place(v_s, v_house, v_today, v_reason);
  end loop;

  return jsonb_build_object('sibling_match', v_sib, 'balanced', v_bal, 'spread', v_spr, 'assigned', v_sib + v_bal + v_spr);
end;
$$;
revoke execute on function public.auto_assign_houses(uuid, uuid) from public, anon;
grant execute on function public.auto_assign_houses(uuid, uuid) to authenticated;

-- Points are attributed to the house the student was in ON THE DAY (history),
-- and that attribution is frozen on the row.
create or replace function public.award_house_points(p_student_id uuid, p_points int, p_awarded_on date default null, p_category text default 'sports', p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s     public.student%rowtype;
  v_day   date := coalesce(p_awarded_on, app.fn_karachi_today());
  v_house uuid;
  v_id    uuid;
begin
  select * into v_s from public.student where id = p_student_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_house_staff(v_s.campus_id);
  v_house := public.house_on_date(p_student_id, v_day);
  if v_house is null then
    raise exception 'STUDENT_HAS_NO_HOUSE_ON_DATE' using errcode = '55000';
  end if;
  insert into public.house_point (tenant_id, campus_id, student_id, house_id, awarded_on, points, category, note, awarded_by)
  values (v_s.tenant_id, v_s.campus_id, p_student_id, v_house, v_day, p_points, p_category, nullif(btrim(p_note), ''), (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.award_house_points(uuid, int, date, text, text) from public, anon;
grant execute on function public.award_house_points(uuid, int, date, text, text) to authenticated;

create or replace function public.house_standings(p_campus_id uuid, p_from date, p_to date)
returns table (house_id uuid, house_name text, colour_hex text, members bigint, points bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select h.id, h.name, h.colour_hex,
         (select count(*) from public.student s where s.house_id = h.id),
         coalesce((select sum(p.points) from public.house_point p where p.house_id = h.id and p.awarded_on between p_from and p_to), 0)::bigint
    from public.house h
   where h.campus_id = p_campus_id and h.tenant_id = app.auth_tenant_id()
     and (app.auth_role() in ('owner', 'super_admin') or h.campus_id = any (app.auth_campus_ids()))
     and app.auth_role() not in ('parent', 'student', 'none')
   order by 5 desc, h.name;
$$;
revoke execute on function public.house_standings(uuid, date, date) from public, anon;
grant execute on function public.house_standings(uuid, date, date) to authenticated;
