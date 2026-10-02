'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createSession } from './actions';
import { createSessionSchema, type CreateSessionInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { DatePicker } from '@/components/ui/date-picker';

export function CreateSessionForm({ campusId }: { campusId: string }) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    control,
    reset,
    formState: { errors },
  } = useForm<CreateSessionInput>({ resolver: zodResolver(createSessionSchema) });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('name', values.name);
    fd.set('startsOn', values.startsOn);
    fd.set('endsOn', values.endsOn);
    startTransition(async () => {
      const result = await createSession(campusId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`Session "${values.name}" created.`);
        reset();
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-[1fr_1fr_1fr_auto] items-end gap-2" noValidate>
      <div className="space-y-1">
        <Label htmlFor="session-name">Name</Label>
        <Input id="session-name" placeholder="2027-28" {...register('name')} />
        {errors.name && <p className="text-xs text-destructive">{errors.name.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="session-starts">Starts</Label>
        <Controller
          control={control}
          name="startsOn"
          render={({ field }) => (
            <DatePicker
              id="session-starts"
              name="startsOn"
              value={field.value}
              onChange={field.onChange}
              onBlur={field.onBlur}
              placeholder="Start date"
              data-testid="session-starts"
            />
          )}
        />
        {errors.startsOn && <p className="text-xs text-destructive">{errors.startsOn.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="session-ends">Ends</Label>
        <Controller
          control={control}
          name="endsOn"
          render={({ field }) => (
            <DatePicker
              id="session-ends"
              name="endsOn"
              value={field.value}
              onChange={field.onChange}
              onBlur={field.onBlur}
              placeholder="End date"
              data-testid="session-ends"
            />
          )}
        />
        {errors.endsOn && <p className="text-xs text-destructive">{errors.endsOn.message}</p>}
      </div>
      <Button type="submit" disabled={pending}>
        {pending ? 'Adding…' : 'Add session'}
      </Button>
    </form>
  );
}
