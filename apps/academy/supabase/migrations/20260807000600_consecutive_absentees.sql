-- Chronic absentees: students whose most recent recorded days are all
-- absences, N or more in a row. The shortage warning (attendance_shortage_
-- warning.sql) looks at the session percentage, which a long recent run of
-- absences can hide behind a good term; this catches the run itself.
--
-- SECURITY INVOKER on purpose: attendance_day, enrolment and student RLS
-- decide whose rows the caller sees, so a class teacher sees their section and
-- a principal their campus, with no role list repeated here. Streaks count
-- recorded school days, not calendar days, so weekends and holidays do not
-- break or extend them.

create or replace function public.consecutive_absentees(p_campus_id uuid, p_min_days int default 3)
returns table (
  enrolment_id  uuid,
  student_name  text,
  gr_number     text,
  class_name    text,
  streak_days   int,
  absent_since  date,
  guardian_phone text
)
language sql
stable
set search_path = ''
as $$
  with recent as (
    select ad.enrolment_id, ad.attendance_date, ad.status,
           row_number() over (partition by ad.enrolment_id order by ad.attendance_date desc) as rn
      from public.attendance_day ad
     where ad.campus_id = p_campus_id
       and ad.attendance_date >= current_date - 90
  ),
  streaks as (
    select r.enrolment_id,
           coalesce(min(r.rn) filter (where r.status <> 'absent') - 1, max(r.rn))::int as streak
      from recent r
     group by r.enrolment_id
  )
  select s.enrolment_id, st.name_en, st.gr_number,
         trim(coalesce(cl.name_en, '') || ' ' || coalesce(cs.name, '')),
         s.streak,
         (select min(r.attendance_date) from recent r where r.enrolment_id = s.enrolment_id and r.rn <= s.streak),
         (select g.phone_e164 from public.student_guardian sg join public.guardian g on g.id = sg.guardian_id
           where sg.student_id = st.id and sg.to_date is null order by sg.is_primary desc limit 1)
    from streaks s
    join public.enrolment e on e.id = s.enrolment_id and e.status = 'active'
    join public.student st on st.id = e.student_id
    left join public.class_level cl on cl.id = e.class_level_id
    left join public.class_section cs on cs.id = e.section_id
   where s.streak >= greatest(coalesce(p_min_days, 3), 2)
   order by s.streak desc, st.name_en;
$$;
revoke execute on function public.consecutive_absentees(uuid, int) from public, anon;
grant execute on function public.consecutive_absentees(uuid, int) to authenticated;
