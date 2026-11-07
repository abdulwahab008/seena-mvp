import { supabaseServer } from '@/lib/supabase/server';
import { formatPkr } from '@/lib/challan/html';
import { formatDatePk, todayPk } from '@/lib/dates';
import { cn } from '@/lib/utils';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { InstallmentForm } from './installment-form';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function InstallmentsPage() {
  const supabase = await supabaseServer();
  const { data: rows } = await supabase.rpc('installment_status', { p_as_of: todayPk() });
  const open = (rows ?? []).filter((r) => r.unpaid_paisa > 0);
  const enrolmentIds = [...new Set(open.map((r) => r.enrolment_id))];
  const { data: enrolments } = enrolmentIds.length
    ? await supabase.from('enrolment').select('id, student(name_en, gr_number)').in('id', enrolmentIds)
    : { data: [] };
  const student = new Map((enrolments ?? []).map((e) => [e.id, one(e.student)]));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Installments</h1>
        <p className="text-sm text-muted-foreground">
          Let a family pay one challan in monthly parts. Payments still go against the challan as usual; a part counts as paid once the challan&apos;s payments reach it. Overdue parts are listed first.
        </p>
      </div>
      <InstallmentForm />
      {open.length === 0 ? (
        <p className="text-sm text-muted-foreground">No unpaid installments.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Due</TableHead>
              <TableHead>Student</TableHead>
              <TableHead>Challan</TableHead>
              <TableHead>Part</TableHead>
              <TableHead className="text-right">Amount</TableHead>
              <TableHead className="text-right">Unpaid</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {open
              .sort((a, b) => Number(b.is_overdue) - Number(a.is_overdue) || a.due_date.localeCompare(b.due_date))
              .map((r) => {
                const s = student.get(r.enrolment_id);
                return (
                  <TableRow key={r.installment_id} data-testid="installment-row">
                    <TableCell className={cn(r.is_overdue && 'font-medium text-destructive')}>
                      {formatDatePk(r.due_date)}
                      {r.is_overdue ? ' (overdue)' : ''}
                    </TableCell>
                    <TableCell>
                      {s?.name_en} <span className="text-xs text-muted-foreground">{s?.gr_number}</span>
                    </TableCell>
                    <TableCell className="font-mono">{r.challan_no}</TableCell>
                    <TableCell>{r.seq}</TableCell>
                    <TableCell className="text-right">{formatPkr(r.amount_paisa)}</TableCell>
                    <TableCell className="text-right">{formatPkr(r.unpaid_paisa)}</TableCell>
                  </TableRow>
                );
              })}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
