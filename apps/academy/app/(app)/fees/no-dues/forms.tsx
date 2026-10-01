'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import {
  disburseDepositSchema,
  recordDepositSchema,
  startClearanceSchema,
  type DisburseDepositInput,
  type RecordDepositInput,
  type StartClearanceInput,
} from '@/lib/validation';
import { approveRefund, clearItem, disburseRefund, netItem, overrideClearance, recordDeposit, setItemOutstanding, startClearance, waiveItem } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const selectClass = 'h-10 w-full rounded-md border bg-background px-3 text-sm';
type Result = { error: string | null };

function useAction() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const run = (fn: () => Promise<Result>, success?: string) =>
    startTransition(async () => {
      const r = await fn();
      setError(r.error);
      if (!r.error) {
        if (success) toast.success(success);
        router.refresh();
      }
    });
  return { pending, error, run };
}

export function StartClearanceForm() {
  const { pending, error, run } = useAction();
  const form = useForm<StartClearanceInput>({ resolver: zodResolver(startClearanceSchema), defaultValues: { grNumber: '' } });
  const onSubmit = form.handleSubmit((v) => run(() => startClearance(v), 'Checklist ready.'));
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2" noValidate>
      <div className="space-y-1">
        <Label htmlFor="clearGr">GR number</Label>
        <Input id="clearGr" className="w-40" {...form.register('grNumber')} />
      </div>
      <Button type="submit" disabled={pending} data-testid="start-clearance">
        Start clearance
      </Button>
      {(error || form.formState.errors.grNumber) && <p role="alert" className="w-full text-sm text-destructive">{error ?? form.formState.errors.grNumber?.message}</p>}
    </form>
  );
}

export function RecordDepositForm() {
  const { pending, error, run } = useAction();
  const form = useForm<RecordDepositInput>({ resolver: zodResolver(recordDepositSchema), defaultValues: { grNumber: '', receivedOn: '', mode: 'cash', receiptRef: '' } });
  const onSubmit = form.handleSubmit((v) => run(() => recordDeposit(v), 'Deposit recorded.'));
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-3" noValidate>
      <div className="space-y-1">
        <Label htmlFor="depGr">GR number</Label>
        <Input id="depGr" {...form.register('grNumber')} />
        {form.formState.errors.grNumber && <p className="text-xs text-destructive">{form.formState.errors.grNumber.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="depAmount">Amount (PKR)</Label>
        <Input id="depAmount" type="number" step="1" {...form.register('amountPkr', { valueAsNumber: true })} />
        {form.formState.errors.amountPkr && <p className="text-xs text-destructive">{form.formState.errors.amountPkr.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="depDate">Received on</Label>
        <Input id="depDate" type="date" {...form.register('receivedOn')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="depMode">Mode</Label>
        <select id="depMode" className={selectClass} {...form.register('mode')}>
          <option value="cash">Cash</option>
          <option value="cheque">Cheque</option>
          <option value="transfer">Bank transfer</option>
          <option value="bank_challan">Bank challan</option>
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="depRef">Receipt reference</Label>
        <Input id="depRef" {...form.register('receiptRef')} />
      </div>
      <div className="flex items-end">
        <Button type="submit" disabled={pending} data-testid="record-deposit">
          Record deposit
        </Button>
      </div>
      {error && <p role="alert" className="text-sm text-destructive sm:col-span-3">{error}</p>}
    </form>
  );
}

export function ItemControls({ itemId, domain, hasDeposit }: { itemId: string; domain: string; hasDeposit: boolean }) {
  const { pending, error, run } = useAction();
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');
  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2">
        {domain !== 'fees' && (
          <>
            <Input aria-label={`${domain} outstanding PKR`} type="number" className="h-8 w-28" placeholder="Owed PKR" value={amount} onChange={(e) => setAmount(e.target.value)} />
            <Button size="sm" variant="outline" disabled={pending || amount === ''} onClick={() => run(() => setItemOutstanding({ itemId, outstandingPkr: Number(amount) }))}>
              Set amount
            </Button>
          </>
        )}
        <Button size="sm" disabled={pending} onClick={() => run(() => clearItem(itemId))} data-testid={`clear-${domain}`}>
          Clear
        </Button>
        {hasDeposit && (
          <Button size="sm" variant="outline" disabled={pending} onClick={() => run(() => netItem(itemId))} data-testid={`net-${domain}`}>
            Net against deposit
          </Button>
        )}
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <Input aria-label={`${domain} waive reason`} className="h-8 w-64" placeholder="Waiver reason (20+ characters)" value={reason} onChange={(e) => setReason(e.target.value)} />
        <Button size="sm" variant="outline" disabled={pending} onClick={() => run(() => waiveItem(itemId, reason))}>
          Waive
        </Button>
      </div>
      {error && <p role="alert" className="text-xs text-destructive">{error}</p>}
    </div>
  );
}

export function ClearanceActions({ clearanceId, enrolmentId, status, hasDeposit, approved }: { clearanceId: string; enrolmentId: string; status: string; hasDeposit: boolean; approved: boolean }) {
  const { pending, error, run } = useAction();
  const [reason, setReason] = useState('');
  const form = useForm<DisburseDepositInput>({ resolver: zodResolver(disburseDepositSchema), defaultValues: { enrolmentId, instrumentType: 'cheque', instrumentRef: '' } });
  const onDisburse = form.handleSubmit((v) => run(() => disburseRefund(v), 'Refund disbursed.'));
  return (
    <div className="space-y-3">
      {status === 'open' && (
        <div className="flex flex-wrap items-center gap-2">
          <Input aria-label="Override reason" className="h-8 w-72" placeholder="Owner override reason (20+ characters)" value={reason} onChange={(e) => setReason(e.target.value)} />
          <Button size="sm" variant="outline" disabled={pending} onClick={() => run(() => overrideClearance(clearanceId, reason), 'Clearance overridden.')} data-testid="override-clearance">
            Override to release the TC
          </Button>
        </div>
      )}
      {status === 'cleared' && hasDeposit && !approved && (
        <Button size="sm" disabled={pending} onClick={() => run(() => approveRefund(enrolmentId), 'Refund approved.')} data-testid="approve-refund">
          Approve deposit refund
        </Button>
      )}
      {status === 'cleared' && hasDeposit && approved && (
        <form onSubmit={onDisburse} className="flex flex-wrap items-center gap-2" noValidate>
          <select className="h-8 rounded-md border bg-background px-2 text-sm" {...form.register('instrumentType')}>
            <option value="cheque">Cheque</option>
            <option value="transfer">Bank transfer</option>
            <option value="cash">Cash</option>
          </select>
          <Input placeholder="Cheque / transfer no." className="h-8 w-48" {...form.register('instrumentRef')} />
          <Button size="sm" type="submit" disabled={pending} data-testid="disburse-refund">
            Disburse refund
          </Button>
          {form.formState.errors.instrumentRef && <p role="alert" className="w-full text-xs text-destructive">{form.formState.errors.instrumentRef.message}</p>}
        </form>
      )}
      {error && <p role="alert" className="text-xs text-destructive">{error}</p>}
    </div>
  );
}
