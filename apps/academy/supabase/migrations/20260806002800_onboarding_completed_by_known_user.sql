-- The auto-complete triggers recorded auth.uid() as completed_by. A caller whose JWT subject has
-- no auth.users row (a service job carrying stale claims) then failed the insert of the fee head,
-- section or staff row itself on the completed_by foreign key. Record the caller only when known.

create or replace function app.complete_onboarding_from_data(p_tenant_id uuid, p_step public.onboarding_step_key)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.onboarding_progress
     set status = 'done',
         completed_by = coalesce(completed_by, (select u.id from auth.users u where u.id = auth.uid())),
         completed_at = coalesce(completed_at, now())
   where tenant_id = p_tenant_id and step_key = p_step and status <> 'done';
$$;
