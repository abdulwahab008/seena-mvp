'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createConcessionScheme } from './actions';
import { createConcessionSchemeSchema, CONCESSION_CALC_TYPES, type CreateConcessionSchemeInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

type FeeHead = { id: string; code: string; name_en: string };

export function CreateSchemeForm({ feeHeads }: { feeHeads: FeeHead[] }) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    control,
    reset,
    formState: { errors },
  } = useForm<CreateConcessionSchemeInput>({
    resolver: zodResolver(createConcessionSchemeSchema),
    defaultValues: { calcType: 'percentage', requiresDocument: false, applicableHeadIds: [] },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('code', values.code);
    fd.set('nameEn', values.nameEn);
    fd.set('nameUr', values.nameUr);
    fd.set('calcType', values.calcType);
    fd.set('value', String(values.value));
    values.applicableHeadIds.forEach((id) => fd.append('applicableHeadIds', id));
    if (values.requiresDocument) fd.set('requiresDocument', 'on');

    startTransition(async () => {
      const result = await createConcessionScheme({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`${values.nameEn} created.`);
        reset({ calcType: 'percentage', requiresDocument: false, applicableHeadIds: [], code: '', nameEn: '', nameUr: '' });
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-4" noValidate>
      <div className="space-y-1">
        <Label htmlFor="code">Code</Label>
        <Input id="code" placeholder="SIBLING2" {...register('code')} />
        {errors.code && <p className="text-xs text-destructive">{errors.code.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="nameEn">Name (English)</Label>
        <Input id="nameEn" placeholder="Sibling 2nd Child" {...register('nameEn')} />
        {errors.nameEn && <p className="text-xs text-destructive">{errors.nameEn.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="nameUr">Name (Urdu)</Label>
        <Input id="nameUr" placeholder="دوسرا بہن بھائی" {...register('nameUr')} />
        {errors.nameUr && <p className="text-xs text-destructive">{errors.nameUr.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="calcType">Type</Label>
        <Controller
          control={control}
          name="calcType"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="concession-calc-type-trigger">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {CONCESSION_CALC_TYPES.map((t) => (
                  <SelectItem key={t} value={t}>
                    {t.replace(/_/g, ' ')}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="value">Value (% or PKR)</Label>
        <Input id="value" type="number" step="0.01" placeholder="10" {...register('value')} />
        {errors.value && <p className="text-xs text-destructive">{errors.value.message}</p>}
      </div>
      <div className="col-span-2 space-y-1 md:col-span-3">
        <Label>Applies to</Label>
        <div className="flex flex-wrap gap-3">
          {feeHeads.map((h) => (
            <label key={h.id} className="flex items-center gap-1 text-sm">
              <input type="checkbox" value={h.id} {...register('applicableHeadIds')} />
              {h.name_en}
            </label>
          ))}
        </div>
        {errors.applicableHeadIds && <p className="text-xs text-destructive">{errors.applicableHeadIds.message}</p>}
      </div>
      <label className="flex items-center gap-2 self-end pb-2 text-sm">
        <input type="checkbox" {...register('requiresDocument')} />
        Requires supporting document
      </label>
      <Button type="submit" disabled={pending} className="col-span-2 w-fit md:col-span-1">
        {pending ? 'Saving…' : 'Add scheme'}
      </Button>
    </form>
  );
}
