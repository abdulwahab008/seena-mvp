import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PageHeader } from '@/components/ui/page-header';
import { ActionForm } from '@/components/action-form';
import { pkr } from '@/lib/rpc-action';
import { createItem, createStore, postStockTake, receiveStock } from './actions';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function InventoryPage() {
  const supabase = await supabaseServer();
  const [stores, items, onHand, classes, subjects, campuses, alerts] = await Promise.all([
    supabase.from('inv_store').select('id, name, campus_id, campus:campus_id(name)').order('name'),
    supabase.from('inv_item').select('id, item_code, name, category, size, uom, reorder_level, sale_price, active').order('item_code'),
    supabase.from('v_stock_on_hand').select('store_id, item_id, on_hand, movement_count'),
    supabase.from('class_level').select('id, name_en').eq('is_active', true).order('ordinal'),
    supabase.from('subject').select('id, name_en').order('name_en'),
    supabase.from('campus').select('id, name').order('name'),
    supabase.from('inv_reorder_alert').select('store_id, item_id, on_hand, reorder_level').is('resolved_at', null),
  ]);
  const storeRows = stores.data ?? [];
  const itemRows = items.data ?? [];
  const balance = new Map((onHand.data ?? []).map((r) => [`${r.store_id}:${r.item_id}`, r]));
  const alerted = new Set((alerts.data ?? []).map((a) => `${a.store_id}:${a.item_id}`));
  const storeOptions = storeRows.map((s) => ({ value: s.id, label: `${one(s.campus)?.name ?? 'Campus'} · ${s.name}` }));
  const itemOptions = itemRows.filter((i) => i.active).map((i) => ({ value: i.id, label: `${i.item_code} · ${i.name}${i.size ? ` (${i.size})` : ''}` }));

  return (
    <div className="space-y-6">
      <PageHeader
        title="Stores and stock"
        description="FR-R01 — uniform, textbook and stationery stock is an immutable ledger of movements per campus store. On-hand is always the sum of movements; a stock-take variance is posted as a new adjustment row, never an edit."
      />

      {storeRows.length === 0 && (
        <Card>
          <CardContent className="pt-6 text-sm text-muted-foreground" data-testid="no-store">
            No store has been set up yet. Create one for a campus below.
          </CardContent>
        </Card>
      )}

      {storeRows.map((s) => (
        <Card key={s.id} data-testid="store-card">
          <CardHeader>
            <CardTitle className="text-base">
              {one(s.campus)?.name ?? 'Campus'} · {s.name}
            </CardTitle>
          </CardHeader>
          <CardContent className="overflow-x-auto text-sm">
            <table className="w-full">
              <thead className="text-left text-muted-foreground">
                <tr>
                  <th className="py-1 pr-3">Code</th>
                  <th className="pr-3">Item</th>
                  <th className="pr-3">Size</th>
                  <th className="pr-3 text-right">On hand</th>
                  <th className="pr-3 text-right">Reorder at</th>
                  <th className="pr-3 text-right">Price</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {itemRows.map((i) => {
                  const b = balance.get(`${s.id}:${i.id}`);
                  const qty = Number(b?.on_hand ?? 0);
                  return (
                    <tr key={i.id} className="border-t" data-testid="stock-row">
                      <td className="py-1 pr-3 font-mono">{i.item_code}</td>
                      <td className="pr-3">{i.name}</td>
                      <td className="pr-3">{i.size ?? '—'}</td>
                      <td className="pr-3 text-right" data-testid={`on-hand-${i.item_code}`}>
                        {qty}
                      </td>
                      <td className="pr-3 text-right">{Number(i.reorder_level)}</td>
                      <td className="pr-3 text-right">{pkr(i.sale_price)}</td>
                      <td>{alerted.has(`${s.id}:${i.id}`) && <Badge variant="outline">Reorder</Badge>}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
            {itemRows.length === 0 && <p className="text-muted-foreground">No items yet.</p>}
          </CardContent>
        </Card>
      ))}

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Add an item</CardTitle>
          </CardHeader>
          <CardContent>
            <ActionForm
              testId="item-form"
              submitLabel="Add item"
              action={createItem}
              fields={[
                { name: 'itemCode', label: 'Item code', required: true },
                { name: 'name', label: 'Name', required: true },
                { name: 'category', label: 'Category', type: 'select', required: true, options: ['uniform', 'textbook', 'stationery', 'consumable'].map((c) => ({ value: c, label: c })) },
                { name: 'size', label: 'Size (uniforms)' },
                { name: 'uom', label: 'Unit of measure', defaultValue: 'pcs' },
                { name: 'classId', label: 'Class (textbooks)', type: 'select', options: (classes.data ?? []).map((c) => ({ value: c.id, label: c.name_en })) },
                { name: 'subjectId', label: 'Subject (textbooks)', type: 'select', options: (subjects.data ?? []).map((c) => ({ value: c.id, label: c.name_en })) },
                { name: 'reorderLevel', label: 'Reorder level', type: 'number', defaultValue: '0' },
                { name: 'salePricePkr', label: 'Sale price (PKR)', type: 'number', defaultValue: '0' },
              ]}
            />
          </CardContent>
        </Card>

        <div className="space-y-6">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Receive stock</CardTitle>
            </CardHeader>
            <CardContent>
              <ActionForm
                testId="receipt-form"
                submitLabel="Receive"
                action={receiveStock}
                fields={[
                  { name: 'storeId', label: 'Store', type: 'select', required: true, options: storeOptions },
                  { name: 'itemId', label: 'Item', type: 'select', required: true, options: itemOptions },
                  { name: 'qty', label: 'Quantity', type: 'number' },
                  { name: 'unitCostPkr', label: 'Unit cost (PKR)', type: 'number' },
                ]}
              />
            </CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Physical stock take</CardTitle>
            </CardHeader>
            <CardContent>
              <ActionForm
                testId="take-form"
                submitLabel="Post variance"
                action={postStockTake}
                fields={[
                  { name: 'storeId', label: 'Store', type: 'select', required: true, options: storeOptions },
                  { name: 'itemId', label: 'Item', type: 'select', required: true, options: itemOptions },
                  { name: 'counted', label: 'Counted quantity', type: 'number' },
                  { name: 'reasonCode', label: 'Reason', type: 'select', required: true, options: ['SHRINKAGE', 'DAMAGE', 'EXPIRED', 'FOUND', 'COUNT_ERROR', 'OTHER'].map((c) => ({ value: c, label: c })) },
                ]}
              />
            </CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Add a store</CardTitle>
            </CardHeader>
            <CardContent>
              <ActionForm
                testId="store-form"
                submitLabel="Add store"
                action={createStore}
                fields={[
                  { name: 'campusId', label: 'Campus', type: 'select', required: true, options: (campuses.data ?? []).map((c) => ({ value: c.id, label: c.name })) },
                  { name: 'name', label: 'Store name', defaultValue: 'Main Store' },
                ]}
              />
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  );
}
