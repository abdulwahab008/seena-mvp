'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { libraryWriteOffSchema, type LibraryWriteOffInput } from '@/lib/validation';
import { reverseWriteOff, writeOff } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export function WriteOffForm() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [result, setResult] = useState<{ error: string | null; message?: string } | null>(null);
  const form = useForm<LibraryWriteOffInput>({
    resolver: zodResolver(libraryWriteOffSchema),
    defaultValues: { barcode: '', basis: 'multiple', multiplier: '1.5', marketValuePkr: '', reason: '' },
  });
  const basis = form.watch('basis');
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await writeOff(v);
      setResult(r);
      if (!r.error) {
        toast.success('Copy written off.');
        form.reset({ barcode: '', basis: v.basis, multiplier: v.multiplier, marketValuePkr: '', reason: '' });
        router.refresh();
      }
    }),
  );
  return (
    <form onSubmit={onSubmit} className="grid gap-3 md:grid-cols-4" noValidate>
      <div className="space-y-1">
        <Label htmlFor="wo-barcode">Barcode of the lost copy</Label>
        <Input id="wo-barcode" className="font-mono" {...form.register('barcode')} />
        {form.formState.errors.barcode && <p className="text-xs text-destructive">{form.formState.errors.barcode.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="wo-basis">Replacement basis</Label>
        <select id="wo-basis" className="h-10 w-full rounded-md border bg-background px-2 text-sm" {...form.register('basis')}>
          <option value="multiple">Purchase cost x multiplier</option>
          <option value="purchase_cost">Purchase cost</option>
          <option value="market">Market value</option>
        </select>
      </div>
      {basis === 'multiple' && (
        <div className="space-y-1">
          <Label htmlFor="wo-mult">Multiplier</Label>
          <Input id="wo-mult" inputMode="decimal" {...form.register('multiplier')} />
          {form.formState.errors.multiplier && <p className="text-xs text-destructive">{form.formState.errors.multiplier.message}</p>}
        </div>
      )}
      {basis === 'market' && (
        <div className="space-y-1">
          <Label htmlFor="wo-market">Market value (PKR)</Label>
          <Input id="wo-market" inputMode="decimal" {...form.register('marketValuePkr')} />
          {form.formState.errors.marketValuePkr && <p className="text-xs text-destructive">{form.formState.errors.marketValuePkr.message}</p>}
        </div>
      )}
      <div className="space-y-1">
        <Label htmlFor="wo-reason">Note (shown on the fee ledger)</Label>
        <Input id="wo-reason" {...form.register('reason')} />
      </div>
      <div className="flex items-end gap-3 md:col-span-4">
        <Button type="submit" disabled={pending} data-testid="write-off">
          Declare lost and write off
        </Button>
        {result?.error && (
          <p role="alert" className="text-sm text-destructive" data-testid="write-off-error">
            {result.error}
          </p>
        )}
        {result?.message && (
          <p className="text-sm" data-testid="write-off-ok">
            {result.message}
          </p>
        )}
      </div>
    </form>
  );
}

export function ReverseButton({ writeOffId }: { writeOffId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [reason, setReason] = useState('');
  const [error, setError] = useState<string | null>(null);
  return (
    <span className="flex flex-wrap items-center gap-2">
      <Input aria-label="Reason for reversal" placeholder="Where it was found" className="h-8 w-44 text-xs" value={reason} onChange={(e) => setReason(e.target.value)} />
      <Button
        size="sm"
        variant="outline"
        disabled={pending}
        data-testid="reverse-write-off"
        onClick={() =>
          startTransition(async () => {
            const r = await reverseWriteOff(writeOffId, reason);
            setError(r.error);
            if (!r.error) {
              toast.success(r.message ?? 'Reversed.');
              router.refresh();
            }
          })
        }
      >
        Found: reverse
      </Button>
      {error && <span role="alert" className="text-xs text-destructive">{error}</span>}
    </span>
  );
}
