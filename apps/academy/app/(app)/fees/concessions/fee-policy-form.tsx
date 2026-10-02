'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { setFeePolicy } from './actions';
import { setFeePolicySchema, type SetFeePolicyInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export function FeePolicyForm({ maxStackedConcessionPct }: { maxStackedConcessionPct: number | null }) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<SetFeePolicyInput>({
    resolver: zodResolver(setFeePolicySchema),
    defaultValues: { maxStackedConcessionPct: maxStackedConcessionPct ?? undefined, allowNegativeNet: false },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    if (values.maxStackedConcessionPct !== undefined) fd.set('maxStackedConcessionPct', String(values.maxStackedConcessionPct));

    startTransition(async () => {
      const result = await setFeePolicy({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Fee policy saved.');
    });
  });

  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2 rounded-lg border p-4" noValidate>
      <div className="space-y-1">
        <Label htmlFor="maxStackedConcessionPct">Max stacked concession (%)</Label>
        <Input
          id="maxStackedConcessionPct"
          type="number"
          step="0.01"
          placeholder="No cap"
          {...register('maxStackedConcessionPct')}
        />
        {errors.maxStackedConcessionPct && <p className="text-xs text-destructive">{errors.maxStackedConcessionPct.message}</p>}
      </div>
      <Button type="submit" disabled={pending} data-testid="save-fee-policy-button">
        {pending ? 'Saving…' : 'Save policy'}
      </Button>
    </form>
  );
}
