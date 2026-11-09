'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { savePayScale } from './actions';
import { payScaleSchema, type PayScaleInput } from './schema';

const BLANK: PayScaleInput = { id: '', code: '', name: '', minPkr: '', maxPkr: '', incrementPkr: '0' };

export function PayScaleForm({ initial }: { initial?: PayScaleInput }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, reset, formState: { errors } } = useForm<PayScaleInput>({ resolver: zodResolver(payScaleSchema), defaultValues: initial ?? BLANK });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await savePayScale(v);
      if (r.error) return void toast.error(r.error);
      toast.success(initial ? 'Pay scale updated.' : 'Pay scale added.');
      if (initial) router.push('/payroll/pay-scales');
      else reset(BLANK);
    }),
  );
  const field = (name: Exclude<keyof PayScaleInput, 'id'>, label: string, numeric = false) => (
    <div className="space-y-1">
      <Label htmlFor={`ps-${name}`}>{label}</Label>
      <Input id={`ps-${name}`} inputMode={numeric ? 'numeric' : undefined} {...register(name)} />
      {errors[name] && <p className="text-sm text-destructive">{errors[name]?.message}</p>}
    </div>
  );
  return (
    <form onSubmit={onSubmit} className="grid gap-2 sm:grid-cols-3" noValidate>
      {field('code', 'Code')}
      {field('name', 'Name')}
      {field('minPkr', 'Minimum basic (PKR)', true)}
      {field('maxPkr', 'Maximum basic (PKR)', true)}
      {field('incrementPkr', 'Annual increment (PKR)', true)}
      <div className="flex items-end gap-2">
        <Button type="submit" disabled={pending}>
          {initial ? 'Save changes' : 'Add pay scale'}
        </Button>
        {initial && (
          <Button type="button" variant="outline" onClick={() => router.push('/payroll/pay-scales')}>
            Cancel
          </Button>
        )}
      </div>
    </form>
  );
}
