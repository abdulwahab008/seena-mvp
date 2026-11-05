-- Audit: payroll paid staff who had no salary structure. See the comment in the loop.
CREATE OR REPLACE FUNCTION public.generate_payroll_run(p_campus_id uuid, p_period_date date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

    -- Audit: someone with no salary structure was paid the flat allowances (Rs 5,000 conveyance)
    -- and charged EOBI on a basic of zero. Nobody is paid until HR sets their structure.
    if v_structure.id is null then
      continue;
    end if;
    v_basic := v_structure.basic_paisa;

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
