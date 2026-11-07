export type StatutoryLine = {
  staffName: string;
  employeeCode: string;
  grossPaisa: number;
  taxPaisa: number;
  components: { code: string; name: string; type: string; amountPaisa: number }[];
};

export type StatutoryReport = {
  columns: { code: string; name: string; type: string }[];
  rows: { staffName: string; employeeCode: string; grossPaisa: number; taxPaisa: number; amounts: Record<string, number> }[];
  totals: { grossPaisa: number; taxPaisa: number; amounts: Record<string, number> };
};

// Everything withheld from staff (deductions) and everything the school pays on
// top (employer contributions), one column per component code. Earnings are
// left out: they are on the payslip, not owed to EOBI or the tax office.
export function buildStatutoryReport(lines: StatutoryLine[]): StatutoryReport {
  const columns = new Map<string, { code: string; name: string; type: string }>();
  for (const l of lines) for (const c of l.components) if (c.type !== 'earning' && !columns.has(c.code)) columns.set(c.code, { code: c.code, name: c.name, type: c.type });
  const cols = [...columns.values()].sort((a, b) => a.type.localeCompare(b.type) || a.code.localeCompare(b.code));

  const totals = { grossPaisa: 0, taxPaisa: 0, amounts: Object.fromEntries(cols.map((c) => [c.code, 0])) as Record<string, number> };
  const rows = lines
    .map((l) => {
      const amounts = Object.fromEntries(cols.map((c) => [c.code, 0])) as Record<string, number>;
      for (const c of l.components) if (c.code in amounts) amounts[c.code]! += c.amountPaisa;
      totals.grossPaisa += l.grossPaisa;
      totals.taxPaisa += l.taxPaisa;
      for (const c of cols) totals.amounts[c.code]! += amounts[c.code]!;
      return { staffName: l.staffName, employeeCode: l.employeeCode, grossPaisa: l.grossPaisa, taxPaisa: l.taxPaisa, amounts };
    })
    .sort((a, b) => a.staffName.localeCompare(b.staffName));
  return { columns: cols, rows, totals };
}
