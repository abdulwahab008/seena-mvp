import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { formatDatePk, todayPk } from '@/lib/dates';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Stat } from '@/components/ui/page-header';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { getStaffOptions } from '../actions';
import { DepositForm } from './deposit-form';

export const dynamic = 'force-dynamic';

const ROLES = ['super_admin', 'owner', 'principal', 'hr_manager', 'accountant'];
const pkr = (paisa: number) => new Intl.NumberFormat('en-PK', { style: 'currency', currency: 'PKR', maximumFractionDigits: 0 }).format(paisa / 100);

export default async function SecurityDepositsPage() {
  const actor = await getCurrentActor();
  if (!actor || !ROLES.includes(actor.role)) notFound();
  const supabase = await supabaseServer();
  const [{ data: deposits, error }, staff] = await Promise.all([
    supabase
      .from('staff_loan')
      .select('id, principal_paisa, installment_paisa, total_repaid_paisa, repayment_start_month, status, refunded_at, notes, staff:staff_id(full_name, employee_code)')
      .eq('loan_type', 'security_deposit')
      .order('created_at', { ascending: false }),
    getStaffOptions(null),
  ]);
  const held = (deposits ?? []).filter((d) => !d.refunded_at).reduce((t, d) => t + d.total_repaid_paisa, 0);
  const due = (deposits ?? []).filter((d) => !d.refunded_at).reduce((t, d) => t + Math.max(0, d.principal_paisa - d.total_repaid_paisa), 0);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Staff security deposits</h1>
        <p className="text-sm text-muted-foreground">
          A deposit the school holds from salary, deducted each month by payroll until the amount is reached, and paid back in the final settlement.
        </p>
      </div>
      <section aria-label="Summary" className="grid gap-3 sm:grid-cols-3">
        <Stat label="Held now" value={pkr(held)} hint="Collected and not yet refunded" />
        <Stat label="Still to collect" value={pkr(due)} />
        <Stat label="Deposits" value={(deposits ?? []).length} />
      </section>
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base">Add a security deposit</CardTitle>
        </CardHeader>
        <CardContent>
          <DepositForm staff={staff} thisMonth={todayPk().slice(0, 7)} />
        </CardContent>
      </Card>
      {error ? (
        <p className="text-sm text-destructive">Could not load deposits. Try again.</p>
      ) : (deposits ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">No security deposits yet.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-10">#</TableHead>
              <TableHead>Staff</TableHead>
              <TableHead className="text-right">Deposit</TableHead>
              <TableHead className="text-right">Monthly</TableHead>
              <TableHead className="text-right">Collected</TableHead>
              <TableHead className="text-right">Remaining</TableHead>
              <TableHead>Starts</TableHead>
              <TableHead>Status</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(deposits ?? []).map((d, i) => {
              const s = one(d.staff);
              const status = d.refunded_at ? 'Refunded' : d.total_repaid_paisa >= d.principal_paisa ? 'Collected' : d.status === 'paused' ? 'Paused' : 'Collecting';
              return (
                <TableRow key={d.id} data-testid="deposit-row">
                  <TableCell className="tabular text-muted-foreground">{i + 1}</TableCell>
                  <TableCell className="font-medium">
                    {s?.full_name} <span className="text-muted-foreground">({s?.employee_code})</span>
                  </TableCell>
                  <TableCell className="tabular text-right">{pkr(d.principal_paisa)}</TableCell>
                  <TableCell className="tabular text-right">{pkr(d.installment_paisa)}</TableCell>
                  <TableCell className="tabular text-right">{pkr(d.total_repaid_paisa)}</TableCell>
                  <TableCell className="tabular text-right">{pkr(Math.max(0, d.principal_paisa - d.total_repaid_paisa))}</TableCell>
                  <TableCell className="whitespace-nowrap">{formatDatePk(d.repayment_start_month)}</TableCell>
                  <TableCell>
                    <Badge variant={status === 'Refunded' ? 'outline' : status === 'Collected' ? 'success' : 'warning'}>{status}</Badge>
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
