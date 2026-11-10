-- Morning and night roll call of hostel residents, marked by the warden or the
-- Principal's side for one campus at a time.

create table public.hostel_roll_call (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  campus_id   uuid not null references public.campus(id) on delete cascade,
  student_id  uuid not null references public.student(id) on delete cascade,
  roll_date   date not null,
  session     text not null check (session in ('morning', 'night')),
  status      text not null check (status in ('present', 'absent', 'on_leave')),
  marked_by   uuid default auth.uid() references auth.users(id),
  marked_at   timestamptz not null default now(),
  constraint uq_hostel_roll_call unique (student_id, roll_date, session)
);
create index idx_hostel_roll_call_scope on public.hostel_roll_call (tenant_id, campus_id, roll_date);

create trigger hostel_roll_call_audit after insert or update or delete on public.hostel_roll_call
  for each row execute function app.tg_audit_row();

alter table public.hostel_roll_call enable row level security;
create policy hostel_roll_call_read on public.hostel_roll_call for select to authenticated
  using (app.fn_hostel_staff(tenant_id, campus_id));
select app.fn_block_portal_roles('public.hostel_roll_call');

-- p_rows: [{"student_id": uuid, "status": "present"|"absent"|"on_leave"}]
create or replace function public.mark_hostel_roll_call(p_campus_id uuid, p_date date, p_session text, p_rows jsonb)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_row jsonb;
  v_student uuid;
  v_count int := 0;
begin
  if not app.fn_hostel_staff(v_tenant, p_campus_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_session not in ('morning', 'night') then
    raise exception 'SESSION_INVALID' using errcode = '22023';
  end if;
  if p_date > current_date then
    raise exception 'FUTURE_DATE' using errcode = '22023';
  end if;
  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    v_student := (v_row ->> 'student_id')::uuid;
    if not exists (select 1 from public.hostel_allocation a
                    where a.student_id = v_student and a.tenant_id = v_tenant and a.campus_id = p_campus_id
                      and a.starts_on <= p_date and (a.ends_on is null or a.ends_on >= p_date)) then
      raise exception 'NOT_A_RESIDENT' using errcode = 'P0002';
    end if;
    insert into public.hostel_roll_call (tenant_id, campus_id, student_id, roll_date, session, status)
    values (v_tenant, p_campus_id, v_student, p_date, p_session, v_row ->> 'status')
    on conflict (student_id, roll_date, session) do update
       set status = excluded.status, marked_by = auth.uid(), marked_at = now();
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;
revoke execute on function public.mark_hostel_roll_call(uuid, date, text, jsonb) from public, anon;
grant execute on function public.mark_hostel_roll_call(uuid, date, text, jsonb) to authenticated;
