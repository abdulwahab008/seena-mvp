import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { PrintButton } from '@/components/print-button';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { getStaffOptions } from '../actions';

export const dynamic = 'force-dynamic';

const ROLES = ['super_admin', 'owner', 'principal', 'hr_manager', 'accountant'];
const pkr = (paisa: number) => new Intl.NumberFormat('en-PK', { maximumFractionDigits: 0 }).format(paisa / 100);
const month = (iso: string) => new Date(`${iso}T00:00:00Z`).toLocaleDateString('en-GB', { month: 'short', year: 'numeric', timeZone: 'UTC' });
const LINKS = [
  { href: '/payroll/runs', label: 'Salary register, pay slips and bank transfer file (open a month)' },
  { href: '/payroll/statutory', label: 'Statutory deductions: income tax, EOBI and social security' },
  { href: '/payroll/loans', label: 'Loan outstanding report' },
  { href: '/payroll/security-deposits', label: 'Security deposit report' },
  { href: '/payroll/gratuity', label: 'Gratuity' },
  { href: '/payroll/structures', label: 'Salary structures' },
];

export default async function PayrollReportsPage({ searchParams }: { searchParams: Promise<{ staff?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !ROLES.includes(actor.role)) notFound();
  const { staff: staffId } = await searchParams;
  const supabase = await supabaseServer();
  const [{ data: runs }, staff, { data: lines }] = await Promise.all([
    supabase.from('payroll_run').select('id, period_month, status, employee_count, total_gross_paisa, total_deductions_paisa, total_net_paisa').order('period_month', { ascending: false }).limit(24),
    getStaffOptions(null),
    staffId
      ? supabase
          .from('payroll_run_line')
          .select('id, basic_paisa, gross_paisa, attendance_deduction_paisa, tax_withholding_paisa, loan_recovery_paisa, other_deductions_paisa, net_paisa, run:payroll_run_id(period_month, status)')
          .eq('staff_id', staffId)
      : Promise.resolve({ data: [] }),
  ]);
  const statement = (lines ?? [])
    .map((l) => ({ ...l, run: one(l.run) }))
    .filter((l) => l.run)
    .sort((a, b) => b.run!.period_month.localeCompare(a.run!.period_month));
  const sum = (k: 'gross_paisa' | 'net_paisa') => statement.reduce((t, l) => t + l[k], 0);

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Payroll reports</h1>
          <p className="text-sm text-muted-foreground">Month-by-month payroll cost, one employee&apos;s salary statement, and every payroll register.</p>
        </div>
        <div className="print:hidden">
          <PrintButton />
        </div>
      </div>

      <section className="space-y-2 print:hidden">
        <h2 className="text-lg font-semibold">Registers</h2>
        <ul className="divide-y rounded-lg border">
          {LINKS.map((r, i) => (
            <li key={r.href} className="flex items-center gap-3 px-4 py-2.5 text-sm" data-testid="report-row">
              <span className="tabular w-6 text-muted-foreground">{i + 1}</span>
              <span className="flex-1">{r.label}</span>
              <Link href={r.href} className="font-medium text-primary hover:underline">
                View
              </Link>
            </li>
          ))}
        </ul>
      </section>

      <section className="space-y-2">
        <h2 className="text-lg font-semibold">Payroll trend</h2>
        {(runs ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">No payroll has been run yet.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Month</TableHead>
                <TableHead className="text-right">Staff</TableHead>
                <TableHead className="text-right">Gross (PKR)</TableHead>
                <TableHead className="text-right">Deductions (PKR)</TableHead>
                <TableHead className="text-right">Net (PKR)</TableHead>
                <TableHead>Status</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {(runs ?? []).map((r) => (
                <TableRow key={r.id} data-testid="trend-row">
                  <TableCell className="font-medium">
                    <Link href={`/payroll/runs/${r.id}`} className="hover:underline">
                      {month(r.period_month)}
                    </Link>
                  </TableCell>
                  <TableCell className="tabular text-right">{r.employee_count}</TableCell>
                  <TableCell className="tabular text-right">{pkr(r.total_gross_paisa)}</TableCell>
                  <TableCell className="tabular text-right">{pkr(r.total_deductions_paisa)}</TableCell>
                  <TableCell className="tabular text-right">{pkr(r.total_net_paisa)}</TableCell>
                  <TableCell>
                    <Badge variant="outline" className="capitalize">
                      {r.status}
                    </Badge>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </section>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold">Salary statement</h2>
        <form method="get" className="flex flex-wrap items-end gap-2 text-sm print:hidden">
          <select name="staff" defaultValue={staffId ?? ''} aria-label="Staff member" className="h-9 min-w-64 rounded-md border bg-background px-2">
            <option value="">Choose a staff member…</option>
            {staff.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name} ({s.code})
              </option>
            ))}
          </select>
          <Button type="submit" size="sm" variant="outline">
            Show
          </Button>
        </form>
        {staffId &&
          (statement.length === 0 ? (
            <p className="text-sm text-muted-foreground">No salary has been processed for this staff member yet.</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Month</TableHead>
                  <TableHead className="text-right">Basic</TableHead>
                  <TableHead className="text-right">Gross</TableHead>
                  <TableHead className="text-right">Absence</TableHead>
                  <TableHead className="text-right">Tax</TableHead>
                  <TableHead className="text-right">Loan / deposit</TableHead>
                  <TableHead className="text-right">Other</TableHead>
                  <TableHead className="text-right">Net</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {statement.map((l) => (
                  <TableRow key={l.id} data-testid="statement-row">
                    <TableCell className="font-medium">{month(l.run!.period_month)}</TableCell>
                    <TableCell className="tabular text-right">{pkr(l.basic_paisa)}</TableCell>
                    <TableCell className="tabular text-right">{pkr(l.gross_paisa)}</TableCell>
                    <TableCell className="tabular text-right">{pkr(l.attendance_deduction_paisa)}</TableCell>
                    <TableCell className="tabular text-right">{pkr(l.tax_withholding_paisa)}</TableCell>
                    <TableCell className="tabular text-right">{pkr(l.loan_recovery_paisa)}</TableCell>
                    <TableCell className="tabular text-right">{pkr(l.other_deductions_paisa)}</TableCell>
                    <TableCell className="tabular text-right font-medium">{pkr(l.net_paisa)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
              <TableFooter>
                <TableRow>
                  <TableCell colSpan={2}>Total</TableCell>
                  <TableCell className="tabular text-right">{pkr(sum('gross_paisa'))}</TableCell>
                  <TableCell colSpan={4} />
                  <TableCell className="tabular text-right">{pkr(sum('net_paisa'))}</TableCell>
                </TableRow>
              </TableFooter>
            </Table>
          ))}
      </section>
    </div>
  );
}
