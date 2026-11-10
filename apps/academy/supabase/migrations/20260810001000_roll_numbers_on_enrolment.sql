-- Every enrolment now gets a roll number. fn_assign_next_roll_no existed but neither enrol_student, the bulk
-- import nor any screen called it, so enrolments had no roll number unless one was typed by hand (on a real
-- school's data: all of them). An active enrolment inserted without one takes the next free number in its
-- section; existing active enrolments without one are numbered alphabetically after the section's highest.
create or replace function app.tg_enrolment_assign_roll_no()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.roll_no is null and new.status = 'active' then
    perform pg_advisory_xact_lock(hashtextextended('roll:' || new.section_id::text || ':' || new.session_id::text, 0));
    select coalesce(max(roll_no), 0) + 1 into new.roll_no
      from public.enrolment
     where section_id = new.section_id and session_id = new.session_id and status = 'active';
  end if;
  return new;
end;
$$;

create trigger enrolment_bi_assign_roll_no
  before insert on public.enrolment
  for each row execute function app.tg_enrolment_assign_roll_no();

with numbered as (
  select e.id,
         coalesce((select max(x.roll_no) from public.enrolment x
                    where x.section_id = e.section_id and x.session_id = e.session_id and x.status = 'active'), 0)
         + row_number() over (partition by e.section_id, e.session_id order by s.name_en, s.gr_number) as roll_no
    from public.enrolment e
    join public.student s on s.id = e.student_id
   where e.status = 'active' and e.roll_no is null
), logged as (
  insert into public.roll_number_change_log (enrolment_id, old_roll_no, new_roll_no, strategy)
  select id, null, roll_no, 'backfill_alphabetical' from numbered
)
update public.enrolment e set roll_no = n.roll_no from numbered n where e.id = n.id;
