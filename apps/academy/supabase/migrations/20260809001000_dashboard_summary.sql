-- Every figure on the main dashboard in one round trip. SECURITY INVOKER, so
-- each table's own RLS decides what the caller sees: a teacher gets zeros for
-- the fee and payroll figures, and the page does not show them those tiles.
-- Summing here also avoids the API's 1,000-row cap on what the page fetches.
create or replace function public.dashboard_summary()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with d as (
    select app.fn_karachi_today() as today,
           date_trunc('month', app.fn_karachi_today())::date as month_start,
           (date_trunc('month', app.fn_karachi_today()) + interval '1 month')::date as next_month
  )
  select jsonb_build_object(
    'students_active', (select count(*) from public.student where status = 'active' and deleted_at is null),
    'students_total', (select count(*) from public.student where deleted_at is null),
    'staff_active', (select count(*) from public.staff where employment_status = 'active'),
    'staff_total', (select count(*) from public.staff),
    'families', (select count(*) from public.family_group),
    'classes', (select count(*) from public.class_level where is_active),
    'library_copies', (select count(*) from public.library_copy),
    'transportees', (select count(*) from public.transport_allocation, d where starts_on <= d.today and (ends_on is null or ends_on >= d.today)),
    'birthdays_today', (
      select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name_en, 'gr', s.gr_number) order by s.name_en), '[]'::jsonb)
        from public.student s, d
       where s.status = 'active' and s.deleted_at is null
         and extract(month from s.dob) = extract(month from d.today) and extract(day from s.dob) = extract(day from d.today)
    ),
    'fee_month_paisa', (select coalesce(sum(net_paisa), 0) from public.fee_challan c, d
                         where c.deleted_at is null and c.status <> 'cancelled' and c.billing_period >= d.month_start and c.billing_period < d.next_month),
    'fee_received_month_paisa', (select coalesce(sum(amount_paisa), 0) from public.fee_payment p, d where p.value_date >= d.month_start and p.value_date < d.next_month),
    'fee_received_today_paisa', (select coalesce(sum(amount_paisa), 0) from public.fee_payment p, d where p.value_date = d.today),
    'fee_postings_today', (select count(*) from public.fee_payment p, d where p.value_date = d.today),
    'receivable_paisa', (select coalesce(sum(case when direction = 'debit' then amount_paisa else -amount_paisa end), 0) from public.fee_ledger),
    'bad_debt_month_paisa', (select coalesce(sum(amount_paisa), 0) from public.fee_bad_debt b, d where b.written_off_on >= d.month_start and b.written_off_on < d.next_month),
    'bad_debt_total_paisa', (select coalesce(sum(amount_paisa), 0) from public.fee_bad_debt),
    'salary_month_paisa', (select coalesce(sum(total_net_paisa), 0) from public.payroll_run r, d where r.period_month = d.month_start and r.status <> 'cancelled'),
    'salary_last_month_paisa', (select coalesce(sum(total_net_paisa), 0) from public.payroll_run r, d where r.period_month = (d.month_start - interval '1 month')::date and r.status <> 'cancelled'),
    'salary_paid_month_paisa', (select coalesce(sum(total_net_paisa), 0) from public.payroll_run r, d where r.period_month = d.month_start and r.status = 'paid'),
    'salary_payable_paisa', (select coalesce(sum(total_net_paisa), 0) from public.payroll_run where status = 'locked'),
    'expenses_today_paisa', (select coalesce(sum(amount_paisa), 0) from public.expense_voucher v, d where v.voucher_date = d.today and v.status in ('approved', 'paid')),
    'expenses_month_paisa', (select coalesce(sum(amount_paisa), 0) from public.expense_voucher v, d where v.voucher_date >= d.month_start and v.voucher_date < d.next_month and v.status in ('approved', 'paid')),
    'shop_sales_month_paisa', (select coalesce(sum(case when s.doc_type = 'sale' then s.total else -s.total end), 0) from public.inv_sale s, d
                                where (s.sold_at at time zone 'Asia/Karachi')::date >= d.month_start and (s.sold_at at time zone 'Asia/Karachi')::date < d.next_month),
    'messages_month', (
      select coalesce(jsonb_object_agg(channel, n), '{}'::jsonb) from (
        select m.channel::text as channel, count(*) as n from public.message m, d
         where m.created_at >= d.month_start and m.status in ('delivered', 'submitted', 'sending')
         group by m.channel) x
    ),
    'commitments_today', (
      select coalesce(jsonb_agg(jsonb_build_object('name', st.name_en, 'gr', st.gr_number, 'class', cl.name_en, 'amount_paisa', fc.amount_paisa) order by fc.amount_paisa desc), '[]'::jsonb)
        from public.fee_commitment fc
        join public.enrolment e on e.id = fc.enrolment_id
        join public.student st on st.id = e.student_id
        left join public.class_section cs on cs.id = e.section_id
        left join public.class_level cl on cl.id = cs.class_level_id, d
       where fc.status = 'open' and fc.promised_date = d.today
    ),
    'receivable_by_month', (
      select coalesce(jsonb_agg(jsonb_build_object('month', m, 'paisa', paisa) order by m), '[]'::jsonb) from (
        select greatest(c.billing_period, (date_trunc('year', d.today))::date - 1) as m, sum(c.net_paisa) as paisa
          from public.fee_challan c, d
         where c.deleted_at is null and c.status in ('unpaid', 'part_paid')
         group by 1) x
    )
  );
$$;

revoke execute on function public.dashboard_summary() from public, anon;
grant execute on function public.dashboard_summary() to authenticated;
