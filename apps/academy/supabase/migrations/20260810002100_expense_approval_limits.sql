-- Changing who approves an expense. Every campus is seeded with three contiguous bands (anyone up to
-- Rs 25,000, the principal up to Rs 200,000, the owner above), and set_approval_threshold() could only
-- add a band, which the no-overlap constraint always refuses. This rewrites the same three bands from
-- two cut-off amounts in one transaction, so a campus is never left with a gap or an overlap.
create or replace function public.set_expense_approval_limits(p_campus_id uuid, p_self_max_paisa bigint, p_principal_max_paisa bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  if app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_self_max_paisa is null or p_principal_max_paisa is null or p_self_max_paisa < 0 or p_principal_max_paisa <= p_self_max_paisa then
    raise exception 'THRESHOLD_RANGE_INVALID' using errcode = '23514';
  end if;

  delete from public.approval_threshold where campus_id = p_campus_id;
  insert into public.approval_threshold (tenant_id, campus_id, min_amount_paisa, max_amount_paisa, required_role) values
    (v_tenant_id, p_campus_id, 0, p_self_max_paisa, null),
    (v_tenant_id, p_campus_id, p_self_max_paisa + 1, p_principal_max_paisa, 'principal'),
    (v_tenant_id, p_campus_id, p_principal_max_paisa + 1, null, 'owner');
end;
$$;

revoke execute on function public.set_expense_approval_limits(uuid, bigint, bigint) from public, anon;
grant execute on function public.set_expense_approval_limits(uuid, bigint, bigint) to authenticated;
