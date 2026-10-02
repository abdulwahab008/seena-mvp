'use client';

import { useState } from 'react';
import { toast } from 'sonner';
import { evaluatePromotion, overridePromotion, readPromotionSheet, savePromotionRule } from './actions';
import {
  DECISION_LABEL,
  PENDING_REASON_LABEL,
  promotionBatch,
  type PromotionRow,
  type PromotionSheet,
} from '@/lib/exams/promotion-query';
import type { MarkClassOption } from '@/lib/exams/mark-query';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';

type Props = { sessionId: string; campusId: string; classes: MarkClassOption[] };

const OVERRIDE_TARGETS = ['promoted', 'promoted_on_trial', 'compartment', 'detained'] as const;

export function PromotionBoard({ sessionId, campusId, classes }: Props) {
  const [classId, setClassId] = useState('');
  const [sheet, setSheet] = useState<PromotionSheet | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [rule, setRule] = useState({ min: '40', comp: '2', promo: '0' });
  const [overriding, setOverriding] = useState<PromotionRow | null>(null);
  const [target, setTarget] = useState<(typeof OVERRIDE_TARGETS)[number]>('promoted_on_trial');
  const [reason, setReason] = useState('');

  const load = async (id: string) => {
    if (!id) {
      setSheet(null);
      return;
    }
    setLoading(true);
    const r = await readPromotionSheet(sessionId, id);
    setLoading(false);
    if (r.error || !r.sheet) {
      toast.error(r.error ?? 'Could not read the decisions.');
      setSheet(null);
      return;
    }
    setSheet(r.sheet);
    setRule({
      min: String(r.sheet.rule.min_aggregate_pct),
      comp: String(r.sheet.rule.max_failed_for_compartment),
      promo: String(r.sheet.rule.max_failed_for_promotion),
    });
  };

  const onEvaluate = async () => {
    setBusy(true);
    const r = await evaluatePromotion({ sessionId, classId });
    setBusy(false);
    if (r.error) return void toast.error(r.error);
    toast.success(r.message ?? 'Evaluated.');
    await load(classId);
  };

  const onSaveRule = async () => {
    setBusy(true);
    const r = await savePromotionRule({
      campusId,
      classId,
      minAggregatePct: Number(rule.min),
      maxFailedForCompartment: Number(rule.comp),
      maxFailedForPromotion: Number(rule.promo),
    });
    setBusy(false);
    if (r.error) return void toast.error(r.error);
    toast.success(r.message ?? 'Saved.');
    await load(classId);
  };

  const onOverride = async () => {
    if (!overriding) return;
    setBusy(true);
    const r = await overridePromotion({ decisionId: overriding.decision_id, decision: target, reason });
    setBusy(false);
    if (r.error) return void toast.error(r.error);
    toast.success(r.message ?? 'Done.');
    setOverriding(null);
    setReason('');
    await load(classId);
  };

  const batch = sheet ? promotionBatch(sheet.decisions) : [];

  return (
    <div className="space-y-6">
      <section className="flex flex-wrap items-end gap-3 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="promotion-class">Class</Label>
          <select
            id="promotion-class"
            className="h-9 rounded-md border bg-background px-3 text-sm"
            value={classId}
            data-testid="promotion-class-select"
            onChange={(e) => {
              setClassId(e.target.value);
              setSheet(null);
            }}
          >
            <option value="">Choose a class…</option>
            {classes.map((c) => (
              <option key={c.id} value={c.id}>
                {c.label}
              </option>
            ))}
          </select>
        </div>
        <Button variant="outline" disabled={loading || !classId} data-testid="open-promotion" onClick={() => void load(classId)}>
          {loading ? 'Opening…' : 'Open decisions'}
        </Button>
      </section>

      {sheet && (
        <div className="space-y-6" data-testid="promotion-sheet">
          <section className="space-y-3 rounded-md border p-4" data-testid="promotion-rule">
            <p className="font-medium">
              Rule in force{' '}
              <span className="text-xs font-normal text-muted-foreground" data-testid="promotion-rule-source">
                ({sheet.rule.source === 'default' ? 'built-in default' : `${sheet.rule.source} rule`})
              </span>
            </p>
            <div className="flex flex-wrap items-end gap-3 text-sm">
              <label className="space-y-1">
                <span className="block text-muted-foreground">Minimum aggregate %</span>
                <input
                  className="h-9 w-24 rounded-md border bg-background px-2"
                  inputMode="decimal"
                  value={rule.min}
                  data-testid="rule-min"
                  onChange={(e) => setRule({ ...rule, min: e.target.value })}
                />
              </label>
              <label className="space-y-1">
                <span className="block text-muted-foreground">Compartment up to N failed</span>
                <input
                  className="h-9 w-24 rounded-md border bg-background px-2"
                  inputMode="numeric"
                  value={rule.comp}
                  data-testid="rule-comp"
                  onChange={(e) => setRule({ ...rule, comp: e.target.value })}
                />
              </label>
              <label className="space-y-1">
                <span className="block text-muted-foreground">Promote up to N failed</span>
                <input
                  className="h-9 w-24 rounded-md border bg-background px-2"
                  inputMode="numeric"
                  value={rule.promo}
                  data-testid="rule-promo"
                  onChange={(e) => setRule({ ...rule, promo: e.target.value })}
                />
              </label>
              <Button variant="outline" disabled={busy} data-testid="save-rule" onClick={() => void onSaveRule()}>
                Save rule for this class
              </Button>
            </div>
            <p className="text-xs text-muted-foreground">
              More than {rule.comp} failed subjects is Detained; {Number(rule.promo) + 1} to {rule.comp} is a Compartment;
              up to {rule.promo} failed with an aggregate of at least {rule.min}% is Promoted.
            </p>
          </section>

          {sheet.can_evaluate && (
            <Button disabled={busy} data-testid="evaluate-promotion" onClick={() => void onEvaluate()}>
              {busy ? 'Working…' : 'Evaluate this class'}
            </Button>
          )}

          {sheet.decisions.length === 0 ? (
            <p className="text-sm text-muted-foreground" data-testid="promotion-none">
              No decisions yet. Evaluate the class once its annual results exist.
            </p>
          ) : (
            <section className="space-y-3">
              <p className="text-sm text-muted-foreground" data-testid="promotion-batch-count">
                {batch.length} of {sheet.decisions.length} candidates are in the promotion batch.
              </p>
              <table className="w-full text-sm" data-testid="promotion-table">
                <thead className="text-left text-muted-foreground">
                  <tr>
                    <th className="py-1">Student</th>
                    <th className="py-1">Aggregate</th>
                    <th className="py-1">Decision</th>
                    <th className="py-1">Detail</th>
                    <th className="py-1" />
                  </tr>
                </thead>
                <tbody>
                  {sheet.decisions.map((d) => (
                    <tr key={d.decision_id} className="border-t align-top" data-testid={`promotion-${d.gr_number}`}>
                      <td className="py-2">
                        {d.roll_no !== null ? `${d.roll_no}. ` : ''}
                        {d.student_name}
                        <span className="block text-xs text-muted-foreground">{d.gr_number}</span>
                      </td>
                      <td className="py-2">{d.aggregate_pct === null ? '—' : `${Number(d.aggregate_pct).toFixed(2)}%`}</td>
                      <td className="py-2 font-medium" data-testid={`promotion-decision-${d.gr_number}`}>
                        {DECISION_LABEL[d.decision]}
                        {d.overridden && (
                          <span className="block text-xs font-normal text-muted-foreground">
                            Overridden from {DECISION_LABEL[d.system_decision]} by {d.overridden_by_name ?? 'the Principal'}
                          </span>
                        )}
                      </td>
                      <td className="py-2 text-xs text-muted-foreground">
                        {d.decision === 'pending' && d.pending_reason
                          ? (PENDING_REASON_LABEL[d.pending_reason] ?? d.pending_reason)
                          : d.failed_subjects.length > 0
                            ? `Failed: ${d.failed_subjects.map((f) => f.subject_name).join(', ')}`
                            : ''}
                        {d.override_reason && <span className="block">Reason: {d.override_reason}</span>}
                        {d.handoff_conflict && (
                          <span className="block text-destructive" data-testid={`promotion-conflict-${d.gr_number}`}>
                            Already enrolled in a higher class — review the enrolment.
                          </span>
                        )}
                      </td>
                      <td className="py-2 text-right">
                        {sheet.can_override && d.decision !== 'pending' && (
                          <Button
                            size="sm"
                            variant="outline"
                            data-testid={`override-${d.gr_number}`}
                            onClick={() => {
                              setOverriding(d);
                              setTarget(d.decision === 'detained' ? 'promoted_on_trial' : 'detained');
                            }}
                          >
                            Override
                          </Button>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </section>
          )}

          {overriding && (
            <section className="space-y-3 rounded-md border p-4" data-testid="override-panel">
              <p className="font-medium">
                Override {overriding.student_name}: currently {DECISION_LABEL[overriding.decision]}
              </p>
              <div className="flex flex-wrap items-end gap-3 text-sm">
                <label className="space-y-1">
                  <span className="block text-muted-foreground">New decision</span>
                  <select
                    className="h-9 rounded-md border bg-background px-2"
                    value={target}
                    data-testid="override-target"
                    onChange={(e) => setTarget(e.target.value as (typeof OVERRIDE_TARGETS)[number])}
                  >
                    {OVERRIDE_TARGETS.map((t) => (
                      <option key={t} value={t}>
                        {DECISION_LABEL[t]}
                      </option>
                    ))}
                  </select>
                </label>
                <label className="min-w-64 flex-1 space-y-1">
                  <span className="block text-muted-foreground">Reason (kept on the record, not printed)</span>
                  <input
                    className="h-9 w-full rounded-md border bg-background px-2"
                    value={reason}
                    data-testid="override-reason"
                    onChange={(e) => setReason(e.target.value)}
                  />
                </label>
                <Button disabled={busy} data-testid="override-save" onClick={() => void onOverride()}>
                  Save override
                </Button>
                <Button variant="ghost" onClick={() => setOverriding(null)}>
                  Cancel
                </Button>
              </div>
            </section>
          )}
        </div>
      )}
    </div>
  );
}
