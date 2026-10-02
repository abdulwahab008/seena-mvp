-- Migration: 20260801230000_dynamic_school_leave_policies.sql
-- Enables dynamic, per-school leave quota management, custom policy creation, and active staff ledger balance synchronization.

create or replace function public.update_school_leave_policy(
  p_id                       uuid,
  p_name_en                  text,
  p_entitlement_days         numeric,
  p_is_paid                  boolean,
  p_doc_required_after_days  smallint default null,
  p_is_active                boolean default true,
  p_sync_active_staff        boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_user_id       uuid := auth.uid();
  v_old_days      numeric;
  v_year_start    date := date_trunc('year', current_date)::date;
  v_staff_updated int := 0;
  v_staff         record;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select entitlement_days into v_old_days
  from public.leave_type
  where id = p_id and tenant_id = v_tenant_id;

  if v_old_days is null then
    raise exception 'LEAVE_POLICY_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.leave_type
  set name_en = trim(p_name_en),
      entitlement_days = p_entitlement_days,
      is_paid = p_is_paid,
      doc_required_after_days = p_doc_required_after_days,
      is_active = p_is_active
  where id = p_id and tenant_id = v_tenant_id;

  -- Sync active staff members' annual grant if requested and entitlement days changed
  if p_sync_active_staff and p_entitlement_days is distinct from v_old_days then
    for v_staff in
      select s.id from public.staff s
      where s.tenant_id = v_tenant_id and s.employment_status = 'active'
    loop
      -- Check if grant exists for this year
      if exists (
        select 1 from public.leave_ledger
        where staff_id = v_staff.id and leave_type_id = p_id
          and entry_type = 'grant' and created_at >= v_year_start
      ) then
        -- Update the grant entry to the new entitlement
        update public.leave_ledger
        set days = p_entitlement_days
        where id = (
          select id from public.leave_ledger
          where staff_id = v_staff.id and leave_type_id = p_id
            and entry_type = 'grant' and created_at >= v_year_start
          order by created_at desc
          limit 1
        );
        v_staff_updated := v_staff_updated + 1;
      else
        -- Insert new grant
        insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, created_by)
        values (v_tenant_id, v_staff.id, p_id, 'grant', p_entitlement_days, v_user_id);
        v_staff_updated := v_staff_updated + 1;
      end if;
    end loop;
  end if;

  return jsonb_build_object(
    'success', true,
    'id', p_id,
    'staff_updated', v_staff_updated
  );
end;
$$;

create or replace function public.create_custom_leave_policy(
  p_code                     text,
  p_name_en                  text,
  p_entitlement_days         numeric,
  p_is_paid                  boolean default false,
  p_doc_required_after_days  smallint default null,
  p_grant_active_staff       boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_user_id       uuid := auth.uid();
  v_id            uuid;
  v_year_start    date := date_trunc('year', current_date)::date;
  v_staff_granted int := 0;
  v_staff         record;
  v_clean_code    text := upper(trim(p_code));
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if exists (select 1 from public.leave_type where tenant_id = v_tenant_id and code = v_clean_code) then
    raise exception 'LEAVE_CODE_ALREADY_EXISTS' using errcode = '23505';
  end if;

  insert into public.leave_type (
    tenant_id, code, name_en, entitlement_days, accrual_method, is_paid,
    doc_required_after_days, eligible_genders, eligible_contract_types, effective_from, is_active
  ) values (
    v_tenant_id, v_clean_code, trim(p_name_en), p_entitlement_days, 'annual_grant', p_is_paid,
    p_doc_required_after_days, array['male', 'female', 'other'], array['permanent', 'contract', 'probation'], v_year_start, true
  ) returning id into v_id;

  if p_grant_active_staff and p_entitlement_days > 0 then
    for v_staff in
      select s.id from public.staff s
      where s.tenant_id = v_tenant_id and s.employment_status = 'active'
    loop
      insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, created_by)
      values (v_tenant_id, v_staff.id, v_id, 'grant', p_entitlement_days, v_user_id);
      v_staff_granted := v_staff_granted + 1;
    end loop;
  end if;

  return jsonb_build_object(
    'success', true,
    'id', v_id,
    'staff_granted', v_staff_granted
  );
end;
$$;

create or replace function public.toggle_leave_policy_status(
  p_id        uuid,
  p_is_active boolean
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.leave_type
  set is_active = p_is_active
  where id = p_id and tenant_id = v_tenant_id;

  return true;
end;
$$;

revoke execute on function public.update_school_leave_policy(uuid, text, numeric, boolean, smallint, boolean, boolean) from public, anon;
grant execute on function public.update_school_leave_policy(uuid, text, numeric, boolean, smallint, boolean, boolean) to authenticated;

revoke execute on function public.create_custom_leave_policy(text, text, numeric, boolean, smallint, boolean) from public, anon;
grant execute on function public.create_custom_leave_policy(text, text, numeric, boolean, smallint, boolean) to authenticated;

revoke execute on function public.toggle_leave_policy_status(uuid, boolean) from public, anon;
grant execute on function public.toggle_leave_policy_status(uuid, boolean) to authenticated;
