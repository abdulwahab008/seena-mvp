'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createSession } from './actions';
import { createSessionSchema, type CreateSessionInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export function CreateSessionForm({ campusId }: { campusId: string }) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
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
        <Input id="session-starts" type="date" {...register('startsOn')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="session-ends">Ends</Label>
        <Input id="session-ends" type="date" {...register('endsOn')} />
        {errors.endsOn && <p className="text-xs text-destructive">{errors.endsOn.message}</p>}
      </div>
      <Button type="submit" disabled={pending}>
        {pending ? 'Adding…' : 'Add session'}
      </Button>
    </form>
  );
}
