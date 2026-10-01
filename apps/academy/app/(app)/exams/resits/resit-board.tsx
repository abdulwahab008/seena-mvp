'use client';

import { useEffect, useState } from 'react';
import { toast } from 'sonner';
import { generateResitList, grantException, readResitSheet, recordAttempt, setPolicy } from './actions';
import { BASIS_LABEL, POLICY_LABEL, type ResitRow, type ResitSheet } from '@/lib/exams/resit-query';
import { RESIT_POLICIES, type ResitPolicy } from '@/lib/validation';
import { Button } from '@/components/ui/button';

type Props = { examTermId: string; campusId: string };

const today = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });

export function ResitBoard({ examTermId, campusId }: Props) {
  const [sheet, setSheet] = useState<ResitSheet | null>(null);
  const [busy, setBusy] = useState(false);
  const [target, setTarget] = useState<ResitRow | null>(null);
  const [mode, setMode] = useState<'attempt' | 'exception'>('attempt');
  const [attemptType, setAttemptType] = useState<'resit' | 'improvement'>('resit');
  const [marks, setMarks] = useState('');
  const [satOn, setSatOn] = useState(today());
  const [reason, setReason] = useState('');
  const [policy, setPolicyValue] = useState<ResitPolicy>('capped_at_pass');

  const load = async () => {
    const r = await readResitSheet(examTermId);
    if (r.error || !r.sheet) return void toast.error(r.error ?? 'Could not read the re-sit list.');
    setSheet(r.sheet);
    setPolicyValue(r.sheet.policy);
  };
  useEffect(() => {
    void load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [examTermId]);

  const run = async (fn: () => Promise<{ error: string | null; message?: string }>) => {
    setBusy(true);
    const r = await fn();
    setBusy(false);
    if (r.error) return void toast.error(r.error);
    toast.success(r.message ?? 'Done.');
    setTarget(null);
    setMarks('');
    setReason('');
    await load();
  };

  return (
    <div className="space-y-6">
      <section className="flex flex-wrap items-end gap-3 rounded-lg border p-4" data-testid="resit-policy">
        <label className="space-y-1 text-sm">
          <span className="block text-muted-foreground">Substitution policy for this campus</span>
          <select
            className="h-9 rounded-md border bg-background px-2"
            value={policy}
            data-testid="resit-policy-select"
            onChange={(e) => setPolicyValue(e.target.value as ResitPolicy)}
          >
            {RESIT_POLICIES.map((p) => (
              <option key={p} value={p}>
                {POLICY_LABEL[p]}
              </option>
            ))}
          </select>
        </label>
        <Button variant="outline" disabled={busy} data-testid="save-policy" onClick={() => void run(() => setPolicy({ campusId, policy }))}>
          Save policy
        </Button>
        <Button disabled={busy} data-testid="generate-list" onClick={() => void run(() => generateResitList({ examTermId }))}>
          Generate re-sit list
        </Button>
      </section>

      {sheet && sheet.rows.length === 0 && (
        <p className="text-sm text-muted-foreground" data-testid="resit-none">
          No one is on the list. Generate it once the term&rsquo;s papers are signed off.
        </p>
      )}

      {sheet && sheet.rows.length > 0 && (
        <table className="w-full text-sm" data-testid="resit-table">
          <thead className="text-left text-muted-foreground">
            <tr>
              <th className="py-1">Student</th>
              <th className="py-1">Subject</th>
              <th className="py-1">Eligibility</th>
              <th className="py-1">Attempts</th>
              <th className="py-1">Published</th>
              <th className="py-1" />
            </tr>
          </thead>
          <tbody>
            {sheet.rows.map((r) => (
              <tr key={`${r.enrolment_id}-${r.exam_subject_id}`} className="border-t align-top" data-testid={`resit-${r.gr_number}-${r.subject_name}`}>
                <td className="py-2">
                  {r.student_name}
                  <span className="block text-xs text-muted-foreground">{r.gr_number}</span>
                </td>
                <td className="py-2">{r.subject_name}</td>
                <td className="py-2" data-testid={`resit-eligibility-${r.gr_number}-${r.subject_name}`}>
                  {r.eligible ? 'Eligible' : 'Not eligible'} · {BASIS_LABEL[r.basis]}
                  {r.exception_reason && <span className="block text-xs text-muted-foreground">{r.exception_reason}</span>}
                </td>
                <td className="py-2 text-xs">
                  {r.attempts.length === 0
                    ? '—'
                    : r.attempts.map((a) => (
                        <span key={a.attempt_no} className="block" data-testid={`resit-attempt-${r.gr_number}-${a.attempt_no}`}>
                          #{a.attempt_no} {a.type} · {Number(a.obtained)} · {a.sat_on}
                        </span>
                      ))}
                </td>
                <td className="py-2" data-testid={`resit-published-${r.gr_number}-${r.subject_name}`}>
                  {r.published ? (
                    <>
                      {Number(r.published.published_obtained)} of {Number(r.published.max_marks)}
                      {r.published.substituted && (
                        <span className="block text-xs text-muted-foreground">
                          R · attempt {r.published.attempt_no} (raw {Number(r.published.raw_obtained)})
                        </span>
                      )}
                    </>
                  ) : (
                    '—'
                  )}
                </td>
                <td className="py-2 text-right">
                  {r.eligible ? (
                    <Button
                      size="sm"
                      variant="outline"
                      data-testid={`record-${r.gr_number}-${r.subject_name}`}
                      onClick={() => {
                        setTarget(r);
                        setMode('attempt');
                        setAttemptType('resit');
                      }}
                    >
                      Record attempt
                    </Button>
                  ) : (
                    sheet.can_grant && (
                      <Button
                        size="sm"
                        variant="outline"
                        data-testid={`grant-${r.gr_number}-${r.subject_name}`}
                        onClick={() => {
                          setTarget(r);
                          setMode('exception');
                        }}
                      >
                        Grant exception
                      </Button>
                    )
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {target && mode === 'attempt' && (
        <section className="space-y-3 rounded-md border p-4" data-testid="attempt-panel">
          <p className="font-medium">
            Record an attempt: {target.student_name} · {target.subject_name}
          </p>
          <div className="flex flex-wrap items-end gap-3 text-sm">
            <label className="space-y-1">
              <span className="block text-muted-foreground">Type</span>
              <select
                className="h-9 rounded-md border bg-background px-2"
                value={attemptType}
                data-testid="attempt-type"
                onChange={(e) => setAttemptType(e.target.value as 'resit' | 'improvement')}
              >
                <option value="resit">Re-sit</option>
                <option value="improvement">Improvement</option>
              </select>
            </label>
            <label className="space-y-1">
              <span className="block text-muted-foreground">Marks obtained</span>
              <input
                className="h-9 w-28 rounded-md border bg-background px-2"
                inputMode="decimal"
                value={marks}
                data-testid="attempt-marks"
                onChange={(e) => setMarks(e.target.value)}
              />
            </label>
            <label className="space-y-1">
              <span className="block text-muted-foreground">Sat on</span>
              <input
                type="date"
                className="h-9 rounded-md border bg-background px-2"
                value={satOn}
                max={today()}
                data-testid="attempt-date"
                onChange={(e) => setSatOn(e.target.value)}
              />
            </label>
            <Button
              disabled={busy}
              data-testid="attempt-save"
              onClick={() =>
                void run(() =>
                  recordAttempt({
                    enrolmentId: target.enrolment_id,
                    examSubjectId: target.exam_subject_id,
                    attemptType,
                    obtained: Number(marks),
                    satOn,
                  }),
                )
              }
            >
              Save attempt
            </Button>
            <Button variant="ghost" onClick={() => setTarget(null)}>
              Cancel
            </Button>
          </div>
        </section>
      )}

      {target && mode === 'exception' && (
        <section className="space-y-3 rounded-md border p-4" data-testid="exception-panel">
          <p className="font-medium">
            Principal exception: {target.student_name} · {target.subject_name}
          </p>
          <div className="flex flex-wrap items-end gap-3 text-sm">
            <label className="min-w-64 flex-1 space-y-1">
              <span className="block text-muted-foreground">Reason (kept on the record)</span>
              <input
                className="h-9 w-full rounded-md border bg-background px-2"
                value={reason}
                data-testid="exception-reason"
                onChange={(e) => setReason(e.target.value)}
              />
            </label>
            <Button
              disabled={busy}
              data-testid="exception-save"
              onClick={() => void run(() => grantException({ enrolmentId: target.enrolment_id, examSubjectId: target.exam_subject_id, reason }))}
            >
              Record exception
            </Button>
            <Button variant="ghost" onClick={() => setTarget(null)}>
              Cancel
            </Button>
          </div>
        </section>
      )}
    </div>
  );
}
