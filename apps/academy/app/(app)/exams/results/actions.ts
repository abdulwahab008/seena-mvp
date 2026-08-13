'use server';

import { supabaseServer } from '@/lib/supabase/server';
import { positionError, subjectResultError, withholdError } from '@/lib/exams/errors';
import type { SubjectResultSheet } from '@/lib/exams/result-query';
import type { PositionSheet } from '@/lib/exams/position-query';
import type { WithholdSheet, WithholdSyncResult } from '@/lib/exams/withhold-query';
import {
  computePositionsSchema,
  computeSubjectResultSchema,
  raiseWithholdSchema,
  releaseWithholdSchema,
  setRankPolicySchema,
  setWithholdThresholdSchema,
  syncFeeWithholdsSchema,
  withholdSheetSchema,
} from '@/lib/validation';

/**
 * FR-J02. Two calls, and the split is the requirement's:
 *
 *   readResultSheet()      shows what has already been computed, including
 *                          whether a break-glass edit has made it stale;
 *   computeSubjectResults() is the explicit recompute, and the only thing on
 *                          this screen that writes.
 *
 * Ordinary computation is not either of these — approving the last paper of a
 * section fires trg_enqueue_result_compute and the results are simply there.
 * This button exists for the correction case.
 */
export type ResultSheetState = { error: string | null; sheet?: SubjectResultSheet };
export type ComputeResultState = { error: string | null; rows?: number };

export async function readResultSheet(examTermId: string, sectionId: string): Promise<ResultSheetState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_subject_result_sheet', {
    p_exam_term_id: examTermId,
    p_section_id: sectionId,
  });
  if (error || !data) {
    return { error: error ? subjectResultError(error.message) : 'Could not read the results.' };
  }
  return { error: null, sheet: data as unknown as SubjectResultSheet };
}

export async function computeSubjectResults(input: unknown): Promise<ComputeResultState> {
  const parsed = computeSubjectResultSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_compute_subject_result', {
    p_exam_term_id: parsed.data.examTermId,
    p_section_id: parsed.data.sectionId,
  });
  if (error) return { error: subjectResultError(error.message) };

  return { error: null, rows: data ?? 0 };
}

/**
 * FR-J05. The merit list sits on this screen rather than on one of its own
 * because it is the same term's marks read a second way — a total instead of a
 * subject, and a cohort instead of a candidate. The three calls split the way
 * FR-J02's two do: reading, the explicit re-rank, and the one setting the FR
 * insists must be stored rather than implied by an ORDER BY.
 *
 * Ordinary ranking is none of them: signing off the LAST section of the class
 * chains into the positions on its own.
 */
export type PositionSheetState = { error: string | null; sheet?: PositionSheet };
export type ComputePositionsState = { error: string | null; rows?: number };

export async function readPositionSheet(examTermId: string, classLevelId: string): Promise<PositionSheetState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_position_sheet', {
    p_exam_term_id: examTermId,
    p_class_id: classLevelId,
  });
  if (error || !data) {
    return { error: error ? positionError(error.message) : 'Could not read the merit list.' };
  }
  return { error: null, sheet: data as unknown as PositionSheet };
}

export async function computePositions(input: unknown): Promise<ComputePositionsState> {
  const parsed = computePositionsSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_compute_positions', {
    p_exam_term_id: parsed.data.examTermId,
    p_class_id: parsed.data.classLevelId,
  });
  if (error) return { error: positionError(error.message) };

  return { error: null, rows: data ?? 0 };
}

export async function setRankPolicy(input: unknown): Promise<{ error: string | null }> {
  const parsed = setRankPolicySchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_rank_policy', {
    p_campus_id: parsed.data.campusId,
    p_policy: parsed.data.policy,
  });
  if (error) return { error: positionError(error.message) };

  return { error: null };
}

/**
 * FR-J08. Four calls, and the split is the requirement's:
 *
 *   readWithholdSheet()      who is withheld in this class and why, with the
 *                            money, because AC4 says staff see everything;
 *   syncFeeWithholds()       AC1 and AC2 in one pass — opens what is owed,
 *                            releases what has been paid. A real 10-minute
 *                            cron calls the same RPC; the button exists
 *                            because there is no pg_cron in this stack;
 *   releaseWithhold()        AC3's hardship override, Principal only, reason
 *                            compulsory, actor recorded by the database;
 *   raiseWithhold()          the discipline and document holds, which have no
 *                            sync to open them.
 */
export type WithholdSheetState = { error: string | null; sheet?: WithholdSheet };
export type WithholdSyncState = { error: string | null; result?: WithholdSyncResult };

export async function readWithholdSheet(input: unknown): Promise<WithholdSheetState> {
  const parsed = withholdSheetSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_withhold_sheet', {
    p_exam_term_id: parsed.data.examTermId,
    p_class_id: parsed.data.classLevelId,
  });
  if (error || !data) {
    return { error: error ? withholdError(error.message) : 'Could not read the withhold list.' };
  }
  return { error: null, sheet: data as unknown as WithholdSheet };
}

export async function syncFeeWithholds(input: unknown): Promise<WithholdSyncState> {
  const parsed = syncFeeWithholdsSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_sync_fee_withholds', {
    p_exam_term_id: parsed.data.examTermId,
  });
  if (error || !data) {
    return { error: error ? withholdError(error.message) : 'Could not sync the fee withholds.' };
  }
  return { error: null, result: data as unknown as WithholdSyncResult };
}

export async function releaseWithhold(input: unknown): Promise<{ error: string | null }> {
  const parsed = releaseWithholdSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('release_result_withhold', {
    p_withhold_id: parsed.data.withholdId,
    p_reason: parsed.data.reason,
  });
  if (error) return { error: withholdError(error.message) };

  return { error: null };
}

export async function raiseWithhold(input: unknown): Promise<{ error: string | null }> {
  const parsed = raiseWithholdSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('raise_result_withhold', {
    p_enrolment_id: parsed.data.enrolmentId,
    p_exam_term_id: parsed.data.examTermId,
    p_reason: parsed.data.reason,
    p_note: parsed.data.note,
  });
  if (error) return { error: withholdError(error.message) };

  return { error: null };
}

export async function setWithholdThreshold(input: unknown): Promise<{ error: string | null }> {
  const parsed = setWithholdThresholdSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_result_withhold_threshold', {
    p_campus_id: parsed.data.campusId,
    p_paisa: parsed.data.rupees * 100,
  });
  if (error) return { error: withholdError(error.message) };

  return { error: null };
}
