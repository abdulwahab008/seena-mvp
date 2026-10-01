import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PageHeader } from '@/components/ui/page-header';
import { pkr } from '@/lib/rpc-action';
import { ReceiptForm } from '../purchasing-forms';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function OrdersPage() {
  const supabase = await supabaseServer();
  const [orders, lines, stores] = await Promise.all([
    supabase.from('purchase_order').select('id, po_no, status, ordered_at, campus_id, vendor:vendor_id(name)').order('ordered_at', { ascending: false }).limit(40),
    supabase.from('v_purchase_order_line').select('po_line_id, po_id, description, qty_ordered, qty_received, shortfall, unit_cost'),
    supabase.from('inv_store').select('id, name, campus_id, campus:campus_id(name)').order('name'),
  ]);

  return (
    <div className="space-y-6">
      <PageHeader
        title="Purchase orders and goods receipts"
        description="FR-R06 — receive what actually arrived. A short delivery keeps the order open and shows the shortfall; stock is posted for the quantity received, not the quantity ordered."
      />
      {(orders.data ?? []).length === 0 && <p className="text-sm text-muted-foreground">No purchase orders yet. Approved requisitions are converted on their own page.</p>}
      {(orders.data ?? []).map((o) => {
        const poLines = (lines.data ?? []).filter((l) => l.po_id === o.id);
        const campusStores = (stores.data ?? []).filter((s) => s.campus_id === o.campus_id).map((s) => ({ value: s.id, label: `${one(s.campus)?.name ?? ''} · ${s.name}` }));
        return (
          <Card key={o.id} data-testid="po-card">
            <CardHeader>
              <CardTitle className="flex items-center justify-between text-base">
                <span>
                  <span className="font-mono">{o.po_no}</span> · {one(o.vendor)?.name}
                </span>
                <Badge data-testid="po-status" variant={o.status === 'fulfilled' ? 'success' : 'outline'}>
                  {o.status.replace('_', ' ')}
                </Badge>
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-3 text-sm">
              {poLines.map((l) => (
                <p key={l.po_line_id} data-testid="po-line">
                  {l.description}: ordered {Number(l.qty_ordered)}, received {Number(l.qty_received)}
                  {Number(l.shortfall) > 0 ? <span className="text-destructive" data-testid="po-shortfall"> · short by {Number(l.shortfall)}</span> : ''} · {pkr(l.unit_cost)} each
                </p>
              ))}
              {o.status !== 'fulfilled' && o.status !== 'cancelled' && (
                <ReceiptForm
                  poId={o.id}
                  stores={campusStores}
                  lines={poLines.map((l) => ({ poLineId: l.po_line_id ?? '', description: l.description ?? '', shortfall: Number(l.shortfall) }))}
                />
              )}
            </CardContent>
          </Card>
        );
      })}
    </div>
  );
}
