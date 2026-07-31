'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { setDocumentRequirement } from './actions';
import { setDocumentRequirementSchema, DOCUMENT_TYPES, type SetDocumentRequirementInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

type ClassLevel = { id: string; name_en: string; ordinal: number };

export function RequirementForm({ campusId, classLevels }: { campusId: string; classLevels: ClassLevel[] }) {
  const [pending, startTransition] = useTransition();
  const {
    handleSubmit,
    control,
    reset,
    formState: { errors },
  } = useForm<SetDocumentRequirementInput>({
    resolver: zodResolver(setDocumentRequirementSchema),
    defaultValues: { campusId, isMandatory: true, minCount: 1 },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('minClassOrdinal', String(values.minClassOrdinal));
    fd.set('maxClassOrdinal', String(values.maxClassOrdinal));
    fd.set('docType', values.docType);
    if (values.isMandatory) fd.set('isMandatory', 'on');
    fd.set('minCount', String(values.minCount));

    startTransition(async () => {
      const result = await setDocumentRequirement(campusId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Requirement saved.');
        reset({ campusId, isMandatory: true, minCount: 1 });
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-5" noValidate>
      <div className="space-y-1">
        <Label htmlFor="docType">Document</Label>
        <Controller
          control={control}
          name="docType"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="doc-type-trigger">
                <SelectValue placeholder="Select a document" />
              </SelectTrigger>
              <SelectContent>
                {DOCUMENT_TYPES.map((d) => (
                  <SelectItem key={d} value={d}>
                    {d.replace(/_/g, ' ')}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
        {errors.docType && <p className="text-xs text-destructive">{errors.docType.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="minClassOrdinal">From class</Label>
        <Controller
          control={control}
          name="minClassOrdinal"
          render={({ field }) => (
            <Select value={field.value?.toString()} onValueChange={(v) => field.onChange(Number(v))}>
              <SelectTrigger data-testid="doc-min-class-trigger">
                <SelectValue placeholder="From" />
              </SelectTrigger>
              <SelectContent>
                {classLevels.map((c) => (
                  <SelectItem key={c.id} value={c.ordinal.toString()}>
                    {c.name_en}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="maxClassOrdinal">To class</Label>
        <Controller
          control={control}
          name="maxClassOrdinal"
          render={({ field }) => (
            <Select value={field.value?.toString()} onValueChange={(v) => field.onChange(Number(v))}>
              <SelectTrigger data-testid="doc-max-class-trigger">
                <SelectValue placeholder="To" />
              </SelectTrigger>
              <SelectContent>
                {classLevels.map((c) => (
                  <SelectItem key={c.id} value={c.ordinal.toString()}>
                    {c.name_en}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
        {errors.maxClassOrdinal && <p className="text-xs text-destructive">{errors.maxClassOrdinal.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="minCount">Count required</Label>
        <Controller
          control={control}
          name="minCount"
          render={({ field }) => (
            <Input id="minCount" type="number" min={1} value={field.value ?? 1} onChange={(e) => field.onChange(Number(e.target.value))} />
          )}
        />
        {errors.minCount && <p className="text-xs text-destructive">{errors.minCount.message}</p>}
      </div>
      <Controller
        control={control}
        name="isMandatory"
        render={({ field }) => (
          <label className="flex items-center gap-2 self-end pb-2 text-sm">
            <input type="checkbox" checked={field.value} onChange={(e) => field.onChange(e.target.checked)} />
            Mandatory
          </label>
        )}
      />
      <Button type="submit" disabled={pending} className="col-span-full w-fit">
        {pending ? 'Saving…' : 'Save requirement'}
      </Button>
    </form>
  );
}
