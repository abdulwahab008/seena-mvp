'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { disburseSettlementSchema, proposeSettlementSchema, type DisburseSettlementInput, type ProposeSettlementInput } from '@/lib/validation';
import { decideSettlement, disburseSettlement, previewSettlement, proposeSettlement } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const pkr = (paisa: number) => `PKR ${(paisa / 100).toLocaleString('en-PK')}`;
const selectClass = 'h-10 w-full rounded-md border bg-background px-3 text-sm';

export function ProposeForm() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [preview, setPreview] = useState<{ credit: number; refund: number; dues: number; balance: number } | null>(null);
  const form = useForm<ProposeSettlementInput>({ resolver: zodResolver(proposeSettlementSchema), defaultValues: { grNumber: '', leavingDate: '', basis: 'half_month', note: '' } });

  const onPreview = form.handleSubmit((v) =>
    startTransition(async () => {
      setError(null);
      const r = await previewSettlement(v);
      if (r.error !== null) return setError(r.error);
      setPreview({ credit: r.preview.credit_adjustment_paisa, refund: r.preview.net_refund_paisa, dues: r.preview.remaining_dues_paisa, balance: r.preview.ledger_balance_paisa });
    }),
  );
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      setError(null);
      const r = await proposeSettlement(v);
      if (r.error) return setError(r.error);
      toast.success('Settlement proposed for approval.');
      setPreview(null);
      router.refresh();
    }),
  );

  return (
    <form className="grid gap-4 sm:grid-cols-2" noValidate onSubmit={(e) => e.preventDefault()}>
      <div className="space-y-2">
        <Label htmlFor="grNumber">GR number</Label>
        <Input id="grNumber" {...form.register('grNumber')} />
        {form.formState.errors.grNumber && <p className="text-sm text-destructive">{form.formState.errors.grNumber.message}</p>}
      </div>
      <div className="space-y-2">
        <Label htmlFor="leavingDate">Leaving date</Label>
        <Input id="leavingDate" type="date" {...form.register('leavingDate')} />
      </div>
      <div className="space-y-2">
        <Label htmlFor="basis">Pro-rata basis for the leaving month</Label>
        <select id="basis" className={selectClass} {...form.register('basis')}>
          <option value="half_month">Half month (refund half if leaving by the 15th)</option>
          <option value="full_month">Full month (leaving month is not refunded)</option>
          <option value="daily">Daily (unused days)</option>
        </select>
      </div>
      <div className="space-y-2">
        <Label htmlFor="note">Note</Label>
        <Input id="note" {...form.register('note')} />
      </div>
      {preview && (
        <div className="space-y-1 rounded-md border p-3 text-sm sm:col-span-2" data-testid="settlement-preview">
          <p>Ledger balance now: {pkr(preview.balance)}</p>
          <p>Unearned fees credited back: {pkr(preview.credit)}</p>
          <p className="font-medium">Refund payable: {pkr(preview.refund)}</p>
          {preview.dues > 0 && <p className="text-amber-700">Still owed after netting: {pkr(preview.dues)}</p>}
        </div>
      )}
      {error && (
        <p role="alert" className="text-sm text-destructive sm:col-span-2">
          {error}
        </p>
      )}
      <div className="flex gap-2 sm:col-span-2">
        <Button type="button" variant="outline" disabled={pending} onClick={() => void onPreview()} data-testid="settlement-preview-btn">
          Preview
        </Button>
        <Button type="button" disabled={pending} onClick={() => void onSubmit()} data-testid="settlement-propose">
          Propose settlement
        </Button>
      </div>
    </form>
  );
}

export function DecideButtons({ settlementId }: { settlementId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const run = (approve: boolean) =>
    startTransition(async () => {
      const r = await decideSettlement(settlementId, approve);
      setError(r.error);
      router.refresh();
    });
  return (
    <div className="space-y-1">
      <div className="flex gap-2">
        <Button size="sm" disabled={pending} onClick={() => run(true)} data-testid="settlement-approve">
          Approve
        </Button>
        <Button size="sm" variant="outline" disabled={pending} onClick={() => run(false)}>
          Reject
        </Button>
      </div>
      {error && <p role="alert" className="text-xs text-destructive">{error}</p>}
    </div>
  );
}

export function DisburseForm({ settlementId }: { settlementId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<DisburseSettlementInput>({ resolver: zodResolver(disburseSettlementSchema), defaultValues: { settlementId, instrumentType: 'cheque', instrumentRef: '' } });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await disburseSettlement(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Refund disbursed.');
        router.refresh();
      }
    }),
  );
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2" noValidate>
      <select className="h-9 rounded-md border bg-background px-2 text-sm" {...form.register('instrumentType')}>
        <option value="cheque">Cheque</option>
        <option value="transfer">Bank transfer</option>
        <option value="cash">Cash</option>
      </select>
      <Input placeholder="Cheque / transfer no." className="h-9 w-48" {...form.register('instrumentRef')} />
      <Button size="sm" type="submit" disabled={pending} data-testid="settlement-disburse">
        Disburse
      </Button>
      {(error || form.formState.errors.instrumentRef) && <p role="alert" className="w-full text-xs text-destructive">{error ?? form.formState.errors.instrumentRef?.message}</p>}
    </form>
  );
}
