'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { addProvidentFund } from './actions';
import { pfSchema, type PfInput } from './schema';

export function ProvidentFundForm() {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, formState: { errors } } = useForm<PfInput>({ resolver: zodResolver(pfSchema), defaultValues: { employeePct: '5', employerPct: '5' } });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await addProvidentFund(v);
      if (r.error) return void toast.error(r.error);
      toast.success('Provident fund added to payroll.');
    }),
  );
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2" noValidate>
      <div className="space-y-1">
        <Label htmlFor="pf-ee">Employee share (% of basic)</Label>
        <Input id="pf-ee" inputMode="decimal" className="w-28" {...register('employeePct')} />
        {errors.employeePct && <p className="text-sm text-destructive">{errors.employeePct.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="pf-er">School share (% of basic)</Label>
        <Input id="pf-er" inputMode="decimal" className="w-28" {...register('employerPct')} />
        {errors.employerPct && <p className="text-sm text-destructive">{errors.employerPct.message}</p>}
      </div>
      <Button type="submit" disabled={pending}>
        Add provident fund
      </Button>
    </form>
  );
}
