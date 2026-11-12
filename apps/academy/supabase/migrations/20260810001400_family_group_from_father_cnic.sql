-- Students are grouped into a family when their father's CNIC is recorded, as the Family List says, but
-- nothing ever did it: link_family_group() had no caller, so every school's family list and family fee
-- counter were empty however many fathers were linked. Linking a father who has a CNIC now puts the
-- student in that father's family (created on first use); existing father links are backfilled.
create or replace function app.tg_student_guardian_family_group()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cnic     text;
  v_group_id uuid;
begin
  select g.cnic into v_cnic from public.guardian g where g.id = new.guardian_id;
  if v_cnic is null or exists (select 1 from public.student where id = new.student_id and family_group_id is not null) then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtext('family:' || new.tenant_id::text || ':' || v_cnic));
  select id into v_group_id from public.family_group
   where tenant_id = new.tenant_id and father_cnic = v_cnic
   order by created_at limit 1;
  if v_group_id is null then
    insert into public.family_group (tenant_id, father_cnic, primary_guardian_id)
    values (new.tenant_id, v_cnic, new.guardian_id)
    returning id into v_group_id;
  end if;

  update public.student set family_group_id = v_group_id where id = new.student_id;
  return new;
end;
$$;

create trigger student_guardian_ai_family_group
  after insert on public.student_guardian
  for each row when (new.relationship = 'father' and new.to_date is null)
  execute function app.tg_student_guardian_family_group();

-- Backfill: one family per father CNIC per school, for students not yet in one.
insert into public.family_group (tenant_id, father_cnic, primary_guardian_id)
select distinct on (g.tenant_id, g.cnic) g.tenant_id, g.cnic, g.id
  from public.student_guardian sg
  join public.guardian g on g.id = sg.guardian_id and g.cnic is not null
  join public.student s on s.id = sg.student_id and s.family_group_id is null
 where sg.relationship = 'father' and sg.to_date is null
   and not exists (select 1 from public.family_group f where f.tenant_id = g.tenant_id and f.father_cnic = g.cnic)
 order by g.tenant_id, g.cnic, g.created_at;

update public.student s
   set family_group_id = f.id
  from public.student_guardian sg
  join public.guardian g on g.id = sg.guardian_id and g.cnic is not null
  join public.family_group f on f.tenant_id = g.tenant_id and f.father_cnic = g.cnic
 where sg.student_id = s.id and sg.relationship = 'father' and sg.to_date is null
   and s.family_group_id is null;
