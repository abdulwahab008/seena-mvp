import { supabaseServer } from '@/lib/supabase/server';
import { pickActiveCampus } from '@/lib/campus-context';
import { summarizeSales, type ReportSale } from '@/lib/inventory/sales-report';
import { formatPkr } from '@/lib/challan/html';
import { todayPk } from '@/lib/dates';
import { PageHeader, Stat } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function SalesReportPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string }> }) {
  const sp = await searchParams;
  const today = todayPk();
  const from = sp.from && DATE.test(sp.from) ? sp.from : `${today.slice(0, 8)}01`;
  const to = sp.to && DATE.test(sp.to) ? sp.to : today;

  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />;

  const { data: sales } = await supabase
    .from('inv_sale')
    .select('doc_type, settlement, total, inv_sale_line(qty, amount, item:item_id(name))')
    .eq('campus_id', campus.id)
    .gte('sold_at', `${from}T00:00:00+05:00`)
    .lte('sold_at', `${to}T23:59:59.999+05:00`)
    .limit(10000);

  const summary = summarizeSales(
    (sales ?? []).map(
      (s): ReportSale => ({
        doc_type: s.doc_type,
        settlement: s.settlement,
        total: s.total,
        lines: (s.inv_sale_line ?? []).map((l) => ({ item: one(l.item)?.name ?? 'Item', qty: Number(l.qty), amount: l.amount })),
      }),
    ),
  );

  return (
    <>
      <PageHeader title="Sales report" description="Counter sales of uniforms, books, canteen and other stock for a date range, net of returns." />
      <form method="get" className="mb-4 flex flex-wrap items-end gap-2 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">From</span>
          <input name="from" type="date" defaultValue={from} className="h-9 rounded-md border bg-background px-2" />
        </label>
        <label className="space-y-1">
          <span className="block text-muted-foreground">To</span>
          <input name="to" type="date" defaultValue={to} className="h-9 rounded-md border bg-background px-2" />
        </label>
        <button type="submit" className="h-9 rounded-md border px-3">
          Show
        </button>
      </form>
      <div className="mb-6 grid gap-4 sm:grid-cols-4" data-testid="sales-summary">
        <Stat label="Net sales" value={formatPkr(summary.net)} />
        <Stat label="Cash" value={formatPkr(summary.cash)} />
        <Stat label="Charged to fees" value={formatPkr(summary.feeLedger)} />
        <Stat label="Receipts / returns" value={`${summary.receipts} / ${summary.creditNotes}`} />
      </div>
      {summary.items.length === 0 ? (
        <EmptyState title="No sales in this period" description="Pick another date range." />
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Item</TableHead>
              <TableHead className="text-right">Quantity</TableHead>
              <TableHead className="text-right">Amount</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {summary.items.map((i) => (
              <TableRow key={i.item} data-testid="sales-item">
                <TableCell>{i.item}</TableCell>
                <TableCell className="text-right">{i.qty}</TableCell>
                <TableCell className="text-right">{formatPkr(i.amount)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </>
  );
}
