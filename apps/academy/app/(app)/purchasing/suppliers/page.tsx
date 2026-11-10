import { supabaseServer } from '@/lib/supabase/server';
import { formatDatePk } from '@/lib/dates';
import { pkr } from '@/lib/rpc-action';
import { PrintButton } from '@/components/print-button';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

export default async function SupplierReportPage() {
  const supabase = await supabaseServer();
  const [{ data: vendors }, { data: orders }, { data: lines }] = await Promise.all([
    supabase.from('procurement_vendor').select('id, name, phone, active').order('name'),
    supabase.from('purchase_order').select('id, vendor_id, status, ordered_at'),
    supabase.from('v_purchase_order_line').select('po_id, qty_ordered, qty_received, unit_cost'),
  ]);
  const rows = (vendors ?? []).map((v) => {
    const pos = (orders ?? []).filter((o) => o.vendor_id === v.id && o.status !== 'cancelled');
    const ids = new Set(pos.map((o) => o.id));
    const own = (lines ?? []).filter((l) => l.po_id && ids.has(l.po_id));
    const ordered = own.reduce((t, l) => t + Number(l.qty_ordered ?? 0) * Number(l.unit_cost ?? 0), 0);
    const received = own.reduce((t, l) => t + Number(l.qty_received ?? 0) * Number(l.unit_cost ?? 0), 0);
    const last = pos.map((o) => o.ordered_at).sort().at(-1) ?? null;
    return { ...v, orders: pos.length, open: pos.filter((o) => o.status === 'open' || o.status === 'partially_fulfilled').length, ordered, received, last };
  });
  const total = (k: 'orders' | 'ordered' | 'received') => rows.reduce((t, r) => t + r[k], 0);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Supplier report</h1>
          <p className="text-sm text-muted-foreground">What has been ordered from each supplier, what has arrived, and orders still open.</p>
        </div>
        <div className="print:hidden">
          <PrintButton />
        </div>
      </div>
      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">No suppliers yet. They are added when a purchase order is raised.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Supplier</TableHead>
              <TableHead>Phone</TableHead>
              <TableHead className="text-right">Orders</TableHead>
              <TableHead className="text-right">Open</TableHead>
              <TableHead className="text-right">Ordered</TableHead>
              <TableHead className="text-right">Received</TableHead>
              <TableHead className="text-right">Still to arrive</TableHead>
              <TableHead>Last order</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={r.id} data-testid="supplier-row">
                <TableCell className="font-medium">
                  {r.name}
                  {!r.active && <span className="ml-2 text-xs text-muted-foreground">inactive</span>}
                </TableCell>
                <TableCell className="tabular">{r.phone ?? ''}</TableCell>
                <TableCell className="tabular text-right">{r.orders}</TableCell>
                <TableCell className="tabular text-right">{r.open}</TableCell>
                <TableCell className="tabular text-right">{pkr(r.ordered)}</TableCell>
                <TableCell className="tabular text-right">{pkr(r.received)}</TableCell>
                <TableCell className="tabular text-right">{pkr(r.ordered - r.received)}</TableCell>
                <TableCell className="whitespace-nowrap">{r.last ? formatDatePk(r.last.slice(0, 10)) : ''}</TableCell>
              </TableRow>
            ))}
          </TableBody>
          <TableFooter>
            <TableRow>
              <TableCell colSpan={2}>Total</TableCell>
              <TableCell className="tabular text-right">{total('orders')}</TableCell>
              <TableCell />
              <TableCell className="tabular text-right">{pkr(total('ordered'))}</TableCell>
              <TableCell className="tabular text-right">{pkr(total('received'))}</TableCell>
              <TableCell className="tabular text-right">{pkr(total('ordered') - total('received'))}</TableCell>
              <TableCell />
            </TableRow>
          </TableFooter>
        </Table>
      )}
    </div>
  );
}
