'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createCampus } from './actions';
import { createCampusSchema, type CreateCampusInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export function CreateCampusForm() {
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<CreateCampusInput>({ resolver: zodResolver(createCampusSchema) });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('code', values.code);
    fd.set('name', values.name);
    if (values.city) fd.set('city', values.city);
    startTransition(async () => {
      const result = await createCampus({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`Campus "${values.name}" created.`);
        reset();
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-[1fr_2fr_2fr_auto] items-end gap-2" noValidate>
      <div className="space-y-1">
        <Label htmlFor="code">Code</Label>
        <Input id="code" placeholder="DHA" {...register('code')} />
        {errors.code && <p className="text-xs text-destructive">{errors.code.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="name">Name</Label>
        <Input id="name" placeholder="DHA Campus" {...register('name')} />
        {errors.name && <p className="text-xs text-destructive">{errors.name.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="city">City</Label>
        <Input id="city" placeholder="Lahore" {...register('city')} />
      </div>
      <Button type="submit" disabled={pending}>
        {pending ? 'Adding…' : 'Add campus'}
      </Button>
    </form>
  );
}
