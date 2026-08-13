'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { gradingSchemeError } from '@/lib/exams/errors';
import {
  gradingSchemeIdSchema,
  newGradingSchemeVersionSchema,
  saveGradingSchemeSchema,
} from '@/lib/validation';

/**
 * FR-J01. Nothing here writes to grading_scheme or grading_band directly:
 * both tables have a SELECT policy, an UPDATE policy whose WITH CHECK is
 * false, and no INSERT policy at all, so a client connection reaches no row.
 * save_grading_scheme(), activate_grading_scheme() and
 * new_grading_scheme_version() own every transition.
 */
const PATH = '/exams/grading';

export type GradingSchemeState = { error: string | null; schemeId?: string };

export async function saveGradingScheme(input: unknown): Promise<GradingSchemeState> {
  const parsed = saveGradingSchemeSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('save_grading_scheme', {
    p_board: parsed.data.board,
    p_name: parsed.data.name,
    p_effective_from: parsed.data.effectiveFrom,
    p_bands: parsed.data.bands.map((b) => ({
      grade_label: b.gradeLabel,
      min_pct: b.minPct,
      max_pct: b.maxPct,
      gpa_point: b.gpaPoint ?? null,
      is_pass: b.isPass,
      remark_en: b.remarkEn ?? null,
      remark_ur: b.remarkUr ?? null,
    })),
    p_scheme_id: parsed.data.schemeId ?? undefined,
  });
  if (error) return { error: gradingSchemeError(error.message) };

  revalidatePath(PATH);
  return { error: null, schemeId: data ?? undefined };
}

export async function activateGradingScheme(input: unknown): Promise<GradingSchemeState> {
  const parsed = gradingSchemeIdSchema.safeParse(input);
  if (!parsed.success) return { error: 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('activate_grading_scheme', { p_scheme_id: parsed.data.schemeId });
  if (error) return { error: gradingSchemeError(error.message) };

  revalidatePath(PATH);
  return { error: null, schemeId: parsed.data.schemeId };
}

/**
 * AC4. The only way to change an activated scale: the bands come across into a
 * new draft with its own effective date, and every result already computed
 * keeps pointing at the version it was graded on.
 */
export async function newGradingSchemeVersion(input: unknown): Promise<GradingSchemeState> {
  const parsed = newGradingSchemeVersionSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('new_grading_scheme_version', {
    p_scheme_id: parsed.data.schemeId,
    p_effective_from: parsed.data.effectiveFrom,
  });
  if (error) return { error: gradingSchemeError(error.message) };

  revalidatePath(PATH);
  return { error: null, schemeId: data ?? undefined };
}
