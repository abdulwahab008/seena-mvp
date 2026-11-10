-- Fee summary by class for a date range: billed, concessions, collected,
-- written off, the balance still owed, and how long the unpaid challans have
-- been overdue. Security invoker, so the fee tables' own RLS decides who sees it.
create or replace function public.fee_class_report(p_from date, p_to date)
returns table (
  class_level_id uuid, class_name text, ordinal int, students bigint,
  billed_paisa bigint, concession_paisa bigint, collected_paisa bigint, written_off_paisa bigint, balance_paisa bigint,
  due_0_30_paisa bigint, due_31_60_paisa bigint, due_61_90_paisa bigint, due_90_plus_paisa bigint
)
language sql
stable
security invoker
set search_path = ''
as $$
  with lg as (
    select e.class_level_id,
           sum(l.amount_paisa) filter (where l.value_date between p_from and p_to and l.direction = 'debit' and l.entry_type in ('charge', 'late_fee')) as billed,
           sum(l.amount_paisa) filter (where l.value_date between p_from and p_to and l.direction = 'credit' and l.entry_type = 'concession') as concession,
           sum(case when l.entry_type = 'payment' and l.direction = 'credit' then l.amount_paisa
                    when l.entry_type = 'refund' and l.direction = 'debit' then -l.amount_paisa end) filter (where l.value_date between p_from and p_to) as collected,
           sum(l.amount_paisa) filter (where l.value_date between p_from and p_to and l.direction = 'credit' and l.entry_type = 'write_off') as written_off,
           sum(case when l.direction = 'debit' then l.amount_paisa else -l.amount_paisa end) filter (where l.value_date <= p_to) as balance
      from public.fee_ledger l
      join public.enrolment e on e.id = l.enrolment_id
     group by e.class_level_id
  ),
  open_challan as (
    select e.class_level_id, (p_to - c.due_date) as age,
           greatest(c.net_paisa - coalesce((select sum(case when l.direction = 'credit' then l.amount_paisa else -l.amount_paisa end)
                                              from public.fee_ledger l where l.challan_id = c.id and l.entry_type in ('payment', 'refund')), 0), 0) as remaining
      from public.fee_challan c
      join public.enrolment e on e.id = c.enrolment_id
     where c.deleted_at is null and c.status in ('unpaid', 'part_paid') and c.due_date <= p_to
  ),
  aging as (
    select class_level_id,
           sum(remaining) filter (where age <= 30) as d0,
           sum(remaining) filter (where age between 31 and 60) as d31,
           sum(remaining) filter (where age between 61 and 90) as d61,
           sum(remaining) filter (where age > 90) as d90
      from open_challan group by class_level_id
  ),
  kids as (
    select class_level_id, count(*) as n from public.enrolment where status = 'active' and deleted_at is null group by class_level_id
  )
  select cl.id, cl.name_en, cl.ordinal, coalesce(k.n, 0),
         coalesce(lg.billed, 0), coalesce(lg.concession, 0), coalesce(lg.collected, 0), coalesce(lg.written_off, 0), coalesce(lg.balance, 0),
         coalesce(a.d0, 0), coalesce(a.d31, 0), coalesce(a.d61, 0), coalesce(a.d90, 0)
    from public.class_level cl
    left join lg on lg.class_level_id = cl.id
    left join aging a on a.class_level_id = cl.id
    left join kids k on k.class_level_id = cl.id
   where cl.tenant_id = app.auth_tenant_id()
     and (k.n is not null or lg.class_level_id is not null)
   order by cl.ordinal;
$$;
revoke execute on function public.fee_class_report(date, date) from public, anon;
grant execute on function public.fee_class_report(date, date) to authenticated;
