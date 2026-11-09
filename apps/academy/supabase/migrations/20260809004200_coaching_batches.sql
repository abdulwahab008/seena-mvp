-- Extra coaching: paid classes outside the timetable (evening tuition, test
-- preparation). A batch has a teacher, a monthly fee and a free-text
-- schedule; students are enrolled into it from a date and leave on a date.
--
-- Billing rides the ancillary-fee path that transport and hostel use: the
-- monthly post writes one fee_ledger debit per coaching enrolment per month
-- under fee head COACHING (source_type 'coaching_fee'), and generate_challans()
-- puts unbilled ancillary rows on the challan as their own line. Post the
-- month before generating that month's challans. The full monthly fee is
-- charged for any month the student is enrolled for at least one day.

create table public.coaching_batch (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  name              text not null check (length(btrim(name)) between 1 and 120),
  subject           text check (subject is null or length(subject) <= 120),
  teacher_staff_id  uuid references public.staff(id),
  monthly_fee_paisa bigint not null default 0 check (monthly_fee_paisa >= 0),
  schedule          text check (schedule is null or length(schedule) <= 300),
  is_active         boolean not null default true,
  created_by        uuid default auth.uid() references auth.users(id),
  created_at        timestamptz not null default now()
);
create unique index uq_coaching_batch_name on public.coaching_batch (campus_id, lower(name));
create index idx_coaching_batch_scope on public.coaching_batch (tenant_id, campus_id);
create index idx_coaching_batch_teacher on public.coaching_batch (teacher_staff_id);
create trigger coaching_batch_audit after insert or update or delete on public.coaching_batch
  for each row execute function app.tg_audit_row();

create table public.coaching_enrolment (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  batch_id   uuid not null references public.coaching_batch(id) on delete cascade,
  student_id uuid not null references public.student(id) on delete cascade,
  starts_on  date not null default current_date,
  ends_on    date,
  created_by uuid default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  constraint chk_coaching_enrolment_dates check (ends_on is null or ends_on >= starts_on)
);
create unique index uq_coaching_enrolment_open on public.coaching_enrolment (batch_id, student_id) where ends_on is null;
create index idx_coaching_enrolment_scope on public.coaching_enrolment (tenant_id, campus_id);
create index idx_coaching_enrolment_student on public.coaching_enrolment (student_id);
create trigger coaching_enrolment_audit after insert or update or delete on public.coaching_enrolment
  for each row execute function app.tg_audit_row();

alter table public.coaching_batch enable row level security;
alter table public.coaching_enrolment enable row level security;
create policy coaching_batch_campus_scope on public.coaching_batch for select to authenticated
  using (app.fn_campus_scope(tenant_id, campus_id));
create policy coaching_enrolment_campus_scope on public.coaching_enrolment for select to authenticated
  using (app.fn_campus_scope(tenant_id, campus_id));
select app.fn_block_portal_roles('public.coaching_batch');
select app.fn_block_portal_roles('public.coaching_enrolment');

create unique index fee_ledger_coaching_month_uq on public.fee_ledger (source_id, value_date) where source_type = 'coaching_fee';

create or replace function app.fn_ancillary_source_types()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['transport_allocation', 'transport_allocation_adj', 'hostel_charge', 'hostel_concession',
               'hostel_adj', 'hostel_deposit', 'library_write_off', 'coaching_fee']::text[];
$$;
revoke execute on function app.fn_ancillary_source_types() from public, anon, authenticated;

create or replace function app.fn_coaching_assert_manager(p_campus_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'accountant')
     or not app.fn_campus_scope(app.auth_tenant_id(), p_campus_id)
     or not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function app.fn_coaching_assert_manager(uuid) from public, anon, authenticated;

create or replace function public.save_coaching_batch(
  p_campus_id uuid, p_name text, p_subject text, p_teacher_staff_id uuid, p_monthly_fee_paisa bigint,
  p_schedule text, p_is_active boolean default true, p_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.fn_coaching_assert_manager(p_campus_id);
  if p_teacher_staff_id is not null and not exists (
    select 1 from public.staff where id = p_teacher_staff_id and tenant_id = app.auth_tenant_id()
  ) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  begin
    if p_id is null then
      insert into public.coaching_batch (tenant_id, campus_id, name, subject, teacher_staff_id, monthly_fee_paisa, schedule, is_active)
      values (app.auth_tenant_id(), p_campus_id, btrim(p_name), nullif(btrim(coalesce(p_subject, '')), ''), p_teacher_staff_id,
              coalesce(p_monthly_fee_paisa, 0), nullif(btrim(coalesce(p_schedule, '')), ''), coalesce(p_is_active, true))
      returning id into v_id;
    else
      update public.coaching_batch
         set name = btrim(p_name), subject = nullif(btrim(coalesce(p_subject, '')), ''), teacher_staff_id = p_teacher_staff_id,
             monthly_fee_paisa = coalesce(p_monthly_fee_paisa, 0), schedule = nullif(btrim(coalesce(p_schedule, '')), ''),
             is_active = coalesce(p_is_active, true)
       where id = p_id and tenant_id = app.auth_tenant_id() and campus_id = p_campus_id
      returning id into v_id;
      if v_id is null then
        raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002';
      end if;
    end if;
  exception
    when unique_violation then
      raise exception 'BATCH_DUPLICATE' using errcode = '23505';
  end;
  return v_id;
end;
$$;
revoke execute on function public.save_coaching_batch(uuid, text, text, uuid, bigint, text, boolean, uuid) from public, anon;
grant execute on function public.save_coaching_batch(uuid, text, text, uuid, bigint, text, boolean, uuid) to authenticated;

create or replace function public.enrol_coaching_student(p_batch_id uuid, p_student_id uuid, p_starts_on date default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  b    public.coaching_batch%rowtype;
  v_id uuid;
begin
  select * into b from public.coaching_batch where id = p_batch_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'BATCH_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_coaching_assert_manager(b.campus_id);
  if not b.is_active then
    raise exception 'BATCH_INACTIVE' using errcode = '55000';
  end if;
  if not exists (
    select 1 from public.student where id = p_student_id and tenant_id = b.tenant_id and campus_id = b.campus_id and deleted_at is null and status = 'active'
  ) then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002', hint = 'The student must be active at the batch''s campus.';
  end if;
  begin
    insert into public.coaching_enrolment (tenant_id, campus_id, batch_id, student_id, starts_on)
    values (b.tenant_id, b.campus_id, b.id, p_student_id, coalesce(p_starts_on, app.fn_karachi_today()))
    returning id into v_id;
  exception
    when unique_violation then
      raise exception 'ALREADY_ENROLLED' using errcode = '23505';
  end;
  return v_id;
end;
$$;
revoke execute on function public.enrol_coaching_student(uuid, uuid, date) from public, anon;
grant execute on function public.enrol_coaching_student(uuid, uuid, date) to authenticated;

create or replace function public.end_coaching_enrolment(p_id uuid, p_ends_on date default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  ce public.coaching_enrolment%rowtype;
begin
  select * into ce from public.coaching_enrolment where id = p_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_coaching_assert_manager(ce.campus_id);
  if ce.ends_on is not null then
    raise exception 'ALREADY_ENDED' using errcode = '55000';
  end if;
  if coalesce(p_ends_on, app.fn_karachi_today()) < ce.starts_on then
    raise exception 'DATE_INVALID' using errcode = '22023', hint = 'The last day cannot be before the first.';
  end if;
  update public.coaching_enrolment set ends_on = coalesce(p_ends_on, app.fn_karachi_today()) where id = p_id;
end;
$$;
revoke execute on function public.end_coaching_enrolment(uuid, date) from public, anon;
grant execute on function public.end_coaching_enrolment(uuid, date) to authenticated;

create or replace function app.fn_coaching_fee_head(p_tenant uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.fee_head where tenant_id = p_tenant and lower(code) = 'coaching';
  if v_id is null then
    insert into public.fee_head (tenant_id, code, name_en, name_ur, default_frequency)
    values (p_tenant, 'COACHING', 'Coaching fee', 'کوچنگ فیس', 'monthly')
    on conflict (tenant_id, lower(code)) do nothing;
    select id into v_id from public.fee_head where tenant_id = p_tenant and lower(code) = 'coaching';
  end if;
  return v_id;
end;
$$;
revoke execute on function app.fn_coaching_fee_head(uuid) from public, anon, authenticated;

-- Posts one month's coaching fee for every enrolment that overlaps it and is
-- not yet posted. A student with no active school enrolment has no ledger to
-- post to and is skipped. Returns the number of rows posted.
create or replace function public.post_coaching_charges(p_month date)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_ms     date := date_trunc('month', p_month)::date;
  v_me     date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_head   uuid;
  v_n      int;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  v_head := app.fn_coaching_fee_head(v_tenant);
  insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction, value_date, source_type, source_id, created_by)
  select v_tenant, e.campus_id, e.id, e.session_id, 'charge', v_head, b.monthly_fee_paisa, 'debit', v_ms, 'coaching_fee', ce.id,
         (select au.user_id from public.app_user au where au.user_id = (select auth.uid()))
    from public.coaching_enrolment ce
    join public.coaching_batch b on b.id = ce.batch_id
    join public.enrolment e on e.student_id = ce.student_id and e.status = 'active' and e.deleted_at is null
   where ce.tenant_id = v_tenant
     and (app.auth_role() in ('super_admin', 'owner') or ce.campus_id = any (app.auth_campus_ids()))
     and b.monthly_fee_paisa > 0
     and ce.starts_on <= v_me and coalesce(ce.ends_on, v_me) >= v_ms
  on conflict (source_id, value_date) where source_type = 'coaching_fee' do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.post_coaching_charges(date) from public, anon;
grant execute on function public.post_coaching_charges(date) to authenticated;
