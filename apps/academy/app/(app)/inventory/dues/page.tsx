import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { one } from '@/lib/hr/current-role';
import { formatDatePk } from '@/lib/dates';
import { pkr } from '@/lib/rpc-action';
import { PrintButton } from '@/components/print-button';
import { Badge } from '@/components/ui/badge';
import { Stat } from '@/components/ui/page-header';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

// Shop sales charged to the student's fee account rather than paid in cash:
// due until the fee challan carrying them is paid.
export default async function ShopDuesPage() {
  const supabase = await supabaseServer();
  const { data: sales, error } = await supabase
    .from('inv_sale')
    .select('id, serial, sold_at, total, student_id, student_name, student_gr, class_name, inv_sale_challan_link(challan:challan_id(challan_no, status))')
    .eq('settlement', 'fee_ledger')
    .eq('doc_type', 'sale')
    .order('sold_at', { ascending: false })
    .limit(500);
  const rows = (sales ?? [])
    .map((s) => {
      const challan = one(one(s.inv_sale_challan_link)?.challan);
      return { ...s, challanNo: challan?.challan_no ?? null, state: challan ? challan.status : 'not_billed' };
    })
    .filter((s) => s.state !== 'paid' && s.state !== 'cancelled');
  const owed = rows.reduce((t, s) => t + s.total, 0);
  const notBilled = rows.filter((s) => s.state === 'not_billed');

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Shop dues</h1>
          <p className="text-sm text-muted-foreground">Shop sales charged to a student&apos;s fee account that have not been paid yet.</p>
        </div>
        <div className="print:hidden">
          <PrintButton />
        </div>
      </div>
      <section aria-label="Summary" className="grid gap-3 sm:grid-cols-3">
        <Stat label="Unpaid sales" value={rows.length} />
        <Stat label="Amount due" value={pkr(owed)} tone={owed > 0 ? 'warning' : 'default'} />
        <Stat label="Not yet on a challan" value={notBilled.length} hint={pkr(notBilled.reduce((t, s) => t + s.total, 0))} />
      </section>
      {error ? (
        <p className="text-sm text-destructive">Could not load shop dues. Try again.</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">No unpaid shop sales.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Receipt</TableHead>
              <TableHead>Date</TableHead>
              <TableHead>Student</TableHead>
              <TableHead>Class</TableHead>
              <TableHead className="text-right">Amount</TableHead>
              <TableHead>Challan</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((s) => (
              <TableRow key={s.id} data-testid="shop-due-row">
                <TableCell className="tabular font-mono">
                  <Link href={`/inventory/sales/${s.id}`} className="hover:underline">
                    {s.serial}
                  </Link>
                </TableCell>
                <TableCell className="whitespace-nowrap">{formatDatePk(s.sold_at.slice(0, 10))}</TableCell>
                <TableCell>
                  <Link href={`/students/${s.student_id}`} className="font-medium hover:underline">
                    {s.student_name}
                  </Link>{' '}
                  <span className="text-muted-foreground">({s.student_gr})</span>
                </TableCell>
                <TableCell>{s.class_name ?? ''}</TableCell>
                <TableCell className="tabular text-right">{pkr(s.total)}</TableCell>
                <TableCell>
                  {s.challanNo ? (
                    <span className="flex items-center gap-2">
                      <span className="tabular font-mono">{s.challanNo}</span>
                      <Badge variant="warning">{s.state === 'part_paid' ? 'Part paid' : 'Unpaid'}</Badge>
                    </span>
                  ) : (
                    <Badge variant="outline">Not yet billed</Badge>
                  )}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
