'use client';

import { useState } from 'react';
import { toast } from 'sonner';
import { cancelOcrJob, promoteOcrMarks, recordOcrReviews } from './actions';
import type { MarkEntryStudent, OcrJobSummary } from '@/lib/exams/mark-query';
import { OCR_CANCEL_REASON_MIN, ocrReviewProgressMessage, validateMarkCell } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';

/**
 * FR-I14's review surface, on FR-I12's grid rather than beside it.
 *
 * The requirement is one sentence — "an explicit human confirm-or-amend action
 * on every OCR-suggested mark before it becomes a submitted mark" — and three
 * things in this file follow from it:
 *
 *   * Nothing here writes a mark. Confirming a script writes an
 *     ocr_review_action; the marks appear only when Submit marks calls
 *     fn_promote_ocr_marks(), which refuses unless every script is confirmed.
 *     The button below is disabled in that case AS WELL, but the disabled
 *     button is decoration — the database is the gate, per the FR's Notes.
 *   * AC3's bulk accept sends one entry per script and lands one review row per
 *     script, each with its own actor and timestamp. "Accept these 10" is ten
 *     rows because ocr_review_action has enrolment_id NOT NULL and there is no
 *     row shape that could mean "a page".
 *   * Confidence is shown and never acted on. A 0.999 suggestion sits in the
 *     same queue as a 0.4 one, needs the same click, and is refused just as
 *     hard without it.
 *
 * A page is ten SCRIPTS, which is what AC3 counts and what fits on a phone.
 */
const PAGE_SIZE = 10;

type Props = {
  job: OcrJobSummary;
  students: MarkEntryStudent[];
  maxMarks: number;
  precision: number;
  canEnter: boolean;
  onChanged: () => void | Promise<void>;
};

const key = (enrolmentId: string, questionNo: number) => `${enrolmentId}:${questionNo}`;

export function OcrReviewPanel({ job, students, maxMarks, precision, canEnter, onChanged }: Props) {
  const scripts = students.filter((s) => s.ocr_questions.length > 0);
  const [page, setPage] = useState(0);
  const [amended, setAmended] = useState<Record<string, string>>({});
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [cancelReason, setCancelReason] = useState('');

  const pageCount = Math.max(1, Math.ceil(scripts.length / PAGE_SIZE));
  const visible = scripts.slice(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE);

  const shownValue = (enrolmentId: string, q: MarkEntryStudent['ocr_questions'][number]) =>
    amended[key(enrolmentId, q.question_no)] ?? String(q.final_value ?? q.ocr_value);

  const onAmend = (enrolmentId: string, questionNo: number, raw: string) => {
    const k = key(enrolmentId, questionNo);
    setAmended((prev) => ({ ...prev, [k]: raw }));
    // A single question can never be worth more than the whole component, so
    // the component maximum is a real upper bound here. The sum is checked
    // again by trg_mark_range_check when the batch is promoted.
    const message = validateMarkCell(raw, maxMarks, precision);
    setErrors((prev) => {
      const next = { ...prev };
      if (message) next[k] = message;
      else delete next[k];
      return next;
    });
  };

  const submitReviews = async (
    entries: { enrolmentId: string; questionNo: number; finalValue?: number }[],
    label: string,
  ) => {
    if (entries.length === 0) return;
    setBusy(true);
    const result = await recordOcrReviews({ jobId: job.job_id, reviews: entries });
    setBusy(false);
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success(label);
    setAmended({});
    await onChanged();
  };

  const acceptScript = (student: MarkEntryStudent) => {
    const entries = student.ocr_questions.flatMap((q) => {
      const k = key(student.enrolment_id, q.question_no);
      if (errors[k]) return [];
      const raw = amended[k];
      // Omitted means "accept what the machine said" — the server copies the
      // suggestion rather than trusting a value the client echoed back.
      return [
        {
          enrolmentId: student.enrolment_id,
          questionNo: q.question_no,
          ...(raw === undefined || raw.trim() === '' || Number(raw) === q.ocr_value
            ? {}
            : { finalValue: Number(raw) }),
        },
      ];
    });
    if (entries.length !== student.ocr_questions.length) {
      toast.error('Fix the value on this script first.');
      return;
    }
    void submitReviews(entries, `Confirmed ${student.student_name}`);
  };

  const acceptPage = () => {
    const entries = visible.flatMap((s) =>
      s.ocr_questions.map((q) => {
        const raw = amended[key(s.enrolment_id, q.question_no)];
        return {
          enrolmentId: s.enrolment_id,
          questionNo: q.question_no,
          ...(raw === undefined || raw.trim() === '' || Number(raw) === q.ocr_value
            ? {}
            : { finalValue: Number(raw) }),
        };
      }),
    );
    if (visible.some((s) => s.ocr_questions.some((q) => errors[key(s.enrolment_id, q.question_no)]))) {
      toast.error('Fix the amended values on this page first.');
      return;
    }
    void submitReviews(entries, `Confirmed ${visible.length} scripts`);
  };

  const promote = async () => {
    setBusy(true);
    const result = await promoteOcrMarks({ jobId: job.job_id });
    setBusy(false);
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success(`Submitted — ${result.confirmedCount} confirmed, ${result.overriddenCount} amended`);
    await onChanged();
  };

  const abandon = async () => {
    setBusy(true);
    const result = await cancelOcrJob({ jobId: job.job_id, reason: cancelReason });
    setBusy(false);
    if (result.error) {
      toast.error(result.error);
      return;
    }
    setCancelReason('');
    toast.success('Batch abandoned — enter these marks by hand');
    await onChanged();
  };

  return (
    <div className="space-y-3 rounded-md border-2 border-amber-500 p-3 text-sm" data-testid="ocr-review-panel">
      <div className="flex flex-wrap items-center gap-3">
        <p className="font-semibold">
          Scanned {job.component} marks awaiting confirmation —{' '}
          <span data-testid="ocr-review-progress">
            {ocrReviewProgressMessage(job.reviewed_count, job.script_count)}
          </span>
        </p>
        {job.engine && <span className="text-xs text-muted-foreground">read by {job.engine}</span>}
      </div>
      <p className="text-xs text-muted-foreground">
        These are suggestions, not marks. Nothing below counts until a named teacher confirms or amends it, and Submit
        marks is refused by the server while any script is still unconfirmed.
      </p>

      <table className="w-full text-sm">
        <thead className="border-b text-left">
          <tr>
            <th className="p-2 font-medium">Script</th>
            <th className="p-2 font-medium">Q</th>
            <th className="p-2 font-medium">Read as</th>
            <th className="p-2 font-medium">Confidence</th>
            <th className="p-2 font-medium">Award</th>
            <th className="p-2 font-medium">Confirmed by</th>
            <th className="p-2" />
          </tr>
        </thead>
        <tbody>
          {visible.map((student) =>
            student.ocr_questions.map((q, qi) => {
              const k = key(student.enrolment_id, q.question_no);
              return (
                <tr key={k} className="border-b last:border-0">
                  {qi === 0 && (
                    <td className="p-2 whitespace-nowrap align-top" rowSpan={student.ocr_questions.length}>
                      <span className="tabular-nums text-muted-foreground">{student.roll_no ?? '—'}</span>{' '}
                      {student.student_name}
                    </td>
                  )}
                  <td className="p-2 tabular-nums">{q.question_no}</td>
                  <td className="p-2 tabular-nums" data-testid={`ocr-suggested-${student.roll_no}-${q.question_no}`}>
                    {q.ocr_value}
                  </td>
                  <td className="p-2 tabular-nums text-muted-foreground">
                    {q.confidence === null ? '—' : `${Math.round(q.confidence * 100)}%`}
                  </td>
                  <td className="p-2 align-top">
                    <Input
                      inputMode="decimal"
                      disabled={!canEnter || busy}
                      aria-invalid={Boolean(errors[k])}
                      aria-label={`${student.student_name} question ${q.question_no} award`}
                      data-testid={`ocr-award-${student.roll_no}-${q.question_no}`}
                      value={shownValue(student.enrolment_id, q)}
                      onChange={(e) => onAmend(student.enrolment_id, q.question_no, e.target.value)}
                    />
                    {errors[k] && (
                      <p
                        className="mt-1 text-xs text-destructive"
                        data-testid={`ocr-award-error-${student.roll_no}-${q.question_no}`}
                      >
                        {errors[k]}
                      </p>
                    )}
                  </td>
                  <td className="p-2 text-xs" data-testid={`ocr-reviewed-${student.roll_no}-${q.question_no}`}>
                    {q.reviewed ? (
                      <span>
                        {q.actor_name ?? 'a teacher'}
                        {q.final_value !== null && q.final_value !== q.ocr_value ? ' (amended)' : ''}
                      </span>
                    ) : (
                      <span className="text-destructive">not confirmed</span>
                    )}
                  </td>
                  {qi === 0 && (
                    <td className="p-2 align-top" rowSpan={student.ocr_questions.length}>
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={!canEnter || busy}
                        data-testid={`ocr-confirm-${student.roll_no}`}
                        onClick={() => acceptScript(student)}
                      >
                        Confirm
                      </Button>
                    </td>
                  )}
                </tr>
              );
            }),
          )}
        </tbody>
      </table>

      <div className="flex flex-wrap items-center gap-3">
        {pageCount > 1 && (
          <div className="flex items-center gap-2">
            <Button
              size="sm"
              variant="outline"
              disabled={page === 0 || busy}
              data-testid="ocr-page-prev"
              onClick={() => setPage((p) => Math.max(0, p - 1))}
            >
              Previous
            </Button>
            <span className="text-xs text-muted-foreground" data-testid="ocr-page-label">
              Page {page + 1} of {pageCount}
            </span>
            <Button
              size="sm"
              variant="outline"
              disabled={page >= pageCount - 1 || busy}
              data-testid="ocr-page-next"
              onClick={() => setPage((p) => Math.min(pageCount - 1, p + 1))}
            >
              Next
            </Button>
          </div>
        )}
        {/* AC3. One entry per script goes up, one review row per script lands. */}
        <Button
          variant="outline"
          disabled={!canEnter || busy || visible.length === 0}
          data-testid="ocr-accept-page"
          onClick={acceptPage}
        >
          Confirm these {visible.length}
        </Button>
        <Button
          disabled={!canEnter || busy || !job.can_promote}
          data-testid="ocr-promote"
          onClick={() => void promote()}
        >
          Submit marks
        </Button>
        {!job.can_promote && (
          <span className="text-xs text-destructive" data-testid="ocr-promote-blocked">
            {ocrReviewProgressMessage(job.reviewed_count, job.script_count)}
          </span>
        )}
      </div>

      {/* A scan that came back unusable must not make the section permanently
          unapprovable — an open batch blocks sign-off. Abandoning it is a door,
          and it is a recorded one. */}
      <div className="flex flex-wrap items-end gap-2 border-t pt-3">
        <Input
          className="max-w-md"
          placeholder="Why this scan is unusable (10 characters or more)"
          aria-label="Reason for abandoning this batch"
          data-testid="ocr-cancel-reason"
          value={cancelReason}
          onChange={(e) => setCancelReason(e.target.value)}
        />
        <Button
          variant="outline"
          disabled={!canEnter || busy || cancelReason.trim().length < OCR_CANCEL_REASON_MIN}
          data-testid="ocr-cancel"
          onClick={() => void abandon()}
        >
          Abandon batch
        </Button>
      </div>
    </div>
  );
}
