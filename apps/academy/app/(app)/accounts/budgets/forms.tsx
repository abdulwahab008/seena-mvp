'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { saveAccountBudget } from '../actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';
const AMOUNT = /^(\d+(\.\d{1,2})?)?$/;

const schema = z.object({
  accountId: z.string().uuid('Choose an account'),
  fill: z.string().regex(AMOUNT, 'Enter an amount in rupees'),
  amounts: z.array(z.string().regex(AMOUNT, 'Enter an amount in rupees')).length(12),
});
type Values = z.infer<typeof schema>;
const empty = () => Array.from({ length: 12 }, () => '');

export function BudgetForm({
  fyStartYear,
  months,
  accounts,
  existing,
}: {
  fyStartYear: number;
  months: string[];
  accounts: { id: string; label: string }[];
  existing: Record<string, string[]>;
}) {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, setValue, getValues, formState: { errors } } = useForm<Values>({
    resolver: zodResolver(schema),
    defaultValues: { accountId: '', fill: '', amounts: empty() },
  });
  const accountField = register('accountId');

  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveAccountBudget({ accountId: v.accountId, fyStartYear, amounts: v.amounts.map((a) => Number(a || 0)) });
      if (r.error) return void toast.error(r.error);
      toast.success('Budget saved.');
    }),
  );

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Set a budget</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-3" noValidate>
          <div className="grid gap-3 sm:grid-cols-[1fr_12rem_auto] sm:items-end">
            <div className="space-y-1">
              <Label htmlFor="budget-account">Account</Label>
              <select
                id="budget-account"
                className={SELECT}
                {...accountField}
                onChange={(e) => {
                  void accountField.onChange(e);
                  setValue('amounts', existing[e.target.value] ?? empty());
                }}
              >
                <option value="">Choose an income or expense account</option>
                {accounts.map((a) => (
                  <option key={a.id} value={a.id}>
                    {a.label}
                  </option>
                ))}
              </select>
              {errors.accountId && <p className="text-sm text-destructive">{errors.accountId.message}</p>}
            </div>
            <div className="space-y-1">
              <Label htmlFor="budget-fill">Same amount every month</Label>
              <Input id="budget-fill" inputMode="decimal" placeholder="0" {...register('fill')} />
            </div>
            <Button
              type="button"
              variant="outline"
              onClick={() => {
                const fill = getValues('fill');
                if (!AMOUNT.test(fill)) return void toast.error('Enter an amount in rupees.');
                setValue('amounts', Array.from({ length: 12 }, () => fill));
              }}
            >
              Fill all months
            </Button>
          </div>
          <div className="grid gap-2 sm:grid-cols-4 lg:grid-cols-6">
            {months.map((m, i) => (
              <div key={m} className="space-y-1">
                <Label htmlFor={`budget-${i}`}>{m}</Label>
                <Input id={`budget-${i}`} inputMode="decimal" placeholder="0" {...register(`amounts.${i}`)} />
              </div>
            ))}
          </div>
          {errors.amounts && <p className="text-sm text-destructive">Amounts are in rupees, up to two decimals.</p>}
          <Button type="submit" disabled={pending}>
            Save budget
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}
