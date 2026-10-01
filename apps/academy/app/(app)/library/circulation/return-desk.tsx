'use client';

import { useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { formatPkrCompact } from '@/lib/format-money';
import { returnCopy, type ReturnResult } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const AFTERMATH: Record<string, string> = {
  available: 'Back on the shelf.',
  in_repair: 'Sent to repair: it will not be offered until a librarian restores it.',
  reserved_hold: 'Held at the counter for the next reader in the reservation queue.',
};

export function ReturnDesk() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [barcode, setBarcode] = useState('');
  const [condition, setCondition] = useState<'good' | 'damaged'>('good');
  const [result, setResult] = useState<ReturnResult | null>(null);
  const ref = useRef<HTMLInputElement>(null);

  return (
    <div className="space-y-3" data-testid="return-desk">
      <form
        className="flex flex-wrap items-end gap-3"
        onSubmit={(e) => {
          e.preventDefault();
          startTransition(async () => {
            const r = await returnCopy(barcode, condition);
            setResult(r);
            if (!r.error) {
              setBarcode('');
              setCondition('good');
              router.refresh();
            }
            ref.current?.focus();
          });
        }}
      >
        <div className="space-y-1">
          <Label htmlFor="return-barcode">Book barcode</Label>
          <Input id="return-barcode" ref={ref} className="w-64 font-mono" value={barcode} onChange={(e) => setBarcode(e.target.value)} autoComplete="off" />
        </div>
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Condition</span>
          <select value={condition} onChange={(e) => setCondition(e.target.value as 'good' | 'damaged')} className="h-10 rounded-md border bg-background px-2" aria-label="Condition">
            <option value="good">Good</option>
            <option value="damaged">Damaged</option>
          </select>
        </label>
        <Button type="submit" disabled={pending} data-testid="return-copy">
          Return
        </Button>
      </form>
      {result?.error && (
        <p role="alert" className="text-sm text-destructive" data-testid="return-error">
          {result.error}
        </p>
      )}
      {result?.summary && (
        <div className="text-sm" data-testid="return-ok">
          <p>
            Returned {result.summary.title} from {result.summary.borrower}. {AFTERMATH[result.summary.copyStatus] ?? ''}
          </p>
          <p className={result.summary.fine > 0 ? 'text-destructive' : 'text-muted-foreground'}>
            {result.summary.fine > 0 ? `Late fine ${formatPkrCompact(result.summary.fine)} (${result.summary.daysLate} days late).` : 'No fine.'}
          </p>
        </div>
      )}
    </div>
  );
}
