'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { addStructureLine } from './actions';
import { addStructureLineSchema, MONTH_LABELS, FEE_FREQUENCIES, type AddStructureLineInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export const ALL_MONTHS = Array.from({ length: 12 }, (_, i) => i);
export const frequencyLabel = (f: string) => f.replace(/_/g, ' ');

type ClassLevel = { id: string; name_en: string };
type FeeHead = { id: string; code: string; name_en: string };

export function MonthPicker({ value, onChange }: { value: number[]; onChange: (months: number[]) => void }) {
  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
      {MONTH_LABELS.map((label, i) => (
        <label key={label} className="flex items-center gap-1 text-sm">
          <input
            type="checkbox"
            checked={value.includes(i)}
            onChange={(e) => onChange(e.target.checked ? [...value, i].sort((a, b) => a - b) : value.filter((m) => m !== i))}
          />
          {label.slice(0, 3)}
        </label>
      ))}
      <Button type="button" size="sm" variant="ghost" className="h-7 px-2" onClick={() => onChange(ALL_MONTHS)}>
        All
      </Button>
      <Button type="button" size="sm" variant="ghost" className="h-7 px-2" onClick={() => onChange([])}>
        None
      </Button>
    </div>
  );
}

export function StructureLineForm({ structureId, classLevels, feeHeads }: { structureId: string; classLevels: ClassLevel[]; feeHeads: FeeHead[] }) {
  const [pending, startTransition] = useTransition();
  const empty = { structureId, classFromId: '', classToId: '', groupCode: '', feeHeadId: '', frequency: 'monthly' as const, months: ALL_MONTHS };
  const {
    register,
    handleSubmit,
    control,
    reset,
    setValue,
    formState: { errors },
  } = useForm<AddStructureLineInput>({ resolver: zodResolver(addStructureLineSchema), defaultValues: empty });

  const first = classLevels[0];
  const last = classLevels.at(-1);

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('structureId', structureId);
    fd.set('classFromId', values.classFromId);
    if (values.classToId) fd.set('classToId', values.classToId);
    if (values.groupCode) fd.set('groupCode', values.groupCode);
    fd.set('feeHeadId', values.feeHeadId);
    fd.set('amountRupees', String(values.amountRupees));
    fd.set('frequency', values.frequency);
    values.months.forEach((m) => fd.append('months', String(m)));

    startTransition(async () => {
      const result = await addStructureLine({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(result.note ?? 'Saved.');
        reset(empty);
      }
    });
  });

  const classSelect = (name: 'classFromId' | 'classToId', placeholder: string, testId: string) => (
    <Controller
      control={control}
      name={name}
      render={({ field }) => (
        <Select value={field.value ?? ''} onValueChange={field.onChange}>
          <SelectTrigger id={name} data-testid={testId}>
            <SelectValue placeholder={placeholder} />
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
  );

  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="text-base">Set a fee</CardTitle>
        <CardDescription>
          Pick a class range, e.g. Class 1 to Class 5. Classes that already have this fee head get the new amount.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-4" noValidate>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <div className="space-y-1">
              <Label htmlFor="classFromId">From class</Label>
              {classSelect('classFromId', 'Select a class', 'structure-line-class-trigger')}
              {errors.classFromId && <p className="text-xs text-destructive">{errors.classFromId.message}</p>}
            </div>
            <div className="space-y-1">
              <div className="flex h-6 items-center justify-between">
                <Label htmlFor="classToId">To class</Label>
                {first && last && (
                  <button
                    type="button"
                    className="text-xs text-primary hover:underline"
                    onClick={() => {
                      setValue('classFromId', first.id);
                      setValue('classToId', last.id);
                    }}
                  >
                    All classes
                  </button>
                )}
              </div>
              {classSelect('classToId', 'Same class', 'structure-line-class-to-trigger')}
            </div>
            <div className="space-y-1">
              <Label htmlFor="feeHeadId">Fee head</Label>
              <Controller
                control={control}
                name="feeHeadId"
                render={({ field }) => (
                  <Select value={field.value} onValueChange={field.onChange}>
                    <SelectTrigger id="feeHeadId" data-testid="structure-line-head-trigger">
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
              <Input id="amountRupees" type="number" step="1" min="0" placeholder="3000" {...register('amountRupees')} />
              {errors.amountRupees && <p className="text-xs text-destructive">{errors.amountRupees.message}</p>}
            </div>
            <div className="space-y-1">
              <Label htmlFor="frequency">Frequency</Label>
              <Controller
                control={control}
                name="frequency"
                render={({ field }) => (
                  <Select value={field.value} onValueChange={field.onChange}>
                    <SelectTrigger id="frequency" data-testid="structure-line-frequency-trigger">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {FEE_FREQUENCIES.map((f) => (
                        <SelectItem key={f} value={f}>
                          {frequencyLabel(f)}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                )}
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="groupCode">Group (optional)</Label>
              <Input id="groupCode" placeholder="e.g. pre_medical" {...register('groupCode')} />
            </div>
          </div>
          <div className="space-y-1">
            <Label>Billing months</Label>
            <Controller control={control} name="months" render={({ field }) => <MonthPicker value={field.value} onChange={field.onChange} />} />
            {errors.months && <p className="text-xs text-destructive">{errors.months.message}</p>}
          </div>
          <Button type="submit" disabled={pending}>
            {pending ? 'Saving…' : 'Add line'}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}
