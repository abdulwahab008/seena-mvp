-- A payroll run could be locked straight from draft, skipping the approval the
-- run screen asks for. Locking now needs a submitted run that has been approved.

create or replace function public.fn_lock_payroll_run(p_run_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
  v_status    text;
  v_approved  timestamptz;
begin
  select tenant_id, campus_id, status, approved_at into v_tenant_id, v_campus_id, v_status, v_approved
    from public.payroll_run where id = p_run_id;
  if found then
    perform app.fn_assert_payroll_access(array['super_admin', 'owner'], v_tenant_id, v_campus_id);
  end if;

  if v_status = 'draft' or (v_status = 'pending_approval' and v_approved is null) then
    raise exception 'RUN_NOT_APPROVED' using errcode = '55000', hint = 'Submit the run and approve it before locking.';
  end if;

  update public.payroll_run
  set
    status = 'locked',
    locked_by = auth.uid(),
    locked_at = now()
  where id = p_run_id and status = 'pending_approval' and approved_at is not null;

  if not found then
    raise exception 'RUN_CANNOT_BE_LOCKED' using errcode = 'P0002';
  end if;
end;
$function$;
