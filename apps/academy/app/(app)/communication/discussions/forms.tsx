'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { postReply, postThread } from './actions';
import { replySchema, threadSchema, type ReplyInput, type ThreadInput } from './schema';

export function ThreadForm() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, formState: { errors } } = useForm<ThreadInput>({ resolver: zodResolver(threadSchema), defaultValues: { title: '', body: '' } });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await postThread(v);
      if (r.error) return void toast.error(r.error);
      router.push(`/communication/discussions/${r.id}`);
    }),
  );
  return (
    <form onSubmit={onSubmit} className="space-y-3" noValidate>
      <div className="space-y-1">
        <Label htmlFor="dt-title">Title</Label>
        <Input id="dt-title" {...register('title')} />
        {errors.title && <p className="text-sm text-destructive">{errors.title.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="dt-body">Message</Label>
        <Textarea id="dt-body" rows={4} {...register('body')} />
        {errors.body && <p className="text-sm text-destructive">{errors.body.message}</p>}
      </div>
      <Button type="submit" disabled={pending}>
        Start thread
      </Button>
    </form>
  );
}

export function ReplyForm({ threadId }: { threadId: string }) {
  const [pending, startTransition] = useTransition();
  const blank: ReplyInput = { threadId, body: '' };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<ReplyInput>({ resolver: zodResolver(replySchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await postReply(v);
      if (r.error) return void toast.error(r.error);
      reset(blank);
    }),
  );
  return (
    <form onSubmit={onSubmit} className="space-y-3" noValidate>
      <div className="space-y-1">
        <Label htmlFor="dr-body">Your reply</Label>
        <Textarea id="dr-body" rows={3} {...register('body')} />
        {errors.body && <p className="text-sm text-destructive">{errors.body.message}</p>}
      </div>
      <Button type="submit" disabled={pending}>
        Reply
      </Button>
    </form>
  );
}
