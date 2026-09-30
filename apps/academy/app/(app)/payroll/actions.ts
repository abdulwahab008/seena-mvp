'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

// ─── Types ───────────────────────────────────────────────────────────────────

export type SalaryComponentRow = {
  id: string;
  tenant_id: string;
  code: string;
  name_en: string;
  name_ur: string | null;
  component_type: 'earning' | 'deduction' | 'employer_contribution';
  calc_method: 'fixed_paisa' | 'pct_of_basic' | 'pct_of_gross';
  calc_value_paisa: number;
  calc_pct: number;
  is_taxable: boolean;
  exemption_cap_pct: number;
  prorates_on_absence: boolean;
  effective_from: string;
  effective_to: string | null;
};

export type EmployeeSalaryStructureRow = {
  id: string;
  tenant_id: string;
  campus_id: string;
  staff_id: string;
  staff_name: string;
  employee_code: string;
  validity: string;
  start_date: string;
  end_date: string | null;
  basic_paisa: number;
  component_overrides: Record<string, number>;
  approved_at: string | null;
};

export type StaffLoanSummaryRow = {
  id: string;
  tenant_id: string;
  campus_id: string;
  staff_id: string;
  staff_name: string;
  employee_code: string;
  loan_type: 'loan' | 'salary_advance';
  principal_paisa: number;
  installment_paisa: number;
  disbursed_at: string;
  repayment_start_month: string;
  total_repaid_paisa: number;
  outstanding_paisa: number;
  status: 'active' | 'paused' | 'closed' | 'written_off';
  notes: string | null;
};

export type TaxSlabRow = {
  id: string;
  version_id: string;
  lower_bound_paisa: number;
  upper_bound_paisa: number | null;
  fixed_amount_paisa: number;
  rate_pct: number;
  rebate_pct: number;
  sort_order: number;
};

export type PayrollRunRow = {
  id: string;
  tenant_id: string;
  campus_id: string;
  campus_name?: string;
  period_month: string;
  status: 'draft' | 'pending_approval' | 'locked' | 'paid' | 'cancelled';
  total_gross_paisa: number;
  total_deductions_paisa: number;
  total_net_paisa: number;
  employee_count: number;
  generated_at: string;
  approved_at: string | null;
  locked_at: string | null;
};

export type PayrollRunLineRow = {
  id: string;
  payroll_run_id: string;
  staff_id: string;
  staff_name: string;
  employee_code: string;
  basic_paisa: number;
  gross_paisa: number;
  attendance_deduction_paisa: number;
  tax_withholding_paisa: number;
  loan_recovery_paisa: number;
  other_deductions_paisa: number;
  net_paisa: number;
  unpaid_days: number;
  payable_days: number;
  status: string;
  components?: Array<{
    id: string;
    code: string;
    name_en: string;
    component_type: string;
    amount_paisa: number;
    is_taxable: boolean;
  }>;
};

export type ActionState = { error: string | null; success?: boolean };

// ─── Helpers ─────────────────────────────────────────────────────────────────

function parseDbError(e: unknown): string {
  if (e && typeof e === 'object') {
    const err = e as Record<string, unknown>;
    const msg = (err.message as string) || (err.error_description as string) || 'Database operation failed';
    if (msg.includes('ex_salary_structure_no_overlap')) return 'This employee already has an active salary structure in that date range.';
    if (msg.includes('PAYROLL_RUN_ALREADY_LOCKED') || msg.includes('PAYROLL_RUN_LOCKED')) return 'This payroll run is locked and cannot be recalculated or modified.';
    if (msg.includes('uq_salary_component_tenant_code')) return 'A salary component with that code already exists.';
    return msg;
  }
  return String(e);
}

// ─── 1. Salary Component Catalogue (FR-L01) ──────────────────────────────────

export async function getSalaryComponents(): Promise<SalaryComponentRow[]> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { data, error } = await (supabase as any)
    .from('salary_component')
    .select('*')
    .order('component_type', { ascending: true })
    .order('code', { ascending: true });

  if (error) {
    console.error('getSalaryComponents error:', error);
    return [];
  }
  return (data as SalaryComponentRow[]) || [];
}

export async function saveSalaryComponent(
  _prev: ActionState,
  formData: FormData
): Promise<ActionState> {
  const supabase = await supabaseServer();
  const id = formData.get('id')?.toString() || null;
  const code = formData.get('code')?.toString()?.trim().toUpperCase() || '';
  const nameEn = formData.get('name_en')?.toString()?.trim() || '';
  const nameUr = formData.get('name_ur')?.toString()?.trim() || null;
  const componentType = formData.get('component_type')?.toString() || 'earning';
  const calcMethod = formData.get('calc_method')?.toString() || 'fixed_paisa';
  const calcValuePkr = parseFloat(formData.get('calc_value_pkr')?.toString() || '0');
  const calcPct = parseFloat(formData.get('calc_pct')?.toString() || '0');
  const isTaxable = formData.get('is_taxable') === 'true';
  const exemptionCapPct = parseFloat(formData.get('exemption_cap_pct')?.toString() || '0');
  const proratesOnAbsence = formData.get('prorates_on_absence') === 'true';
  const effectiveFrom = formData.get('effective_from')?.toString() || new Date().toISOString().slice(0, 10);

  if (!code || !nameEn) {
    return { error: 'Component code and English name are required.' };
  }

  // Convert PKR to paisa
  const calcValuePaisa = Math.round(calcValuePkr * 100);

  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const userRes = await (supabase as any).auth.getUser();
    const userId = userRes.data?.user?.id;

    // Get tenant id
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { data: tenantData } = await (supabase as any).rpc('auth_tenant_id');
    const tenantId = tenantData;

    const payload = {
      tenant_id: tenantId,
      code,
      name_en: nameEn,
      name_ur: nameUr,
      component_type: componentType,
      calc_method: calcMethod,
      calc_value_paisa: calcValuePaisa,
      calc_pct: calcPct,
      is_taxable: isTaxable,
      exemption_cap_pct: exemptionCapPct,
      prorates_on_absence: proratesOnAbsence,
      effective_from: effectiveFrom,
      created_by: userId,
    };

    if (id) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { error } = await (supabase as any)
        .from('salary_component')
        .update(payload)
        .eq('id', id);
      if (error) throw error;
    } else {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { error } = await (supabase as any)
        .from('salary_component')
        .insert(payload);
      if (error) throw error;
    }

    revalidatePath('/payroll/components');
    return { error: null, success: true };
  } catch (e) {
    return { error: parseDbError(e) };
  }
}

// ─── 2. Employee Salary Structures (FR-L02) ──────────────────────────────────

export async function getEmployeeSalaryStructures(campusId: string | null): Promise<EmployeeSalaryStructureRow[]> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let query = (supabase as any)
    .from('employee_salary_structure')
    .select(`
      id,
      tenant_id,
      campus_id,
      staff_id,
      validity,
      basic_paisa,
      component_overrides,
      approved_at,
      staff:staff_id (id, full_name, employee_code)
    `)
    .order('created_at', { ascending: false });

  if (campusId) {
    query = query.eq('campus_id', campusId);
  }

  const { data, error } = await query;
  if (error) {
    console.error('getEmployeeSalaryStructures error:', error);
    return [];
  }

  // Format records
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return (data || []).map((row: any) => {
    // Parse postgres daterange e.g. [2026-01-01,2026-12-31]
    const val = row.validity || '';
    const clean = val.replace(/[[\]()]/g, '');
    const [start, end] = clean.split(',');
    return {
      id: row.id,
      tenant_id: row.tenant_id,
      campus_id: row.campus_id,
      staff_id: row.staff_id,
      staff_name: row.staff?.full_name || 'Unknown Staff',
      employee_code: row.staff?.employee_code || '',
      validity: row.validity,
      start_date: start || '',
      end_date: end && end !== 'infinity' ? end : null,
      basic_paisa: row.basic_paisa,
      component_overrides: row.component_overrides || {},
      approved_at: row.approved_at,
    };
  });
}

export async function saveEmployeeSalaryStructure(
  _prev: ActionState,
  formData: FormData
): Promise<ActionState> {
  const supabase = await supabaseServer();
  const staffId = formData.get('staff_id')?.toString() || '';
  const campusId = formData.get('campus_id')?.toString() || '';
  const basicPkr = parseFloat(formData.get('basic_pkr')?.toString() || '0');
  const startDate = formData.get('start_date')?.toString() || '';
  const endDate = formData.get('end_date')?.toString() || null;
  const overridesJson = formData.get('component_overrides')?.toString() || '{}';

  if (!staffId || !startDate || basicPkr <= 0) {
    return { error: 'Staff member, start date, and a positive basic salary are required.' };
  }

  const basicPaisa = Math.round(basicPkr * 100);
  let componentOverrides = {};
  try {
    componentOverrides = JSON.parse(overridesJson);
  } catch {
    // fallback empty
  }

  // Format range: [start, end] or [start, )
  const validityRange = endDate ? `[${startDate},${endDate}]` : `[${startDate},)`;

  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const userRes = await (supabase as any).auth.getUser();
    const userId = userRes.data?.user?.id;

    // Get tenant id from staff
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { data: staffData } = await (supabase as any)
      .from('staff')
      .select('tenant_id, campus_id')
      .eq('id', staffId)
      .single();

    const tenantId = staffData?.tenant_id;
    const finalCampusId = campusId || staffData?.campus_id;

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { error } = await (supabase as any)
      .from('employee_salary_structure')
      .insert({
        tenant_id: tenantId,
        campus_id: finalCampusId,
        staff_id: staffId,
        validity: validityRange,
        basic_paisa: basicPaisa,
        component_overrides: componentOverrides,
        approved_by: userId,
        approved_at: new Date().toISOString(),
        created_by: userId,
      });

    if (error) throw error;

    revalidatePath('/payroll/structures');
    return { error: null, success: true };
  } catch (e) {
    return { error: parseDbError(e) };
  }
}

// ─── 3. Staff Loans & Advances (FR-L03) ───────────────────────────────────────

export async function getStaffLoans(campusId: string | null): Promise<StaffLoanSummaryRow[]> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let query = (supabase as any)
    .from('v_staff_loan_summary')
    .select('*')
    .order('created_at', { ascending: false });

  if (campusId) {
    query = query.eq('campus_id', campusId);
  }

  const { data, error } = await query;
  if (error) {
    console.error('getStaffLoans error:', error);
    return [];
  }
  return (data as StaffLoanSummaryRow[]) || [];
}

export async function createStaffLoan(
  _prev: ActionState,
  formData: FormData
): Promise<ActionState> {
  const supabase = await supabaseServer();
  const staffId = formData.get('staff_id')?.toString() || '';
  const loanType = formData.get('loan_type')?.toString() || 'loan';
  const principalPkr = parseFloat(formData.get('principal_pkr')?.toString() || '0');
  const installmentPkr = parseFloat(formData.get('installment_pkr')?.toString() || '0');
  const disbursedAt = formData.get('disbursed_at')?.toString() || new Date().toISOString().slice(0, 10);
  const repaymentMonth = formData.get('repayment_start_month')?.toString() || disbursedAt.slice(0, 7) + '-01';
  const notes = formData.get('notes')?.toString()?.trim() || null;

  if (!staffId || principalPkr <= 0 || installmentPkr <= 0) {
    return { error: 'Staff, principal amount, and monthly installment are required.' };
  }

  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const userRes = await (supabase as any).auth.getUser();
    const userId = userRes.data?.user?.id;

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { data: staffData } = await (supabase as any)
      .from('staff')
      .select('tenant_id, campus_id')
      .eq('id', staffId)
      .single();

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { error } = await (supabase as any)
      .from('staff_loan')
      .insert({
        tenant_id: staffData.tenant_id,
        campus_id: staffData.campus_id,
        staff_id: staffId,
        loan_type: loanType,
        principal_paisa: Math.round(principalPkr * 100),
        installment_paisa: Math.round(installmentPkr * 100),
        disbursed_at: disbursedAt,
        repayment_start_month: repaymentMonth,
        status: 'active',
        approved_by: userId,
        created_by: userId,
        notes,
      });

    if (error) throw error;

    revalidatePath('/payroll/loans');
    return { error: null, success: true };
  } catch (e) {
    return { error: parseDbError(e) };
  }
}

export async function recordLoanPayoff(
  _prev: ActionState,
  formData: FormData
): Promise<ActionState> {
  const supabase = await supabaseServer();
  const loanId = formData.get('loan_id')?.toString() || '';
  const amountPkr = parseFloat(formData.get('amount_pkr')?.toString() || '0');
  const notes = formData.get('notes')?.toString() || 'Manual lump sum payment';

  if (!loanId || amountPkr <= 0) {
    return { error: 'Invalid payoff amount.' };
  }

  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { error } = await (supabase as any)
      .from('staff_loan_recovery')
      .insert({
        loan_id: loanId,
        amount_paisa: Math.round(amountPkr * 100),
        notes,
      });

    if (error) throw error;

    revalidatePath('/payroll/loans');
    return { error: null, success: true };
  } catch (e) {
    return { error: parseDbError(e) };
  }
}

// ─── 4. Tax Slabs (FR-L05) ───────────────────────────────────────────────────

export async function getTaxSlabs(): Promise<TaxSlabRow[]> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { data, error } = await (supabase as any)
    .from('tax_slab')
    .select(`
      id,
      version_id,
      lower_bound_paisa,
      upper_bound_paisa,
      fixed_amount_paisa,
      rate_pct,
      rebate_pct,
      sort_order,
      version:version_id (tax_year, is_active)
    `)
    .order('sort_order', { ascending: true });

  if (error) {
    console.error('getTaxSlabs error:', error);
    return [];
  }
  return (data as TaxSlabRow[]) || [];
}

export async function simulateTaxCalculation(monthlySalaryPkr: number): Promise<{
  annualGrossPkr: number;
  annualTaxPkr: number;
  monthlyWithholdingPkr: number;
  monthlyNetPkr: number;
  effectiveRatePct: number;
}> {
  const supabase = await supabaseServer();
  const monthlyPaisa = Math.round(monthlySalaryPkr * 100);

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { data, error } = await (supabase as any).rpc('fn_monthly_withholding_paisa', {
    p_staff_id: '00000000-0000-0000-0000-000000000000',
    p_monthly_taxable_paisa: monthlyPaisa,
  });

  if (error) {
    console.error('simulateTaxCalculation error:', error);
    return {
      annualGrossPkr: monthlySalaryPkr * 12,
      annualTaxPkr: 0,
      monthlyWithholdingPkr: 0,
      monthlyNetPkr: monthlySalaryPkr,
      effectiveRatePct: 0,
    };
  }

  const monthlyWithholdingPkr = (data || 0) / 100;
  const annualTaxPkr = monthlyWithholdingPkr * 12;
  const annualGrossPkr = monthlySalaryPkr * 12;
  const effectiveRatePct = annualGrossPkr > 0 ? (annualTaxPkr / annualGrossPkr) * 100 : 0;

  return {
    annualGrossPkr,
    annualTaxPkr,
    monthlyWithholdingPkr,
    monthlyNetPkr: monthlySalaryPkr - monthlyWithholdingPkr,
    effectiveRatePct: Math.round(effectiveRatePct * 100) / 100,
  };
}

// ─── 5. Payroll Runs (FR-L06 + FR-L07) ───────────────────────────────────────

export async function getPayrollRuns(campusId: string | null): Promise<PayrollRunRow[]> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let query = (supabase as any)
    .from('payroll_run')
    .select(`
      id,
      tenant_id,
      campus_id,
      period_month,
      status,
      total_gross_paisa,
      total_deductions_paisa,
      total_net_paisa,
      employee_count,
      generated_at,
      approved_at,
      locked_at,
      campus:campus_id (name)
    `)
    .order('period_month', { ascending: false });

  if (campusId) {
    query = query.eq('campus_id', campusId);
  }

  const { data, error } = await query;
  if (error) {
    console.error('getPayrollRuns error:', error);
    return [];
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return (data || []).map((row: any) => ({
    id: row.id,
    tenant_id: row.tenant_id,
    campus_id: row.campus_id,
    campus_name: row.campus?.name || 'Main Campus',
    period_month: row.period_month,
    status: row.status,
    total_gross_paisa: row.total_gross_paisa,
    total_deductions_paisa: row.total_deductions_paisa,
    total_net_paisa: row.total_net_paisa,
    employee_count: row.employee_count,
    generated_at: row.generated_at,
    approved_at: row.approved_at,
    locked_at: row.locked_at,
  }));
}

export async function getPayrollRunDetails(runId: string): Promise<{
  run: PayrollRunRow | null;
  lines: PayrollRunLineRow[];
}> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { data: run, error: runError } = await (supabase as any)
    .from('payroll_run')
    .select('*, campus:campus_id(name)')
    .eq('id', runId)
    .single();

  if (runError || !run) {
    return { run: null, lines: [] };
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { data: lines, error: lineError } = await (supabase as any)
    .from('payroll_run_line')
    .select(`
      *,
      staff:staff_id (id, full_name, employee_code),
      components:payroll_run_line_component (*)
    `)
    .eq('payroll_run_id', runId)
    .order('staff_id');

  if (lineError) {
    console.error('getPayrollRunDetails lines error:', lineError);
    return { run, lines: [] };
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const formattedLines: PayrollRunLineRow[] = (lines || []).map((l: any) => ({
    id: l.id,
    payroll_run_id: l.payroll_run_id,
    staff_id: l.staff_id,
    staff_name: l.staff?.full_name || 'Staff Member',
    employee_code: l.staff?.employee_code || '',
    basic_paisa: l.basic_paisa,
    gross_paisa: l.gross_paisa,
    attendance_deduction_paisa: l.attendance_deduction_paisa,
    tax_withholding_paisa: l.tax_withholding_paisa,
    loan_recovery_paisa: l.loan_recovery_paisa,
    other_deductions_paisa: l.other_deductions_paisa,
    net_paisa: l.net_paisa,
    unpaid_days: l.unpaid_days,
    payable_days: l.payable_days,
    status: l.status,
    components: l.components || [],
  }));

  return {
    run: {
      id: run.id,
      tenant_id: run.tenant_id,
      campus_id: run.campus_id,
      campus_name: run.campus?.name,
      period_month: run.period_month,
      status: run.status,
      total_gross_paisa: run.total_gross_paisa,
      total_deductions_paisa: run.total_deductions_paisa,
      total_net_paisa: run.total_net_paisa,
      employee_count: run.employee_count,
      generated_at: run.generated_at,
      approved_at: run.approved_at,
      locked_at: run.locked_at,
    },
    lines: formattedLines,
  };
}

export async function generatePayrollRunAction(
  campusId: string,
  periodMonth: string
): Promise<{ error: string | null; runId?: string }> {
  const supabase = await supabaseServer();

  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { data, error } = await (supabase as any).rpc('generate_payroll_run', {
      p_campus_id: campusId,
      p_period_date: periodMonth,
    });

    if (error) throw error;

    revalidatePath('/payroll/runs');
    return { error: null, runId: data };
  } catch (e) {
    return { error: parseDbError(e) };
  }
}

export async function submitPayrollRunForApproval(runId: string): Promise<ActionState> {
  const supabase = await supabaseServer();
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { error } = await (supabase as any).rpc('fn_submit_payroll_for_approval', {
      p_run_id: runId,
    });
    if (error) throw error;
    revalidatePath('/payroll/runs');
    return { error: null, success: true };
  } catch (e) {
    return { error: parseDbError(e) };
  }
}

export async function approvePayrollRun(runId: string): Promise<ActionState> {
  const supabase = await supabaseServer();
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { error } = await (supabase as any).rpc('fn_approve_payroll_run', {
      p_run_id: runId,
    });
    if (error) throw error;
    revalidatePath('/payroll/runs');
    return { error: null, success: true };
  } catch (e) {
    return { error: parseDbError(e) };
  }
}

export async function lockPayrollRun(runId: string): Promise<ActionState> {
  const supabase = await supabaseServer();
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { error } = await (supabase as any).rpc('fn_lock_payroll_run', {
      p_run_id: runId,
    });
    if (error) throw error;
    revalidatePath('/payroll/runs');
    return { error: null, success: true };
  } catch (e) {
    return { error: parseDbError(e) };
  }
}

// ─── 6. Staff Options Helper ─────────────────────────────────────────────────

export async function getStaffOptions(campusId?: string | null): Promise<Array<{ id: string; name: string; code: string }>> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let query = (supabase as any)
    .from('staff')
    .select('id, full_name, employee_code')
    .eq('employment_status', 'active')
    .order('full_name');

  if (campusId) {
    query = query.eq('campus_id', campusId);
  }

  const { data, error } = await query;
  if (error) return [];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return (data || []).map((s: any) => ({
    id: s.id,
    name: s.full_name,
    code: s.employee_code,
  }));
}
