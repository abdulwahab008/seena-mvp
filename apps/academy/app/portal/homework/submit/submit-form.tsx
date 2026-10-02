'use client';

import { useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { compressImage } from '@/lib/uploads/compress-image';
import { submitHomework, type SubmitResult } from './actions';
import { Button } from '@/components/ui/button';

const schema = z.object({ text: z.string().max(2000, 'Text can be at most 2000 characters').optional() });
type FormValues = z.infer<typeof schema>;
const MAX_BYTES = 5 * 1024 * 1024;

export function SubmitForm({ homeworkId, enrolmentId, locked }: { homeworkId: string; enrolmentId: string; locked: boolean }) {
  const router = useRouter();
  const fileRef = useRef<HTMLInputElement>(null);
  const [pending, startTransition] = useTransition();
  const [result, setResult] = useState<SubmitResult | null>(null);
  const form = useForm<FormValues>({ resolver: zodResolver(schema), defaultValues: { text: '' } });

  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      setResult(null);
      const picked = Array.from(fileRef.current?.files ?? []);
      const files = await Promise.all(picked.map(compressImage));
      const tooBig = files.find((f) => f.size > MAX_BYTES);
      if (tooBig) return setResult({ error: `${tooBig.name}: File exceeds 5 MB limit` });
      if (files.length > 5) return setResult({ error: 'Maximum 5 files per submission' });
      const fd = new FormData();
      fd.set('homeworkId', homeworkId);
      fd.set('enrolmentId', enrolmentId);
      fd.set('text', v.text ?? '');
      for (const f of files) fd.append('files', f);
      const r = await submitHomework(fd);
      setResult(r);
      if (!r.error) {
        toast.success('Submitted.');
        form.reset({ text: '' });
        if (fileRef.current) fileRef.current.value = '';
        router.refresh();
      }
    }),
  );

  if (locked) return <p className="text-sm text-muted-foreground">This submission has been checked and can no longer be changed.</p>;
  return (
    <form onSubmit={onSubmit} className="space-y-3" noValidate>
      <div className="space-y-1">
        <label htmlFor="hwText" className="text-sm font-medium">
          Your answer (optional, up to 2000 characters)
        </label>
        <textarea id="hwText" rows={4} dir="auto" className="w-full rounded-md border bg-background px-3 py-2 text-sm" {...form.register('text')} />
        {form.formState.errors.text && <p className="text-sm text-destructive">{form.formState.errors.text.message}</p>}
      </div>
      <div className="space-y-1">
        <label htmlFor="hwFiles" className="text-sm font-medium">
          Photos or PDFs (up to 5 files, 5 MB each)
        </label>
        <input id="hwFiles" ref={fileRef} type="file" multiple accept="application/pdf,image/jpeg,image/png,image/webp" className="block text-sm" />
      </div>
      {result?.error && (
        <p role="alert" className="text-sm text-destructive" data-testid="submit-error">
          {result.error}
        </p>
      )}
      {result?.done && (
        <p role="status" className="text-sm text-emerald-700" data-testid="submit-done">
          Submitted as version {result.done.version}
          {result.done.isLate ? ` — late by ${result.done.lateByMinutes} minutes` : ''}.
        </p>
      )}
      <Button type="submit" disabled={pending} data-testid="submit-work">
        {pending ? 'Uploading…' : 'Submit'}
      </Button>
    </form>
  );
}
