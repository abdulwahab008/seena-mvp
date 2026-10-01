'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { promotionError, type PromotionSheet } from '@/lib/exams/promotion-query';
import { evaluatePromotionSchema, overridePromotionSchema, promotionRuleSchema } from '@/lib/validation';

/**
 * FR-J04. Reading, evaluating, configuring the rule, and the Principal's
 * override. Every one is a single RPC: the rule, the decision and the
 * hand-off check live in the database so the screen cannot disagree with the
 * enrolment gate.
 */
export type PromotionSheetState = { error: string | null; sheet?: PromotionSheet };
export type PromotionActionState = { error: string | null; message?: string };

export async function readPromotionSheet(sessionId: string, classId: string): Promise<PromotionSheetState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_promotion_sheet', { p_session_id: sessionId, p_class_id: classId });
  if (error || !data) return { error: error ? promotionError(error.message) : 'Could not read the decisions.' };
  return { error: null, sheet: data as unknown as PromotionSheet };
}

export async function evaluatePromotion(input: unknown): Promise<PromotionActionState> {
  const parsed = evaluatePromotionSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_evaluate_promotion', {
    p_session_id: parsed.data.sessionId,
    p_class_id: parsed.data.classId,
  });
  if (error) return { error: promotionError(error.message) };
  const r = data as unknown as { evaluated: number; conflicts: number };
  revalidatePath('/exams/promotion');
  return {
    error: null,
    message:
      r.conflicts > 0
        ? `${r.evaluated} candidates evaluated. ${r.conflicts} already enrolled in the next class need attention.`
        : `${r.evaluated} candidates evaluated.`,
  };
}

export async function savePromotionRule(input: unknown): Promise<PromotionActionState> {
  const parsed = promotionRuleSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_promotion_rule', {
    p_campus_id: parsed.data.campusId,
    p_class_id: parsed.data.classId as string,
    p_min_aggregate_pct: parsed.data.minAggregatePct,
    p_max_failed_for_compartment: parsed.data.maxFailedForCompartment,
    p_max_failed_for_promotion: parsed.data.maxFailedForPromotion,
  });
  if (error) return { error: promotionError(error.message) };
  revalidatePath('/exams/promotion');
  return { error: null, message: 'Rule saved. Evaluate again to apply it.' };
}

export async function overridePromotion(input: unknown): Promise<PromotionActionState> {
  const parsed = overridePromotionSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('override_promotion_decision', {
    p_decision_id: parsed.data.decisionId,
    p_new_decision: parsed.data.decision,
    p_reason: parsed.data.reason,
  });
  if (error) return { error: promotionError(error.message) };
  revalidatePath('/exams/promotion');
  return { error: null, message: 'Decision overridden.' };
}
