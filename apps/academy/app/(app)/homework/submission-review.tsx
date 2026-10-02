'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { FEEDBACK_CODES, bulkCheckSchema, checkSubmissionSchema, type BulkCheckInput, type CheckSubmissionInput } from '@/lib/validation';
import { bulkCheck, checkSubmission, setMaxScore } from './review-actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';

const label = (c: string) => c.replace('_', ' ');
const selectClass = 'h-8 rounded-md border bg-background px-2 text-sm capitalize';

export function ReviewForm({ submissionId, maxScore, feedbackCode, remark, score }: { submissionId: string; maxScore: number | null; feedbackCode: string | null; remark: string | null; score: number | null }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<CheckSubmissionInput>({
    resolver: zodResolver(checkSubmissionSchema),
    defaultValues: { submissionId, feedbackCode: (feedbackCode as CheckSubmissionInput['feedbackCode']) ?? undefined, remark: remark ?? '', score: score ?? undefined },
  });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await checkSubmission({ ...v, score: Number.isFinite(v.score as number) ? v.score : null });
      setError(r.error);
      if (!r.error) {
        toast.success('Saved.');
        router.refresh();
      }
    }),
  );
  return (
    <form onSubmit={onSubmit} className="mt-1 flex flex-wrap items-center gap-2" noValidate>
      <select aria-label="Feedback" className={selectClass} {...form.register('feedbackCode')}>
        <option value="">Feedback…</option>
        {FEEDBACK_CODES.map((c) => (
          <option key={c} value={c}>
            {label(c)}
          </option>
        ))}
      </select>
      <Input aria-label="Remark" className="h-8 w-52" placeholder="Remark" {...form.register('remark')} />
      {maxScore !== null && <Input aria-label={`Score out of ${maxScore}`} type="number" step="0.5" className="h-8 w-20" placeholder={`/ ${maxScore}`} {...form.register('score', { setValueAs: (v) => (v === '' || v === null || v === undefined ? undefined : Number(v)) })} />}
      <Button size="sm" type="submit" disabled={pending} data-testid="check-submission">
        {feedbackCode ? 'Update' : 'Mark checked'}
      </Button>
      {(error || form.formState.errors.feedbackCode) && (
        <span role="alert" className="text-xs text-destructive" data-testid="review-error">
          {error ?? form.formState.errors.feedbackCode?.message}
        </span>
      )}
    </form>
  );
}

export function BulkCheck({ homeworkId, submissionIds }: { homeworkId: string; submissionIds: string[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<BulkCheckInput>({ resolver: zodResolver(bulkCheckSchema), defaultValues: { homeworkId, submissionIds, feedbackCode: 'good', remark: '' } });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await bulkCheck(v);
      setError(r.error);
      if (!r.error) {
        toast.success(`${r.count} submissions checked.`);
        router.refresh();
      }
    }),
  );
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-center gap-2" noValidate>
      <span className="text-xs text-muted-foreground">Check all {submissionIds.length} as</span>
      <select aria-label="Bulk feedback" className={selectClass} {...form.register('feedbackCode')}>
        {FEEDBACK_CODES.map((c) => (
          <option key={c} value={c}>
            {label(c)}
          </option>
        ))}
      </select>
      <Input aria-label="Bulk remark" className="h-8 w-44" placeholder="Remark (optional)" {...form.register('remark')} />
      <Button size="sm" variant="outline" type="submit" disabled={pending} data-testid="bulk-check">
        Check all
      </Button>
      {error && <span role="alert" className="text-xs text-destructive">{error}</span>}
    </form>
  );
}

export function MaxScoreForm({ homeworkId, current }: { homeworkId: string; current: number | null }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [value, setValue] = useState(current === null ? '' : String(current));
  const [error, setError] = useState<string | null>(null);
  return (
    <div className="flex items-center gap-2 text-xs">
      <span className="text-muted-foreground">Max score</span>
      <Input aria-label="Max score" type="number" className="h-8 w-20" value={value} onChange={(e) => setValue(e.target.value)} />
      <Button
        size="sm"
        variant="ghost"
        disabled={pending}
        onClick={() =>
          startTransition(async () => {
            const r = await setMaxScore(homeworkId, value.trim() === '' ? null : Number(value));
            setError(r.error);
            if (!r.error) router.refresh();
          })
        }
      >
        Set
      </Button>
      {error && <span role="alert" className="text-destructive">{error}</span>}
    </div>
  );
}
