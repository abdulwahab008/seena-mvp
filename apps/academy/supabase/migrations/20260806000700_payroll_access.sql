-- Payroll is for the people who run payroll.
--
-- Two separate problems, both found by signing in as every role:
--
-- 1. The functions. generate_payroll_run() had no role, tenant or campus check at all: any
--    signed-in user, a class teacher or a student included, could (re)generate payroll for any
--    campus of any school, wiping that campus's draft lines and loan recoveries on the way.
--    fn_submit_payroll_for_approval(), fn_approve_payroll_run() and fn_lock_payroll_run() looked
--    protected ("current_user <> 'postgres' and role not in ..."), but they are SECURITY DEFINER, so
--    current_user is always the owner there and the check never ran: anyone could approve or lock
--    anyone's payroll run. They now go through app.fn_assert_payroll_access(), which checks the role,
--    that the run (or campus) belongs to the caller's tenant, and that the caller is assigned to its
--    campus unless they are an Owner or Super Admin. Server-side callers (the service role, cron and
--    direct database sessions) are unchanged, which is also what the old check was trying to allow.
--    Helpers that return one person's salary, attendance deductions or loan recoveries
--    (fn_active_salary_structure, fn_salary_for_period, fn_unpaid_days, fn_attendance_deduction_paisa,
--    fn_accrue_loan_recovery, seed_default_salary_components) are only ever called from
--    generate_payroll_run(); they were open to every signed-in user and are now service-role only.
--
-- 2. The tables. The read policies on the salary structure, payroll runs and lines, adjustments,
--    arrears, loans and recoveries let in anyone whose token carries the campus ("campus_id = any
--    (auth_campus_ids())"), which is every teacher, nurse and librarian on the campus, and every
--    parent and student, because their tokens carry campus ids too. They now name the roles that
--    handle payroll (Owner, Super Admin, HR Manager, Accountant) and keep the employee's own rows.
--    Tax slabs stay public: they are statutory.

create or replace function app.fn_assert_payroll_access(p_roles text[], p_tenant_id uuid, p_campus_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is not null then
    if app.auth_role() <> all (p_roles) or p_tenant_id is distinct from app.auth_tenant_id() then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any (app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    return;
  end if;
  -- No school session: only the service role, cron and direct database connections get through.
  if coalesce(auth.role(), '') = 'service_role'
     or (coalesce(auth.role(), '') = '' and session_user in ('postgres', 'supabase_admin')) then
    return;
  end if;
  raise exception 'FORBIDDEN' using errcode = '42501';
end;
$$;

revoke all on function app.fn_assert_payroll_access(text[], uuid, uuid) from public, anon, authenticated;

-- public.generate_payroll_run
create or replace function public.generate_payroll_run(p_campus_id uuid, p_period_date date)
 returns uuid
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_tenant_id       uuid;
  v_period_month    date;
  v_period_end      date;
  v_run_id          uuid;
  v_run_status      public.payroll_run_status;
  v_cfg             record;
  v_payable_basis   numeric := 26;
  v_staff           record;
  v_structure       public.employee_salary_structure;
  v_unpaid_days     numeric := 0;
  v_basic           bigint := 0;
  v_gross           bigint := 0;
  v_att_ded         bigint := 0;
  v_taxable         bigint := 0;
  v_tax             bigint := 0;
  v_loan_rec        bigint := 0;
  v_other_ded       bigint := 0;
  v_net             bigint := 0;
  v_min_net         bigint := 0;
  v_line_id         uuid;
  v_comp            record;
  v_tot_gross       bigint := 0;
  v_tot_ded         bigint := 0;
  v_tot_net         bigint := 0;
  v_count           int := 0;
begin
  select tenant_id into v_tenant_id from public.campus where id = p_campus_id;
  if v_tenant_id is null then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform app.fn_assert_payroll_access(array['super_admin', 'owner', 'hr_manager', 'accountant'], v_tenant_id, p_campus_id);

  -- Normalize to first day and last day of month
  v_period_month := date_trunc('month', p_period_date)::date;
  v_period_end   := (date_trunc('month', p_period_date) + interval '1 month - 1 day')::date;

  -- Acquire transaction-level lock to prevent concurrent generation races
  perform pg_advisory_xact_lock(hashtext('generate_payroll_run:' || p_campus_id::text || ':' || v_period_month::text));

  -- Check if a run already exists
  select id, status into v_run_id, v_run_status
  from public.payroll_run
  where campus_id = p_campus_id and period_month = v_period_month;

  if v_run_id is not null then
    if v_run_status in ('locked', 'paid') then
      raise exception 'PAYROLL_RUN_ALREADY_LOCKED' using errcode = 'P0001';
    end if;

    -- Clean up previous draft line items & recoveries
    delete from public.staff_loan_recovery where payroll_run_id = v_run_id;
    delete from public.payroll_run_line where payroll_run_id = v_run_id;
  else
    insert into public.payroll_run (
      tenant_id, campus_id, period_month, status, generated_by
    ) values (
      v_tenant_id, p_campus_id, v_period_month, 'draft', auth.uid()
    )
    returning id into v_run_id;
  end if;

  -- Read campus payroll configuration
  select payable_day_basis, net_pay_floor_pct
  into v_cfg
  from public.payroll_config
  where campus_id = p_campus_id;

  if v_cfg.payable_day_basis = 'calendar' then
    v_payable_basis := extract(day from v_period_end);
  elsif v_cfg.payable_day_basis = 'working' then
    v_payable_basis := 22;
  else
    v_payable_basis := 26;
  end if;

  -- Ensure default salary components exist
  perform public.seed_default_salary_components(v_tenant_id);

  -- Iterate through active staff in this campus
  for v_staff in
    select s.id, s.employee_code, s.full_name
    from public.staff s
    where s.campus_id = p_campus_id
      and s.employment_status = 'active'
    order by s.employee_code
  loop
    v_basic     := 0;
    v_gross     := 0;
    v_taxable   := 0;
    v_other_ded := 0;

    -- Unpaid absence days
    v_unpaid_days := public.fn_unpaid_days(v_staff.id, v_period_month, v_period_end);

    -- Active salary structure
    select * into v_structure
    from public.fn_active_salary_structure(v_staff.id, v_period_end);

    if v_structure.id is not null then
      v_basic := v_structure.basic_paisa;
    end if;

    -- Attendance deduction on basic
    v_att_ded := public.fn_attendance_deduction_paisa(
      v_staff.id, v_basic, v_period_month, v_period_end, v_payable_basis
    );

    -- Calculate all components
    for v_comp in
      select * from public.fn_salary_for_period(
        v_staff.id, v_period_month, v_period_end, v_payable_basis, v_unpaid_days
      )
    loop
      if v_comp.component_type = 'earning' then
        v_gross := v_gross + v_comp.amount_paisa;
        if v_comp.is_taxable then
          v_taxable := v_taxable + v_comp.taxable_paisa;
        end if;
      elsif v_comp.component_type = 'deduction' then
        v_other_ded := v_other_ded + v_comp.amount_paisa;
      end if;
    end loop;

    -- Monthly withholding tax on taxable income
    v_tax := public.fn_monthly_withholding_paisa(v_staff.id, v_taxable);

    -- Accrue loan recovery
    v_loan_rec := public.fn_accrue_loan_recovery(v_run_id, v_staff.id, v_period_month);

    -- Net pay calculation
    v_net := v_gross - (v_att_ded + v_tax + v_loan_rec + v_other_ded);

    -- Apply floor if configured
    if coalesce(v_cfg.net_pay_floor_pct, 0) > 0 and v_gross > 0 then
      v_min_net := round((v_gross::numeric * v_cfg.net_pay_floor_pct) / 100.0)::bigint;
      v_net := greatest(v_net, v_min_net);
    else
      v_net := greatest(0, v_net);
    end if;

    -- Insert payroll run line
    insert into public.payroll_run_line (
      payroll_run_id,
      staff_id,
      basic_paisa,
      gross_paisa,
      attendance_deduction_paisa,
      tax_withholding_paisa,
      loan_recovery_paisa,
      other_deductions_paisa,
      net_paisa,
      unpaid_days,
      payable_days,
      status
    ) values (
      v_run_id,
      v_staff.id,
      v_basic,
      v_gross,
      v_att_ded,
      v_tax,
      v_loan_rec,
      v_other_ded,
      v_net,
      v_unpaid_days,
      v_payable_basis,
      'calculated'
    )
    returning id into v_line_id;

    -- Insert line component breakdown
    for v_comp in
      select * from public.fn_salary_for_period(
        v_staff.id, v_period_month, v_period_end, v_payable_basis, v_unpaid_days
      )
    loop
      insert into public.payroll_run_line_component (
        line_id, component_id, code, name_en, component_type, amount_paisa, is_taxable
      ) values (
        v_line_id, v_comp.component_id, v_comp.code, v_comp.name_en, v_comp.component_type::text, v_comp.amount_paisa, v_comp.is_taxable
      );
    end loop;

    -- Accumulate run totals
    v_tot_gross := v_tot_gross + v_gross;
    v_tot_ded   := v_tot_ded + (v_att_ded + v_tax + v_loan_rec + v_other_ded);
    v_tot_net   := v_tot_net + v_net;
    v_count     := v_count + 1;
  end loop;

  -- Update run summary totals
  update public.payroll_run
  set
    total_gross_paisa      = v_tot_gross,
    total_deductions_paisa = v_tot_ded,
    total_net_paisa        = v_tot_net,
    employee_count         = v_count,
    generated_at           = now()
  where id = v_run_id;

  return v_run_id;
end;
$function$;

-- public.fn_submit_payroll_for_approval
create or replace function public.fn_submit_payroll_for_approval(p_run_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
begin
  select tenant_id, campus_id into v_tenant_id, v_campus_id from public.payroll_run where id = p_run_id;
  if found then
    perform app.fn_assert_payroll_access(array['super_admin', 'owner', 'hr_manager', 'accountant'], v_tenant_id, v_campus_id);
  end if;

  update public.payroll_run
  set status = 'pending_approval'
  where id = p_run_id and status = 'draft';

  if not found then
    raise exception 'RUN_NOT_FOUND_OR_NOT_DRAFT' using errcode = 'P0002';
  end if;
end;
$function$;

-- public.fn_approve_payroll_run
create or replace function public.fn_approve_payroll_run(p_run_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
begin
  select tenant_id, campus_id into v_tenant_id, v_campus_id from public.payroll_run where id = p_run_id;
  if found then
    perform app.fn_assert_payroll_access(array['super_admin', 'owner'], v_tenant_id, v_campus_id);
  end if;

  update public.payroll_run
  set
    approved_by = auth.uid(),
    approved_at = now()
  where id = p_run_id and status = 'pending_approval';

  if not found then
    raise exception 'RUN_NOT_FOUND_OR_NOT_PENDING' using errcode = 'P0002';
  end if;
end;
$function$;

-- public.fn_lock_payroll_run
create or replace function public.fn_lock_payroll_run(p_run_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
begin
  select tenant_id, campus_id into v_tenant_id, v_campus_id from public.payroll_run where id = p_run_id;
  if found then
    perform app.fn_assert_payroll_access(array['super_admin', 'owner'], v_tenant_id, v_campus_id);
  end if;

  update public.payroll_run
  set
    status = 'locked',
    locked_by = auth.uid(),
    locked_at = now()
  where id = p_run_id and status in ('draft', 'pending_approval');

  if not found then
    raise exception 'RUN_CANNOT_BE_LOCKED' using errcode = 'P0002';
  end if;
end;
$function$;


-- ── functions that only generate_payroll_run() calls ────────────────────────────────

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (array[
         'fn_accrue_loan_recovery', 'fn_active_salary_structure', 'fn_attendance_deduction_paisa',
         'fn_salary_for_period', 'fn_unpaid_days', 'seed_default_salary_components'
       ])
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $$;

-- ── who can read payroll ────────────────────────────────────────────────────────────

-- A policy expression runs with the reader's own row-level security, so an employee could not see
-- the payroll run their own line belongs to (and should not: it carries the run's totals). This reads
-- the run on their behalf and answers only "may I see this line?".
create or replace function app.fn_payroll_line_visible(p_line_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.payroll_run_line l
      join public.payroll_run r on r.id = l.payroll_run_id
     where l.id = p_line_id
       and r.tenant_id = app.auth_tenant_id()
       and (
         app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
         or exists (select 1 from public.staff s where s.id = l.staff_id and s.user_id = (select auth.uid()))
       )
  );
$$;

revoke all on function app.fn_payroll_line_visible(uuid) from public, anon;
grant execute on function app.fn_payroll_line_visible(uuid) to authenticated;

alter policy salary_structure_read on public.employee_salary_structure using (
  tenant_id = (select app.auth_tenant_id())
  and (
    app.auth_role() in ('super_admin', 'owner')
    or (app.auth_role() in ('hr_manager', 'accountant') and campus_id = any (app.auth_campus_ids()))
    or exists (select 1 from public.staff s where s.id = employee_salary_structure.staff_id and s.user_id = (select auth.uid()))
  )
);

alter policy payroll_arrear_read on public.payroll_arrear using (
  tenant_id = (select app.auth_tenant_id())
  and (
    app.auth_role() in ('super_admin', 'owner')
    or (app.auth_role() in ('hr_manager', 'accountant') and campus_id = any (app.auth_campus_ids()))
    or exists (select 1 from public.staff s where s.id = payroll_arrear.staff_id and s.user_id = (select auth.uid()))
  )
);

alter policy payroll_config_read on public.payroll_config using (
  tenant_id = (select app.auth_tenant_id())
  and (
    app.auth_role() in ('super_admin', 'owner')
    or (app.auth_role() in ('hr_manager', 'accountant') and campus_id = any (app.auth_campus_ids()))
  )
);

alter policy payroll_run_read on public.payroll_run using (
  tenant_id = (select app.auth_tenant_id())
  and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
);

alter policy payroll_run_line_read on public.payroll_run_line using (app.fn_payroll_line_visible(id));

alter policy payroll_adj_read on public.payroll_adjustment using (app.fn_payroll_line_visible(line_id));

alter policy payroll_line_comp_read on public.payroll_run_line_component using (app.fn_payroll_line_visible(line_id));

alter policy staff_loan_read on public.staff_loan using (
  tenant_id = (select app.auth_tenant_id())
  and (
    app.auth_role() in ('super_admin', 'owner')
    or (app.auth_role() in ('hr_manager', 'accountant') and campus_id = any (app.auth_campus_ids()))
    or exists (select 1 from public.staff s where s.id = staff_loan.staff_id and s.user_id = (select auth.uid()))
  )
);

alter policy staff_loan_recovery_read on public.staff_loan_recovery using (
  exists (
    select 1
      from public.staff_loan l
     where l.id = staff_loan_recovery.loan_id
       and l.tenant_id = (select app.auth_tenant_id())
       and (
         app.auth_role() in ('super_admin', 'owner')
         or (app.auth_role() in ('hr_manager', 'accountant') and l.campus_id = any (app.auth_campus_ids()))
         or exists (select 1 from public.staff s where s.id = l.staff_id and s.user_id = (select auth.uid()))
       )
  )
);

-- The component catalogue (basic, house rent, ...) is school setup, not an individual's pay: staff only.
alter policy salary_component_tenant_read on public.salary_component using (
  tenant_id = (select app.auth_tenant_id())
  and app.auth_role() not in ('parent', 'student', 'none')
);
