'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { addStructureLine } from './actions';
import { addStructureLineSchema, MONTH_LABELS, FEE_FREQUENCIES, type AddStructureLineInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

type ClassLevel = { id: string; name_en: string };
type FeeHead = { id: string; code: string; name_en: string };

export function StructureLineForm({ structureId, classLevels, feeHeads }: { structureId: string; classLevels: ClassLevel[]; feeHeads: FeeHead[] }) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    control,
    reset,
    formState: { errors },
  } = useForm<AddStructureLineInput>({
    resolver: zodResolver(addStructureLineSchema),
    defaultValues: { structureId, classId: '', groupCode: '', feeHeadId: '', frequency: 'monthly', months: [] },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('structureId', structureId);
    fd.set('classId', values.classId);
    if (values.groupCode) fd.set('groupCode', values.groupCode);
    fd.set('feeHeadId', values.feeHeadId);
    fd.set('amountRupees', String(values.amountRupees));
    fd.set('frequency', values.frequency);
    values.months.forEach((m) => fd.append('months', String(m)));

    startTransition(async () => {
      const result = await addStructureLine({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Line added.');
        reset({ structureId, classId: '', groupCode: '', feeHeadId: '', frequency: 'monthly', months: [] });
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-4" noValidate>
      <div className="space-y-1">
        <Label htmlFor="classId">Class</Label>
        <Controller
          control={control}
          name="classId"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="structure-line-class-trigger">
                <SelectValue placeholder="Select a class" />
              </SelectTrigger>
              <SelectContent>
                {classLevels.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.name_en}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
        {errors.classId && <p className="text-xs text-destructive">{errors.classId.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="groupCode">Group (optional)</Label>
        <Input id="groupCode" placeholder="pre_medical" {...register('groupCode')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="feeHeadId">Fee head</Label>
        <Controller
          control={control}
          name="feeHeadId"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="structure-line-head-trigger">
                <SelectValue placeholder="Select a fee head" />
              </SelectTrigger>
              <SelectContent>
                {feeHeads.map((h) => (
                  <SelectItem key={h.id} value={h.id}>
                    {h.name_en} ({h.code})
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
        {errors.feeHeadId && <p className="text-xs text-destructive">{errors.feeHeadId.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="amountRupees">Amount (PKR)</Label>
        <Input id="amountRupees" type="number" step="1" placeholder="5000" {...register('amountRupees')} />
        {errors.amountRupees && <p className="text-xs text-destructive">{errors.amountRupees.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="frequency">Frequency</Label>
        <Controller
          control={control}
          name="frequency"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="structure-line-frequency-trigger">
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
      <div className="col-span-2 space-y-1 md:col-span-4">
        <Label>Billing months</Label>
        <div className="flex flex-wrap gap-3">
          {MONTH_LABELS.map((label, i) => (
            <label key={label} className="flex items-center gap-1 text-sm">
              <input type="checkbox" value={i} {...register('months')} />
              {label.slice(0, 3)}
            </label>
          ))}
        </div>
        {errors.months && <p className="text-xs text-destructive">{errors.months.message}</p>}
      </div>
      <Button type="submit" disabled={pending} className="col-span-2 w-fit md:col-span-1">
        {pending ? 'Adding…' : 'Add line'}
      </Button>
    </form>
  );
}
