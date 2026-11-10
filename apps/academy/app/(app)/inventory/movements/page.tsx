import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { one } from '@/lib/hr/current-role';
import { todayPk } from '@/lib/dates';
import { PrintButton } from '@/components/print-button';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const TYPES = { receipt: 'Received', sale: 'Sold', issue: 'Issued', return: 'Returned', adjustment: 'Adjusted', writeoff: 'Written off' } as const;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const when = (iso: string) => new Date(iso).toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Karachi' });

export default async function StockMovementsPage({ searchParams }: { searchParams: Promise<{ item?: string; store?: string; type?: string; from?: string; to?: string }> }) {
  const f = await searchParams;
  const to = f.to && DATE.test(f.to) ? f.to : todayPk();
  const from = f.from && DATE.test(f.from) ? f.from : `${to.slice(0, 7)}-01`;
  const supabase = await supabaseServer();
  let query = supabase
    .from('inv_stock_movement')
    .select('id, moved_at, movement_type, qty, unit_cost, reason_code, item:item_id(item_code, name, uom), store:store_id(name)')
    .gte('moved_at', `${from}T00:00:00+05:00`)
    .lte('moved_at', `${to}T23:59:59+05:00`)
    .order('moved_at', { ascending: false })
    .limit(500);
  if (f.item) query = query.eq('item_id', f.item);
  if (f.store) query = query.eq('store_id', f.store);
  if (f.type && f.type in TYPES) query = query.eq('movement_type', f.type as keyof typeof TYPES);
  const [{ data: moves, error }, { data: items }, { data: stores }] = await Promise.all([
    query,
    supabase.from('inv_item').select('id, item_code, name').eq('active', true).order('name'),
    supabase.from('inv_store').select('id, name').order('name'),
  ]);
  const totalIn = (moves ?? []).filter((m) => m.qty > 0).reduce((t, m) => t + Number(m.qty), 0);
  const totalOut = (moves ?? []).filter((m) => m.qty < 0).reduce((t, m) => t - Number(m.qty), 0);
  const select = 'h-9 rounded-md border bg-background px-2';

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Stock movement report</h1>
          <p className="text-sm text-muted-foreground">Every item received, sold, issued, returned, adjusted or written off, store by store.</p>
        </div>
        <div className="print:hidden">
          <PrintButton />
        </div>
      </div>
      <form method="get" className="flex flex-wrap items-end gap-2 rounded-lg border p-4 text-sm print:hidden">
        <select name="item" defaultValue={f.item ?? ''} aria-label="Item" className={select}>
          <option value="">All items</option>
          {(items ?? []).map((i) => (
            <option key={i.id} value={i.id}>
              {i.name} ({i.item_code})
            </option>
          ))}
        </select>
        <select name="store" defaultValue={f.store ?? ''} aria-label="Store" className={select}>
          <option value="">All stores</option>
          {(stores ?? []).map((s) => (
            <option key={s.id} value={s.id}>
              {s.name}
            </option>
          ))}
        </select>
        <select name="type" defaultValue={f.type ?? ''} aria-label="Movement" className={select}>
          <option value="">All movements</option>
          {Object.entries(TYPES).map(([k, label]) => (
            <option key={k} value={k}>
              {label}
            </option>
          ))}
        </select>
        <input type="date" name="from" defaultValue={from} aria-label="From" className={select} />
        <input type="date" name="to" defaultValue={to} aria-label="To" className={select} />
        <Button type="submit" size="sm">
          Show
        </Button>
        {Object.values(f).some(Boolean) && (
          <Link href="/inventory/movements" className="h-9 px-2 leading-9 text-muted-foreground underline">
            Clear
          </Link>
        )}
        <p className="w-full text-muted-foreground">
          In: <span className="tabular font-medium text-foreground">{totalIn}</span> · Out: <span className="tabular font-medium text-foreground">{totalOut}</span>
        </p>
      </form>
      {error ? (
        <p className="text-sm text-destructive">Could not load stock movements. Try again.</p>
      ) : (moves ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">No stock moved in this period.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>When</TableHead>
              <TableHead>Item</TableHead>
              <TableHead>Store</TableHead>
              <TableHead>Movement</TableHead>
              <TableHead className="text-right">Quantity</TableHead>
              <TableHead className="text-right">Unit cost (PKR)</TableHead>
              <TableHead>Reason</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(moves ?? []).map((m) => {
              const item = one(m.item);
              return (
                <TableRow key={m.id} data-testid="movement-row">
                  <TableCell className="whitespace-nowrap">{when(m.moved_at)}</TableCell>
                  <TableCell className="font-medium">
                    {item?.name} <span className="text-muted-foreground">({item?.item_code})</span>
                  </TableCell>
                  <TableCell>{one(m.store)?.name ?? ''}</TableCell>
                  <TableCell>
                    <Badge variant={m.qty > 0 ? 'success' : 'outline'}>{TYPES[m.movement_type]}</Badge>
                  </TableCell>
                  <TableCell className={`tabular text-right ${m.qty < 0 ? 'text-destructive' : ''}`}>
                    {m.qty > 0 ? '+' : ''}
                    {Number(m.qty)} {item?.uom}
                  </TableCell>
                  <TableCell className="tabular text-right">{m.unit_cost === null ? '' : (m.unit_cost / 100).toLocaleString('en-PK')}</TableCell>
                  <TableCell>{m.reason_code ?? ''}</TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
