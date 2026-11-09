-- Who each staff member reports to, for the org chart. Nullable: the head of
-- the school, and anyone not yet placed, report to no one.

alter table public.staff
  add column reports_to_staff_id uuid references public.staff(id) on delete set null,
  add constraint chk_staff_not_own_manager check (reports_to_staff_id is null or reports_to_staff_id <> id);
create index idx_staff_reports_to on public.staff (reports_to_staff_id) where reports_to_staff_id is not null;
grant select (reports_to_staff_id) on public.staff to authenticated;

create or replace function public.set_staff_manager(p_staff_id uuid, p_manager_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  if v_tenant_id is null or app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.staff where id = p_staff_id and tenant_id = v_tenant_id) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_manager_id is not null then
    if not exists (select 1 from public.staff where id = p_manager_id and tenant_id = v_tenant_id) then
      raise exception 'MANAGER_NOT_FOUND' using errcode = 'P0002';
    end if;
    -- Serialise per tenant: two concurrent edits (A under B, B under A) would
    -- each pass the cycle check against the other's uncommitted state.
    perform pg_advisory_xact_lock(hashtextextended('staff_reports_to:' || v_tenant_id::text, 0));
    if p_manager_id = p_staff_id or exists (
      with recursive chain(id) as (
        select s.reports_to_staff_id from public.staff s where s.id = p_manager_id
        union
        select s.reports_to_staff_id from public.staff s join chain c on s.id = c.id
      )
      select 1 from chain where id = p_staff_id
    ) then
      raise exception 'REPORTING_CYCLE' using errcode = '22023';
    end if;
  end if;

  update public.staff set reports_to_staff_id = p_manager_id where id = p_staff_id and tenant_id = v_tenant_id;
end;
$$;
revoke execute on function public.set_staff_manager(uuid, uuid) from public, anon;
grant execute on function public.set_staff_manager(uuid, uuid) to authenticated;
