'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { moderationSchema, reverseModerationSchema, type ModerationInput, type ReverseModerationInput } from '@/lib/validation';
import { applyModeration, reverseModeration, type ModerationCapped } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export function ModerationForm({ examSubjectId, sectionId, cap }: { examSubjectId: string; sectionId: string; cap: number }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<{ affected: number; capped: ModerationCapped[] } | null>(null);
  const form = useForm<ModerationInput>({ resolver: zodResolver(moderationSchema), defaultValues: { examSubjectId, sectionId, delta: 4, reason: '' } });
  const submit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await applyModeration(v);
      setError(r.error);
      if (!r.error) {
        setResult({ affected: r.affected ?? 0, capped: r.capped ?? [] });
        toast.success('Moderation applied.');
        router.refresh();
      } else {
        setResult(null);
      }
    }),
  );
  // A new attempt starts clean: otherwise the previous refusal from the server (still in state) would mask
  // the validation message for what was just typed, because an invalid form never reaches the server call.
  const onSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    setError(null);
    return submit(e);
  };
  const firstError = Object.values(form.formState.errors)[0]?.message as string | undefined;
  return (
    <form onSubmit={onSubmit} className="space-y-3" noValidate>
      <div className="grid gap-3 sm:grid-cols-4">
        <div className="space-y-1">
          <Label htmlFor="modDelta">Adjustment (marks, up to ±{cap})</Label>
          <Input id="modDelta" type="number" step="1" {...form.register('delta', { valueAsNumber: true })} />
        </div>
        <div className="space-y-1 sm:col-span-3">
          <Label htmlFor="modReason">Reason (at least 20 characters)</Label>
          <textarea id="modReason" rows={2} className="w-full rounded-md border bg-background px-3 py-2 text-sm" {...form.register('reason')} />
        </div>
      </div>
      <Button type="submit" disabled={pending} data-testid="apply-moderation">
        Apply moderation
      </Button>
      {(error || firstError) && (
        <p role="alert" className="text-sm text-destructive" data-testid="moderation-error">
          {error ?? firstError}
        </p>
      )}
      {result && (
        <div className="space-y-1 rounded-md border p-3 text-sm" data-testid="moderation-result">
          <p>{result.affected} present candidates were moderated.</p>
          {result.capped.length > 0 ? (
            <div data-testid="capped-list">
              <p className="font-medium">Candidates who hit the component maximum or zero:</p>
              <ul className="list-disc pl-5">
                {result.capped.map((c) => (
                  <li key={c.enrolment_id}>
                    {c.gr_number} {c.name}: {c.before} to {c.after}
                  </li>
                ))}
              </ul>
            </div>
          ) : (
            <p className="text-muted-foreground">Nobody reached a bound.</p>
          )}
        </div>
      )}
    </form>
  );
}

export function ReverseForm({ moderationId }: { moderationId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const form = useForm<ReverseModerationInput>({ resolver: zodResolver(reverseModerationSchema), defaultValues: { moderationId, reason: '' } });
  const submit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await reverseModeration(v);
      setError(r.error);
      if (!r.error) {
        setNotice(`${r.restored} marks restored${r.skipped ? `, ${r.skipped} left as re-entered by the teacher` : ''}.`);
        toast.success('Moderation reversed.');
        router.refresh();
      }
    }),
  );
  const onSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    setError(null);
    setNotice(null);
    return submit(e);
  };
  const firstError = Object.values(form.formState.errors)[0]?.message as string | undefined;
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-3" noValidate>
      <div className="space-y-1">
        <Label htmlFor="revReason">Reason for reversing</Label>
        <Input id="revReason" className="w-96" {...form.register('reason')} />
      </div>
      <Button type="submit" variant="outline" disabled={pending} data-testid="reverse-moderation">
        Reverse moderation
      </Button>
      {notice && <span className="text-sm text-muted-foreground">{notice}</span>}
      {(error || firstError) && (
        <p role="alert" className="w-full text-sm text-destructive" data-testid="reverse-error">
          {error ?? firstError}
        </p>
      )}
    </form>
  );
}
