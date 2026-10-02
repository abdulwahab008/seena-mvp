'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { unsettledDaysSchema, type UnsettledDaysInput } from '@/lib/validation';
import { setUnsettledDays, uploadGatewaySettlement } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const pkr = (paisa: number) => `PKR ${(paisa / 100).toLocaleString('en-PK')}`;

export function SettlementUploadForm() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [message, setMessage] = useState<{ error: boolean; text: string } | null>(null);

  function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = e.currentTarget;
    const fd = new FormData(form);
    setMessage(null);
    startTransition(async () => {
      const r = await uploadGatewaySettlement(fd);
      if (r.error !== null) return setMessage({ error: true, text: r.error });
      setMessage({ error: false, text: `${r.rows} rows: ${r.matched} matched, ${r.exceptions} exceptions, commission ${pkr(r.commissionPaisa)} recorded.` });
      toast.success('Settlement imported.');
      form.reset();
      router.refresh();
    });
  }

  return (
    <form onSubmit={onSubmit} className="grid gap-4 sm:grid-cols-2">
      <div className="space-y-2">
        <Label htmlFor="gateway">Gateway</Label>
        <select id="gateway" name="gateway" className="h-10 w-full rounded-md border bg-background px-3 text-sm" required>
          <option value="jazzcash">JazzCash</option>
          <option value="easypaisa">Easypaisa</option>
          <option value="onelink">1LINK</option>
        </select>
      </div>
      <div className="space-y-2">
        <Label htmlFor="settlementFile">Settlement report (CSV)</Label>
        <Input id="settlementFile" name="file" type="file" accept=".csv,text/csv" required />
      </div>
      {message && (
        <p role={message.error ? 'alert' : 'status'} className={`text-sm sm:col-span-2 ${message.error ? 'text-destructive' : 'text-emerald-700'}`} data-testid="settlement-upload-message">
          {message.text}
        </p>
      )}
      <div className="sm:col-span-2">
        <Button type="submit" disabled={pending} data-testid="settlement-upload">
          {pending ? 'Importing…' : 'Import and reconcile'}
        </Button>
      </div>
    </form>
  );
}

export function UnsettledDaysForm({ days }: { days: number }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<UnsettledDaysInput>({ resolver: zodResolver(unsettledDaysSchema), defaultValues: { days } });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await setUnsettledDays(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Threshold saved.');
        router.refresh();
      }
    }),
  );
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2" noValidate>
      <div className="space-y-1">
        <Label htmlFor="days">Flag payments unsettled after (days)</Label>
        <Input id="days" type="number" className="w-24" {...form.register('days', { valueAsNumber: true })} />
      </div>
      <Button type="submit" size="sm" variant="outline" disabled={pending}>
        Save
      </Button>
      {(error || form.formState.errors.days) && <p role="alert" className="w-full text-xs text-destructive">{error ?? form.formState.errors.days?.message}</p>}
    </form>
  );
}
