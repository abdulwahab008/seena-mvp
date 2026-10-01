'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import { createSaleAction } from './actions';

export type SaleItem = { id: string; code: string; name: string; size: string | null; pricePaisa: number; packageRemaining: number };

export function SaleForm({ studentId, items }: { studentId: string; items: SaleItem[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [qty, setQty] = useState<Record<string, string>>({});
  const [fromPackage, setFromPackage] = useState<Record<string, boolean>>({});
  const [settlement, setSettlement] = useState<'cash' | 'fee_ledger'>('cash');

  const lines = items.filter((i) => Number(qty[i.id] ?? 0) > 0);
  const total = lines.reduce((sum, i) => sum + (fromPackage[i.id] ? 0 : i.pricePaisa * Number(qty[i.id])), 0);

  const submit = () =>
    startTransition(async () => {
      const r = await createSaleAction({
        studentId,
        settlement,
        lines: lines.map((i) => ({ itemId: i.id, qty: Number(qty[i.id]), fromPackage: !!fromPackage[i.id] })),
      });
      setError(r.error);
      if (!r.error && r.saleId) {
        toast.success('Sale recorded.');
        router.push(`/inventory/sales/${r.saleId}`);
      }
    });

  return (
    <div className="space-y-3" data-testid="sale-form">
      <table className="w-full text-sm">
        <thead className="text-left text-muted-foreground">
          <tr>
            <th className="py-1">Item</th>
            <th>Price</th>
            <th>Quantity</th>
            <th>Admission package</th>
          </tr>
        </thead>
        <tbody>
          {items.map((i) => (
            <tr key={i.id} className="border-t" data-testid="sale-item-row">
              <td className="py-1">
                {i.code} · {i.name}
                {i.size ? ` (${i.size})` : ''}
              </td>
              <td>PKR {(i.pricePaisa / 100).toLocaleString('en-PK')}</td>
              <td>
                <input
                  aria-label={`Quantity of ${i.code}`}
                  type="number"
                  min={0}
                  className="h-8 w-20 rounded-md border bg-background px-2"
                  value={qty[i.id] ?? ''}
                  onChange={(e) => setQty({ ...qty, [i.id]: e.target.value })}
                />
              </td>
              <td>
                {i.packageRemaining > 0 ? (
                  <label className="flex items-center gap-2">
                    <input aria-label={`Issue ${i.code} from package`} type="checkbox" checked={!!fromPackage[i.id]} onChange={(e) => setFromPackage({ ...fromPackage, [i.id]: e.target.checked })} />
                    <span data-testid={`package-${i.code}`}>Covers {i.packageRemaining}</span>
                  </label>
                ) : (
                  <span className="text-muted-foreground">—</span>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <div className="flex flex-wrap items-end gap-4">
        <div className="space-y-1">
          <Label htmlFor="settlement">Settlement</Label>
          <select id="settlement" value={settlement} onChange={(e) => setSettlement(e.target.value as 'cash' | 'fee_ledger')} className="h-9 rounded-md border bg-background px-2 text-sm">
            <option value="cash">Cash now</option>
            <option value="fee_ledger">Charge to fee (next challan)</option>
          </select>
        </div>
        <p className="text-sm font-medium" data-testid="sale-total">
          Total PKR {(total / 100).toLocaleString('en-PK')}
        </p>
        <Button type="button" disabled={pending || lines.length === 0} onClick={submit} data-testid="sale-submit">
          Record sale
        </Button>
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid="sale-error">
          {error}
        </p>
      )}
    </div>
  );
}
