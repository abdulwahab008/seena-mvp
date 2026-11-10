'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { createSecurityDeposit } from './actions';
import { depositSchema } from './schema';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';
type Values = z.input<typeof depositSchema>;

export function DepositForm({ staff, thisMonth }: { staff: { id: string; name: string; code: string }[]; thisMonth: string }) {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, reset, formState: { errors } } = useForm<Values>({
    resolver: zodResolver(depositSchema),
    defaultValues: { staffId: '', startMonth: thisMonth, notes: '' },
  });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const res = await createSecurityDeposit(v);
      if (res.error) return void toast.error(res.error);
      toast.success('Security deposit added. Payroll will deduct it each month.');
      reset();
    }),
  );
  const err = (m?: string) => m && <p className="text-xs text-destructive">{m}</p>;

  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4" noValidate>
      <div className="space-y-1">
        <Label htmlFor="dep-staff">Staff member</Label>
        <select id="dep-staff" className={SELECT} {...register('staffId')}>
          <option value="">Choose…</option>
          {staff.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name} ({s.code})
            </option>
          ))}
        </select>
        {err(errors.staffId?.message)}
      </div>
      <div className="space-y-1">
        <Label htmlFor="dep-target">Deposit amount (PKR)</Label>
        <Input id="dep-target" type="number" min={1} step={1} {...register('targetPkr')} />
        {err(errors.targetPkr?.message)}
      </div>
      <div className="space-y-1">
        <Label htmlFor="dep-installment">Monthly deduction (PKR)</Label>
        <Input id="dep-installment" type="number" min={1} step={1} {...register('installmentPkr')} />
        {err(errors.installmentPkr?.message)}
      </div>
      <div className="space-y-1">
        <Label htmlFor="dep-start">First deduction month</Label>
        <Input id="dep-start" type="month" {...register('startMonth')} />
        {err(errors.startMonth?.message)}
      </div>
      <div className="space-y-1 sm:col-span-2 lg:col-span-3">
        <Label htmlFor="dep-notes">Notes</Label>
        <Input id="dep-notes" placeholder="Optional" {...register('notes')} />
      </div>
      <div className="flex items-end">
        <Button type="submit" disabled={pending}>
          {pending ? 'Saving…' : 'Add deposit'}
        </Button>
      </div>
    </form>
  );
}
