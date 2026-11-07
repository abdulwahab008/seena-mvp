import type { supabaseServer } from '@/lib/supabase/server';
import { buildStatutoryReport, type StatutoryLine } from './statutory';

type Client = Awaited<ReturnType<typeof supabaseServer>>;
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export async function loadStatutoryReport(supabase: Client, runId: string) {
  const { data } = await supabase
    .from('payroll_run_line')
    .select('gross_paisa, tax_withholding_paisa, staff:staff_id(full_name, employee_code), payroll_run_line_component(code, name_en, component_type, amount_paisa)')
    .eq('payroll_run_id', runId);
  const lines: StatutoryLine[] = (data ?? []).map((l) => {
    const staff = one(l.staff);
    return {
      staffName: staff?.full_name ?? '',
      employeeCode: staff?.employee_code ?? '',
      grossPaisa: l.gross_paisa,
      taxPaisa: l.tax_withholding_paisa,
      components: (l.payroll_run_line_component ?? []).map((c) => ({ code: c.code, name: c.name_en, type: c.component_type, amountPaisa: c.amount_paisa })),
    };
  });
  return buildStatutoryReport(lines);
}
