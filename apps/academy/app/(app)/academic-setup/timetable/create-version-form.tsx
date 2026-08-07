'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createTimetableVersion } from './actions';
import { createTimetableVersionSchema, BELL_SHIFTS, type CreateTimetableVersionInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export function CreateVersionForm({ campusId, sessionId }: { campusId: string; sessionId: string }) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    control,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<CreateTimetableVersionInput>({ resolver: zodResolver(createTimetableVersionSchema), defaultValues: { shift: 'MORNING', name: '' } });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('shift', values.shift);
    fd.set('name', values.name);

    startTransition(async () => {
      const result = await createTimetableVersion(campusId, sessionId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`${values.name} created.`);
        reset({ shift: 'MORNING', name: '' });
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-4" data-testid="create-version-form" noValidate>
      <div className="space-y-1">
        <Label htmlFor="version-shift">Shift</Label>
        <Controller
          control={control}
          name="shift"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="version-shift-trigger">
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
      <div className="col-span-2 space-y-1">
        <Label htmlFor="version-name">Name</Label>
        <Input id="version-name" placeholder="Draft v1" {...register('name')} />
        {errors.name && <p className="text-xs text-destructive">{errors.name.message}</p>}
      </div>
      <Button type="submit" disabled={pending} data-testid="create-version-button" className="self-end">
        {pending ? 'Creating…' : 'Create draft version'}
      </Button>
    </form>
  );
}
