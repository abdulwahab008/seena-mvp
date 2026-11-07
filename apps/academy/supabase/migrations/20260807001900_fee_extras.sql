-- Fee extras: installment plans, fee reminders to parents by WhatsApp, and
-- collection analytics.
--
-- An installment plan splits one challan's net amount into dated parts. It
-- does not change how payments allocate (still challan by challan, oldest
-- first); an installment counts as paid once the challan's payments reach
-- the running total up to it. The plan is what tells the accountant which
-- part is late.

create or replace function app.fn_assert_fee_staff(p_campus_id uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant')
     or (app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function app.fn_assert_fee_staff(uuid) from public, anon, authenticated;

-- ── installments ──────────────────────────────────────────────────────────

create table public.fee_installment (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  challan_id   uuid not null references public.fee_challan(id) on delete cascade,
  seq          int not null check (seq between 1 and 24),
  due_date     date not null,
  amount_paisa bigint not null check (amount_paisa > 0),
  created_by   uuid default auth.uid() references auth.users(id),
  created_at   timestamptz not null default now(),
  unique (challan_id, seq)
);
create index idx_fee_installment_due on public.fee_installment (tenant_id, campus_id, due_date);
alter table public.fee_installment enable row level security;
create policy fee_installment_read on public.fee_installment for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'principal', 'accountant')
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
select app.fn_block_portal_roles('public.fee_installment');

-- p_plan: [{"due_date": "YYYY-MM-DD", "amount_paisa": n}, ...] in order. An
-- empty plan removes the schedule.
create or replace function public.set_challan_installments(p_challan_id uuid, p_plan jsonb)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  c     public.fee_challan%rowtype;
  v_sum bigint;
  v_n   int;
begin
  select * into c from public.fee_challan where id = p_challan_id and tenant_id = app.auth_tenant_id() and deleted_at is null for update;
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_fee_staff(c.campus_id);
  if c.status in ('paid', 'cancelled') then
    raise exception 'CHALLAN_CLOSED' using errcode = '55000', hint = 'Only an unpaid or part-paid challan can be split.';
  end if;
  delete from public.fee_installment where challan_id = p_challan_id;
  if jsonb_array_length(coalesce(p_plan, '[]'::jsonb)) = 0 then
    return 0;
  end if;
  if jsonb_array_length(p_plan) < 2 then
    raise exception 'PLAN_TOO_SHORT' using errcode = '22023', hint = 'An installment plan has at least two parts.';
  end if;
  select sum((x ->> 'amount_paisa')::bigint) into v_sum from jsonb_array_elements(p_plan) x;
  if v_sum <> c.net_paisa then
    raise exception 'PLAN_TOTAL_MISMATCH' using errcode = '22023', detail = format('plan %s, challan %s', v_sum, c.net_paisa);
  end if;
  if exists (select 1 from jsonb_array_elements(p_plan) with ordinality x(v, n)
               join jsonb_array_elements(p_plan) with ordinality y(v, n) on y.n = x.n + 1
              where (y.v ->> 'due_date')::date <= (x.v ->> 'due_date')::date) then
    raise exception 'PLAN_DATES_ORDER' using errcode = '22023', hint = 'Each installment falls due after the one before it.';
  end if;
  insert into public.fee_installment (tenant_id, campus_id, challan_id, seq, due_date, amount_paisa)
  select c.tenant_id, c.campus_id, c.id, n, (v ->> 'due_date')::date, (v ->> 'amount_paisa')::bigint
    from jsonb_array_elements(p_plan) with ordinality x(v, n);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.set_challan_installments(uuid, jsonb) from public, anon;
grant execute on function public.set_challan_installments(uuid, jsonb) to authenticated;

-- Each installment with how much of it is still unpaid. Invoker: RLS scopes
-- it to fee staff on their campuses.
create or replace function public.installment_status(p_as_of date default current_date)
returns table (installment_id uuid, challan_id uuid, challan_no text, enrolment_id uuid, seq int, due_date date,
               amount_paisa bigint, unpaid_paisa bigint, is_overdue boolean)
language sql
stable
set search_path = ''
as $$
  with paid as (
    select a.challan_id, coalesce(sum(a.amount_paisa), 0) as paid
      from public.fee_payment_allocation a
     where a.challan_id in (select challan_id from public.fee_installment)
     group by a.challan_id
  ), running as (
    select i.*, sum(i.amount_paisa) over (partition by i.challan_id order by i.seq) as upto
      from public.fee_installment i
  )
  select r.id, r.challan_id, c.challan_no, c.enrolment_id, r.seq, r.due_date, r.amount_paisa,
         greatest(least(r.amount_paisa, r.upto - coalesce(p.paid, 0)), 0)::bigint,
         r.due_date < p_as_of and r.upto > coalesce(p.paid, 0)
    from running r
    join public.fee_challan c on c.id = r.challan_id and c.status <> 'cancelled' and c.deleted_at is null
    left join paid p on p.challan_id = r.challan_id
   order by r.due_date, c.challan_no, r.seq;
$$;
revoke execute on function public.installment_status(date) from public, anon;
grant execute on function public.installment_status(date) to authenticated;

-- ── fee reminders by WhatsApp ─────────────────────────────────────────────

-- One message per unpaid challan of a billing month, to the guardian who
-- receives fee notices. WhatsApp first; the outbox's fallback chain drops to
-- SMS where WhatsApp cannot reach. Never twice for the same challan and day.
create or replace function public.queue_fee_slip_messages(p_campus_id uuid, p_billing_period date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_queued   int := 0;
  v_no_phone int := 0;
  r record;
  v_msg uuid;
begin
  perform app.fn_assert_fee_staff(p_campus_id);
  for r in
    select c.id, c.challan_no, c.net_paisa, c.due_date, s.name_en,
           c.net_paisa - coalesce((select sum(a.amount_paisa) from public.fee_payment_allocation a where a.challan_id = c.id), 0) as due,
           (select g.phone_e164 from public.student_guardian sg join public.guardian g on g.id = sg.guardian_id
             where sg.student_id = s.id and sg.receives_billing and (sg.to_date is null or sg.to_date >= current_date) and g.phone_e164 is not null
             order by sg.is_primary desc, sg.priority limit 1) as phone
      from public.fee_challan c
      join public.enrolment e on e.id = c.enrolment_id
      join public.student s on s.id = e.student_id
     where c.tenant_id = app.auth_tenant_id() and c.campus_id = p_campus_id
       and date_trunc('month', c.billing_period) = date_trunc('month', p_billing_period)
       and c.status in ('unpaid', 'part_paid') and c.deleted_at is null
  loop
    if r.due <= 0 then
      continue;
    end if;
    if r.phone is null then
      v_no_phone := v_no_phone + 1;
      continue;
    end if;
    insert into public.message (tenant_id, campus_id, recipient_type, recipient_phone, channel, subject, body, status, idempotency_key, metadata)
    values (app.auth_tenant_id(), p_campus_id, 'guardian', r.phone, 'whatsapp', 'Fee due',
            format('Assalam o Alaikum. %s''s fee of PKR %s (challan %s) is due on %s. Please pay at the school counter or the bank. JazakAllah.',
                   r.name_en, to_char(r.due / 100.0, 'FM999,999,990'), r.challan_no, to_char(r.due_date, 'DD Mon YYYY')),
            'queued', 'fee-slip:' || r.id || ':' || current_date,
            jsonb_build_object('template', 'fee_slip', 'challan_id', r.id))
    on conflict (tenant_id, idempotency_key) where idempotency_key is not null do nothing
    returning id into v_msg;
    if v_msg is not null then
      v_queued := v_queued + 1;
    end if;
  end loop;
  return jsonb_build_object('queued', v_queued, 'no_phone', v_no_phone);
end;
$$;
revoke execute on function public.queue_fee_slip_messages(uuid, date) from public, anon;
grant execute on function public.queue_fee_slip_messages(uuid, date) to authenticated;

-- ── analytics ─────────────────────────────────────────────────────────────
-- Invoker functions: RLS on challans and payments decides what each reader sees.

create or replace function public.fee_collection_by_month(p_from date, p_to date)
returns table (month date, billed_paisa bigint, collected_paisa bigint)
language sql
stable
set search_path = ''
as $$
  with months as (
    select generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month')::date as month
  )
  select m.month,
         coalesce((select sum(c.net_paisa) from public.fee_challan c
                    where date_trunc('month', c.billing_period) = m.month and c.status <> 'cancelled' and c.deleted_at is null), 0)::bigint,
         coalesce((select sum(p.amount_paisa) from public.fee_payment p
                    where date_trunc('month', p.value_date) = m.month and p.mode <> 'adjustment'), 0)::bigint
    from months m
   order by m.month;
$$;
revoke execute on function public.fee_collection_by_month(date, date) from public, anon;
grant execute on function public.fee_collection_by_month(date, date) to authenticated;

-- Outstanding by how long past due: 0-30, 31-60, 61-90 and over 90 days.
create or replace function public.fee_outstanding_ageing(p_as_of date default current_date)
returns table (bucket text, challans bigint, outstanding_paisa bigint)
language sql
stable
set search_path = ''
as $$
  with open as (
    select c.due_date,
           c.net_paisa - coalesce((select sum(a.amount_paisa) from public.fee_payment_allocation a where a.challan_id = c.id), 0) as due
      from public.fee_challan c
     where c.status in ('unpaid', 'part_paid') and c.deleted_at is null and c.due_date < p_as_of
  ), bucketed as (
    select case when p_as_of - due_date <= 30 then '1-30 days'
                when p_as_of - due_date <= 60 then '31-60 days'
                when p_as_of - due_date <= 90 then '61-90 days'
                else 'Over 90 days' end as bucket, due
      from open where due > 0
  )
  select b.bucket, count(*)::bigint, sum(b.due)::bigint
    from bucketed b
   group by b.bucket
   order by min(case b.bucket when '1-30 days' then 1 when '31-60 days' then 2 when '61-90 days' then 3 else 4 end);
$$;
revoke execute on function public.fee_outstanding_ageing(date) from public, anon;
grant execute on function public.fee_outstanding_ageing(date) to authenticated;
