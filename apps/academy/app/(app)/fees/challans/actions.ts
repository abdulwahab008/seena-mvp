'use server';

import { revalidatePath } from 'next/cache';
import { generateChallansSchema, buildChallanRenderPayloadSchema, setChallanTemplateSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type GenerateResult = {
  error: string | null;
  generated?: number;
  skipped?: number;
  failed?: number;
  dryRun?: boolean;
  previewByClass?: Record<string, number>;
};

type GenerateChallansResponse = {
  batch_id: string | null;
  generated: number;
  skipped: number;
  failed: number;
  dry_run: boolean;
  preview_by_class: Record<string, number>;
};

// FR-K09: runs generate_challans() for one (campus, session, billing month).
// The dry-run branch never revalidates the page — it writes nothing, so
// there's nothing new for the challan list or batch history to show.
export async function generateChallans(_prev: GenerateResult, formData: FormData): Promise<GenerateResult> {
  const parsed = generateChallansSchema.safeParse({
    campusId: formData.get('campusId'),
    sessionId: formData.get('sessionId'),
    period: formData.get('period'),
    dryRun: formData.get('dryRun') === 'on',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('generate_challans', {
    p_campus_id: parsed.data.campusId,
    p_session_id: parsed.data.sessionId,
    p_period: `${parsed.data.period}-01`,
    p_dry_run: parsed.data.dryRun,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to generate challans.' };
    if (error.message.includes('CAMPUS_NOT_FOUND')) return { error: 'Campus not found.' };
    if (error.message.includes('SESSION_NOT_FOUND')) return { error: 'Session not found.' };
    return { error: 'Could not generate challans.' };
  }

  if (!parsed.data.dryRun) revalidatePath('/fees/challans');

  const result = data as GenerateChallansResponse;
  return {
    error: null,
    generated: result.generated,
    skipped: result.skipped,
    failed: result.failed,
    dryRun: result.dry_run,
    previewByClass: result.preview_by_class,
  };
}

// FR-K11 (data layer only — see the migration header for why there's no
// PDF renderer yet): the exact JSON an Edge Function would consume to
// draw the three copies. Surfaced here as a read-only preview so the
// feature is genuinely visible and testable through the UI now, not
// just from pgTAP.
export type PayloadResult = { error: string | null; payload?: unknown };

export async function buildChallanRenderPayload(_prev: PayloadResult, formData: FormData): Promise<PayloadResult> {
  const parsed = buildChallanRenderPayloadSchema.safeParse({ challanId: formData.get('challanId') });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('build_challan_render_payload', { p_challan_id: parsed.data.challanId });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to view this challan.' };
    if (error.message.includes('CHALLAN_NOT_FOUND')) return { error: 'Challan not found.' };
    return { error: 'Could not build the payload.' };
  }

  return { error: null, payload: data };
}

export type ActionState = { error: string | null };

export async function setChallanTemplate(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = setChallanTemplateSchema.safeParse({
    campusId: formData.get('campusId'),
    bankName: formData.get('bankName'),
    bankAccountTitle: formData.get('bankAccountTitle'),
    bankAccountNo: formData.get('bankAccountNo'),
    footerNoteEn: formData.get('footerNoteEn') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_challan_template', {
    p_campus_id: parsed.data.campusId,
    p_bank_name: parsed.data.bankName,
    p_bank_account_title: parsed.data.bankAccountTitle,
    p_bank_account_no: parsed.data.bankAccountNo,
    p_footer_note_en: parsed.data.footerNoteEn,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to configure the challan template.' };
    return { error: 'Could not save the template.' };
  }

  revalidatePath('/fees/challans');
  return { error: null };
}
