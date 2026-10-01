'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { appraisalCycleSchema, appraisalDisputeSchema, appraisalScoresSchema } from '@/lib/validation';
import { parseCompetencies } from '@/lib/appraisal/scoring';
import { supabaseServer } from '@/lib/supabase/server';

export type AppraisalState = { error: string | null; message?: string | null; id?: string | null };

function mapError(message: string): string {
  if (message.includes('WEIGHTS_NOT_100')) return 'The competency weights must add up to exactly 100 before the cycle can be published.';
  if (message.includes('CYCLE_TEMPLATE_FROZEN')) return 'The cycle is published; its competencies can no longer be changed.';
  if (message.includes('CYCLE_ALREADY_PUBLISHED')) return 'This cycle is already published.';
  if (message.includes('SCORES_INCOMPLETE')) return 'Rate every competency before releasing the appraisal.';
  if (message.includes('RATING_OUT_OF_RANGE')) return 'Ratings are from 1 to 5.';
  if (message.includes('APPRAISAL_NOT_EDITABLE')) return 'This appraisal has been released and can no longer be changed.';
  if (message.includes('APPRAISAL_NOT_RELEASED')) return 'This appraisal has not been released, or is already closed.';
  if (message.includes('COMMENT_TOO_LONG')) return 'Your response can be at most 2000 characters.';
  if (message.includes('COMMENT_REQUIRED')) return 'Write your response.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  if (message.includes('APPRAISAL_NOT_FOUND') || message.includes('CYCLE_NOT_FOUND')) return 'Record not found.';
  if (message.includes('SESSION_NOT_FOUND')) return 'Academic session not found.';
  return 'Something went wrong. Please try again.';
}

const blank = (v: FormDataEntryValue | null) => (typeof v === 'string' && v.trim() !== '' ? v : undefined);

export async function createCycle(_prev: AppraisalState, formData: FormData): Promise<AppraisalState> {
  const p = appraisalCycleSchema.safeParse({
    sessionId: formData.get('sessionId'), name: formData.get('name'), opensOn: formData.get('opensOn'),
    closesOn: formData.get('closesOn'), minServiceDays: formData.get('minServiceDays'),
  });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const parsed = parseCompetencies(String(formData.get('competencies') ?? ''));
  // creating a cycle with a template that cannot be published is allowed (it stays a draft), but
  // lines that cannot even be read are not
  const unreadable = parsed.errors.filter((e) => e.startsWith('Line '));
  if (unreadable.length > 0) return { error: unreadable[0]! };
  const supabase = await supabaseServer();
  const { data: id, error } = await supabase.rpc('create_appraisal_cycle', {
    p_session_id: p.data.sessionId, p_name: p.data.name, p_opens_on: p.data.opensOn, p_closes_on: p.data.closesOn, p_min_service_days: p.data.minServiceDays,
  });
  if (error || !id) return { error: mapError(error?.message ?? '') };
  if (parsed.items.length > 0) {
    const { error: cErr } = await supabase.rpc('set_cycle_competencies', {
      p_cycle_id: id as string,
      p_competencies: parsed.items.map((c) => ({ name: c.name, weight_pct: c.weightPct })),
    });
    if (cErr) return { error: mapError(cErr.message) };
  }
  revalidatePath('/staff/appraisals');
  return { error: null, message: 'Cycle created as a draft.', id: id as string };
}

export async function saveCompetencies(_prev: AppraisalState, formData: FormData): Promise<AppraisalState> {
  const cycleId = z.string().uuid().safeParse(formData.get('cycleId'));
  if (!cycleId.success) return { error: 'Invalid cycle.' };
  const parsed = parseCompetencies(String(formData.get('competencies') ?? ''));
  const unreadable = parsed.errors.filter((e) => e.startsWith('Line '));
  if (unreadable.length > 0) return { error: unreadable[0]! };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_cycle_competencies', {
    p_cycle_id: cycleId.data,
    p_competencies: parsed.items.map((c) => ({ name: c.name, weight_pct: c.weightPct })),
  });
  if (error) return { error: mapError(error.message) };
  revalidatePath(`/staff/appraisals/cycles/${cycleId.data}`);
  return { error: null, message: parsed.errors.length ? `Saved as a draft. ${parsed.errors[0]}` : 'Competencies saved.' };
}

export async function publishCycle(_prev: AppraisalState, formData: FormData): Promise<AppraisalState> {
  const cycleId = z.string().uuid().safeParse(formData.get('cycleId'));
  if (!cycleId.success) return { error: 'Invalid cycle.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('publish_appraisal_cycle', { p_cycle_id: cycleId.data });
  if (error) return { error: mapError(error.message) };
  revalidatePath(`/staff/appraisals/cycles/${cycleId.data}`);
  revalidatePath('/staff/appraisals');
  return { error: null, message: `Published. ${data ?? 0} appraisal(s) opened for eligible staff.` };
}

export async function saveScores(_prev: AppraisalState, formData: FormData): Promise<AppraisalState> {
  const ratings: { competencyId: string; rating: string }[] = [];
  for (const [k, v] of formData.entries()) {
    if (k.startsWith('rating:') && typeof v === 'string' && v !== '') ratings.push({ competencyId: k.slice('rating:'.length), rating: v });
  }
  const p = appraisalScoresSchema.safeParse({ appraisalId: formData.get('appraisalId'), ratings });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Rate at least one competency.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_appraisal_scores', {
    p_appraisal_id: p.data.appraisalId,
    p_scores: p.data.ratings.map((r) => ({ competency_id: r.competencyId, rating: r.rating })),
  });
  if (error) return { error: mapError(error.message) };
  revalidatePath(`/staff/appraisals/${p.data.appraisalId}`);
  return { error: null, message: 'Ratings saved.' };
}

export async function releaseAppraisal(_prev: AppraisalState, formData: FormData): Promise<AppraisalState> {
  const id = z.string().uuid().safeParse(formData.get('appraisalId'));
  if (!id.success) return { error: 'Invalid appraisal.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('release_appraisal', { p_appraisal_id: id.data });
  if (error) return { error: mapError(error.message) };
  revalidatePath(`/staff/appraisals/${id.data}`);
  revalidatePath('/staff/appraisals');
  return { error: null, message: `Released to the appraisee. Score: ${Number(data).toFixed(2)} of 100.` };
}

async function appraiseeAction(formData: FormData, rpc: 'acknowledge_appraisal' | 'finalise_appraisal', ok: string): Promise<AppraisalState> {
  const id = z.string().uuid().safeParse(formData.get('appraisalId'));
  if (!id.success) return { error: 'Invalid appraisal.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc(rpc, { p_appraisal_id: id.data });
  if (error) return { error: mapError(error.message) };
  revalidatePath(`/staff/appraisals/${id.data}`);
  revalidatePath('/staff/appraisals');
  return { error: null, message: ok };
}
export async function acknowledgeAppraisal(_prev: AppraisalState, formData: FormData) {
  return appraiseeAction(formData, 'acknowledge_appraisal', 'Acknowledged.');
}
export async function finaliseAppraisal(_prev: AppraisalState, formData: FormData) {
  return appraiseeAction(formData, 'finalise_appraisal', 'Appraisal closed.');
}

export async function disputeAppraisal(_prev: AppraisalState, formData: FormData): Promise<AppraisalState> {
  const p = appraisalDisputeSchema.safeParse({ appraisalId: formData.get('appraisalId'), comment: blank(formData.get('comment')) ?? '' });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('dispute_appraisal', { p_appraisal_id: p.data.appraisalId, p_comment: p.data.comment });
  if (error) return { error: mapError(error.message) };
  revalidatePath(`/staff/appraisals/${p.data.appraisalId}`);
  return { error: null, message: 'Your response has been recorded and sent to the Owner.' };
}
