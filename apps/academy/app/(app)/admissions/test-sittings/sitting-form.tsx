'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createTestSitting } from './actions';
import { createTestSittingSchema, type CreateTestSittingInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

type ClassLevel = { id: string; name_en: string };

export function SittingForm({ campusId, sessionId, classLevels }: { campusId: string; sessionId: string; classLevels: ClassLevel[] }) {
  const [pending, startTransition] = useTransition();
  const {
    handleSubmit,
    control,
    register,
    reset,
    formState: { errors },
  } = useForm<CreateTestSittingInput>({
    resolver: zodResolver(createTestSittingSchema),
    defaultValues: { campusId, sessionId, capacity: 30 },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('classLevelId', values.classLevelId);
    fd.set('startsAt', values.startsAt);
    fd.set('capacity', String(values.capacity));
    if (values.venue) fd.set('venue', values.venue);

    startTransition(async () => {
      const result = await createTestSitting(campusId, sessionId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Test sitting scheduled.');
        reset({ campusId, sessionId, capacity: 30 });
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-5" noValidate>
      <div className="space-y-1">
        <Label htmlFor="classLevelId">Class</Label>
        <Controller
          control={control}
          name="classLevelId"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="sitting-class-trigger">
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
        {errors.classLevelId && <p className="text-xs text-destructive">{errors.classLevelId.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="startsAt">Starts at</Label>
        <Input id="startsAt" type="datetime-local" {...register('startsAt')} />
        {errors.startsAt && <p className="text-xs text-destructive">{errors.startsAt.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="venue">Venue</Label>
        <Input id="venue" placeholder="Main hall" {...register('venue')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="capacity">Capacity</Label>
        <Input id="capacity" type="number" min={1} {...register('capacity')} />
        {errors.capacity && <p className="text-xs text-destructive">{errors.capacity.message}</p>}
      </div>
      <Button type="submit" disabled={pending} className="col-span-full w-fit self-end">
        {pending ? 'Scheduling…' : 'Schedule sitting'}
      </Button>
    </form>
  );
}
