'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { bankQuestionSchema, type BankQuestionInput } from '@/lib/validation';
import { addBankQuestion, setBankQuestionActive } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';

const SELECT = 'h-10 w-full rounded-md border bg-background px-2 text-sm';
const OPTIONS = ['A', 'B', 'C', 'D'] as const;

export function BankQuestionForm({ classSubjectId }: { classSubjectId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<BankQuestionInput>({
    resolver: zodResolver(bankQuestionSchema),
    defaultValues: { classSubjectId, chapter: '', type: 'mcq', marks: 1, text: '', optionA: '', optionB: '', optionC: '', optionD: '', answer: '', difficulty: 'medium' },
  });
  const type = form.watch('type');
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await addBankQuestion(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Question added to the bank.');
        // Keep chapter, type and marks: teachers usually enter several of the same kind in a row.
        form.reset({ ...v, text: '', optionA: '', optionB: '', optionC: '', optionD: '', answer: '' });
        router.refresh();
      }
    }),
  );
  const firstError = Object.values(form.formState.errors)[0]?.message as string | undefined;
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-6" noValidate>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor="bqChapter">Chapter</Label>
        <Input id="bqChapter" placeholder="Ch.1" {...form.register('chapter')} />
      </div>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor="bqType">Type</Label>
        <select
          id="bqType"
          className={SELECT}
          {...form.register('type', {
            onChange: (e) => form.setValue('marks', e.target.value === 'mcq' ? 1 : e.target.value === 'short' ? 2 : 5),
          })}
        >
          <option value="mcq">MCQ</option>
          <option value="short">Short question</option>
          <option value="long">Long question</option>
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="bqMarks">Marks</Label>
        <Input id="bqMarks" type="number" {...form.register('marks', { valueAsNumber: true })} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="bqDifficulty">Difficulty</Label>
        <select id="bqDifficulty" className={SELECT} {...form.register('difficulty')}>
          <option value="easy">Easy</option>
          <option value="medium">Medium</option>
          <option value="hard">Hard</option>
        </select>
      </div>
      <div className="space-y-1 sm:col-span-6">
        <Label htmlFor="bqText">Question</Label>
        <Textarea id="bqText" rows={3} {...form.register('text')} />
      </div>
      {type === 'mcq' ? (
        <>
          {OPTIONS.map((o) => (
            <div key={o} className="space-y-1 sm:col-span-3">
              <Label htmlFor={`bqOption${o}`}>Option {o}</Label>
              <Input id={`bqOption${o}`} {...form.register(`option${o}`)} />
            </div>
          ))}
          <div className="space-y-1 sm:col-span-2">
            <Label htmlFor="bqAnswer">Correct option</Label>
            <select id="bqAnswer" className={SELECT} {...form.register('answer')}>
              <option value="">Choose</option>
              {OPTIONS.map((o) => (
                <option key={o} value={o}>
                  {o}
                </option>
              ))}
            </select>
          </div>
        </>
      ) : (
        <div className="space-y-1 sm:col-span-6">
          <Label htmlFor="bqAnswer">Model answer (optional)</Label>
          <Textarea id="bqAnswer" rows={2} {...form.register('answer')} />
        </div>
      )}
      <div className="sm:col-span-6">
        <Button type="submit" disabled={pending} data-testid="add-bank-question">
          Add to bank
        </Button>
      </div>
      {(error || firstError) && (
        <p role="alert" className="text-sm text-destructive sm:col-span-6" data-testid="bank-error">
          {error ?? firstError}
        </p>
      )}
    </form>
  );
}

export function ActiveToggle({ id, active }: { id: string; active: boolean }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  return (
    <Button
      size="sm"
      variant="outline"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await setBankQuestionActive(id, !active);
          if (r.error) toast.error(r.error);
          else router.refresh();
        })
      }
    >
      {active ? 'Retire' : 'Restore'}
    </Button>
  );
}
