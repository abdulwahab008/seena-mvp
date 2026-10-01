-- FR-S03: principal same-day operations dashboard.
--
-- Deliberately NOT built on agg_campus_day: this screen answers "what is wrong
-- right now", and a nightly rollup would show yesterday. Everything here reads
-- the live tables through RLS (security_invoker), bounded by the campus_ids
-- claim, with covering indexes so a 1,500-student campus stays fast.
--
-- "Collected today" counts only money that is in the drawer: payment ledger
-- credits dated today (Asia/Karachi) minus reversals of payments dated today.
-- A cancelled receipt is a reversal and drops out; an online payment awaiting
-- its gateway callback has no payment row yet, so it never counts — it is
-- shown separately as "pending online".

create index if not exists idx_attendance_campus_date on public.attendance_day (campus_id, attendance_date) include (status, section_id);

create view public.v_principal_today with (security_invoker = true) as
select c.id as campus_id, c.tenant_id, app.fn_karachi_today() as on_date,
       (select count(*) from public.class_section s where s.campus_id = c.id and s.is_active)::int as sections_total,
       (select count(distinct a.section_id) from public.attendance_day a where a.campus_id = c.id and a.attendance_date = app.fn_karachi_today())::int as sections_marked,
       (select count(*) from public.attendance_day a where a.campus_id = c.id and a.attendance_date = app.fn_karachi_today() and a.status = 'absent')::int as absent_count,
       (select coalesce(sum(case when fl.entry_type = 'payment' and fl.direction = 'credit' then fl.amount_paisa else 0 end), 0)
               - coalesce(sum(case when fl.entry_type = 'reversal'
                                    and exists (select 1 from public.fee_ledger o where o.id = fl.reversal_of_id and o.entry_type = 'payment')
                                   then fl.amount_paisa else 0 end), 0)
          from public.fee_ledger fl
         where fl.campus_id = c.id and fl.value_date = app.fn_karachi_today())::bigint as collected_today_paisa,
       (select count(*) from public.payment_intent i where i.campus_id = c.id and i.status = 'pending')::int as pending_online_count
  from public.campus c
 where c.deleted_at is null;

create or replace function app.fn_can_see_principal_today(p_campus_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal')
     and p_campus_id = any(app.auth_campus_ids())
     and exists (select 1 from public.campus c where c.id = p_campus_id and c.tenant_id = app.auth_tenant_id());
$$;
grant execute on function app.fn_can_see_principal_today(uuid) to authenticated;

create or replace function public.fn_unmarked_sections(p_campus_id uuid, p_on_date date default null)
returns table (section_id uuid, section_name text, class_name text, class_teacher_name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_date date := coalesce(p_on_date, app.fn_karachi_today());
begin
  if not app.fn_can_see_principal_today(p_campus_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  return query
  select s.id, s.name, cl.name_en,
         (select u.full_name
            from public.section_class_teacher t
            join public.app_user u on u.user_id = t.staff_id
           where t.section_id = s.id and t.effective_from <= v_date and (t.effective_to is null or t.effective_to >= v_date)
           order by t.effective_from desc limit 1)
    from public.class_section s
    join public.class_level cl on cl.id = s.class_level_id
   where s.campus_id = p_campus_id and s.is_active
     and not exists (select 1 from public.attendance_day a where a.section_id = s.id and a.attendance_date = v_date)
   order by cl.ordinal, s.name;
end;
$$;
revoke execute on function public.fn_unmarked_sections(uuid, date) from public, anon;
grant execute on function public.fn_unmarked_sections(uuid, date) to authenticated;

create or replace function public.fn_today_absentees(p_campus_id uuid, p_on_date date default null)
returns table (enrolment_id uuid, gr_number text, student_name text, class_name text, section_name text, guardian_name text, guardian_phone text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_date date := coalesce(p_on_date, app.fn_karachi_today());
begin
  if not app.fn_can_see_principal_today(p_campus_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  return query
  select e.id, st.gr_number, st.name_en, cl.name_en, s.name, g.name_en, g.phone_e164
    from public.attendance_day a
    join public.enrolment e on e.id = a.enrolment_id
    join public.student st on st.id = e.student_id
    join public.class_section s on s.id = a.section_id
    join public.class_level cl on cl.id = s.class_level_id
    left join lateral (
      select gg.name_en, gg.phone_e164
        from public.student_guardian sg join public.guardian gg on gg.id = sg.guardian_id
       where sg.student_id = st.id and sg.to_date is null and gg.phone_e164 is not null
       order by sg.is_primary desc, sg.priority asc
       limit 1
    ) g on true
   where a.campus_id = p_campus_id and a.attendance_date = v_date and a.status = 'absent'
   order by cl.ordinal, s.name, st.name_en;
end;
$$;
revoke execute on function public.fn_today_absentees(uuid, date) from public, anon;
grant execute on function public.fn_today_absentees(uuid, date) to authenticated;
