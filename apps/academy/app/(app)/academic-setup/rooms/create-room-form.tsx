'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createRoom } from './actions';
import { createRoomSchema, ROOM_TYPES, type CreateRoomInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export function CreateRoomForm({ campusId }: { campusId: string }) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    control,
    reset,
    formState: { errors },
  } = useForm<CreateRoomInput>({
    resolver: zodResolver(createRoomSchema),
    defaultValues: { roomType: 'CLASSROOM' },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('code', values.code);
    fd.set('name', values.name);
    fd.set('roomType', values.roomType);
    fd.set('capacity', String(values.capacity));
    if (values.blockLabel) fd.set('blockLabel', values.blockLabel);

    startTransition(async () => {
      const result = await createRoom(campusId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`${values.name} added.`);
        reset({ roomType: 'CLASSROOM', code: '', name: '', blockLabel: '' });
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-5" noValidate>
      <div className="space-y-1">
        <Label htmlFor="code">Code</Label>
        <Input id="code" placeholder="SL-1" {...register('code')} />
        {errors.code && <p className="text-xs text-destructive">{errors.code.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="name">Name</Label>
        <Input id="name" placeholder="Science Lab 1" {...register('name')} />
        {errors.name && <p className="text-xs text-destructive">{errors.name.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="roomType">Type</Label>
        <Controller
          control={control}
          name="roomType"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid="room-type-trigger">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {ROOM_TYPES.map((t) => (
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
        <Label htmlFor="capacity">Capacity</Label>
        <Input id="capacity" type="number" min={1} {...register('capacity')} />
        {errors.capacity && <p className="text-xs text-destructive">{errors.capacity.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="blockLabel">Block (optional)</Label>
        <Input id="blockLabel" placeholder="Block C" {...register('blockLabel')} />
      </div>
      <Button type="submit" disabled={pending} className="col-span-full w-fit">
        {pending ? 'Saving…' : 'Add room'}
      </Button>
    </form>
  );
}
