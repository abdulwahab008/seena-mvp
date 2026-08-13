'use server';

import { supabaseServer } from '@/lib/supabase/server';
import { markEntryError, ocrReviewError } from '@/lib/exams/errors';
import type { MarkEntrySheet } from '@/lib/exams/mark-query';
import {
  cancelOcrJobSchema,
  promoteOcrMarksSchema,
  recordOcrReviewSchema,
  setExamAttendanceSchema,
  upsertMarksSchema,
} from '@/lib/validation';

/**
 * FR-I12. mark_entry has a SELECT policy and no write policy, so
 * fn_upsert_marks() is the only writer — and it is the only one either way,
 * because the batch plus the idempotency key IS the requirement (AC4), not a
 * later optimisation over per-cell PATCHes.
 *
 * Neither action calls revalidatePath: the grid autosaves under the teacher's
 * fingers and a re-render on every cell would fight the keyboard. What the
 * server returns is the saved count, which the grid reconciles itself.
 */

export type SheetState = { error: string | null; sheet?: MarkEntrySheet };
export type SaveMarksState = { error: string | null; saved?: number; replayed?: boolean };

export async function readMarkEntrySheet(
  examTermId: string,
  sectionId: string,
  subjectId: string,
): Promise<SheetState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_mark_entry_sheet', {
    p_exam_term_id: examTermId,
    p_section_id: sectionId,
    p_subject_id: subjectId,
  });
  if (error || !data) return { error: error ? markEntryError(error.message) : 'Could not open the mark sheet.' };
  return { error: null, sheet: data as unknown as MarkEntrySheet };
}

export async function saveMarks(input: unknown): Promise<SaveMarksState> {
  const parsed = upsertMarksSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_upsert_marks', {
    p_payload: {
      exam_subject_id: parsed.data.examSubjectId,
      marks: parsed.data.cells.map((c) => ({
        enrolment_id: c.enrolmentId,
        component: c.component,
        marks_obtained: c.marksObtained,
      })),
    },
    // Omitted rather than sent as null: p_client_batch_id defaults to null in
    // SQL, and the generated types type the optional argument as string only.
    ...(parsed.data.clientBatchId ? { p_client_batch_id: parsed.data.clientBatchId } : {}),
  });
  if (error) return { error: markEntryError(error.message) };

  const result = (data ?? {}) as { saved?: number; replayed?: boolean };
  return { error: null, saved: result.saved ?? 0, replayed: result.replayed ?? false };
}

/**
 * FR-I11. Absent, exempt and debarred are a status on the paper, never a
 * value in the marks column, so this is a separate write from saveMarks() and
 * goes nowhere near the autosave queue: a status change is a deliberate act,
 * not something typed under one's fingers.
 *
 * The reason code is mandatory for every non-present status and forbidden for
 * 'present' — chk_exam_attendance_reason enforces both, and
 * set_exam_attendance() raises the named errors ahead of it.
 */
export async function setExamAttendance(input: unknown): Promise<SaveMarksState> {
  const parsed = setExamAttendanceSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_exam_attendance', {
    p_exam_subject_id: parsed.data.examSubjectId,
    p_enrolment_id: parsed.data.enrolmentId,
    p_status: parsed.data.status,
    ...(parsed.data.reason ? { p_reason: parsed.data.reason } : {}),
    ...(parsed.data.note ? { p_note: parsed.data.note } : {}),
  });
  if (error) return { error: markEntryError(error.message) };

  return { error: null };
}

/**
 * FR-I14. The affirmation. Nothing here decides anything — the counts come back
 * from the database, which is also the only thing that can refuse a promotion,
 * because the FR's Notes put that guard below the UI on purpose.
 *
 * AC3's bulk accept is this action with ten entries in it. There is no "accept
 * the page" call, because ocr_review_action has no row that could mean a page.
 */
export type OcrReviewState = {
  error: string | null;
  reviewedCount?: number;
  scriptCount?: number;
  canPromote?: boolean;
};

export async function recordOcrReviews(input: unknown): Promise<OcrReviewState> {
  const parsed = recordOcrReviewSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_record_ocr_review', {
    p_job_id: parsed.data.jobId,
    p_reviews: parsed.data.reviews.map((r) => ({
      enrolment_id: r.enrolmentId,
      question_no: r.questionNo,
      ...(r.finalValue === undefined ? {} : { final_value: r.finalValue }),
    })),
  });
  if (error) return { error: ocrReviewError(error.message) };

  const result = (data ?? {}) as { reviewed_count?: number; script_count?: number; can_promote?: boolean };
  return {
    error: null,
    reviewedCount: result.reviewed_count ?? 0,
    scriptCount: result.script_count ?? 0,
    canPromote: result.can_promote ?? false,
  };
}

export type PromoteOcrState = {
  error: string | null;
  confirmedCount?: number;
  overriddenCount?: number;
};

export async function promoteOcrMarks(input: unknown): Promise<PromoteOcrState> {
  const parsed = promoteOcrMarksSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_promote_ocr_marks', { p_job_id: parsed.data.jobId });
  if (error) return { error: ocrReviewError(error.message) };

  const result = (data ?? {}) as { confirmed_count?: number; overridden_count?: number };
  return {
    error: null,
    confirmedCount: result.confirmed_count ?? 0,
    overriddenCount: result.overridden_count ?? 0,
  };
}

/** The way out of a scan that came back unusable. See the migration header. */
export async function cancelOcrJob(input: unknown): Promise<{ error: string | null }> {
  const parsed = cancelOcrJobSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('fn_cancel_ocr_job', {
    p_job_id: parsed.data.jobId,
    p_reason: parsed.data.reason,
  });
  if (error) return { error: ocrReviewError(error.message) };

  return { error: null };
}
