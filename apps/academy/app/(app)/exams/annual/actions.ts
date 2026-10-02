'use server';

import { supabaseServer } from '@/lib/supabase/server';
import { annualResultError } from '@/lib/exams/errors';
import type { AnnualResultSheet } from '@/lib/exams/annual-query';
import { computeAnnualResultSchema } from '@/lib/validation';

/**
 * FR-J03. Reading and recomputing, split the way FR-J02 split them: the
 * ordinary path is neither, because signing off a section's last paper already
 * chained into the aggregate. The button is for the correction case and for a
 * class whose sections finished on different days.
 *
 * The recompute is per CLASS, not per section — an annual result spans every
 * section of the class, which is the grain the FR's own signature asks for.
 */
export type AnnualSheetState = { error: string | null; sheet?: AnnualResultSheet };
export type ComputeAnnualState = { error: string | null; rows?: number };

export async function readAnnualSheet(sessionId: string, sectionId: string): Promise<AnnualSheetState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_annual_result_sheet', {
    p_session_id: sessionId,
    p_section_id: sectionId,
  });
  if (error || !data) {
    return { error: error ? annualResultError(error.message) : 'Could not read the annual results.' };
  }
  return { error: null, sheet: data as unknown as AnnualResultSheet };
}

export async function computeAnnualResults(input: unknown): Promise<ComputeAnnualState> {
  const parsed = computeAnnualResultSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_compute_annual_result', {
    p_session_id: parsed.data.sessionId,
    p_class_id: parsed.data.classLevelId,
  });
  if (error) return { error: annualResultError(error.message) };

  return { error: null, rows: data ?? 0 };
}
