'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import {
  pettyCashAccountSchema,
  pettyCashPaymentSchema,
  pettyCashReplenishSchema,
  type PettyCashAccountInput,
  type PettyCashPaymentInput,
  type PettyCashReplenishInput,
} from '@/lib/validation';
import { changeCustodian, createAccount, decideReplenishment, payFromPettyCash, requestReplenishment, type PettyResult } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const selectClass = 'h-10 w-full rounded-md border bg-background px-3 text-sm';
type Option = { id: string; label: string };

function useAction() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const run = (fn: () => Promise<PettyResult>, success?: string) =>
    startTransition(async () => {
      const r = await fn();
      setError(r.error);
      if (r.useVoucher) {
        toast.message('Above the petty cash cap — raise a full expense voucher.');
        router.push('/expenses/vouchers');
        return;
      }
      if (!r.error) {
        if (success) toast.success(success);
        router.refresh();
      }
    });
  return { pending, error, run };
}

export function PayForm({ accountId, heads }: { accountId: string; heads: Option[] }) {
  const { pending, error, run } = useAction();
  const form = useForm<PettyCashPaymentInput>({ resolver: zodResolver(pettyCashPaymentSchema), defaultValues: { accountId, headId: heads[0]?.id ?? '', narrative: '' } });
  const onSubmit = form.handleSubmit((v) =>
    run(() => payFromPettyCash(v), 'Payment recorded.'),
  );
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-4" noValidate>
      <div className="space-y-1">
        <Label htmlFor={`pay-amount-${accountId}`}>Amount (PKR)</Label>
        <Input id={`pay-amount-${accountId}`} type="number" {...form.register('amountPkr', { valueAsNumber: true })} />
        {form.formState.errors.amountPkr && <p className="text-xs text-destructive">{form.formState.errors.amountPkr.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor={`pay-head-${accountId}`}>Expense head</Label>
        <select id={`pay-head-${accountId}`} className={selectClass} {...form.register('headId')}>
          {heads.map((h) => (
            <option key={h.id} value={h.id}>
              {h.label}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor={`pay-note-${accountId}`}>What for</Label>
        <Input id={`pay-note-${accountId}`} {...form.register('narrative')} />
      </div>
      {error && <p role="alert" className="text-sm text-destructive sm:col-span-4">{error}</p>}
      <div className="sm:col-span-4">
        <Button type="submit" disabled={pending} data-testid="petty-pay">
          Pay from petty cash
        </Button>
      </div>
    </form>
  );
}

export function ReplenishForm({ accountId }: { accountId: string }) {
  const { pending, error, run } = useAction();
  const form = useForm<PettyCashReplenishInput>({ resolver: zodResolver(pettyCashReplenishSchema), defaultValues: { accountId, explanation: '' } });
  const onSubmit = form.handleSubmit((v) => run(() => requestReplenishment(v), 'Count submitted for sign-off.'));
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-3" noValidate>
      <div className="space-y-1">
        <Label htmlFor={`count-${accountId}`}>Cash counted in the tin (PKR)</Label>
        <Input id={`count-${accountId}`} type="number" {...form.register('countedPkr', { valueAsNumber: true })} />
        {form.formState.errors.countedPkr && <p className="text-xs text-destructive">{form.formState.errors.countedPkr.message}</p>}
      </div>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor={`explain-${accountId}`}>Explanation if the count differs (20+ characters)</Label>
        <Input id={`explain-${accountId}`} {...form.register('explanation')} />
      </div>
      {error && <p role="alert" className="text-sm text-destructive sm:col-span-3">{error}</p>}
      <div className="sm:col-span-3">
        <Button type="submit" variant="outline" disabled={pending} data-testid="petty-replenish">
          Request replenishment
        </Button>
      </div>
    </form>
  );
}

export function DecideButtons({ reconciliationId }: { reconciliationId: string }) {
  const { pending, error, run } = useAction();
  return (
    <div className="space-y-1">
      <div className="flex gap-2">
        <Button size="sm" disabled={pending} onClick={() => run(() => decideReplenishment(reconciliationId, true), 'Replenishment posted.')} data-testid="petty-approve">
          Approve and top up
        </Button>
        <Button size="sm" variant="outline" disabled={pending} onClick={() => run(() => decideReplenishment(reconciliationId, false))}>
          Reject
        </Button>
      </div>
      {error && <p role="alert" className="text-xs text-destructive">{error}</p>}
    </div>
  );
}

export function CreateAccountForm({ campuses, staff }: { campuses: Option[]; staff: Option[] }) {
  const { pending, error, run } = useAction();
  const form = useForm<PettyCashAccountInput>({ resolver: zodResolver(pettyCashAccountSchema), defaultValues: { campusId: campuses[0]?.id ?? '', custodianId: staff[0]?.id ?? '' } });
  const onSubmit = form.handleSubmit((v) => run(() => createAccount(v), 'Petty cash account opened.'));
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-4" noValidate>
      <div className="space-y-1">
        <Label htmlFor="pcCampus">Campus</Label>
        <select id="pcCampus" className={selectClass} {...form.register('campusId')}>
          {campuses.map((c) => (
            <option key={c.id} value={c.id}>
              {c.label}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="pcFloat">Float (PKR)</Label>
        <Input id="pcFloat" type="number" {...form.register('floatPkr', { valueAsNumber: true })} />
        {form.formState.errors.floatPkr && <p className="text-xs text-destructive">{form.formState.errors.floatPkr.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="pcCap">Per-payment cap (PKR)</Label>
        <Input id="pcCap" type="number" {...form.register('capPkr', { valueAsNumber: true })} />
        {form.formState.errors.capPkr && <p className="text-xs text-destructive">{form.formState.errors.capPkr.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="pcCustodian">Custodian</Label>
        <select id="pcCustodian" className={selectClass} {...form.register('custodianId')}>
          {staff.map((s) => (
            <option key={s.id} value={s.id}>
              {s.label}
            </option>
          ))}
        </select>
      </div>
      {error && <p role="alert" className="text-sm text-destructive sm:col-span-4">{error}</p>}
      <div className="sm:col-span-4">
        <Button type="submit" disabled={pending} data-testid="petty-create">
          Open account
        </Button>
      </div>
    </form>
  );
}

export function CustodianForm({ accountId, staff, current }: { accountId: string; staff: Option[]; current: string }) {
  const { pending, error, run } = useAction();
  const [value, setValue] = useState(current);
  return (
    <div className="space-y-1">
      <div className="flex items-center gap-2">
        <select aria-label="New custodian" className="h-9 rounded-md border bg-background px-2 text-sm" value={value} onChange={(e) => setValue(e.target.value)}>
          {staff.map((s) => (
            <option key={s.id} value={s.id}>
              {s.label}
            </option>
          ))}
        </select>
        <Button size="sm" variant="outline" disabled={pending || value === current} onClick={() => run(() => changeCustodian(accountId, value), 'Custodian changed.')}>
          Hand over
        </Button>
      </div>
      {error && <p role="alert" className="text-xs text-destructive">{error}</p>}
    </div>
  );
}
