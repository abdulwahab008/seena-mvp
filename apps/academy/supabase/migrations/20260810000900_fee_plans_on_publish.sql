-- Students enrolled before a campus/session's first fee structure was published never got a fee plan:
-- app.build_fee_plan_for only ran from the enrolment insert trigger, so a school that imported its students
-- first and set up fees second could not bill anyone (every challan failed NO_FEE_PLAN).
-- Publishing a structure now builds the missing plans for that campus and session.
create or replace function app.tg_fee_structure_build_missing_plans()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.build_fee_plan_for(e.id, e.tenant_id)
     from public.enrolment e
    where e.campus_id = new.campus_id and e.session_id = new.session_id
      and e.status = 'active' and e.deleted_at is null
      and not exists (select 1 from public.fee_plan fp where fp.enrolment_id = e.id);
  return new;
end;
$$;

create trigger fee_structure_au_build_missing_plans
  after update of status on public.fee_structure
  for each row when (new.status = 'published' and old.status is distinct from 'published')
  execute function app.tg_fee_structure_build_missing_plans();

-- One-time backfill for structures published before this trigger existed.
select app.build_fee_plan_for(e.id, e.tenant_id)
  from public.enrolment e
  join public.fee_structure fs on fs.campus_id = e.campus_id and fs.session_id = e.session_id and fs.status = 'published'
 where e.status = 'active' and e.deleted_at is null
   and not exists (select 1 from public.fee_plan fp where fp.enrolment_id = e.id);
