-- Donors, donations and student sponsorships (common in madrassas and trust
-- schools).
--
-- A donation is a register entry. A sponsorship is a donor's promise to pay
-- a student's fees up to a monthly amount; applying sponsorships for a month
-- records a fee payment against the student's open challans through the
-- normal payment path (record_payment), so the challan, the receipt trail
-- and the ledger all see it. Applying the same month twice does nothing.

create table public.donor (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  name       text not null check (length(btrim(name)) between 1 and 150),
  phone      text check (phone is null or length(phone) <= 30),
  email      text check (email is null or length(email) <= 200),
  cnic       text check (cnic is null or length(cnic) <= 20),
  notes      text check (notes is null or length(notes) <= 500),
  created_at timestamptz not null default now()
);
create index idx_donor_tenant on public.donor (tenant_id, name);

create table public.donation (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  donor_id     uuid not null references public.donor(id) on delete cascade,
  amount_paisa bigint not null check (amount_paisa > 0),
  received_on  date not null default current_date,
  mode         text not null check (mode in ('cash', 'bank', 'cheque', 'online')),
  purpose      text not null default 'general' check (purpose in ('general', 'zakat', 'sadaqah', 'building', 'sponsorship')),
  reference    text check (reference is null or length(reference) <= 100),
  created_by   uuid default auth.uid() references auth.users(id),
  created_at   timestamptz not null default now()
);
create index idx_donation_donor on public.donation (donor_id, received_on desc);
create index idx_donation_tenant on public.donation (tenant_id, received_on desc);

create table public.sponsorship (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  donor_id      uuid not null references public.donor(id) on delete cascade,
  student_id    uuid not null references public.student(id) on delete cascade,
  monthly_paisa bigint not null check (monthly_paisa > 0),
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);
create unique index uq_sponsorship_active on public.sponsorship (student_id, donor_id) where is_active;
create index idx_sponsorship_donor on public.sponsorship (donor_id);

create table public.sponsorship_payment (
  sponsorship_id uuid not null references public.sponsorship(id) on delete cascade,
  month          date not null check (month = date_trunc('month', month)::date),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  fee_payment_id uuid references public.fee_payment(id) on delete set null,
  amount_paisa   bigint not null check (amount_paisa > 0),
  created_at     timestamptz not null default now(),
  primary key (sponsorship_id, month)
);
create index idx_sponsorship_payment_tenant on public.sponsorship_payment (tenant_id, month);

create or replace function app.fn_donor_reader()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('super_admin', 'owner', 'principal', 'accountant');
$$;

alter table public.donor enable row level security;
alter table public.donation enable row level security;
alter table public.sponsorship enable row level security;
alter table public.sponsorship_payment enable row level security;
create policy donor_read on public.donor for select to authenticated using (tenant_id = app.auth_tenant_id() and app.fn_donor_reader());
create policy donation_read on public.donation for select to authenticated using (tenant_id = app.auth_tenant_id() and app.fn_donor_reader());
create policy sponsorship_read on public.sponsorship for select to authenticated using (tenant_id = app.auth_tenant_id() and app.fn_donor_reader());
create policy sponsorship_payment_read on public.sponsorship_payment for select to authenticated using (tenant_id = app.auth_tenant_id() and app.fn_donor_reader());
select app.fn_block_portal_roles('public.donor');
select app.fn_block_portal_roles('public.donation');
select app.fn_block_portal_roles('public.sponsorship');
select app.fn_block_portal_roles('public.sponsorship_payment');

create or replace function app.fn_assert_donor_writer()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is null or app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function app.fn_assert_donor_writer() from public, anon, authenticated;

create or replace function public.save_donor(p_name text, p_phone text default null, p_email text default null, p_cnic text default null, p_notes text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.fn_assert_donor_writer();
  insert into public.donor (tenant_id, name, phone, email, cnic, notes)
  values (app.auth_tenant_id(), btrim(p_name), nullif(btrim(coalesce(p_phone, '')), ''), nullif(btrim(coalesce(p_email, '')), ''),
          nullif(btrim(coalesce(p_cnic, '')), ''), nullif(btrim(coalesce(p_notes, '')), ''))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.save_donor(text, text, text, text, text) from public, anon;
grant execute on function public.save_donor(text, text, text, text, text) to authenticated;

create or replace function public.record_donation(p_donor_id uuid, p_amount_paisa bigint, p_received_on date, p_mode text, p_purpose text, p_reference text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.fn_assert_donor_writer();
  if not exists (select 1 from public.donor where id = p_donor_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'DONOR_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_received_on > current_date then
    raise exception 'DATE_INVALID' using errcode = '22023';
  end if;
  insert into public.donation (tenant_id, donor_id, amount_paisa, received_on, mode, purpose, reference)
  values (app.auth_tenant_id(), p_donor_id, p_amount_paisa, p_received_on, p_mode, p_purpose, nullif(btrim(coalesce(p_reference, '')), ''))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.record_donation(uuid, bigint, date, text, text, text) from public, anon;
grant execute on function public.record_donation(uuid, bigint, date, text, text, text) to authenticated;

create or replace function public.save_sponsorship(p_donor_id uuid, p_student_id uuid, p_monthly_paisa bigint)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.fn_assert_donor_writer();
  if not exists (select 1 from public.donor where id = p_donor_id and tenant_id = app.auth_tenant_id())
     or not exists (select 1 from public.student where id = p_student_id and tenant_id = app.auth_tenant_id() and deleted_at is null) then
    raise exception 'NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into public.sponsorship (tenant_id, donor_id, student_id, monthly_paisa)
  values (app.auth_tenant_id(), p_donor_id, p_student_id, p_monthly_paisa)
  on conflict (student_id, donor_id) where is_active do update set monthly_paisa = excluded.monthly_paisa
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.save_sponsorship(uuid, uuid, bigint) from public, anon;
grant execute on function public.save_sponsorship(uuid, uuid, bigint) to authenticated;

create or replace function public.end_sponsorship(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.fn_assert_donor_writer();
  update public.sponsorship set is_active = false where id = p_id and tenant_id = app.auth_tenant_id();
end;
$$;
revoke execute on function public.end_sponsorship(uuid) from public, anon;
grant execute on function public.end_sponsorship(uuid) to authenticated;

-- Pays each active sponsorship for the month, up to the smaller of the
-- monthly amount and what the student owes on open challans.
create or replace function public.apply_sponsorships(p_month date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_month date := date_trunc('month', p_month)::date;
  v_paid  int := 0;
  v_total bigint := 0;
  v_amt   bigint;
  v_pay   uuid;
  r record;
begin
  perform app.fn_assert_donor_writer();
  for r in
    select s.id, s.monthly_paisa, d.name as donor, e.id as enrolment_id,
           (select coalesce(sum(c.net_paisa), 0) - coalesce(sum((select coalesce(sum(a.amount_paisa), 0) from public.fee_payment_allocation a where a.challan_id = c.id)), 0)
              from public.fee_challan c where c.enrolment_id = e.id and c.status in ('unpaid', 'part_paid') and c.deleted_at is null) as owed
      from public.sponsorship s
      join public.donor d on d.id = s.donor_id
      join public.enrolment e on e.student_id = s.student_id and e.status = 'active'
     where s.tenant_id = app.auth_tenant_id() and s.is_active
       and not exists (select 1 from public.sponsorship_payment p where p.sponsorship_id = s.id and p.month = v_month)
  loop
    v_amt := least(r.monthly_paisa, r.owed);
    if v_amt <= 0 then
      continue;
    end if;
    v_pay := public.record_payment(r.enrolment_id, v_amt, 'bank_challan', left('Sponsored by ' || r.donor, 100));
    insert into public.sponsorship_payment (sponsorship_id, month, tenant_id, fee_payment_id, amount_paisa)
    values (r.id, v_month, app.auth_tenant_id(), v_pay, v_amt);
    v_paid := v_paid + 1;
    v_total := v_total + v_amt;
  end loop;
  return jsonb_build_object('paid', v_paid, 'total_paisa', v_total);
end;
$$;
revoke execute on function public.apply_sponsorships(date) from public, anon;
grant execute on function public.apply_sponsorships(date) to authenticated;
