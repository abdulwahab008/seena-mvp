'use client';

import { useActionState, useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import {
  acknowledgeAppraisal, createCycle, disputeAppraisal, finaliseAppraisal, publishCycle, releaseAppraisal, saveCompetencies, saveScores,
  type AppraisalState,
} from './actions';
import { appraisalScore, parseCompetencies } from '@/lib/appraisal/scoring';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const initial: AppraisalState = { error: null };

function useSuccess(state: AppraisalState, then?: (s: AppraisalState) => void) {
  const router = useRouter();
  useEffect(() => {
    if (state.message) {
      toast.success(state.message);
      router.refresh();
      then?.(state);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state, router]);
}

const DEFAULT_COMPETENCIES = 'Subject knowledge | 25\nLesson planning | 20\nClassroom management | 20\nAssessment and feedback | 15\nProfessionalism | 10\nCommunication | 10';

function WeightsHint({ text }: { text: string }) {
  const parsed = useMemo(() => parseCompetencies(text), [text]);
  return (
    <p className={`text-xs ${parsed.errors.length ? 'text-destructive' : 'text-muted-foreground'}`} data-testid="weights-hint">
      {parsed.errors.length ? parsed.errors[0] : `Weights add up to 100 across ${parsed.items.length} competencies.`}
    </p>
  );
}

export function CreateCycleForm({ sessions }: { sessions: { id: string; name: string }[] }) {
  const router = useRouter();
  const [state, action, pending] = useActionState(createCycle, initial);
  const [text, setText] = useState(DEFAULT_COMPETENCIES);
  useSuccess(state, (s) => {
    if (s.id) router.push(`/staff/appraisals/cycles/${s.id}`);
  });
  return (
    <form action={action} className="space-y-3" data-testid="create-cycle-form">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <div className="space-y-1 lg:col-span-2">
          <Label htmlFor="cycleName">Name</Label>
          <Input id="cycleName" name="name" required placeholder="2026 annual appraisal" />
        </div>
        <div className="space-y-1">
          <Label htmlFor="sessionId">Session</Label>
          <select id="sessionId" name="sessionId" required className="h-9 w-full rounded-md border bg-background px-2 text-sm">
            {sessions.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="opensOn">Opens</Label>
          <Input id="opensOn" name="opensOn" type="date" required />
        </div>
        <div className="space-y-1">
          <Label htmlFor="closesOn">Closes</Label>
          <Input id="closesOn" name="closesOn" type="date" required />
        </div>
      </div>
      <div className="space-y-1 sm:w-64">
        <Label htmlFor="minServiceDays">Minimum service at close (days)</Label>
        <Input id="minServiceDays" name="minServiceDays" type="number" min={0} defaultValue={90} required />
      </div>
      <div className="space-y-1">
        <Label htmlFor="competencies">Competencies and weights (one per line: name | weight)</Label>
        <textarea id="competencies" name="competencies" rows={6} value={text} onChange={(e) => setText(e.target.value)} className="w-full rounded-md border bg-background px-3 py-2 font-mono text-sm" />
        <WeightsHint text={text} />
      </div>
      {state.error && <p role="alert" className="text-sm text-destructive" data-testid="cycle-error">{state.error}</p>}
      <Button type="submit" disabled={pending} data-testid="create-cycle">
        Create cycle (draft)
      </Button>
    </form>
  );
}

export function CompetenciesForm({ cycleId, initialText }: { cycleId: string; initialText: string }) {
  const [state, action, pending] = useActionState(saveCompetencies, initial);
  const [text, setText] = useState(initialText);
  useSuccess(state);
  return (
    <form action={action} className="space-y-2">
      <input type="hidden" name="cycleId" value={cycleId} />
      <textarea name="competencies" aria-label="Competencies and weights" rows={7} value={text} onChange={(e) => setText(e.target.value)} className="w-full rounded-md border bg-background px-3 py-2 font-mono text-sm" />
      <WeightsHint text={text} />
      {state.error && <p role="alert" className="text-sm text-destructive">{state.error}</p>}
      <Button type="submit" variant="outline" disabled={pending} data-testid="save-competencies">
        Save competencies
      </Button>
    </form>
  );
}

export function PublishButton({ cycleId }: { cycleId: string }) {
  const [state, action, pending] = useActionState(publishCycle, initial);
  useSuccess(state);
  return (
    <form action={action} className="space-y-2">
      <input type="hidden" name="cycleId" value={cycleId} />
      <Button type="submit" disabled={pending} data-testid="publish-cycle">
        Publish cycle and open appraisals
      </Button>
      {state.error && <p role="alert" className="text-sm text-destructive" data-testid="publish-error">{state.error}</p>}
    </form>
  );
}

export function ScoreForm({ appraisalId, competencies, existing }: { appraisalId: string; competencies: { id: string; name: string; weight_pct: number }[]; existing: Record<string, number> }) {
  const [saveState, saveAction, saving] = useActionState(saveScores, initial);
  const [releaseState, releaseAction, releasing] = useActionState(releaseAppraisal, initial);
  const [ratings, setRatings] = useState<Record<string, number | null>>(() => Object.fromEntries(competencies.map((c) => [c.id, existing[c.id] ?? null])));
  useSuccess(saveState);
  useSuccess(releaseState);
  const preview = appraisalScore(competencies.map((c) => c.weight_pct), competencies.map((c) => ratings[c.id] ?? null));
  return (
    <div className="space-y-4">
      <form action={saveAction} className="space-y-3" data-testid="score-form">
        <input type="hidden" name="appraisalId" value={appraisalId} />
        {competencies.map((c) => (
          <div key={c.id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2">
            <Label htmlFor={`r-${c.id}`}>
              {c.name} <span className="text-xs text-muted-foreground">({c.weight_pct}%)</span>
            </Label>
            <select
              id={`r-${c.id}`}
              name={`rating:${c.id}`}
              value={ratings[c.id] ?? ''}
              onChange={(e) => setRatings((r) => ({ ...r, [c.id]: e.target.value === '' ? null : Number(e.target.value) }))}
              className="h-9 rounded-md border bg-background px-2 text-sm"
              aria-label={c.name}
            >
              <option value="">Not rated</option>
              {[1, 2, 3, 4, 5].map((n) => (
                <option key={n} value={n}>
                  {n}
                </option>
              ))}
            </select>
          </div>
        ))}
        <p className="text-sm" data-testid="score-preview">
          {preview === null ? 'Rate every competency to see the score.' : `Score: ${preview.toFixed(2)} of 100`}
        </p>
        {saveState.error && <p role="alert" className="text-sm text-destructive">{saveState.error}</p>}
        <Button type="submit" variant="outline" disabled={saving} data-testid="save-scores">
          Save ratings
        </Button>
      </form>
      <form action={releaseAction} className="space-y-2">
        <input type="hidden" name="appraisalId" value={appraisalId} />
        <p className="text-xs text-muted-foreground">Releasing shows the scores to the staff member and locks them. Save your ratings first.</p>
        <Button type="submit" disabled={releasing} data-testid="release-appraisal">
          Release to the staff member
        </Button>
        {releaseState.error && <p role="alert" className="text-sm text-destructive" data-testid="release-error">{releaseState.error}</p>}
      </form>
    </div>
  );
}

export function AckForm({ appraisalId, canAcknowledge }: { appraisalId: string; canAcknowledge: boolean }) {
  const [ackState, ackAction, acking] = useActionState(acknowledgeAppraisal, initial);
  const [disputeState, disputeAction, disputing] = useActionState(disputeAppraisal, initial);
  useSuccess(ackState);
  useSuccess(disputeState);
  return (
    <div className="space-y-4">
      {canAcknowledge && (
        <form action={ackAction}>
          <input type="hidden" name="appraisalId" value={appraisalId} />
          <Button type="submit" disabled={acking} data-testid="acknowledge-appraisal">
            I acknowledge this appraisal
          </Button>
          {ackState.error && <p role="alert" className="mt-1 text-sm text-destructive">{ackState.error}</p>}
        </form>
      )}
      <form action={disputeAction} className="space-y-2" data-testid="dispute-form">
        <input type="hidden" name="appraisalId" value={appraisalId} />
        <Label htmlFor="disputeComment">Or record your response (up to 2000 characters)</Label>
        <textarea id="disputeComment" name="comment" rows={4} maxLength={2000} required className="w-full rounded-md border bg-background px-3 py-2 text-sm" />
        {disputeState.error && <p role="alert" className="text-sm text-destructive" data-testid="dispute-error">{disputeState.error}</p>}
        <Button type="submit" variant="outline" disabled={disputing} data-testid="dispute-appraisal">
          Send my response
        </Button>
      </form>
    </div>
  );
}

export function FinaliseButton({ appraisalId }: { appraisalId: string }) {
  const [state, action, pending] = useActionState(finaliseAppraisal, initial);
  useSuccess(state);
  return (
    <form action={action}>
      <input type="hidden" name="appraisalId" value={appraisalId} />
      <Button type="submit" variant="outline" disabled={pending} data-testid="finalise-appraisal">
        Close this appraisal
      </Button>
      {state.error && <p role="alert" className="mt-1 text-sm text-destructive">{state.error}</p>}
    </form>
  );
}
