'use server';

import { revalidatePath } from 'next/cache';
import {
  addStructureLineSchema,
  createDraftStructureSchema,
  createNextStructureVersionSchema,
  updateStructureLineSchema,
  publishStructureSchema,
} from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null; note?: string };

export async function createDraftStructure(campusId: string, sessionId: string, _prev: ActionState, _formData: FormData): Promise<ActionState> {
  const parsed = createDraftStructureSchema.safeParse({ campusId, sessionId });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_draft_structure', {
    p_campus_id: parsed.data.campusId,
    p_session_id: parsed.data.sessionId,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to create a fee structure.' };
    return { error: 'Could not create a draft structure.' };
  }

  revalidatePath('/fees/structure');
  return { error: null };
}

const toMask = (months: number[]) => months.reduce((mask, m) => mask | (1 << m), 0);

function lineError(message: string, fallback: string): ActionState {
  if (message.includes('STRUCTURE_NOT_DRAFT')) return { error: 'Only a draft structure can be changed. Create the next version to revise a published one.' };
  if (message.includes('FORBIDDEN')) return { error: 'You do not have permission to edit fee structures.' };
  return { error: fallback };
}

// FR-K02: set one fee head for a range of classes (From..To in class order). Classes that already have
// the head are updated rather than rejected. Rupees become paisa here and stay bigint from this point on.
export async function addStructureLine(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = addStructureLineSchema.safeParse({
    structureId: formData.get('structureId'),
    classFromId: formData.get('classFromId'),
    classToId: formData.get('classToId') || undefined,
    groupCode: formData.get('groupCode') || undefined,
    feeHeadId: formData.get('feeHeadId'),
    amountRupees: formData.get('amountRupees'),
    frequency: formData.get('frequency'),
    months: formData.getAll('months').map(Number),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data: classes } = await supabase.from('class_level').select('id').eq('is_active', true).order('ordinal');
  const ids = (classes ?? []).map((c) => c.id);
  const from = ids.indexOf(parsed.data.classFromId);
  const to = parsed.data.classToId ? ids.indexOf(parsed.data.classToId) : from;
  if (from < 0 || to < 0) return { error: 'Choose a class.' };
  const classIds = ids.slice(Math.min(from, to), Math.max(from, to) + 1);

  const { data, error } = await supabase.rpc('set_structure_lines', {
    p_structure_id: parsed.data.structureId,
    p_class_ids: classIds,
    p_fee_head_id: parsed.data.feeHeadId,
    p_amount_paisa: Math.round(parsed.data.amountRupees * 100),
    p_frequency: parsed.data.frequency,
    p_group_code: parsed.data.groupCode,
    p_billing_month_mask: toMask(parsed.data.months),
  });
  if (error) return lineError(error.message, 'Could not save the fee.');

  revalidatePath('/fees/structure');
  const { added, updated } = data as { added: number; updated: number };
  if (added === 1 && updated === 0) return { error: null, note: 'Line added.' };
  if (added === 0 && updated === 1) return { error: null, note: 'Line updated.' };
  const parts = [added && `added ${added}`, updated && `updated ${updated}`].filter(Boolean).join(', ');
  return { error: null, note: `${parts.charAt(0).toUpperCase()}${parts.slice(1)} lines.` };
}

export async function publishStructure(structureId: string, _prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = publishStructureSchema.safeParse({
    structureId,
    regulatorReference: formData.get('regulatorReference') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('publish_fee_structure', {
    p_structure_id: parsed.data.structureId,
    p_regulator_reference: parsed.data.regulatorReference,
  });
  if (error) {
    if (error.message.includes('MANDATORY_HEAD_COVERAGE_GAP'))
      return { error: 'Every active class needs a line for each mandatory fee head before this structure can publish.' };
    if (error.message.includes('REGULATOR_REFERENCE_REQUIRED'))
      return { error: 'This revision exceeds the allowed average increase — enter a regulator reference (4+ characters) to proceed.' };
    if (error.message.includes('FORBIDDEN'))
      return { error: 'You do not have permission to publish fee structures, or this above-cap increase needs an Owner/Super Admin.' };
    return { error: 'Could not publish the structure.' };
  }

  revalidatePath('/fees/structure');
  return { error: null };
}

// FR-K03: clone a published structure into a new draft version, effective
// from a future date — the prior version stays intact and, once this one
// publishes, becomes 'superseded' rather than edited or deleted.
export async function createNextStructureVersion(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = createNextStructureVersionSchema.safeParse({
    priorStructureId: formData.get('priorStructureId'),
    effectiveFrom: formData.get('effectiveFrom'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_next_structure_version', {
    p_prior_structure_id: parsed.data.priorStructureId,
    p_effective_from: parsed.data.effectiveFrom,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to create a new structure version.' };
    if (error.message.includes('PRIOR_STRUCTURE_NOT_PUBLISHED')) return { error: 'Only a published structure can be revised.' };
    return { error: 'Could not create the new version.' };
  }

  revalidatePath('/fees/structure');
  return { error: null };
}

export async function updateStructureLine(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = updateStructureLineSchema.safeParse({
    lineId: formData.get('lineId'),
    amountRupees: formData.get('amountRupees'),
    frequency: formData.get('frequency'),
    months: formData.getAll('months').map(Number),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('update_structure_line', {
    p_line_id: parsed.data.lineId,
    p_amount_paisa: Math.round(parsed.data.amountRupees * 100),
    p_frequency: parsed.data.frequency,
    p_billing_month_mask: toMask(parsed.data.months),
  });
  if (error) return lineError(error.message, 'Could not update the line.');

  revalidatePath('/fees/structure');
  return { error: null };
}

export async function removeStructureLine(lineId: string): Promise<ActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('remove_structure_line', { p_line_id: lineId });
  if (error) return lineError(error.message, 'Could not delete the line.');

  revalidatePath('/fees/structure');
  return { error: null };
}
