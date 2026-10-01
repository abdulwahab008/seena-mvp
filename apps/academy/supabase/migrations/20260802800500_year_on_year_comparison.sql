-- FR-S10: year-on-year comparison report.
--
-- Comparing "April with April" is meaningless for a group that runs Punjab-board
-- campuses (April-March) beside Cambridge streams (August-July). Every series is
-- therefore indexed by MONTH-OF-SESSION: index 1 is the month the session starts,
-- whatever the calendar says, and the calendar month travels along as a label.
--
-- Three honesty rules, each the usual source of a wrong report:
--   * A period with no data is "no data", never zero. A campus that opened mid-year
--     has no early months; they are excluded from every change calculation instead of
--     showing -100%.
--   * Percentage change divides by the prior value only when there is one: a zero or
--     missing baseline reads "no baseline", not infinity and not an error.
--   * Classes are matched on their stable codes (class_level.code + stream.code), not
--     on whatever they were called that year. Renaming "Class 9 (Science)" to
--     "Class 9 Pre-Medical" must not split one cohort into two rows.
--
-- Everything is SECURITY INVOKER over the nightly aggregate (FR-S01), so the
-- campus_ids claim bounds the data exactly as it does on the owner dashboard.

alter table public.metric_definition add column if not exists yoy_unit text check (yoy_unit is null or yoy_unit in ('paisa', 'count', 'percent'));

insert into public.metric_definition (metric_key, display_name, numerator_desc, denominator_desc, note, yoy_unit) values
  ('enrolment', 'Enrolment', 'Students enrolled on the last refreshed day of the month', 'n/a', 'Summed across the selected campuses; month-end headcount, not an average.', 'count'),
  ('fees_collected', 'Fees collected', 'Payments received in the month, net of reversals', 'n/a', 'Money is held in paisa and shown in rupees.', 'paisa')
on conflict (metric_key) do update set yoy_unit = excluded.yoy_unit;
update public.metric_definition set yoy_unit = 'percent' where metric_key in ('collection_rate', 'attendance_rate', 'staff_cost_ratio');
update public.metric_definition set yoy_unit = 'paisa' where metric_key = 'outstanding';

-- Month-of-session index for every session.
create or replace view public.v_session_month_index with (security_invoker = true) as
select s.id as session_id, s.tenant_id, s.campus_id, g.mi as month_index,
       (date_trunc('month', s.starts_on) + (g.mi - 1) * interval '1 month')::date as month_start,
       (date_trunc('month', s.starts_on) + g.mi * interval '1 month' - interval '1 day')::date as month_end,
       to_char(date_trunc('month', s.starts_on) + (g.mi - 1) * interval '1 month', 'Mon YYYY') as period_label
  from public.academic_session s
  cross join lateral generate_series(
    1, ((extract(year from s.ends_on)::int - extract(year from s.starts_on)::int) * 12 + extract(month from s.ends_on)::int - extract(month from s.starts_on)::int + 1)
  ) as g(mi);

create index if not exists idx_agg_campus_day_campus_day on public.agg_campus_day (campus_id, day);

create or replace function public.fn_yoy_series(tenant_id uuid, campus_ids uuid[], metric_key text, session_ids uuid[])
returns table (session_id uuid, month_index int, period_label text, value numeric)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_unit text;
begin
  select m.yoy_unit into v_unit from public.metric_definition m where m.metric_key = fn_yoy_series.metric_key;
  if v_unit is null then
    raise exception 'METRIC_NOT_COMPARABLE' using errcode = '22023';
  end if;

  return query
  with pc as (
    select vi.session_id as sid, vi.month_index as mi, vi.period_label as plabel, c.id as cid,
           count(a.day) as n_days,
           coalesce(sum(a.collected_paisa), 0) as coll,
           coalesce(sum(a.billed_paisa), 0) as billed,
           coalesce(sum(a.staff_cost_paisa), 0) as staff,
           coalesce(sum(a.present_count) filter (where a.marked_sections > 0), 0) as present_marked,
           coalesce(sum(a.enrolled_count) filter (where a.marked_sections > 0), 0) as enrolled_marked,
           (select x.enrolled_count from public.agg_campus_day x where x.campus_id = c.id and x.day between greatest(vi.month_start, s.starts_on) and least(vi.month_end, s.ends_on) order by x.day desc limit 1) as last_enrolled,
           (select x.outstanding_paisa from public.agg_campus_day x where x.campus_id = c.id and x.day between greatest(vi.month_start, s.starts_on) and least(vi.month_end, s.ends_on) order by x.day desc limit 1) as last_outstanding
      from public.academic_session s
      join public.v_session_month_index vi on vi.session_id = s.id
      join public.campus c on c.tenant_id = fn_yoy_series.tenant_id and c.id = any (fn_yoy_series.campus_ids) and (s.campus_id is null or s.campus_id = c.id)
      left join public.agg_campus_day a on a.campus_id = c.id and a.day between greatest(vi.month_start, s.starts_on) and least(vi.month_end, s.ends_on)
     where s.id = any (fn_yoy_series.session_ids) and s.tenant_id = fn_yoy_series.tenant_id
       -- a campus that did not exist yet has no data for that month, rather than zero
       and (c.created_at at time zone 'Asia/Karachi')::date <= vi.month_end
     group by vi.session_id, vi.month_index, vi.period_label, c.id, s.starts_on, s.ends_on, vi.month_start, vi.month_end
  ), agg as (
    select pc.sid, pc.mi, pc.plabel,
           sum(pc.n_days) as n_days, sum(pc.coll) as coll, sum(pc.billed) as billed, sum(pc.staff) as staff,
           sum(pc.present_marked) as present_marked, sum(pc.enrolled_marked) as enrolled_marked,
           sum(pc.last_enrolled) as last_enrolled, sum(pc.last_outstanding) as last_outstanding
      from pc group by pc.sid, pc.mi, pc.plabel
  )
  select vi.session_id, vi.month_index, vi.period_label,
         case when coalesce(agg.n_days, 0) = 0 then null
              else case fn_yoy_series.metric_key
                     when 'fees_collected' then agg.coll::numeric
                     when 'enrolment' then agg.last_enrolled::numeric
                     when 'outstanding' then agg.last_outstanding::numeric
                     when 'collection_rate' then round(agg.coll * 100.0 / nullif(agg.billed, 0), 1)
                     when 'attendance_rate' then round(agg.present_marked * 100.0 / nullif(agg.enrolled_marked, 0), 1)
                     when 'staff_cost_ratio' then round(agg.staff * 100.0 / nullif(agg.coll, 0), 1)
                   end
         end
    from public.v_session_month_index vi
    left join agg on agg.sid = vi.session_id and agg.mi = vi.month_index
   where vi.session_id = any (fn_yoy_series.session_ids) and vi.tenant_id = fn_yoy_series.tenant_id
   order by vi.session_id, vi.month_index;
end;
$$;
revoke execute on function public.fn_yoy_series(uuid, uuid[], text, uuid[]) from public, anon;
grant execute on function public.fn_yoy_series(uuid, uuid[], text, uuid[]) to authenticated;

-- Month-by-month comparison of two sessions on the same index.
create or replace function public.fn_yoy_compare(tenant_id uuid, campus_ids uuid[], metric_key text, current_session_id uuid, prior_session_id uuid)
returns table (month_index int, current_label text, prior_label text, current_value numeric, prior_value numeric, abs_change numeric, pct_change numeric, status text)
language sql
stable
set search_path = ''
as $$
  with cur as (select * from public.fn_yoy_series(tenant_id, campus_ids, metric_key, array[current_session_id])),
       pri as (select * from public.fn_yoy_series(tenant_id, campus_ids, metric_key, array[prior_session_id]))
  select coalesce(cur.month_index, pri.month_index), cur.period_label, pri.period_label, cur.value, pri.value,
         case when cur.value is null or pri.value is null then null else cur.value - pri.value end,
         case when cur.value is null or pri.value is null or pri.value = 0 then null
              else round((cur.value - pri.value) * 100 / abs(pri.value), 1) end,
         case when cur.value is null or pri.value is null then 'no_data'
              when pri.value = 0 then 'no_baseline'
              else 'ok' end
    from cur full outer join pri on pri.month_index = cur.month_index
   order by 1;
$$;
revoke execute on function public.fn_yoy_compare(uuid, uuid[], text, uuid, uuid) from public, anon;
grant execute on function public.fn_yoy_compare(uuid, uuid[], text, uuid, uuid) to authenticated;

-- The headline: only months where BOTH sessions have data are compared.
create or replace function public.fn_yoy_overall(tenant_id uuid, campus_ids uuid[], metric_key text, current_session_id uuid, prior_session_id uuid)
returns table (months_compared int, months_excluded int, current_value numeric, prior_value numeric, abs_change numeric, pct_change numeric)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_unit text;
begin
  select m.yoy_unit into v_unit from public.metric_definition m where m.metric_key = fn_yoy_overall.metric_key;
  return query
  with c as (select * from public.fn_yoy_compare(tenant_id, campus_ids, metric_key, current_session_id, prior_session_id)),
       t as (
         select count(*) filter (where c.current_value is not null and c.prior_value is not null)::int as ok_n,
                count(*) filter (where c.current_value is null or c.prior_value is null)::int as ex_n,
                -- amounts add up over months; headcounts and percentages are averaged
                case when fn_yoy_overall.metric_key = 'fees_collected' then sum(c.current_value) filter (where c.current_value is not null and c.prior_value is not null)
                     else avg(c.current_value) filter (where c.current_value is not null and c.prior_value is not null) end as cv,
                case when fn_yoy_overall.metric_key = 'fees_collected' then sum(c.prior_value) filter (where c.current_value is not null and c.prior_value is not null)
                     else avg(c.prior_value) filter (where c.current_value is not null and c.prior_value is not null) end as pv
           from c
       )
  select t.ok_n, t.ex_n, round(t.cv, 2), round(t.pv, 2),
         case when t.cv is null or t.pv is null then null else round(t.cv - t.pv, 2) end,
         case when t.cv is null or t.pv is null or t.pv = 0 then null else round((t.cv - t.pv) * 100 / abs(t.pv), 1) end
    from t;
end;
$$;
revoke execute on function public.fn_yoy_overall(uuid, uuid[], text, uuid, uuid) from public, anon;
grant execute on function public.fn_yoy_overall(uuid, uuid[], text, uuid, uuid) to authenticated;

-- Class-wise enrolment per session, aligned on class_level.code + stream.code.
create or replace function public.fn_yoy_class_enrolment(tenant_id uuid, campus_ids uuid[], session_ids uuid[])
returns table (class_code text, group_code text, ordinal smallint, display_name text, session_id uuid, enrolled int, section_names text[])
language sql
stable
set search_path = ''
as $$
  select cl.code, coalesce(st.code, ''), cl.ordinal,
         cl.name_en || case when st.id is not null then ' ' || st.name_en else '' end,
         e.session_id, count(*)::int, array_agg(distinct sec.name order by sec.name)
    from public.enrolment e
    join public.class_level cl on cl.id = e.class_level_id
    join public.class_section sec on sec.id = e.section_id
    left join public.stream st on st.id = sec.stream_id
   where e.tenant_id = fn_yoy_class_enrolment.tenant_id and e.session_id = any (fn_yoy_class_enrolment.session_ids)
     and e.campus_id = any (fn_yoy_class_enrolment.campus_ids) and e.deleted_at is null
   group by cl.code, st.code, cl.ordinal, cl.name_en, st.id, st.name_en, e.session_id
   order by cl.ordinal, cl.code, 2, e.session_id;
$$;
revoke execute on function public.fn_yoy_class_enrolment(uuid, uuid[], uuid[]) from public, anon;
grant execute on function public.fn_yoy_class_enrolment(uuid, uuid[], uuid[]) to authenticated;
