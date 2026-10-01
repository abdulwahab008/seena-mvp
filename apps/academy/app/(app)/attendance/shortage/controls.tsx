'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { closeShortageSchema, type CloseShortageInput } from '@/lib/validation';
import { closeWarning, runEvaluation } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';

export function RunButton() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <div className="space-y-1">
      <Button
        size="sm"
        variant="outline"
        disabled={pending}
        data-testid="run-shortage-eval"
        onClick={() =>
          startTransition(async () => {
            const r = await runEvaluation();
            setError(r.error);
            if (!r.error) {
              toast.success(r.summary ?? 'Evaluation complete.');
              router.refresh();
            }
          })
        }
      >
        {pending ? 'Evaluating…' : 'Run evaluation now'}
      </Button>
      {error && <p role="alert" className="text-xs text-destructive">{error}</p>}
    </div>
  );
}

export function CloseForm({ warningId }: { warningId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<CloseShortageInput>({ resolver: zodResolver(closeShortageSchema), defaultValues: { warningId, reason: '' } });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await closeWarning(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Warning closed.');
        router.refresh();
      }
    }),
  );
  return (
    <form onSubmit={onSubmit} className="space-y-1" noValidate>
      <div className="flex items-center gap-2">
        <Input aria-label="Reason for closing" className="h-8 w-64" placeholder="Reason (e.g. condoned on medical grounds)" {...form.register('reason')} />
        <Button size="sm" variant="outline" type="submit" disabled={pending} data-testid="close-shortage">
          Close
        </Button>
      </div>
      {(error || form.formState.errors.reason) && <p role="alert" className="text-xs text-destructive">{error ?? form.formState.errors.reason?.message}</p>}
    </form>
  );
}
