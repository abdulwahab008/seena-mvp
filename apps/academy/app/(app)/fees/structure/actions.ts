'use server';

import { revalidatePath } from 'next/cache';
import { addStructureLineSchema, createDraftStructureSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

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

// FR-K02: add a line to a draft structure. amountRupees is converted to
// paisa here, at the server-action boundary — amount_paisa is bigint end
// to end from this point on, never a float. months (0-11) are packed into
// the 12-bit billing_month_mask add_structure_line() expects.
export async function addStructureLine(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = addStructureLineSchema.safeParse({
    structureId: formData.get('structureId'),
    classId: formData.get('classId'),
    groupCode: formData.get('groupCode') || undefined,
    feeHeadId: formData.get('feeHeadId'),
    amountRupees: formData.get('amountRupees'),
    frequency: formData.get('frequency'),
    months: formData.getAll('months').map(Number),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const amountPaisa = Math.round(parsed.data.amountRupees * 100);
  const billingMonthMask = parsed.data.months.reduce((mask, m) => mask | (1 << m), 0);

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('add_structure_line', {
    p_structure_id: parsed.data.structureId,
    p_class_id: parsed.data.classId,
    p_fee_head_id: parsed.data.feeHeadId,
    p_amount_paisa: amountPaisa,
    p_frequency: parsed.data.frequency,
    p_group_code: parsed.data.groupCode,
    p_billing_month_mask: billingMonthMask,
  });
  if (error) {
    if (error.message.includes('duplicate key')) return { error: 'A line for this class, group and fee head already exists.' };
    if (error.message.includes('STRUCTURE_NOT_DRAFT')) return { error: 'This structure is no longer a draft.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to edit fee structures.' };
    return { error: 'Could not add the line.' };
  }

  revalidatePath('/fees/structure');
  return { error: null };
}

export async function publishStructure(structureId: string, _prev: ActionState, _formData: FormData): Promise<ActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('publish_fee_structure', { p_structure_id: structureId });
  if (error) {
    if (error.message.includes('MANDATORY_HEAD_COVERAGE_GAP'))
      return { error: 'Every active class needs a line for each mandatory fee head before this structure can publish.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to publish fee structures.' };
    return { error: 'Could not publish the structure.' };
  }

  revalidatePath('/fees/structure');
  return { error: null };
}
