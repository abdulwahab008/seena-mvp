-- Migration: 20260801220000_school_leave_policies_and_seeding.sql
-- Configure standard school leave policies: strictly 18 paid days (10 Casual + 8 Sick) and unpaid other categories

create or replace function public.initialize_school_leave_policies()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_user_id       uuid := auth.uid();
  v_created_types int := 0;
  v_staff_count   int := 0;
  v_casual_id     uuid;
  v_sick_id       uuid;
  v_unpaid_id     uuid;
  v_mat_id        uuid;
  v_hajj_id       uuid;
  v_staff         record;
  v_year_start    date := date_trunc('year', current_date)::date;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- 1. Casual Leave (10 days, Paid)
  select id into v_casual_id from public.leave_type where tenant_id = v_tenant_id and code = 'CASUAL';
  if v_casual_id is null then
    insert into public.leave_type (
      tenant_id, code, name_en, entitlement_days, accrual_method, is_paid,
      doc_required_after_days, eligible_genders, eligible_contract_types, effective_from
    ) values (
      v_tenant_id, 'CASUAL', 'Casual Leave', 10, 'annual_grant', true,
      null, array['male', 'female', 'other'], array['permanent', 'contract', 'probation'], v_year_start
    ) returning id into v_casual_id;
    v_created_types := v_created_types + 1;
  end if;

  -- 2. Sick / Medical Leave (8 days, Paid, Medical cert required after 2 days)
  select id into v_sick_id from public.leave_type where tenant_id = v_tenant_id and code = 'SICK';
  if v_sick_id is null then
    insert into public.leave_type (
      tenant_id, code, name_en, entitlement_days, accrual_method, is_paid,
      doc_required_after_days, eligible_genders, eligible_contract_types, effective_from
    ) values (
      v_tenant_id, 'SICK', 'Sick / Medical Leave', 8, 'annual_grant', true,
      2, array['male', 'female', 'other'], array['permanent', 'contract', 'probation'], v_year_start
    ) returning id into v_sick_id;
    v_created_types := v_created_types + 1;
  end if;

  -- 3. Unpaid Leave (Loss of Pay - 30 days quota, Unpaid)
  select id into v_unpaid_id from public.leave_type where tenant_id = v_tenant_id and code = 'UNPAID';
  if v_unpaid_id is null then
    insert into public.leave_type (
      tenant_id, code, name_en, entitlement_days, accrual_method, is_paid,
      doc_required_after_days, eligible_genders, eligible_contract_types, effective_from
    ) values (
      v_tenant_id, 'UNPAID', 'Unpaid Leave (Loss of Pay)', 30, 'annual_grant', false,
      null, array['male', 'female', 'other'], array['permanent', 'contract', 'probation'], v_year_start
    ) returning id into v_unpaid_id;
    v_created_types := v_created_types + 1;
  end if;

  -- 4. Maternity Leave (90 days, Unpaid, Female only)
  select id into v_mat_id from public.leave_type where tenant_id = v_tenant_id and code = 'MATERNITY';
  if v_mat_id is null then
    insert into public.leave_type (
      tenant_id, code, name_en, entitlement_days, accrual_method, is_paid,
      doc_required_after_days, eligible_genders, eligible_contract_types, effective_from
    ) values (
      v_tenant_id, 'MATERNITY', 'Maternity Leave (Unpaid)', 90, 'none', false,
      null, array['female'], array['permanent', 'contract', 'probation'], v_year_start
    ) returning id into v_mat_id;
    v_created_types := v_created_types + 1;
  end if;

  -- 5. Hajj / Pilgrimage Leave (30 days, Unpaid)
  select id into v_hajj_id from public.leave_type where tenant_id = v_tenant_id and code = 'HAJJ';
  if v_hajj_id is null then
    insert into public.leave_type (
      tenant_id, code, name_en, entitlement_days, accrual_method, is_paid,
      doc_required_after_days, eligible_genders, eligible_contract_types, effective_from
    ) values (
      v_tenant_id, 'HAJJ', 'Hajj / Pilgrimage Leave (Unpaid)', 30, 'none', false,
      null, array['male', 'female', 'other'], array['permanent', 'contract', 'probation'], v_year_start
    ) returning id into v_hajj_id;
    v_created_types := v_created_types + 1;
  end if;

  -- Grant annual balances to all active staff in the tenant
  for v_staff in
    select id, gender, contract_type from public.staff
    where tenant_id = v_tenant_id and employment_status = 'active'
  loop
    v_staff_count := v_staff_count + 1;

    -- Grant Casual (10 days) if not already granted this year
    if not exists (
      select 1 from public.leave_ledger
      where staff_id = v_staff.id and leave_type_id = v_casual_id
        and entry_type = 'grant' and created_at >= v_year_start
    ) then
      insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, created_by)
      values (v_tenant_id, v_staff.id, v_casual_id, 'grant', 10, v_user_id);
    end if;

    -- Grant Sick (8 days) if not already granted this year
    if not exists (
      select 1 from public.leave_ledger
      where staff_id = v_staff.id and leave_type_id = v_sick_id
        and entry_type = 'grant' and created_at >= v_year_start
    ) then
      insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, created_by)
      values (v_tenant_id, v_staff.id, v_sick_id, 'grant', 8, v_user_id);
    end if;

    -- Grant Unpaid (30 days) if not already granted this year
    if not exists (
      select 1 from public.leave_ledger
      where staff_id = v_staff.id and leave_type_id = v_unpaid_id
        and entry_type = 'grant' and created_at >= v_year_start
    ) then
      insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, created_by)
      values (v_tenant_id, v_staff.id, v_unpaid_id, 'grant', 30, v_user_id);
    end if;
  end loop;

  return jsonb_build_object(
    'leave_types_created', v_created_types,
    'staff_credited', v_staff_count
  );
end;
$$;

revoke execute on function public.initialize_school_leave_policies() from public, anon;
grant execute on function public.initialize_school_leave_policies() to authenticated;
