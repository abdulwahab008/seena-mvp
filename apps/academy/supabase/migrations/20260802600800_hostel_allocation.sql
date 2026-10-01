-- FR-Q02: bed allocation without double booking.
--
-- The guarantee is in the database, not in an availability check that two clerks
-- on two phones can both pass in the same second: two GiST exclusion constraints
-- on hostel_allocation reject an overlapping allocation of the same bed
-- (ex_bed_no_overlap) and of the same student to two beds at once
-- (ex_student_one_bed). Whoever commits second receives BED_TAKEN (or
-- STUDENT_ALREADY_HOUSED); the bed row is also locked for the duration of the
-- allocation so the loser waits and then fails cleanly rather than racing.
--
-- ends_on is the LAST night of the stay, and the constraint works on the
-- half-open range [starts_on, ends_on + 1). That is what makes "A leaves bed 1 on
-- the 4th, B takes it on the 5th" and "A moves rooms today" legal on the same
-- day, while a real overlap is still refused.
--
-- A withdrawn enrolment closes the student's open allocation on the leaving date
-- (trigger); a nightly job re-derives bed.status so a bed whose stay has ended is
-- available again that same night. allocate_bed refuses an out-of-service room
-- for NEW stays, but never touches the allocations already in it.

create table public.hostel_allocation (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  student_id    uuid not null references public.student(id),
  enrolment_id  uuid not null references public.enrolment(id),
  bed_id        uuid not null references public.hostel_bed(id),
  starts_on     date not null,
  ends_on       date,
  allocated_by  uuid references auth.users(id),
  vacate_reason text check (vacate_reason is null or char_length(vacate_reason) <= 300),
  created_at    timestamptz not null default now(),
  constraint chk_hostel_alloc_span check (ends_on is null or ends_on >= starts_on),
  constraint ex_bed_no_overlap exclude using gist (bed_id with =, daterange(starts_on, coalesce(ends_on + 1, 'infinity'), '[)') with &&),
  constraint ex_student_one_bed exclude using gist (student_id with =, daterange(starts_on, coalesce(ends_on + 1, 'infinity'), '[)') with &&)
);
create index idx_hostel_alloc_scope on public.hostel_allocation (tenant_id, campus_id);
create index idx_hostel_alloc_enrolment on public.hostel_allocation (enrolment_id);
create index idx_hostel_alloc_open on public.hostel_allocation (student_id) where ends_on is null;

create trigger hostel_allocation_audit after insert or update or delete on public.hostel_allocation
  for each row execute function app.tg_audit_row();

alter table public.hostel_allocation enable row level security;
create policy hostel_allocation_campus_scope on public.hostel_allocation for select to authenticated
  using (app.fn_hostel_staff(tenant_id, campus_id));
create policy hostel_allocation_parent_read on public.hostel_allocation for select to authenticated
  using (tenant_id = app.auth_tenant_id() and (student_id = any (app.auth_guardian_student_ids()) or student_id = public.my_student_id()));

-- bed.status = occupied while an allocation is open or still to come.
create or replace function app.fn_hostel_refresh_bed(p_bed_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.hostel_bed d
     set status = case
       when d.status = 'retired' then 'retired'::public.hostel_bed_status
       when exists (select 1 from public.hostel_allocation a where a.bed_id = d.id and (a.ends_on is null or a.ends_on >= app.fn_karachi_today())) then 'occupied'::public.hostel_bed_status
       else 'available'::public.hostel_bed_status end
   where d.id = p_bed_id;
$$;
revoke execute on function app.fn_hostel_refresh_bed(uuid) from public, anon, authenticated;

-- A bed is "occupied" for the BED_OCCUPIED rule if any stay is open or upcoming.
create or replace function app.fn_hostel_bed_occupied(p_bed_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.hostel_bed where id = p_bed_id and status = 'occupied')
      or exists (select 1 from public.hostel_allocation a where a.bed_id = p_bed_id and (a.ends_on is null or a.ends_on >= app.fn_karachi_today()));
$$;
revoke execute on function app.fn_hostel_bed_occupied(uuid) from public, anon, authenticated;

-- Shared insert for allocate and transfer.
create or replace function app.fn_hostel_allocate(p_student_id uuid, p_bed_id uuid, p_from date, p_to date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bed    public.hostel_bed%rowtype;
  v_room   public.hostel_room%rowtype;
  v_enrol  public.enrolment%rowtype;
  v_id     uuid;
  v_con    text;
begin
  select * into v_bed from public.hostel_bed where id = p_bed_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'BED_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_hostel_assert_staff(v_bed.campus_id);
  select * into v_room from public.hostel_room where id = v_bed.room_id;
  if v_bed.status = 'retired' then
    raise exception 'BED_RETIRED' using errcode = '22023';
  end if;
  if v_room.status = 'out_of_service' then
    raise exception 'ROOM_OUT_OF_SERVICE' using errcode = '22023';
  end if;
  select * into v_enrol from public.enrolment
   where student_id = p_student_id and tenant_id = v_bed.tenant_id and campus_id = v_bed.campus_id and status = 'active' and deleted_at is null
   order by joined_on desc limit 1;
  if not found then
    raise exception 'NO_ACTIVE_ENROLMENT' using errcode = 'P0002';
  end if;
  perform public.assert_bed_gender(p_student_id, p_bed_id);
  insert into public.hostel_allocation (tenant_id, campus_id, student_id, enrolment_id, bed_id, starts_on, ends_on, allocated_by)
  values (v_bed.tenant_id, v_bed.campus_id, p_student_id, v_enrol.id, p_bed_id, p_from, p_to, (select auth.uid()))
  returning id into v_id;
  perform app.fn_hostel_refresh_bed(p_bed_id);
  return v_id;
exception when exclusion_violation then
  get stacked diagnostics v_con = constraint_name;
  if v_con = 'ex_student_one_bed' then
    raise exception 'STUDENT_ALREADY_HOUSED' using errcode = '23P01';
  end if;
  raise exception 'BED_TAKEN' using errcode = '23P01';
end;
$$;
revoke execute on function app.fn_hostel_allocate(uuid, uuid, date, date) from public, anon, authenticated;

create or replace function public.allocate_bed(p_student_id uuid, p_bed_id uuid, p_from date, p_to date default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_to is not null and p_to < p_from then
    raise exception 'SPAN_INVALID' using errcode = '22023';
  end if;
  return app.fn_hostel_allocate(p_student_id, p_bed_id, p_from, p_to);
end;
$$;
revoke execute on function public.allocate_bed(uuid, uuid, date, date) from public, anon;
grant execute on function public.allocate_bed(uuid, uuid, date, date) to authenticated;

-- Ends a stay on p_last_day (the last night in the bed).
create or replace function app.fn_hostel_close(p_alloc_id uuid, p_last_day date, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a public.hostel_allocation%rowtype;
begin
  update public.hostel_allocation set ends_on = p_last_day, vacate_reason = nullif(btrim(p_reason), '') where id = p_alloc_id returning * into v_a;
  perform app.fn_hostel_refresh_bed(v_a.bed_id);
end;
$$;
revoke execute on function app.fn_hostel_close(uuid, date, text) from public, anon, authenticated;

create or replace function public.vacate_bed(p_allocation_id uuid, p_last_day date, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a public.hostel_allocation%rowtype;
begin
  select * into v_a from public.hostel_allocation where id = p_allocation_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ALLOCATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_hostel_assert_staff(v_a.campus_id);
  if v_a.ends_on is not null then
    raise exception 'ALLOCATION_NOT_OPEN' using errcode = '22023';
  end if;
  if p_last_day < v_a.starts_on then
    raise exception 'SPAN_INVALID' using errcode = '22023';
  end if;
  perform app.fn_hostel_close(p_allocation_id, p_last_day, p_reason);
end;
$$;
revoke execute on function public.vacate_bed(uuid, date, text) from public, anon;
grant execute on function public.vacate_bed(uuid, date, text) to authenticated;

-- Moves a student to another bed: the old stay ends the day before p_from, the
-- new one starts on p_from, atomically (a refused new bed leaves the old stay alone).
create or replace function public.transfer_bed(p_student_id uuid, p_to_bed_id uuid, p_from date, p_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old public.hostel_allocation%rowtype;
begin
  select * into v_old from public.hostel_allocation
   where student_id = p_student_id and tenant_id = app.auth_tenant_id() and ends_on is null and starts_on < p_from
   order by starts_on desc limit 1;
  if not found then
    raise exception 'ALLOCATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_hostel_assert_staff(v_old.campus_id);
  if v_old.bed_id = p_to_bed_id then
    raise exception 'SAME_BED' using errcode = '22023';
  end if;
  perform app.fn_hostel_close(v_old.id, p_from - 1, coalesce(p_reason, 'Transferred to another bed'));
  return app.fn_hostel_allocate(p_student_id, p_to_bed_id, p_from, null);
end;
$$;
revoke execute on function public.transfer_bed(uuid, uuid, date, text) from public, anon;
grant execute on function public.transfer_bed(uuid, uuid, date, text) to authenticated;

-- A withdrawn student's stay ends on the leaving date.
create or replace function app.tg_enrolment_vacate_hostel()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r      record;
  v_last date := coalesce(new.left_on, app.fn_karachi_today());
begin
  if new.status <> 'active' and old.status = 'active' then
    for r in select id, starts_on from public.hostel_allocation where enrolment_id = new.id and ends_on is null loop
      perform app.fn_hostel_close(r.id, greatest(v_last, r.starts_on), 'Enrolment withdrawn');
    end loop;
  end if;
  return new;
end;
$$;
create trigger trg_enrolment_vacate_hostel after update of status on public.enrolment
  for each row execute function app.tg_enrolment_vacate_hostel();

-- Nightly: beds whose stay ended become available again the same night.
create or replace function public.hostel_bed_status_refresh()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  update public.hostel_bed d
     set status = case when exists (select 1 from public.hostel_allocation a where a.bed_id = d.id and (a.ends_on is null or a.ends_on >= app.fn_karachi_today()))
                       then 'occupied'::public.hostel_bed_status else 'available'::public.hostel_bed_status end
   where d.status <> 'retired'
     and d.status is distinct from case when exists (select 1 from public.hostel_allocation a where a.bed_id = d.id and (a.ends_on is null or a.ends_on >= app.fn_karachi_today()))
                       then 'occupied'::public.hostel_bed_status else 'available'::public.hostel_bed_status end;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.hostel_bed_status_refresh() from public, anon, authenticated;
grant execute on function public.hostel_bed_status_refresh() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('hostel_bed_status_refresh', '5 19 * * *', 'select public.hostel_bed_status_refresh();');
  end if;
exception
  when others then null;
end;
$$;
