import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { loadStatutoryReport } from '@/lib/payroll/statutory-load';
import { formatPkr } from '@/lib/challan/html';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const ROLES = ['super_admin', 'owner', 'principal', 'hr_manager', 'accountant'];
const monthLabel = (iso: string) => new Date(`${iso}T00:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });

export default async function StatutoryPage({ searchParams }: { searchParams: Promise<{ run?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !ROLES.includes(actor.role)) notFound();
  const { run: runParam } = await searchParams;

  const supabase = await supabaseServer();
  const { data: runs } = await supabase.from('payroll_run').select('id, period_month, status, campus:campus_id(name)').order('period_month', { ascending: false }).limit(36);
  const run = (runs ?? []).find((r) => r.id === runParam) ?? (runs ?? [])[0];
  const report = run ? await loadStatutoryReport(supabase, run.id) : null;

  return (
    <>
      <PageHeader
        title="Statutory deductions"
        description="Income tax withheld, EOBI, provident fund and every other deduction or employer contribution in a payroll run, per staff member. Use it for the monthly EOBI and tax returns."
      />
      {!run || !report ? (
        <EmptyState title="No payroll runs yet" description="Run payroll first." />
      ) : (
        <div className="space-y-4">
          <form method="get" className="flex flex-wrap items-end gap-2 text-sm">
            <label className="space-y-1">
              <span className="block text-muted-foreground">Payroll run</span>
              <select name="run" defaultValue={run.id} className="h-9 rounded-md border bg-background px-2">
                {(runs ?? []).map((r) => (
                  <option key={r.id} value={r.id}>
                    {monthLabel(r.period_month)} · {one(r.campus)?.name} · {r.status}
                  </option>
                ))}
              </select>
            </label>
            <button type="submit" className="h-9 rounded-md border px-3">
              Show
            </button>
            <a href={`/api/payroll/statutory?run=${run.id}`} className="h-9 rounded-md border px-3 py-2">
              Download CSV
            </a>
          </form>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Staff</TableHead>
                <TableHead className="text-right">Gross</TableHead>
                <TableHead className="text-right">Income tax</TableHead>
                {report.columns.map((c) => (
                  <TableHead key={c.code} className="text-right">
                    {c.name}
                    {c.type === 'employer_contribution' ? ' (school)' : ''}
                  </TableHead>
                ))}
              </TableRow>
            </TableHeader>
            <TableBody>
              {report.rows.map((r) => (
                <TableRow key={r.employeeCode} data-testid="statutory-row">
                  <TableCell>
                    {r.staffName} <span className="text-xs text-muted-foreground">{r.employeeCode}</span>
                  </TableCell>
                  <TableCell className="text-right">{formatPkr(r.grossPaisa)}</TableCell>
                  <TableCell className="text-right">{formatPkr(r.taxPaisa)}</TableCell>
                  {report.columns.map((c) => (
                    <TableCell key={c.code} className="text-right">
                      {formatPkr(r.amounts[c.code] ?? 0)}
                    </TableCell>
                  ))}
                </TableRow>
              ))}
            </TableBody>
            <TableFooter>
              <TableRow>
                <TableCell className="font-medium">
                  Total
                </TableCell>
                <TableCell className="text-right font-medium">{formatPkr(report.totals.grossPaisa)}</TableCell>
                <TableCell className="text-right font-medium" data-testid="statutory-total-tax">
                  {formatPkr(report.totals.taxPaisa)}
                </TableCell>
                {report.columns.map((c) => (
                  <TableCell key={c.code} className="text-right font-medium">
                    {formatPkr(report.totals.amounts[c.code] ?? 0)}
                  </TableCell>
                ))}
              </TableRow>
            </TableFooter>
          </Table>
        </div>
      )}
    </>
  );
}
