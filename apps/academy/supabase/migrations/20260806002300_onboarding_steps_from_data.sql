-- Audit: the setup checklist never noticed real progress. A school with nine fee heads, sections
-- and staff still read 0/7 and stayed blocked from Fee Structure until someone ticked
-- "Mark done". The steps that are about creating something now complete themselves when that
-- thing is first created. "Campus details" and "Academic session" stay manual: provisioning
-- creates a campus and session, and those steps ask a person to confirm them.

create or replace function app.complete_onboarding_from_data(p_tenant_id uuid, p_step public.onboarding_step_key)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.onboarding_progress
     set status = 'done', completed_by = coalesce(completed_by, auth.uid()), completed_at = coalesce(completed_at, now())
   where tenant_id = p_tenant_id and step_key = p_step and status <> 'done';
$$;

revoke execute on function app.complete_onboarding_from_data(uuid, public.onboarding_step_key) from public, anon, authenticated;

create or replace function app.tg_onboarding_from_data()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.complete_onboarding_from_data(new.tenant_id, tg_argv[0]::public.onboarding_step_key);
  return null;
end;
$$;

drop trigger if exists onboarding_fee_heads on public.fee_head;
create trigger onboarding_fee_heads after insert on public.fee_head
  for each row execute function app.tg_onboarding_from_data('fee_heads');
drop trigger if exists onboarding_class_structure on public.class_section;
create trigger onboarding_class_structure after insert on public.class_section
  for each row execute function app.tg_onboarding_from_data('class_structure');
drop trigger if exists onboarding_staff_invitations on public.tenant_invitation;
create trigger onboarding_staff_invitations after insert on public.tenant_invitation
  for each row when (new.app_role <> 'owner') execute function app.tg_onboarding_from_data('staff_invitations');
drop trigger if exists onboarding_staff_registered on public.staff;
create trigger onboarding_staff_registered after insert on public.staff
  for each row execute function app.tg_onboarding_from_data('staff_invitations');
drop trigger if exists onboarding_first_student on public.student;
create trigger onboarding_first_student after insert on public.student
  for each row execute function app.tg_onboarding_from_data('first_student');
drop trigger if exists onboarding_branding_theme on public.tenant_theme;
create trigger onboarding_branding_theme after insert or update on public.tenant_theme
  for each row execute function app.tg_onboarding_from_data('branding');
drop trigger if exists onboarding_branding_asset on public.branding_asset;
create trigger onboarding_branding_asset after insert on public.branding_asset
  for each row execute function app.tg_onboarding_from_data('branding');

-- Schools that already did the work.
update public.onboarding_progress op set status = 'done', completed_at = coalesce(op.completed_at, now())
 where op.status <> 'done' and (
   (op.step_key = 'fee_heads' and exists (select 1 from public.fee_head x where x.tenant_id = op.tenant_id))
or (op.step_key = 'class_structure' and exists (select 1 from public.class_section x where x.tenant_id = op.tenant_id))
or (op.step_key = 'staff_invitations' and (exists (select 1 from public.tenant_invitation x where x.tenant_id = op.tenant_id and x.app_role <> 'owner')
                                          or exists (select 1 from public.staff x where x.tenant_id = op.tenant_id)))
or (op.step_key = 'first_student' and exists (select 1 from public.student x where x.tenant_id = op.tenant_id))
or (op.step_key = 'branding' and (exists (select 1 from public.tenant_theme x where x.tenant_id = op.tenant_id)
                                 or exists (select 1 from public.branding_asset x where x.tenant_id = op.tenant_id))));
