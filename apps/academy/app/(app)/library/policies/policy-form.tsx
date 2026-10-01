'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { libraryPolicySchema, type LibraryPolicyInput } from '@/lib/validation';
import { savePolicy } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

type Option = { id: string; name: string };

export function PolicyForm({ campuses, classes }: { campuses: Option[]; classes: { ordinal: number; name: string }[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
  const form = useForm<LibraryPolicyInput>({
    resolver: zodResolver(libraryPolicySchema),
    defaultValues: {
      role: 'student', campusId: '', bandFrom: '', bandTo: '', maxLoans: 2, loanDays: 14, maxRenewals: 1,
      finePerDayPkr: '5', fineCapPkr: '500', blockThresholdPkr: '300', countWorkingDaysOnly: false, effectiveFrom: today,
    },
  });
  const role = form.watch('role');
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await savePolicy(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Borrowing policy saved.');
        router.refresh();
      }
    }),
  );
  const err = (name: keyof LibraryPolicyInput) => form.formState.errors[name] && <p className="text-xs text-destructive">{String(form.formState.errors[name]?.message)}</p>;
  const sel = 'h-10 w-full rounded-md border bg-background px-2 text-sm';
  return (
    <form onSubmit={onSubmit} className="grid gap-3 md:grid-cols-4" noValidate>
      <div className="space-y-1">
        <Label htmlFor="pol-role">Borrower role</Label>
        <select id="pol-role" className={sel} {...form.register('role')}>
          <option value="student">Student</option>
          <option value="teacher">Teacher</option>
          <option value="staff">Other staff</option>
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="pol-campus">Campus</Label>
        <select id="pol-campus" className={sel} {...form.register('campusId')}>
          <option value="">All campuses</option>
          {campuses.map((c) => (
            <option key={c.id} value={c.id}>
              {c.name}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="pol-band-from">Class band from</Label>
        <select id="pol-band-from" className={sel} disabled={role !== 'student'} {...form.register('bandFrom')}>
          <option value="">No band</option>
          {classes.map((c) => (
            <option key={c.ordinal} value={c.ordinal}>
              {c.name}
            </option>
          ))}
        </select>
        {err('bandFrom')}
      </div>
      <div className="space-y-1">
        <Label htmlFor="pol-band-to">Class band to</Label>
        <select id="pol-band-to" className={sel} disabled={role !== 'student'} {...form.register('bandTo')}>
          <option value="">No band</option>
          {classes.map((c) => (
            <option key={c.ordinal} value={c.ordinal}>
              {c.name}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="pol-max">Concurrent loans</Label>
        <Input id="pol-max" type="number" {...form.register('maxLoans', { valueAsNumber: true })} />
        {err('maxLoans')}
      </div>
      <div className="space-y-1">
        <Label htmlFor="pol-days">Loan period (days)</Label>
        <Input id="pol-days" type="number" {...form.register('loanDays', { valueAsNumber: true })} />
        {err('loanDays')}
      </div>
      <div className="space-y-1">
        <Label htmlFor="pol-renew">Renewals</Label>
        <Input id="pol-renew" type="number" {...form.register('maxRenewals', { valueAsNumber: true })} />
        {err('maxRenewals')}
      </div>
      <div className="space-y-1">
        <Label htmlFor="pol-effective">Effective from</Label>
        <Input id="pol-effective" type="date" {...form.register('effectiveFrom')} />
        {err('effectiveFrom')}
      </div>
      <div className="space-y-1">
        <Label htmlFor="pol-fine">Fine per day (PKR)</Label>
        <Input id="pol-fine" inputMode="decimal" {...form.register('finePerDayPkr')} />
        {err('finePerDayPkr')}
      </div>
      <div className="space-y-1">
        <Label htmlFor="pol-cap">Fine cap per loan (PKR)</Label>
        <Input id="pol-cap" inputMode="decimal" {...form.register('fineCapPkr')} />
        {err('fineCapPkr')}
      </div>
      <div className="space-y-1">
        <Label htmlFor="pol-block">Block borrowing at unpaid fines of (PKR)</Label>
        <Input id="pol-block" inputMode="decimal" {...form.register('blockThresholdPkr')} />
        {err('blockThresholdPkr')}
      </div>
      <label className="flex items-end gap-2 pb-2 text-sm">
        <input type="checkbox" {...form.register('countWorkingDaysOnly')} />
        Fine working days only
      </label>
      <div className="flex items-end gap-3 md:col-span-4">
        <Button type="submit" disabled={pending} data-testid="save-policy">
          Save policy
        </Button>
        {error && (
          <p role="alert" className="text-sm text-destructive" data-testid="policy-error">
            {error}
          </p>
        )}
      </div>
    </form>
  );
}
