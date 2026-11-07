import { supabaseServer } from '@/lib/supabase/server';
import { formatPkr } from '@/lib/challan/html';
import { todayPk } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const DATE = /^\d{4}-\d{2}-\d{2}$/;

export default async function ShopProfitPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string }> }) {
  const sp = await searchParams;
  const to = sp.to && DATE.test(sp.to) ? sp.to : todayPk();
  const from = sp.from && DATE.test(sp.from) ? sp.from : `${to.slice(0, 7)}-01`;
  const supabase = await supabaseServer();
  const { data: rows, error } = await supabase.rpc('inventory_profit', { p_from: from, p_to: to });
  const sum = (k: 'revenue_paisa' | 'cost_paisa' | 'profit_paisa') => (rows ?? []).reduce((n, r) => n + r[k], 0);

  return (
    <div className="space-y-4">
      <PageHeader title="Shop profit" description="What the uniform and book shop sold between two dates, net of returns, against the average purchase cost of each item." />
      <form method="get" className="flex flex-wrap items-end gap-2 text-sm">
        {[
          { name: 'from', label: 'From', value: from },
          { name: 'to', label: 'To', value: to },
        ].map((f) => (
          <label key={f.name} className="space-y-1">
            <span className="block text-muted-foreground">{f.label}</span>
            <input name={f.name} type="date" defaultValue={f.value} className="h-9 rounded-md border bg-background px-2" />
          </label>
        ))}
        <button type="submit" className="h-9 rounded-md border px-3">
          Show
        </button>
      </form>
      {error ? (
        <p className="text-sm text-muted-foreground">Only leadership and the accountant can see shop profit.</p>
      ) : (rows ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">Nothing was sold in this period.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Item</TableHead>
              <TableHead className="text-right">Sold</TableHead>
              <TableHead className="text-right">Revenue</TableHead>
              <TableHead className="text-right">Cost</TableHead>
              <TableHead className="text-right">Profit</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(rows ?? []).map((r) => (
              <TableRow key={r.item_id} data-testid="profit-row">
                <TableCell>
                  {r.name} <span className="text-xs text-muted-foreground">{r.item_code}</span>
                </TableCell>
                <TableCell className="text-right">{Number(r.qty_sold)}</TableCell>
                <TableCell className="text-right">{formatPkr(r.revenue_paisa)}</TableCell>
                <TableCell className="text-right">{r.cost_paisa ? formatPkr(r.cost_paisa) : 'No cost recorded'}</TableCell>
                <TableCell className="text-right">{formatPkr(r.profit_paisa)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
          <TableFooter>
            <TableRow>
              <TableCell colSpan={2} className="font-medium">
                Total
              </TableCell>
              <TableCell className="text-right font-medium">{formatPkr(sum('revenue_paisa'))}</TableCell>
              <TableCell className="text-right font-medium">{formatPkr(sum('cost_paisa'))}</TableCell>
              <TableCell className="text-right font-medium" data-testid="profit-total">
                {formatPkr(sum('profit_paisa'))}
              </TableCell>
            </TableRow>
          </TableFooter>
        </Table>
      )}
    </div>
  );
}
