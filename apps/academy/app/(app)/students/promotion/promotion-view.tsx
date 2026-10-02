'use client';

import { useMemo, useState, useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import {
  startRollover,
  fetchRolloverDecisions,
  overrideRolloverDecision,
  overrideRolloverDecisionsBulk,
  advanceRolloverBatch,
  type RolloverRunSummary,
  type RolloverDecisionRow,
} from './actions';
import { startRolloverSchema, type StartRolloverInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

type CampusOption = { id: string; name: string };
type SessionOption = { id: string; name: string };

// Safety cap on the client-side "drive to completion" loop — well beyond
// any realistic batch count (p_limit=200 per call), just so a genuine bug
// server-side can never hang the tab in an infinite loop.
const MAX_BATCH_CALLS = 500;

const OVERRIDABLE_DECISIONS = ['promote', 'retain', 'pass_out'] as const;

export function PromotionView({ campuses, sessions }: { campuses: CampusOption[]; sessions: SessionOption[] }) {
  const [pending, startTransition] = useTransition();
  const [autoRunning, setAutoRunning] = useState(false);
  const [runSummary, setRunSummary] = useState<RolloverRunSummary | null>(null);
  const [decisions, setDecisions] = useState<RolloverDecisionRow[]>([]);
  const [selected, setSelected] = useState<Set<string>>(new Set());

  const { handleSubmit, control } = useForm<StartRolloverInput>({ resolver: zodResolver(startRolloverSchema) });

  const exceptions = useMemo(() => decisions.filter((d) => d.errorCode !== null), [decisions]);
  const pct = runSummary && runSummary.total_count > 0 ? Math.round((runSummary.processed_count / runSummary.total_count) * 100) : 0;
  const canEdit = runSummary !== null && runSummary.status !== 'completed';

  const refreshDecisions = async (runId: string) => {
    const result = await fetchRolloverDecisions(runId);
    setDecisions(result.decisions);
  };

  const onStart = handleSubmit((values) => {
    startTransition(async () => {
      const fd = new FormData();
      fd.set('campusId', values.campusId);
      fd.set('fromSessionId', values.fromSessionId);
      fd.set('toSessionId', values.toSessionId);

      const result = await startRollover({ error: null, summary: null }, fd);
      if (result.error || !result.summary) {
        toast.error(result.error ?? 'Could not start the rollover.');
        return;
      }
      setRunSummary(result.summary);
      setSelected(new Set());
      await refreshDecisions(result.summary.run_id);
      toast.success(`Rollover started — ${result.summary.total_count} students in scope.`);
    });
  });

  const onOverrideOne = (studentId: string, decision: (typeof OVERRIDABLE_DECISIONS)[number]) => {
    if (!runSummary) return;
    startTransition(async () => {
      const result = await overrideRolloverDecision(runSummary.run_id, studentId, decision);
      if (result.error) toast.error(result.error);
      await refreshDecisions(runSummary.run_id);
    });
  };

  const onOverrideBulk = (decision: (typeof OVERRIDABLE_DECISIONS)[number]) => {
    if (!runSummary || selected.size === 0) return;
    startTransition(async () => {
      const result = await overrideRolloverDecisionsBulk(runSummary.run_id, Array.from(selected), decision);
      if (result.error) toast.error(result.error);
      setSelected(new Set());
      await refreshDecisions(runSummary.run_id);
    });
  };

  const toggleSelected = (studentId: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(studentId)) next.delete(studentId);
      else next.add(studentId);
      return next;
    });
  };

  const onRunToCompletion = () => {
    if (!runSummary) return;
    setAutoRunning(true);
    startTransition(async () => {
      const runId = runSummary.run_id;
      let latest = runSummary;
      let calls = 0;

      while (latest.status !== 'completed' && calls < MAX_BATCH_CALLS) {
        const result = await advanceRolloverBatch(runId);
        calls += 1;
        if (result.error || !result.summary) {
          toast.error(result.error ?? 'Could not advance the rollover.');
          break;
        }
        latest = result.summary;
        setRunSummary(latest);
      }

      await refreshDecisions(runId);
      setAutoRunning(false);
      if (latest.status === 'completed') {
        toast.success(
          latest.is_no_op
            ? 'Rollover complete — nothing to do, every eligible student was already rolled over.'
            : `Rollover complete — ${latest.promoted_count} promoted, ${latest.retained_count} retained, ${latest.passed_out_count} passed out, ${latest.held_count} held.`
        );
      }
    });
  };

  return (
    <div className="space-y-6">
      <form onSubmit={(e) => e.preventDefault()} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-4" noValidate>
        <div className="space-y-1">
          <Label htmlFor="campusId">Campus</Label>
          <Controller
            control={control}
            name="campusId"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="promotion-campus-trigger">
                  <SelectValue placeholder="Select a campus" />
                </SelectTrigger>
                <SelectContent>
                  {campuses.map((c) => (
                    <SelectItem key={c.id} value={c.id}>
                      {c.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="fromSessionId">From session</Label>
          <Controller
            control={control}
            name="fromSessionId"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="promotion-from-session-trigger">
                  <SelectValue placeholder="Select a session" />
                </SelectTrigger>
                <SelectContent>
                  {sessions.map((s) => (
                    <SelectItem key={s.id} value={s.id}>
                      {s.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="toSessionId">To session</Label>
          <Controller
            control={control}
            name="toSessionId"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="promotion-to-session-trigger">
                  <SelectValue placeholder="Select a session" />
                </SelectTrigger>
                <SelectContent>
                  {sessions.map((s) => (
                    <SelectItem key={s.id} value={s.id}>
                      {s.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
        </div>
        <div className="flex items-end">
          <Button type="button" disabled={pending} onClick={onStart} data-testid="promotion-start-button">
            {pending && !autoRunning ? 'Starting…' : 'Start rollover'}
          </Button>
        </div>
      </form>

      {runSummary && (
        <div className="space-y-4 rounded-lg border p-4" data-testid="promotion-summary">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <p className="text-sm font-medium">
                Status: <span data-testid="promotion-status">{runSummary.status}</span>
                {runSummary.is_no_op === true && <span className="ml-2 text-muted-foreground">(no-op — nothing changed)</span>}
              </p>
              <p className="text-sm text-muted-foreground">
                {runSummary.processed_count} of {runSummary.total_count} processed
              </p>
            </div>
            {runSummary.status !== 'completed' && (
              <Button type="button" disabled={pending} onClick={onRunToCompletion} data-testid="promotion-run-button">
                {autoRunning ? 'Running…' : 'Run rollover'}
              </Button>
            )}
          </div>

          <div className="h-2 w-full rounded bg-muted" data-testid="promotion-progress" data-progress={pct}>
            <div className="h-2 rounded bg-primary transition-all" style={{ width: `${pct}%` }} />
          </div>

          {runSummary.status === 'completed' && (
            <dl className="grid grid-cols-2 gap-3 text-sm md:grid-cols-5">
              <div>
                <dt className="text-muted-foreground">Promoted</dt>
                <dd data-testid="promotion-promoted-count">{runSummary.promoted_count}</dd>
              </div>
              <div>
                <dt className="text-muted-foreground">Retained</dt>
                <dd data-testid="promotion-retained-count">{runSummary.retained_count}</dd>
              </div>
              <div>
                <dt className="text-muted-foreground">Passed out</dt>
                <dd data-testid="promotion-passed-out-count">{runSummary.passed_out_count}</dd>
              </div>
              <div>
                <dt className="text-muted-foreground">Held</dt>
                <dd data-testid="promotion-held-count">{runSummary.held_count}</dd>
              </div>
              <div>
                <dt className="text-muted-foreground">Newly created</dt>
                <dd data-testid="promotion-created-count">{runSummary.created_count}</dd>
              </div>
            </dl>
          )}
        </div>
      )}

      {runSummary && decisions.length > 0 && (
        <div className="space-y-2">
          <div className="flex items-center justify-between">
            <h2 className="text-lg font-medium">Decision list</h2>
            {canEdit && (
              <div className="flex gap-2">
                <Button type="button" size="sm" variant="outline" disabled={pending || selected.size === 0} onClick={() => onOverrideBulk('retain')} data-testid="promotion-bulk-retain">
                  Mark selected: Retain
                </Button>
                <Button type="button" size="sm" variant="outline" disabled={pending || selected.size === 0} onClick={() => onOverrideBulk('pass_out')} data-testid="promotion-bulk-pass-out">
                  Mark selected: Pass out
                </Button>
                <Button type="button" size="sm" variant="outline" disabled={pending || selected.size === 0} onClick={() => onOverrideBulk('promote')} data-testid="promotion-bulk-promote">
                  Mark selected: Promote
                </Button>
              </div>
            )}
          </div>
          <div className="overflow-x-auto rounded-lg border">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b bg-muted/50 text-left">
                  {canEdit && <th className="p-2"></th>}
                  <th className="p-2">GR</th>
                  <th className="p-2">Student</th>
                  <th className="p-2">Current class</th>
                  <th className="p-2">Decision</th>
                  <th className="p-2">Target class</th>
                  <th className="p-2">Status</th>
                </tr>
              </thead>
              <tbody>
                {decisions.map((d) => {
                  const rowEditable = canEdit && d.processedAt === null;
                  return (
                    <tr key={d.id} className="border-b" data-testid={`promotion-decision-row-${d.studentId}`}>
                      {canEdit && (
                        <td className="p-2">
                          {rowEditable && (
                            <input
                              type="checkbox"
                              checked={selected.has(d.studentId)}
                              onChange={() => toggleSelected(d.studentId)}
                              data-testid={`promotion-select-${d.studentId}`}
                            />
                          )}
                        </td>
                      )}
                      <td className="p-2">{d.grNumber}</td>
                      <td className="p-2">{d.studentName}</td>
                      <td className="p-2">{d.sourceClassName}</td>
                      <td className="p-2">
                        {rowEditable ? (
                          <select
                            value={d.decision === 'hold' ? 'promote' : d.decision}
                            onChange={(e) => onOverrideOne(d.studentId, e.target.value as (typeof OVERRIDABLE_DECISIONS)[number])}
                            disabled={pending}
                            className="rounded border bg-background px-2 py-1"
                            data-testid={`promotion-decision-select-${d.studentId}`}
                          >
                            {OVERRIDABLE_DECISIONS.map((opt) => (
                              <option key={opt} value={opt}>
                                {opt}
                              </option>
                            ))}
                          </select>
                        ) : (
                          <span data-testid={`promotion-decision-value-${d.studentId}`}>{d.decision}</span>
                        )}
                      </td>
                      <td className="p-2">{d.targetClassName ?? '—'}</td>
                      <td className="p-2" data-testid={`promotion-row-status-${d.studentId}`}>
                        {d.errorCode ? (
                          <span className="text-destructive">Held — {d.errorCode}</span>
                        ) : d.processedAt ? (
                          'Processed'
                        ) : (
                          'Pending'
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {exceptions.length > 0 && (
        <div className="space-y-2">
          <h2 className="text-lg font-medium">Exception list</h2>
          <div className="overflow-x-auto rounded-lg border" data-testid="promotion-exception-list">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b bg-muted/50 text-left">
                  <th className="p-2">GR</th>
                  <th className="p-2">Student</th>
                  <th className="p-2">Current class</th>
                  <th className="p-2">Reason</th>
                </tr>
              </thead>
              <tbody>
                {exceptions.map((d) => (
                  <tr key={d.id} className="border-b" data-testid={`promotion-exception-row-${d.studentId}`}>
                    <td className="p-2">{d.grNumber}</td>
                    <td className="p-2">{d.studentName}</td>
                    <td className="p-2">{d.sourceClassName}</td>
                    <td className="p-2 text-destructive">{d.errorCode}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
