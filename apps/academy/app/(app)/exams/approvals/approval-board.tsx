'use client';

import { useState } from 'react';
import { toast } from 'sonner';
import { approveMarks, readApprovalQueue } from './actions';
import type { MarkApprovalQueue, MarkApprovalSubject, MarkSectionOption } from '@/lib/exams/mark-query';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';

/**
 * FR-I16's board: one section's papers, what is blocking each of them, and the
 * one button that signs a paper off.
 *
 * The blocking candidates are rendered from the queue rather than from a
 * refusal, because a controller chasing two missing scripts should not have to
 * click Approve to learn whose they are (AC1). Approve is disabled until the
 * database would accept it — and pressed anyway it would still be refused,
 * because fn_approve_marks() re-checks completeness in the transaction that
 * writes the lock.
 */
type Props = {
  examTermId: string;
  termName: string;
  sections: MarkSectionOption[];
};

export function ApprovalBoard({ examTermId, termName, sections }: Props) {
  const [sectionId, setSectionId] = useState('');
  const [queue, setQueue] = useState<MarkApprovalQueue | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState('');

  const load = async (id: string) => {
    if (!id) {
      setQueue(null);
      return;
    }
    setLoading(true);
    const result = await readApprovalQueue(examTermId, id);
    setLoading(false);
    if (result.error || !result.queue) {
      toast.error(result.error ?? 'Could not read the approval queue.');
      setQueue(null);
      return;
    }
    setQueue(result.queue);
  };

  const onApprove = async (subject: MarkApprovalSubject) => {
    setBusy(subject.exam_subject_id);
    const result = await approveMarks({ examSubjectId: subject.exam_subject_id, sectionId });
    setBusy('');
    if (result.error) {
      toast.error(result.error);
      // The refusal may have named candidates the queue did not yet know about.
      await load(sectionId);
      return;
    }
    toast.success(
      result.termLocked
        ? `${subject.subject_name} signed off — every paper in ${termName} is now locked.`
        : `${subject.subject_name} signed off — ${result.marksLocked} marks locked.`,
    );
    await load(sectionId);
  };

  return (
    <div className="space-y-6">
      <section className="flex flex-wrap items-end gap-3 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="approval-section">Section</Label>
          <select
            id="approval-section"
            className="h-9 rounded-md border bg-background px-3 text-sm"
            value={sectionId}
            data-testid="approval-section-select"
            onChange={(e) => {
              setSectionId(e.target.value);
              setQueue(null);
            }}
          >
            <option value="">Choose a section…</option>
            {sections.map((s) => (
              <option key={s.id} value={s.id}>
                {s.label}
              </option>
            ))}
          </select>
        </div>
        <Button variant="outline" disabled={loading} data-testid="open-approval-queue" onClick={() => void load(sectionId)}>
          {loading ? 'Opening…' : 'Open approval queue'}
        </Button>
      </section>

      {queue && (
        <div className="space-y-4" data-testid="approval-queue">
          <div
            className={`rounded-md border p-4 text-sm ${queue.result_ready.ready ? 'border-emerald-600' : 'border-dashed'}`}
            data-testid="approval-result-ready"
          >
            {queue.result_ready.ready ? (
              <p>
                Every paper in {termName} is locked for this class —{' '}
                <span className="font-semibold">term result computation is available.</span>
              </p>
            ) : (
              <p className="text-muted-foreground">
                {queue.result_ready.locked_count} of {queue.result_ready.subject_count} papers locked. Term result
                computation waits on{' '}
                <span data-testid="approval-pending-subjects">{queue.result_ready.pending_subjects.join(', ')}</span>.
              </p>
            )}
          </div>

          {queue.subjects.length === 0 && (
            <p className="text-sm text-muted-foreground" data-testid="approval-no-subjects">
              No papers are configured for this section in {termName}.
            </p>
          )}

          {queue.subjects.map((subject) => {
            const { completeness: c } = subject;
            return (
              <div
                key={subject.exam_subject_id}
                className="space-y-3 rounded-md border p-4"
                data-testid={`approval-subject-${subject.subject_name}`}
              >
                <div className="flex flex-wrap items-center gap-3">
                  <h2 className="text-base font-semibold">{subject.subject_name}</h2>
                  {subject.is_locked ? (
                    <span
                      className="rounded-full border px-2 py-0.5 text-xs"
                      data-testid={`approval-locked-${subject.subject_name}`}
                    >
                      Locked{subject.locked_by_name ? ` by ${subject.locked_by_name}` : ''}
                    </span>
                  ) : (
                    <span className="text-xs text-muted-foreground">
                      {c.mark_count} marks across {c.candidate_count} candidates
                    </span>
                  )}
                  {!subject.is_locked && (
                    <Button
                      className="ml-auto"
                      disabled={!queue.can_approve || !c.complete || busy === subject.exam_subject_id}
                      data-testid={`approve-${subject.subject_name}`}
                      onClick={() => void onApprove(subject)}
                    >
                      {busy === subject.exam_subject_id ? 'Approving…' : 'Approve and lock'}
                    </Button>
                  )}
                </div>

                {!subject.is_locked && c.not_started.length > 0 && (
                  <p className="text-sm text-destructive" data-testid={`approval-not-started-${subject.subject_name}`}>
                    {c.not_started.length} candidate{c.not_started.length === 1 ? ' has' : 's have'} neither a mark nor an
                    exam status: {c.not_started.map((s) => s.gr_number).join(', ')}
                  </p>
                )}
                {!subject.is_locked && c.partial.length > 0 && (
                  <p className="text-sm text-destructive" data-testid={`approval-partial-${subject.subject_name}`}>
                    {c.partial.length} candidate{c.partial.length === 1 ? ' is' : 's are'} missing a component mark:{' '}
                    {c.partial.map((s) => `${s.gr_number} (${s.missing.join(', ')})`).join(', ')}
                  </p>
                )}
                {!subject.is_locked && c.complete && (
                  <p className="text-sm text-muted-foreground">
                    Every candidate is accounted for. Approving locks these marks against every role, including yours.
                  </p>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
