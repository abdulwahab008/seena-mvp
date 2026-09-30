'use client';

import { useMemo, useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { activateExamTerms, deleteExamTerm, lockExamTerm, upsertExamTerm } from './actions';
import { formatWeightPct, upsertExamTermSchema, type UpsertExamTermInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { ConfirmDialog } from '@/components/ui/modal';

export type ExamTermRow = {
  id: string;
  code: string;
  name: string;
  name_ur: string | null;
  sequence: number;
  weight_pct: number | null;
  counts_toward_annual: boolean;
  status: string;
};

type Props = {
  campusId: string;
  sessionId: string;
  canWrite: boolean;
  terms: ExamTermRow[];
};

const STATUS_LABEL: Record<string, string> = {
  draft: 'Draft',
  active: 'Active — selectable in mark entry',
  locked: 'Locked by approved marks',
};

export function TermSetEditor({ campusId, sessionId, canWrite, terms }: Props) {
  const [pending, startTransition] = useTransition();

  // AC4: only the counting terms are in the total. A non-counting term
  // (weekly test, mock) carries its own weight for the report card and must
  // never move this figure — the same rule fn_validate_term_weightage()
  // applies, mirrored here so the Controller sees where they stand before
  // pressing Activate rather than only after.
  const countingTotal = useMemo(
    () => terms.filter((t) => t.counts_toward_annual).reduce((sum, t) => sum + Number(t.weight_pct ?? 0), 0),
    [terms],
  );
  const totalIsValid = Math.round(countingTotal * 100) === 10000;
  const hasDraft = terms.some((t) => t.status === 'draft');

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<UpsertExamTermInput>({
    resolver: zodResolver(upsertExamTermSchema),
    defaultValues: {
      campusId,
      sessionId,
      code: '',
      name: '',
      nameUr: '',
      sequence: terms.length + 1,
      weightPct: 0,
      countsTowardAnnual: true,
    },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('sessionId', sessionId);
    fd.set('code', values.code);
    fd.set('name', values.name);
    if (values.nameUr) fd.set('nameUr', values.nameUr);
    fd.set('sequence', String(values.sequence));
    fd.set('weightPct', String(values.weightPct));
    if (values.countsTowardAnnual) fd.set('countsTowardAnnual', 'on');

    startTransition(async () => {
      const result = await upsertExamTerm({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`${values.name} saved.`);
        reset({
          campusId,
          sessionId,
          code: '',
          name: '',
          nameUr: '',
          sequence: values.sequence + 1,
          weightPct: 0,
          countsTowardAnnual: true,
        });
      }
    });
  });

  const onActivate = () => {
    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('sessionId', sessionId);
    startTransition(async () => {
      const result = await activateExamTerms({ error: null }, fd);
      // AC2's sentence reaches the screen exactly as the database wrote it.
      if (result.error) toast.error(result.error);
      else toast.success(`${result.activated} term(s) activated.`);
    });
  };

  const [termToRemove, setTermToRemove] = useState<ExamTermRow | null>(null);

  const confirmDeleteTerm = () => {
    if (!termToRemove) return;
    const fd = new FormData();
    fd.set('examTermId', termToRemove.id);
    startTransition(async () => {
      const result = await deleteExamTerm(fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Term removed.');
        setTermToRemove(null);
      }
    });
  };

  const onLock = (id: string) => {
    const fd = new FormData();
    fd.set('examTermId', id);
    startTransition(async () => {
      const result = await lockExamTerm(fd);
      if (result.error) toast.error(result.error);
      else toast.success('Term locked.');
    });
  };

  return (
    <div className="space-y-6">
      <div className="rounded-lg border">
        <table className="w-full text-sm">
          <thead className="border-b bg-muted/40 text-left">
            <tr>
              <th className="p-3 font-medium">#</th>
              <th className="p-3 font-medium">Code</th>
              <th className="p-3 font-medium">Term</th>
              <th className="p-3 font-medium">Weightage</th>
              <th className="p-3 font-medium">Counts toward annual</th>
              <th className="p-3 font-medium">Status</th>
              <th className="p-3 font-medium" />
            </tr>
          </thead>
          <tbody>
            {terms.length === 0 && (
              <tr>
                <td colSpan={7} className="p-4 text-muted-foreground" data-testid="exam-term-empty">
                  No exam terms defined for this session yet.
                </td>
              </tr>
            )}
            {terms.map((t) => (
              <tr key={t.id} className="border-b last:border-0" data-testid={`exam-term-row-${t.code}`}>
                <td className="p-3 tabular-nums">{t.sequence}</td>
                <td className="p-3 font-mono text-xs">{t.code}</td>
                <td className="p-3">
                  {t.name}
                  {t.name_ur && <span className="ml-2 text-muted-foreground">{t.name_ur}</span>}
                </td>
                <td className="p-3 tabular-nums" data-testid={`exam-term-weight-${t.code}`}>
                  {formatWeightPct(Number(t.weight_pct ?? 0))}%
                </td>
                <td className="p-3">{t.counts_toward_annual ? 'Yes' : 'No — excluded from the 100% total'}</td>
                <td className="p-3" data-testid={`exam-term-status-${t.code}`}>
                  {STATUS_LABEL[t.status] ?? t.status}
                </td>
                <td className="p-3 text-right">
                  {canWrite && t.status === 'draft' && (
                    <Button
                      variant="ghost"
                      size="sm"
                      disabled={pending}
                      onClick={() => setTermToRemove(t)}
                      className="text-destructive hover:text-destructive hover:bg-destructive/10"
                    >
                      Remove
                    </Button>
                  )}
                  {canWrite && t.status === 'active' && (
                    <Button
                      variant="ghost"
                      size="sm"
                      disabled={pending}
                      data-testid={`exam-term-lock-${t.code}`}
                      onClick={() => onLock(t.id)}
                    >
                      Lock (marks approved)
                    </Button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="flex flex-wrap items-center gap-4 rounded-lg border p-4">
        <div>
          <p className="text-sm text-muted-foreground">Counting terms total</p>
          <p
            className={`text-2xl font-semibold tabular-nums ${totalIsValid ? '' : 'text-destructive'}`}
            data-testid="exam-term-counting-total"
          >
            {formatWeightPct(countingTotal)}%
          </p>
        </div>
        <p className="max-w-md text-xs text-muted-foreground">
          Activation requires the counting terms to total exactly 100.00%. Terms flagged as not counting toward the annual
          result are excluded from this figure but still appear on the report card.
        </p>
        {canWrite && (
          <Button className="ml-auto" disabled={pending || !hasDraft} data-testid="activate-terms" onClick={onActivate}>
            {pending ? 'Working…' : 'Activate term set'}
          </Button>
        )}
      </div>

      {canWrite && (
        <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-6" noValidate>
          <div className="space-y-1">
            <Label htmlFor="code">Code</Label>
            <Input id="code" placeholder="T1" {...register('code')} />
            {errors.code && <p className="text-xs text-destructive">{errors.code.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="name">Term name</Label>
            <Input id="name" placeholder="First Term" {...register('name')} />
            {errors.name && <p className="text-xs text-destructive">{errors.name.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="nameUr">Name (Urdu)</Label>
            <Input id="nameUr" placeholder="پہلی سہ ماہی" {...register('nameUr')} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="sequence">Position</Label>
            <Input id="sequence" type="number" min={1} max={40} {...register('sequence')} />
            {errors.sequence && <p className="text-xs text-destructive">{errors.sequence.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="weightPct">Weightage %</Label>
            <Input id="weightPct" type="number" step="0.01" min={0} max={100} {...register('weightPct')} />
            {errors.weightPct && <p className="text-xs text-destructive">{errors.weightPct.message}</p>}
          </div>
          <label className="flex items-center gap-2 self-end pb-2 text-sm">
            <input type="checkbox" {...register('countsTowardAnnual')} />
            Counts toward annual
          </label>
          <Button type="submit" disabled={pending} className="col-span-full w-fit" data-testid="save-exam-term">
            {pending ? 'Saving…' : 'Save term'}
          </Button>
        </form>
      )}

      <ConfirmDialog
        open={Boolean(termToRemove)}
        onClose={() => setTermToRemove(null)}
        onConfirm={confirmDeleteTerm}
        title="Remove Exam Term"
        description={
          termToRemove
            ? `Are you sure you want to remove the draft exam term "${termToRemove.name}" (${termToRemove.code})? This action cannot be undone.`
            : undefined
        }
        confirmLabel={pending ? 'Removing…' : 'Remove Term'}
        destructive
        pending={pending}
      />
    </div>
  );
}
