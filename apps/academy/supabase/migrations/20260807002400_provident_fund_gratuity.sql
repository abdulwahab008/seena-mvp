-- Provident fund and gratuity.
--
-- Provident fund is two salary components on the existing catalogue: the
-- employee's share deducted from pay and the school's matching share as an
-- employer contribution, both a percentage of basic. The payroll engine
-- already applies them; this adds them in one step.
--
-- Gratuity is a liability report: one month's current basic for each
-- completed year of service, the usual practice for private schools in
-- Pakistan. Nothing is paid from here.

create or replace function public.add_provident_fund_components(p_employee_pct numeric, p_employer_pct numeric)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_n int := 0;
begin
  if v_tenant is null or app.auth_role() not in ('super_admin', 'owner', 'hr_manager', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_employee_pct <= 0 or p_employee_pct > 20 or p_employer_pct < 0 or p_employer_pct > 20 then
    raise exception 'PCT_INVALID' using errcode = '22023', hint = 'Provident fund shares are up to 20% of basic.';
  end if;
  if exists (select 1 from public.salary_component where tenant_id = v_tenant and code in ('PF_EE', 'PF_ER') and effective_to is null) then
    raise exception 'PF_EXISTS' using errcode = '22023', hint = 'Provident fund components are already set up; change them under Salary Components.';
  end if;
  insert into public.salary_component (tenant_id, code, name_en, name_ur, component_type, calc_method, calc_pct, is_taxable, prorates_on_absence, created_by)
  values (v_tenant, 'PF_EE', 'Provident Fund (employee)', 'پراویڈنٹ فنڈ (ملازم)', 'deduction', 'pct_of_basic', p_employee_pct, false, false, auth.uid());
  v_n := 1;
  if p_employer_pct > 0 then
    insert into public.salary_component (tenant_id, code, name_en, name_ur, component_type, calc_method, calc_pct, is_taxable, prorates_on_absence, created_by)
    values (v_tenant, 'PF_ER', 'Provident Fund (school)', 'پراویڈنٹ فنڈ (ادارہ)', 'employer_contribution', 'pct_of_basic', p_employer_pct, false, false, auth.uid());
    v_n := 2;
  end if;
  return v_n;
end;
$$;
revoke execute on function public.add_provident_fund_components(numeric, numeric) from public, anon;
grant execute on function public.add_provident_fund_components(numeric, numeric) to authenticated;

create or replace function public.gratuity_liability(p_as_of date default current_date)
returns table (staff_id uuid, employee_code text, full_name text, doj date, years_completed int, basic_paisa bigint, gratuity_paisa bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
    select s.id, s.employee_code, s.full_name, s.doj,
           extract(year from age(p_as_of, s.doj))::int,
           coalesce(ss.basic_paisa, 0),
           (extract(year from age(p_as_of, s.doj))::int * coalesce(ss.basic_paisa, 0))::bigint
      from public.staff s
      left join lateral (
        select x.basic_paisa from public.employee_salary_structure x
         where x.staff_id = s.id and x.validity @> p_as_of
         order by lower(x.validity) desc limit 1
      ) ss on true
     where s.tenant_id = app.auth_tenant_id() and s.employment_status <> 'exited' and s.doj <= p_as_of
       and (app.auth_role() in ('super_admin', 'owner') or s.campus_id = any (app.auth_campus_ids()))
     order by s.full_name;
end;
$$;
revoke execute on function public.gratuity_liability(date) from public, anon;
grant execute on function public.gratuity_liability(date) to authenticated;
