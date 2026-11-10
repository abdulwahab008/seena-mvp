import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { pkr } from '@/lib/rpc-action';
import { PrintButton } from '@/components/print-button';
import { Stat } from '@/components/ui/page-header';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const CATEGORY = { furniture: 'Furniture', it: 'IT equipment', lab: 'Lab equipment', vehicle: 'Vehicles', building: 'Buildings', other: 'Other' } as const;
const STATUS = { active: 'In use', in_repair: 'In repair', disposed: 'Disposed', written_off: 'Written off' } as const;
const REQ = { draft: 'Draft', pending: 'Waiting for approval', approved: 'Approved', rejected: 'Rejected', converted: 'Ordered' } as const;

export default async function AssetReportsPage() {
  const supabase = await supabaseServer();
  const [{ data: assets }, { data: low }, { data: reqs }] = await Promise.all([
    supabase.from('v_asset_register').select('category, status, capitalised_cost, accumulated_depreciation, net_book_value'),
    supabase.from('v_stock_on_hand').select('item_id, item_name, size, on_hand, reorder_level').eq('at_or_below_reorder', true).order('on_hand'),
    supabase.from('purchase_requisition').select('status'),
  ]);
  const held = (assets ?? []).filter((a) => a.status === 'active' || a.status === 'in_repair');
  const byCategory = Object.entries(CATEGORY)
    .map(([k, label]) => {
      const rows = held.filter((a) => a.category === k);
      return { label, count: rows.length, cost: rows.reduce((t, a) => t + (a.capitalised_cost ?? 0), 0), dep: rows.reduce((t, a) => t + (a.accumulated_depreciation ?? 0), 0), nbv: rows.reduce((t, a) => t + (a.net_book_value ?? 0), 0) };
    })
    .filter((c) => c.count > 0);
  const sum = (k: 'count' | 'cost' | 'dep' | 'nbv') => byCategory.reduce((t, c) => t + c[k], 0);
  const count = <T extends string>(list: { status: T | null }[] | null, s: string) => (list ?? []).filter((x) => x.status === s).length;

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Asset and stock reports</h1>
          <p className="text-sm text-muted-foreground">What the school owns and what it is worth, stock running low, and purchase requests.</p>
        </div>
        <div className="flex gap-2 print:hidden">
          <Link href="/assets" className="h-9 px-2 text-sm leading-9 text-muted-foreground underline">
            Asset register
          </Link>
          <PrintButton />
        </div>
      </div>
      <section aria-label="Assets by status" className="grid gap-3 sm:grid-cols-4">
        {Object.entries(STATUS).map(([k, label]) => (
          <Stat key={k} label={label} value={count(assets, k)} />
        ))}
      </section>

      <section className="space-y-2">
        <h2 className="text-lg font-semibold">Value by category</h2>
        {byCategory.length === 0 ? (
          <p className="text-sm text-muted-foreground">No assets registered yet.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Category</TableHead>
                <TableHead className="text-right">Assets</TableHead>
                <TableHead className="text-right">Cost</TableHead>
                <TableHead className="text-right">Depreciation</TableHead>
                <TableHead className="text-right">Book value</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {byCategory.map((c) => (
                <TableRow key={c.label} data-testid="asset-category-row">
                  <TableCell className="font-medium">{c.label}</TableCell>
                  <TableCell className="tabular text-right">{c.count}</TableCell>
                  <TableCell className="tabular text-right">{pkr(c.cost)}</TableCell>
                  <TableCell className="tabular text-right">{pkr(c.dep)}</TableCell>
                  <TableCell className="tabular text-right font-medium">{pkr(c.nbv)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
            <TableFooter>
              <TableRow>
                <TableCell>Total</TableCell>
                <TableCell className="tabular text-right">{sum('count')}</TableCell>
                <TableCell className="tabular text-right">{pkr(sum('cost'))}</TableCell>
                <TableCell className="tabular text-right">{pkr(sum('dep'))}</TableCell>
                <TableCell className="tabular text-right">{pkr(sum('nbv'))}</TableCell>
              </TableRow>
            </TableFooter>
          </Table>
        )}
      </section>

      <section className="space-y-2">
        <h2 className="text-lg font-semibold">Stock at or below reorder level</h2>
        {(low ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">No item is running low.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Item</TableHead>
                <TableHead className="text-right">In stock</TableHead>
                <TableHead className="text-right">Reorder at</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {(low ?? []).map((i) => (
                <TableRow key={`${i.item_id}`} data-testid="low-stock-row">
                  <TableCell className="font-medium">
                    {i.item_name}
                    {i.size ? ` (${i.size})` : ''}
                  </TableCell>
                  <TableCell className="tabular text-right text-destructive">{i.on_hand ?? 0}</TableCell>
                  <TableCell className="tabular text-right">{i.reorder_level ?? 0}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </section>

      <section aria-label="Purchase requests" className="space-y-2">
        <h2 className="text-lg font-semibold">Purchase requests</h2>
        <div className="grid gap-3 sm:grid-cols-5">
          {Object.entries(REQ).map(([k, label]) => (
            <Stat key={k} label={label} value={count(reqs, k)} />
          ))}
        </div>
      </section>
    </div>
  );
}
