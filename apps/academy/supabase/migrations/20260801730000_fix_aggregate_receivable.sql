-- FR-S01 fix: outstanding is the ledger balance per student (see fn_agg_compute), not a sum of per-challan
-- balances, which double counted arrears carried forward into later challans.
create or replace function app.fn_agg_compute(p_tenant_id uuid, p_campus_id uuid, p_day date)
returns public.agg_campus_day
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.agg_campus_day;
  v_month date := date_trunc('month', p_day)::date;
  v_dim int := extract(day from (v_month + interval '1 month - 1 day'))::int;
  v_payroll record;
begin
  r.tenant_id := p_tenant_id;
  r.campus_id := p_campus_id;
  r.day := p_day;

  select count(*)::int into r.enrolled_count
    from public.enrolment e
   where e.tenant_id = p_tenant_id and e.campus_id = p_campus_id and e.deleted_at is null
     and coalesce(e.joined_on, (e.created_at at time zone 'Asia/Karachi')::date) <= p_day
     and (e.left_on is null or e.left_on > p_day);

  select count(distinct a.enrolment_id) filter (where a.status in ('present', 'late', 'half_day'))::int,
         count(distinct a.section_id)::int
    into r.present_count, r.marked_sections
    from public.attendance_day a
   where a.tenant_id = p_tenant_id and a.campus_id = p_campus_id and a.attendance_date = p_day;

  select coalesce(sum(case when entry_type = 'payment' and direction = 'credit' then amount_paisa else 0 end), 0)
         - coalesce(sum(case when entry_type = 'reversal' and exists (select 1 from public.fee_ledger o where o.id = fl.reversal_of_id and o.entry_type = 'payment') then amount_paisa else 0 end), 0),
         coalesce(sum(case when entry_type in ('charge', 'late_fee') and direction = 'debit' then amount_paisa else 0 end), 0)
         - coalesce(sum(case when entry_type = 'concession' and direction = 'credit' then amount_paisa else 0 end), 0)
    into r.collected_paisa, r.billed_paisa
    from public.fee_ledger fl
   where fl.tenant_id = p_tenant_id and fl.campus_id = p_campus_id and fl.value_date = p_day;

  -- Receivable = each student's LEDGER balance as of the day's close (debits
  -- minus credits). Per-challan balances would double count: a later challan
  -- carries earlier arrears inside its own net. Each student lands in exactly
  -- one age bucket, by their oldest unpaid challan, so the buckets sum to the total.
  with bal as (
    select fl.enrolment_id, sum(case when fl.direction = 'debit' then fl.amount_paisa else -fl.amount_paisa end) as b
      from public.fee_ledger fl
     where fl.tenant_id = p_tenant_id and fl.campus_id = p_campus_id and fl.value_date <= p_day
       and not exists (select 1 from public.fee_challan c
                        where c.id = coalesce(fl.challan_id, case when fl.source_type = 'fee_challan' then fl.source_id end) and c.deleted_at is not null)
     group by fl.enrolment_id
    having sum(case when fl.direction = 'debit' then fl.amount_paisa else -fl.amount_paisa end) > 0
  ), age as (
    select c.enrolment_id, p_day - min(c.due_date) as days
      from public.fee_challan c
     where c.tenant_id = p_tenant_id and c.campus_id = p_campus_id and c.deleted_at is null and c.status <> 'cancelled'
       and c.issue_date <= p_day and c.due_date <= p_day
       and c.net_paisa - coalesce((select sum(al.amount_paisa) from public.fee_payment_allocation al
                                    join public.fee_payment p on p.id = al.payment_id
                                   where al.challan_id = c.id and p.value_date <= p_day), 0) > 0
     group by c.enrolment_id
  )
  select coalesce(sum(bal.b) filter (where coalesce(age.days, 0) <= 30), 0),
         coalesce(sum(bal.b) filter (where age.days between 31 and 60), 0),
         coalesce(sum(bal.b) filter (where age.days > 60), 0)
    into r.outstanding_0_30_paisa, r.outstanding_31_60_paisa, r.outstanding_60plus_paisa
    from bal left join age on age.enrolment_id = bal.enrolment_id;
  r.outstanding_paisa := r.outstanding_0_30_paisa + r.outstanding_31_60_paisa + r.outstanding_60plus_paisa;

  select status::text as status, total_gross_paisa into v_payroll
    from public.payroll_run
   where tenant_id = p_tenant_id and campus_id = p_campus_id and period_month = v_month and status <> 'cancelled'
   order by generated_at desc limit 1;
  if v_payroll.status is null then
    r.staff_cost_paisa := 0;
    r.payroll_status := 'none';
  else
    r.staff_cost_paisa := v_payroll.total_gross_paisa / v_dim
      + case when extract(day from p_day)::int = v_dim then v_payroll.total_gross_paisa % v_dim else 0 end;
    r.payroll_status := v_payroll.status;
  end if;

  r.last_refreshed_at := now();
  return r;
end;
$$;
