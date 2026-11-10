'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { decideStudentLeave } from './actions';

const schema = z.object({ note: z.string().trim().max(500, 'Keep it under 500 characters') });

export function DecideButtons({ id }: { id: string }) {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, formState: { errors } } = useForm<z.infer<typeof schema>>({ resolver: zodResolver(schema), defaultValues: { note: '' } });
  const decide = (approve: boolean) =>
    handleSubmit((v) =>
      startTransition(async () => {
        const res = await decideStudentLeave({ id, approve, note: v.note });
        if (res.error) toast.error(res.error);
        else toast.success(approve ? 'Leave approved.' : 'Leave rejected.');
      }),
    )();

  return (
    <div className="flex flex-wrap items-center gap-2">
      <input {...register('note')} placeholder="Note (optional)" aria-label="Decision note" className="h-8 w-40 rounded-md border bg-background px-2 text-sm" />
      <Button type="button" size="sm" disabled={pending} onClick={() => decide(true)}>
        Approve
      </Button>
      <Button type="button" size="sm" variant="outline" disabled={pending} onClick={() => decide(false)}>
        Reject
      </Button>
      {errors.note && <p className="w-full text-xs text-destructive">{errors.note.message}</p>}
    </div>
  );
}
