'use client';

import { useTransition } from 'react';
import { useForm, useFieldArray, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createBellTemplate } from './actions';
import { createBellTemplateSchema, BELL_SEGMENT_KINDS, BELL_SHIFTS, type CreateBellTemplateInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

const EMPTY_SEGMENT = { kind: 'TEACHING' as const, startTime: '', endTime: '' };
const DEFAULT_VALUES: CreateBellTemplateInput = { shift: 'MORNING', code: '', name: '', segments: [EMPTY_SEGMENT], isDefault: false };

export function CreateBellTemplateForm({ campusId }: { campusId: string }) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    control,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<CreateBellTemplateInput>({ resolver: zodResolver(createBellTemplateSchema), defaultValues: DEFAULT_VALUES });
  const { fields, append, remove } = useFieldArray({ control, name: 'segments' });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('shift', values.shift);
    fd.set('code', values.code);
    fd.set('name', values.name);
    fd.set('segments', JSON.stringify(values.segments));
    if (values.isDefault) fd.set('isDefault', 'on');

    startTransition(async () => {
      const result = await createBellTemplate(campusId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`${values.name} created.`);
        reset(DEFAULT_VALUES);
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="space-y-3 rounded-lg border p-4" data-testid="create-bell-template-form" noValidate>
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <div className="space-y-1">
          <Label htmlFor="shift">Shift</Label>
          <Controller
            control={control}
            name="shift"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="bell-shift-trigger">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {BELL_SHIFTS.map((s) => (
                    <SelectItem key={s} value={s}>
                      {s}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="code">Code</Label>
          <Input id="code" placeholder="REGULAR" {...register('code')} />
          {errors.code && <p className="text-xs text-destructive">{errors.code.message}</p>}
        </div>
        <div className="col-span-2 space-y-1">
          <Label htmlFor="name">Name</Label>
          <Input id="name" placeholder="Regular Morning" {...register('name')} />
          {errors.name && <p className="text-xs text-destructive">{errors.name.message}</p>}
        </div>
      </div>

      <div className="space-y-2">
        {fields.map((field, i) => (
          <div key={field.id} className="grid grid-cols-[1fr_1fr_1fr_auto] items-center gap-2">
            <Controller
              control={control}
              name={`segments.${i}.kind`}
              render={({ field: kindField }) => (
                <Select value={kindField.value} onValueChange={kindField.onChange}>
                  <SelectTrigger data-testid={`segment-kind-trigger-${i}`}>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {BELL_SEGMENT_KINDS.map((k) => (
                      <SelectItem key={k} value={k}>
                        {k}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}
            />
            <Input type="time" data-testid={`segment-start-${i}`} {...register(`segments.${i}.startTime`)} />
            <Input type="time" data-testid={`segment-end-${i}`} {...register(`segments.${i}.endTime`)} />
            <Button type="button" variant="ghost" size="sm" onClick={() => remove(i)} disabled={fields.length <= 1}>
              Remove
            </Button>
          </div>
        ))}
        {errors.segments?.root?.message && <p className="text-sm text-destructive">{errors.segments.root.message}</p>}
        <Button type="button" variant="outline" size="sm" data-testid="add-segment-button" onClick={() => append(EMPTY_SEGMENT)}>
          Add segment
        </Button>
      </div>

      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" {...register('isDefault')} />
        Set as default for this campus + shift
      </label>

      <Button type="submit" disabled={pending} data-testid="create-bell-template-button">
        {pending ? 'Saving…' : 'Create template'}
      </Button>
    </form>
  );
}
