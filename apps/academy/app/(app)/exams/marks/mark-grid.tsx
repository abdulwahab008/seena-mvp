'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { toast } from 'sonner';
import { readMarkEntrySheet, saveMarks } from './actions';
import type { MarkEntrySheet, MarkSectionOption, MarkSubjectOption } from '@/lib/exams/mark-query';
import { validateMarkCell, type MarkComponentCode } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

/**
 * FR-I12's grid.
 *
 * AC3 ("moves down a column using Enter or Tab only, each value autosaves as
 * draft within 2 seconds without a page reload") and AC4 ("the device loses
 * connectivity mid-entry... queued values flush in ONE batch... with no
 * duplicates") are the two that shape this file:
 *
 *   * every accepted cell goes into one pending map and one debounced flush,
 *     so forty cells typed quickly are one request, not forty;
 *   * a flush attempted while navigator.onLine is false does not fire and
 *     does not clear the map — it mints ONE client batch id (once, and reused
 *     across every retry of that queue) and waits for the 'online' event;
 *   * a failed flush puts its cells back, so nothing is lost by a round trip
 *     that never landed.
 *
 * AC1/AC2's cell validation is validateMarkCell(), which is the same rule
 * trg_mark_range_check enforces in SQL. An invalid cell is never queued, so
 * no value is persisted, and nothing moves the focus — the caret stays where
 * the teacher is already typing.
 *
 * FR-G05's lib/offline-queue.ts is deliberately NOT reused. Its QueuedRegister
 * is shaped around one attendance register per (section, date) — a whole
 * submission the teacher makes once — and generalising it would mean
 * rewriting a shipped FR's module and its tests to fit a queue whose unit is
 * a single cell that is overwritten as the teacher retypes it. That module's
 * own header notes it does not survive a hard reload either, so the
 * localStorage it buys is not the difference it looks like.
 */
const AUTOSAVE_MS = 600;

type Props = {
  examTermId: string;
  sections: MarkSectionOption[];
  subjects: MarkSubjectOption[];
};

type PendingCell = { enrolmentId: string; component: MarkComponentCode; marksObtained: number | null };

const cellKey = (enrolmentId: string, component: string) => `${enrolmentId}:${component}`;

export function MarkGrid({ examTermId, sections, subjects }: Props) {
  const [sectionId, setSectionId] = useState('');
  const [subjectId, setSubjectId] = useState('');
  const [sheet, setSheet] = useState<MarkEntrySheet | null>(null);
  const [loading, setLoading] = useState(false);

  const [values, setValues] = useState<Record<string, string>>({});
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [status, setStatus] = useState('');
  const [queued, setQueued] = useState(0);

  const pendingRef = useRef<Map<string, PendingCell>>(new Map());
  const batchIdRef = useRef<string | null>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const inputsRef = useRef<Record<string, HTMLInputElement | null>>({});
  const sheetRef = useRef<MarkEntrySheet | null>(null);
  sheetRef.current = sheet;

  const sectionsSubjects = subjects.filter(
    (s) => s.classLevelId === sections.find((sec) => sec.id === sectionId)?.classLevelId,
  );

  const flush = useCallback(async () => {
    const examSubjectId = sheetRef.current?.exam_subject_id;
    if (!examSubjectId || pendingRef.current.size === 0) return;

    // AC4. Offline is checked here rather than caught as a failure, because a
    // request that never leaves the device is not an error to report — it is
    // a queue to hold, under one batch id so the eventual flush is replayable.
    if (typeof navigator !== 'undefined' && navigator.onLine === false) {
      batchIdRef.current ??= crypto.randomUUID();
      setQueued(pendingRef.current.size);
      setStatus('Offline — held for sending');
      return;
    }

    const cells = [...pendingRef.current.values()];
    pendingRef.current.clear();
    const batchId = batchIdRef.current ?? undefined;
    setStatus('Saving…');

    const result = await saveMarks({ examSubjectId, cells, clientBatchId: batchId });
    if (result.error) {
      // Put them back: a round trip that did not land must not lose work.
      for (const c of cells) pendingRef.current.set(cellKey(c.enrolmentId, c.component), c);
      setQueued(pendingRef.current.size);
      setStatus('Not saved');
      toast.error(result.error);
      return;
    }

    batchIdRef.current = null;
    setQueued(pendingRef.current.size);
    setStatus(result.replayed ? 'Already saved' : `Saved ${result.saved}`);
  }, []);

  const schedule = useCallback(() => {
    if (timerRef.current) clearTimeout(timerRef.current);
    timerRef.current = setTimeout(() => void flush(), AUTOSAVE_MS);
  }, [flush]);

  useEffect(() => {
    const onOnline = () => {
      setStatus('Back online — sending');
      void flush();
    };
    const onOffline = () => setStatus('Offline — held for sending');
    window.addEventListener('online', onOnline);
    window.addEventListener('offline', onOffline);
    return () => {
      window.removeEventListener('online', onOnline);
      window.removeEventListener('offline', onOffline);
    };
  }, [flush]);

  const open = async () => {
    if (!sectionId || !subjectId) {
      toast.error('Choose a section and a subject.');
      return;
    }
    setLoading(true);
    const result = await readMarkEntrySheet(examTermId, sectionId, subjectId);
    setLoading(false);
    if (result.error || !result.sheet) {
      toast.error(result.error ?? 'Could not open the mark sheet.');
      setSheet(null);
      return;
    }
    const next: Record<string, string> = {};
    for (const s of result.sheet.students) {
      for (const [component, mark] of Object.entries(s.marks)) {
        if (mark !== null && mark !== undefined) next[cellKey(s.enrolment_id, component)] = String(mark);
      }
    }
    pendingRef.current.clear();
    batchIdRef.current = null;
    setValues(next);
    setErrors({});
    setQueued(0);
    setStatus('');
    setSheet(result.sheet);
  };

  const onCellChange = (enrolmentId: string, component: MarkComponentCode, maxMarks: number, raw: string) => {
    const key = cellKey(enrolmentId, component);
    setValues((prev) => ({ ...prev, [key]: raw }));

    const message = validateMarkCell(raw, maxMarks, sheet?.mark_precision ?? 0);
    setErrors((prev) => {
      const next = { ...prev };
      if (message) next[key] = message;
      else delete next[key];
      return next;
    });
    // AC1: an invalid value is never queued, so nothing is persisted.
    if (message) {
      pendingRef.current.delete(key);
      setQueued(pendingRef.current.size);
      return;
    }

    const trimmed = raw.trim();
    pendingRef.current.set(key, {
      enrolmentId,
      component,
      marksObtained: trimmed === '' ? null : Number(trimmed),
    });
    setQueued(pendingRef.current.size);
    schedule();
  };

  // AC3: down the column, not across the row — a teacher marks one paper at a
  // time. An invalid cell holds the focus rather than carrying the mistake on.
  const onCellKeyDown = (e: React.KeyboardEvent<HTMLInputElement>, component: string, rowIndex: number) => {
    if (e.key !== 'Enter' || !sheet) return;
    e.preventDefault();
    const key = cellKey(sheet.students[rowIndex]!.enrolment_id, component);
    if (errors[key]) return;
    const next = sheet.students[rowIndex + (e.shiftKey ? -1 : 1)];
    if (next) inputsRef.current[cellKey(next.enrolment_id, component)]?.focus();
  };

  return (
    <div className="space-y-6">
      <section className="flex flex-wrap items-end gap-3 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="section">Section</Label>
          <select
            id="section"
            className="h-9 rounded-md border bg-background px-3 text-sm"
            value={sectionId}
            data-testid="mark-section-select"
            onChange={(e) => {
              setSectionId(e.target.value);
              setSubjectId('');
              setSheet(null);
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
        <div className="space-y-1">
          <Label htmlFor="subject">Subject</Label>
          <select
            id="subject"
            className="h-9 rounded-md border bg-background px-3 text-sm"
            value={subjectId}
            data-testid="mark-subject-select"
            onChange={(e) => {
              setSubjectId(e.target.value);
              setSheet(null);
            }}
          >
            <option value="">Choose a subject…</option>
            {sectionsSubjects.map((s) => (
              <option key={s.subjectId} value={s.subjectId}>
                {s.subjectName}
              </option>
            ))}
          </select>
        </div>
        <Button variant="outline" disabled={loading} data-testid="open-mark-entry" onClick={() => void open()}>
          {loading ? 'Opening…' : 'Open mark entry'}
        </Button>
      </section>

      {sheet && !sheet.ready && (
        <div className="rounded-md border border-dashed p-4" data-testid="mark-entry-disabled">
          <table className="w-full text-sm opacity-50">
            <thead className="border-b text-left">
              <tr>
                <th className="p-2 font-medium">Student</th>
                <th className="p-2 font-medium">Marks</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td className="p-2 text-muted-foreground">—</td>
                <td className="p-2">
                  <Input disabled placeholder="—" />
                </td>
              </tr>
            </tbody>
          </table>
          <p className="mt-3 text-sm text-destructive" data-testid="mark-entry-pending-message">
            {sheet.message}
          </p>
        </div>
      )}

      {sheet && sheet.ready && (
        <div className="space-y-3 rounded-md border p-4" data-testid="mark-entry-grid">
          <div className="flex flex-wrap items-center gap-4 text-sm">
            <p>
              Total max{' '}
              <span className="font-semibold tabular-nums" data-testid="mark-entry-total-max">
                {sheet.total_max_marks}
              </span>
            </p>
            <p className="text-muted-foreground" data-testid="mark-entry-precision">
              {sheet.mark_precision === 0
                ? 'Whole numbers only'
                : `Up to ${sheet.mark_precision} decimal place${sheet.mark_precision === 1 ? '' : 's'}`}
            </p>
            <p className="ml-auto text-muted-foreground" data-testid="mark-entry-save-status">
              {status}
            </p>
            {queued > 0 && (
              <span
                className="rounded-full border border-dashed px-2 py-0.5 text-xs"
                data-testid="mark-entry-queued-count"
              >
                {queued} waiting
              </span>
            )}
          </div>

          {!sheet.can_enter && (
            <p className="text-sm text-destructive" data-testid="mark-entry-readonly">
              You do not teach this class subject — these marks are read-only for you.
            </p>
          )}

          <table className="w-full text-sm">
            <thead className="border-b text-left">
              <tr>
                <th className="p-2 font-medium">Student</th>
                {sheet.components.map((c) => (
                  <th key={c.component} className="p-2 font-medium" data-testid={`mark-entry-column-${c.component}`}>
                    {c.component} (max {c.max_marks} / pass {c.pass_marks})
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {sheet.students.length === 0 && (
                <tr>
                  <td colSpan={sheet.components.length + 1} className="p-3 text-muted-foreground" data-testid="mark-entry-no-candidates">
                    No active enrolments in this section.
                  </td>
                </tr>
              )}
              {sheet.students.map((student, rowIndex) => (
                <tr key={student.enrolment_id} className="border-b last:border-0">
                  <td className="p-2 whitespace-nowrap">
                    <span className="tabular-nums text-muted-foreground">{student.roll_no ?? '—'}</span>{' '}
                    {student.student_name}
                  </td>
                  {sheet.components.map((c) => {
                    const key = cellKey(student.enrolment_id, c.component);
                    return (
                      <td key={c.component} className="p-2 align-top">
                        <Input
                          ref={(el) => {
                            inputsRef.current[key] = el;
                          }}
                          inputMode="decimal"
                          disabled={!sheet.can_enter}
                          aria-invalid={Boolean(errors[key])}
                          aria-label={`${student.student_name} ${c.component}`}
                          data-testid={`mark-cell-${student.roll_no ?? student.enrolment_id}-${c.component}`}
                          placeholder={`0–${c.max_marks}`}
                          value={values[key] ?? ''}
                          onChange={(e) =>
                            onCellChange(student.enrolment_id, c.component, c.max_marks, e.target.value)
                          }
                          onKeyDown={(e) => onCellKeyDown(e, c.component, rowIndex)}
                          onBlur={() => void flush()}
                        />
                        {errors[key] && (
                          <p
                            className="mt-1 text-xs text-destructive"
                            data-testid={`mark-cell-error-${student.roll_no ?? student.enrolment_id}-${c.component}`}
                          >
                            {errors[key]}
                          </p>
                        )}
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
