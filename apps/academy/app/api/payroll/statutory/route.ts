import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { loadStatutoryReport } from '@/lib/payroll/statutory-load';
import { toCsv } from '@/lib/csv';

const ROLES = ['super_admin', 'owner', 'principal', 'hr_manager', 'accountant'];
const rupees = (paisa: number) => (paisa / 100).toFixed(2);

export async function GET(req: NextRequest) {
  const run = req.nextUrl.searchParams.get('run');
  if (!z.string().uuid().safeParse(run).success) return NextResponse.json({ error: 'Choose a payroll run.' }, { status: 400 });
  const actor = await getCurrentActor();
  if (!actor || !ROLES.includes(actor.role)) return NextResponse.json({ error: 'Not allowed.' }, { status: 403 });

  const supabase = await supabaseServer();
  const report = await loadStatutoryReport(supabase, run!);
  const header = ['Staff', 'Employee code', 'Gross', 'Income tax', ...report.columns.map((c) => c.name)];
  const rows = report.rows.map((r) => [r.staffName, r.employeeCode, rupees(r.grossPaisa), rupees(r.taxPaisa), ...report.columns.map((c) => rupees(r.amounts[c.code] ?? 0))]);
  rows.push(['Total', '', rupees(report.totals.grossPaisa), rupees(report.totals.taxPaisa), ...report.columns.map((c) => rupees(report.totals.amounts[c.code] ?? 0))]);
  return new NextResponse(toCsv(header, rows), {
    headers: { 'content-type': 'text/csv; charset=utf-8', 'content-disposition': 'attachment; filename="statutory-deductions.csv"', 'cache-control': 'private, no-store' },
  });
}
