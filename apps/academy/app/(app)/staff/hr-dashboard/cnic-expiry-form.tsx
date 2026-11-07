'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { setCnicExpiry } from './actions';
import { cnicExpirySchema, type CnicExpiryInput } from './schema';

export function CnicExpiryForm() {
  const [pending, startTransition] = useTransition();
  const blank: CnicExpiryInput = { employeeCode: '', expiresOn: '' };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<CnicExpiryInput>({ resolver: zodResolver(cnicExpirySchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await setCnicExpiry(v);
      if (r.error) return void toast.error(r.error);
      toast.success('CNIC expiry saved.');
      reset(blank);
    }),
  );
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2" noValidate>
      <div className="space-y-1">
        <Label htmlFor="cx-code">Employee code</Label>
        <Input id="cx-code" {...register('employeeCode')} />
        {errors.employeeCode && <p className="text-sm text-destructive">{errors.employeeCode.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="cx-date">CNIC expires on</Label>
        <Input id="cx-date" type="date" {...register('expiresOn')} />
        {errors.expiresOn && <p className="text-sm text-destructive">{errors.expiresOn.message}</p>}
      </div>
      <Button type="submit" disabled={pending}>
        Save
      </Button>
    </form>
  );
}
