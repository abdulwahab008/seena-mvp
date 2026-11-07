'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { todayPk } from '@/lib/dates';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { setInstallments } from './actions';
import { installmentFormSchema, type InstallmentFormInput } from './plan';

export function InstallmentForm() {
  const [pending, startTransition] = useTransition();
  const blank: InstallmentFormInput = { challanNo: '', parts: '3', firstDue: todayPk() };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<InstallmentFormInput>({ resolver: zodResolver(installmentFormSchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await setInstallments(v);
      if (r.error) return void toast.error(r.error);
      toast.success(`Challan split into ${r.parts} monthly installments.`);
      reset(blank);
    }),
  );
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Split a challan</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-4" noValidate>
          <div className="space-y-1">
            <Label htmlFor="in-challan">Challan number</Label>
            <Input id="in-challan" {...register('challanNo')} />
            {errors.challanNo && <p className="text-sm text-destructive">{errors.challanNo.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="in-parts">Installments</Label>
            <Input id="in-parts" inputMode="numeric" {...register('parts')} />
            {errors.parts && <p className="text-sm text-destructive">{errors.parts.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="in-first">First due on</Label>
            <Input id="in-first" type="date" {...register('firstDue')} />
            {errors.firstDue && <p className="text-sm text-destructive">{errors.firstDue.message}</p>}
          </div>
          <div className="flex items-end">
            <Button type="submit" disabled={pending}>
              Split into installments
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  );
}
