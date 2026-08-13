'use server';

import { supabaseServer } from '@/lib/supabase/server';
import { markEntryError } from '@/lib/exams/errors';
import type { MarkEntrySheet } from '@/lib/exams/mark-query';
import { setExamAttendanceSchema, upsertMarksSchema } from '@/lib/validation';

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
