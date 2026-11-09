'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useFieldArray, useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { postDueRecurringJournals, saveRecurringJournal, setRecurringJournalActive } from '../actions';
import { todayPk } from '@/lib/dates';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';
const money = (v: string) => Number(v || 0);

const schema = z.object({
  name: z.string().trim().min(1, 'Enter a name').max(150),
  narration: z.string().trim().min(1, 'Enter a narration').max(500),
  frequency: z.enum(['monthly', 'quarterly', 'yearly']),
  nextRun: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the next due date'),
  lines: z.array(z.object({ accountId: z.string(), costCenterId: z.string(), debit: z.string(), credit: z.string(), memo: z.string() })),
});
export type RecurringValues = z.infer<typeof schema>;
const blankLine = { accountId: '', costCenterId: '', debit: '', credit: '', memo: '' };

export function RecurringForm({
  id,
  initial,
  accounts,
  costCenters,
}: {
  id?: string;
  initial?: RecurringValues;
  accounts: { id: string; label: string }[];
  costCenters: { id: string; label: string }[];
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const blank: RecurringValues = { name: '', narration: '', frequency: 'monthly', nextRun: todayPk(), lines: [blankLine, blankLine] };
  const { register, control, handleSubmit, watch, reset, formState: { errors } } = useForm<RecurringValues>({
    resolver: zodResolver(schema),
    defaultValues: initial ?? blank,
  });
  const { fields, append, remove } = useFieldArray({ control, name: 'lines' });
  const lines = watch('lines');
  const dr = lines.reduce((s, l) => s + money(l.debit), 0);
  const cr = lines.reduce((s, l) => s + money(l.credit), 0);

  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveRecurringJournal({ ...v, id, lines: v.lines.filter((l) => l.accountId && (money(l.debit) || money(l.credit))) });
      if (r.error) return void toast.error(r.error);
      toast.success(id ? 'Recurring voucher saved.' : 'Recurring voucher added.');
      if (id) router.push('/accounts/recurring');
      else reset(blank);
    }),
  );

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">{id ? 'Edit recurring voucher' : 'New recurring voucher'}</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-3" noValidate>
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="space-y-1">
              <Label htmlFor="rj-name">Name</Label>
              <Input id="rj-name" placeholder="Building rent" {...register('name')} />
              {errors.name && <p className="text-sm text-destructive">{errors.name.message}</p>}
            </div>
            <div className="space-y-1">
              <Label htmlFor="rj-narration">Narration on each voucher</Label>
              <Input id="rj-narration" {...register('narration')} />
              {errors.narration && <p className="text-sm text-destructive">{errors.narration.message}</p>}
            </div>
            <div className="space-y-1">
              <Label htmlFor="rj-frequency">Repeats</Label>
              <select id="rj-frequency" className={SELECT} {...register('frequency')}>
                <option value="monthly">Every month</option>
                <option value="quarterly">Every quarter</option>
                <option value="yearly">Every year</option>
              </select>
            </div>
            <div className="space-y-1">
              <Label htmlFor="rj-next">Next due</Label>
              <Input id="rj-next" type="date" {...register('nextRun')} />
              {errors.nextRun && <p className="text-sm text-destructive">{errors.nextRun.message}</p>}
            </div>
          </div>
          <div className="space-y-2">
            {fields.map((f, i) => (
              <div key={f.id} className="grid gap-2 sm:grid-cols-[1fr_10rem_8rem_8rem_1fr_auto]">
                <select aria-label={`Account, line ${i + 1}`} className={SELECT} {...register(`lines.${i}.accountId`)}>
                  <option value="">Account</option>
                  {accounts.map((a) => (
                    <option key={a.id} value={a.id}>
                      {a.label}
                    </option>
                  ))}
                </select>
                <select aria-label={`Cost centre, line ${i + 1}`} className={SELECT} {...register(`lines.${i}.costCenterId`)}>
                  <option value="">No cost centre</option>
                  {costCenters.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.label}
                    </option>
                  ))}
                </select>
                <Input aria-label={`Debit, line ${i + 1}`} placeholder="Debit" inputMode="decimal" {...register(`lines.${i}.debit`)} />
                <Input aria-label={`Credit, line ${i + 1}`} placeholder="Credit" inputMode="decimal" {...register(`lines.${i}.credit`)} />
                <Input aria-label={`Memo, line ${i + 1}`} placeholder="Memo" {...register(`lines.${i}.memo`)} />
                <Button type="button" variant="ghost" size="sm" onClick={() => remove(i)} disabled={fields.length <= 2}>
                  Remove
                </Button>
              </div>
            ))}
          </div>
          <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
            <Button type="button" variant="outline" size="sm" onClick={() => append(blankLine)}>
              Add line
            </Button>
            <span className={dr === cr && dr > 0 ? 'text-success' : 'text-destructive'} data-testid="rj-totals">
              Debits {dr.toLocaleString('en-PK')} · Credits {cr.toLocaleString('en-PK')}
              {dr !== cr ? ` · off by ${Math.abs(dr - cr).toLocaleString('en-PK')}` : ''}
            </span>
          </div>
          <div className="flex gap-2">
            <Button type="submit" disabled={pending || dr !== cr || dr === 0}>
              {id ? 'Save changes' : 'Add recurring voucher'}
            </Button>
            {id && (
              <Button type="button" variant="outline" onClick={() => router.push('/accounts/recurring')} disabled={pending}>
                Cancel
              </Button>
            )}
          </div>
        </form>
      </CardContent>
    </Card>
  );
}

export function PostDueButton({ due }: { due: number }) {
  const [pending, startTransition] = useTransition();
  return (
    <Button
      disabled={pending || due === 0}
      onClick={() =>
        startTransition(async () => {
          const r = await postDueRecurringJournals();
          if (r.error) return void toast.error(r.error);
          toast.success(r.posted === 0 ? 'Nothing is due.' : `Posted ${r.posted} ${r.posted === 1 ? 'voucher' : 'vouchers'}.`);
        })
      }
    >
      Post due now
    </Button>
  );
}

export function RecurringActiveButton({ id, name, isActive }: { id: string; name: string; isActive: boolean }) {
  const [pending, startTransition] = useTransition();
  return (
    <Button
      size="sm"
      variant="ghost"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await setRecurringJournalActive(id, !isActive);
          if (r.error) return void toast.error(r.error);
          toast.success(`${name} ${isActive ? 'paused' : 'resumed'}.`);
        })
      }
    >
      {isActive ? 'Pause' : 'Resume'}
    </Button>
  );
}
