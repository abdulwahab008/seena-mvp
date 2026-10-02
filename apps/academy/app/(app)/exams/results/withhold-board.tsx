'use client';

import { useState } from 'react';
import { toast } from 'sonner';
import { raiseWithhold, readWithholdSheet, releaseWithhold, setWithholdThreshold, syncFeeWithholds } from './actions';
import type { MarkClassOption } from '@/lib/exams/mark-query';
import type { WithholdSheet } from '@/lib/exams/withhold-query';
import { WITHHOLD_REASON_LABELS, formatPkr } from '@/lib/exams/withhold-query';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

/**
 * FR-J08's working list for the accounts office: one term, one whole class,
 * who is being disclosed and who is not.
 *
 * Three things this screen refuses to be vague about.
 *
 *   * A withhold is a DECISION, not a live balance read. A candidate can owe
 *     money and not be withheld because nobody has synced yet, and the screen
 *     shows both numbers — today's balance and the figure frozen onto the
 *     withhold — rather than one that silently stands for the other.
 *   * A money hold and a DEBARMENT are different refusals settled at
 *     different desks, so they are two different badges. Merging them would
 *     send a parent to the accounts counter over an exam-committee decision.
 *   * A hardship release keeps the dues outstanding. The row says so
 *     afterwards, with the reason, because that is the state a later auditor
 *     is trying to understand.
 */
type Props = {
  examTermId: string;
  termName: string;
  campusId: string;
  classes: MarkClassOption[];
};

export function WithholdBoard({ examTermId, termName, campusId, classes }: Props) {
  const [classLevelId, setClassLevelId] = useState('');
  const [sheet, setSheet] = useState<WithholdSheet | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [thresholdRupees, setThresholdRupees] = useState('');
  const [pending, setPending] = useState<{ kind: 'release' | 'hold'; id: string; name: string } | null>(null);
  const [reason, setReason] = useState('');

  const load = async (id: string) => {
    if (!id) {
      setSheet(null);
      return;
    }
    setLoading(true);
    const result = await readWithholdSheet({ examTermId, classLevelId: id });
    setLoading(false);
    if (result.error || !result.sheet) {
      toast.error(result.error ?? 'Could not read the withhold list.');
      setSheet(null);
      return;
    }
    setSheet(result.sheet);
    setThresholdRupees(String(Math.round(result.sheet.threshold_paisa / 100)));
  };

  const onSync = async () => {
    setBusy(true);
    const result = await syncFeeWithholds({ examTermId });
    setBusy(false);
    if (result.error || !result.result) {
      toast.error(result.error ?? 'Could not sync the fee withholds.');
      return;
    }
    const { opened, released, refreshed } = result.result;
    toast.success(`${opened} withheld, ${released} released, ${refreshed} refreshed.`);
    await load(classLevelId);
  };

  const onThreshold = async () => {
    setBusy(true);
    const result = await setWithholdThreshold({ campusId, rupees: thresholdRupees });
    setBusy(false);
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success('Threshold saved. Sync the term to apply it.');
    await load(classLevelId);
  };

  // The reason is compulsory and is what a later audit reads, so it is typed
  // into the page rather than into a browser dialog: a native prompt() cannot
  // be validated, cannot be labelled, and leaves nothing on screen to check
  // before committing an override.
  const onSubmitPending = async () => {
    if (!pending) return;
    setBusy(true);
    const result =
      pending.kind === 'release'
        ? await releaseWithhold({ withholdId: pending.id, reason })
        : await raiseWithhold({ enrolmentId: pending.id, examTermId, reason: 'discipline', note: reason });
    setBusy(false);
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success(
      pending.kind === 'release'
        ? 'Released. The dues remain outstanding and the override is on the audit trail.'
        : 'Held. The marks are untouched; only the disclosure is stopped.',
    );
    setPending(null);
    setReason('');
    await load(classLevelId);
  };

  const withheldCount = sheet?.candidates.filter((c) => c.is_withheld).length ?? 0;

  return (
    <div className="space-y-6">
      <section className="flex flex-wrap items-end gap-3 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="withhold-class">Class</Label>
          <select
            id="withhold-class"
            className="h-9 rounded-md border bg-background px-3 text-sm"
            value={classLevelId}
            data-testid="withhold-class-select"
            onChange={(e) => {
              setClassLevelId(e.target.value);
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
        <Button variant="outline" disabled={loading} data-testid="open-withholds" onClick={() => void load(classLevelId)}>
          {loading ? 'Opening…' : 'Open withhold list'}
        </Button>
      </section>

      {sheet && (
        <div className="space-y-4" data-testid="withhold-sheet">
          <div className="rounded-md border p-4 text-sm" data-testid="withhold-rules">
            <p>
              A candidate whose outstanding balance is <span className="font-semibold">above</span> the threshold as at
              the cut-off has their {termName} result withheld: no report card, and the parent portal reads
              &ldquo;Result withheld — please contact the accounts office&rdquo;. Their marks, grades and position are
              computed and ranked exactly as everyone else&rsquo;s and stay visible on this screen — withholding stops
              disclosure, not computation.
            </p>
            <p className="mt-2" data-testid="withhold-threshold">
              Threshold: {formatPkr(sheet.threshold_paisa)}.
            </p>
            {sheet.can_sync && (
              <div className="mt-3 flex flex-wrap items-end gap-3">
                <div className="space-y-1">
                  <Label htmlFor="withhold-threshold-input">Threshold (PKR)</Label>
                  <Input
                    id="withhold-threshold-input"
                    className="h-9 w-40"
                    inputMode="numeric"
                    value={thresholdRupees}
                    data-testid="withhold-threshold-input"
                    onChange={(e) => setThresholdRupees(e.target.value)}
                  />
                </div>
                <Button variant="outline" disabled={busy} data-testid="save-withhold-threshold" onClick={() => void onThreshold()}>
                  Save threshold
                </Button>
                <Button disabled={busy} data-testid="sync-withholds" onClick={() => void onSync()}>
                  {busy ? 'Syncing…' : 'Sync fee withholds'}
                </Button>
              </div>
            )}
            {sheet.can_sync && (
              <p className="mt-2 text-xs text-muted-foreground">
                A scheduled job runs this every ten minutes in production; the button is here because a paid challan
                should not have to wait for one.
              </p>
            )}
          </div>

          {sheet.candidates.length === 0 ? (
            <p className="text-sm text-muted-foreground" data-testid="withhold-none">
              No active candidates in this class for this term.
            </p>
          ) : (
            <div className="space-y-2">
              <p className="text-xs text-muted-foreground" data-testid="withhold-count">
                {withheldCount} of {sheet.candidates.length} candidates withheld
              </p>
              <table className="w-full text-sm">
                <thead className="text-left text-muted-foreground">
                  <tr>
                    <th className="py-1">Candidate</th>
                    <th className="py-1">Section</th>
                    <th className="py-1">Balance today</th>
                    <th className="py-1">Disclosure</th>
                    <th className="py-1" />
                  </tr>
                </thead>
                <tbody>
                  {sheet.candidates.map((c) => (
                    <tr key={c.enrolment_id} data-testid={`withhold-${c.gr_number}`} className="align-top">
                      <td className="py-1 font-medium">
                        {c.roll_no !== null ? `${c.roll_no}. ` : ''}
                        {c.student_name}
                        <span className="ml-2 text-xs text-muted-foreground">{c.gr_number}</span>
                      </td>
                      <td className="py-1">{c.section_name}</td>
                      <td className="py-1" data-testid={`withhold-balance-${c.gr_number}`}>
                        {formatPkr(c.balance_paisa)}
                      </td>
                      <td className="py-1">
                        {c.is_withheld ? (
                          <div className="space-y-0.5">
                            <span
                              className="font-medium text-destructive"
                              data-testid={`withhold-state-${c.gr_number}`}
                            >
                              Withheld — {WITHHOLD_REASON_LABELS[c.reason ?? 'fee_default']}
                            </span>
                            <p className="text-xs text-muted-foreground" data-testid={`withhold-reason-${c.gr_number}`}>
                              {c.message}
                            </p>
                          </div>
                        ) : (
                          <div className="space-y-0.5">
                            <span data-testid={`withhold-state-${c.gr_number}`}>Released</span>
                            {c.last_release_kind === 'hardship' && (
                              <p className="text-xs text-muted-foreground" data-testid={`withhold-hardship-${c.gr_number}`}>
                                Hardship release — dues still outstanding. {c.last_release_reason}
                              </p>
                            )}
                          </div>
                        )}
                        {c.is_debarred && (
                          <p className="mt-1 text-xs text-destructive" data-testid={`withhold-debarred-${c.gr_number}`}>
                            Also debarred in this term — an exam-committee decision, not an accounts one.
                          </p>
                        )}
                      </td>
                      <td className="py-1 text-right">
                        {c.is_withheld && c.withhold_id && sheet.can_release && (
                          <Button
                            size="sm"
                            variant="outline"
                            disabled={busy}
                            data-testid={`release-withhold-${c.gr_number}`}
                            onClick={() => {
                              setPending({ kind: 'release', id: c.withhold_id!, name: c.student_name });
                              setReason('');
                            }}
                          >
                            Hardship release
                          </Button>
                        )}
                        {!c.is_withheld && sheet.can_release && (
                          <Button
                            size="sm"
                            variant="ghost"
                            disabled={busy}
                            data-testid={`hold-${c.gr_number}`}
                            onClick={() => {
                              setPending({ kind: 'hold', id: c.enrolment_id, name: c.student_name });
                              setReason('');
                            }}
                          >
                            Discipline hold
                          </Button>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          {pending && (
            <div className="space-y-2 rounded-md border p-4" data-testid="withhold-reason-panel">
              <Label htmlFor="withhold-reason">
                {pending.kind === 'release'
                  ? `Hardship release for ${pending.name} — why are the dues being set aside?`
                  : `Discipline hold for ${pending.name} — why is this result being held?`}
              </Label>
              <textarea
                id="withhold-reason"
                rows={3}
                className="w-full rounded-md border bg-background p-2 text-sm"
                value={reason}
                data-testid="withhold-reason-input"
                onChange={(e) => setReason(e.target.value)}
              />
              <p className="text-xs text-muted-foreground">
                {pending.kind === 'release'
                  ? 'The dues stay outstanding. This reason and your name are written to the audit trail and the sync will not re-open the withhold.'
                  : 'The marks are untouched. Only the disclosure is stopped.'}
              </p>
              <div className="flex gap-2">
                <Button disabled={busy} data-testid="confirm-withhold-reason" onClick={() => void onSubmitPending()}>
                  {pending.kind === 'release' ? 'Release' : 'Hold'}
                </Button>
                <Button variant="ghost" disabled={busy} onClick={() => setPending(null)}>
                  Cancel
                </Button>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
