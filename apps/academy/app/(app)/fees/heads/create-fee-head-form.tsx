'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createFeeHead } from './actions';
import { createFeeHeadSchema, FEE_FREQUENCIES, type CreateFeeHeadInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export function CreateFeeHeadForm() {
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    control,
    reset,
    formState: { errors },
  } = useForm<CreateFeeHeadInput>({
    resolver: zodResolver(createFeeHeadSchema),
    defaultValues: { isRefundable: false, defaultFrequency: 'monthly' },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('code', values.code);
    fd.set('nameEn', values.nameEn);
    fd.set('nameUr', values.nameUr);
    if (values.isRefundable) fd.set('isRefundable', 'on');
    fd.set('defaultFrequency', values.defaultFrequency);

    startTransition(async () => {
      const result = await createFeeHead({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`${values.nameEn} created.`);
        reset({ isRefundable: false, defaultFrequency: 'monthly', code: '', nameEn: '', nameUr: '' });
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-4" noValidate>
      <div className="space-y-1">
        <Label htmlFor="code">Code</Label>
        <Input id="code" placeholder="LIBRARY" {...register('code')} />
        {errors.code && <p className="text-xs text-destructive">{errors.code.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="nameEn">Name (English)</Label>
        <Input id="nameEn" placeholder="Library Fee" {...register('nameEn')} />
        {errors.nameEn && <p className="text-xs text-destructive">{errors.nameEn.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="nameUr">Name (Urdu)</Label>
        <Input id="nameUr" placeholder="لائبریری فیس" {...register('nameUr')} />
        {errors.nameUr && <p className="text-xs text-destructive">{errors.nameUr.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="defaultFrequency">Frequency</Label>
        <Controller
          control={control}
          name="defaultFrequency"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="fee-head-frequency-trigger">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {FEE_FREQUENCIES.map((f) => (
                  <SelectItem key={f} value={f}>
                    {f.replace(/_/g, ' ')}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>
      <label className="flex items-center gap-2 self-end pb-2 text-sm">
        <input type="checkbox" {...register('isRefundable')} />
        Refundable (e.g. security deposit)
      </label>
      <Button type="submit" disabled={pending} className="col-span-full w-fit">
        {pending ? 'Saving…' : 'Add fee head'}
      </Button>
    </form>
  );
}
