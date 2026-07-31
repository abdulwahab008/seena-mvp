'use server';

import { revalidatePath } from 'next/cache';
import { cloneAcademicStructureSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type RolloverSummary = {
  sections: { created: number; skipped: number };
  class_subject_maps: { created: number; skipped: number };
  allocations: { created: number; skipped: number };
  resigned_staff_allocations: { role: string; section_name: string; subject_name?: string; staff_name: string }[];
  run_id: string;
};
export type RolloverState = { error: string | null; summary: RolloverSummary | null; applied: boolean };

async function runClone(formData: FormData, dryRun: boolean): Promise<RolloverState> {
  const parsed = cloneAcademicStructureSchema.safeParse({
    campusId: formData.get('campusId'),
    fromSessionId: formData.get('fromSessionId'),
    toSessionId: formData.get('toSessionId'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', summary: null, applied: false };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('clone_academic_structure', {
    p_from_session_id: parsed.data.fromSessionId,
    p_to_session_id: parsed.data.toSessionId,
    p_campus_id: parsed.data.campusId,
    p_dry_run: dryRun,
  });
  if (error) {
    if (error.message.includes('SAME_SESSION')) return { error: 'The source and target sessions must be different.', summary: null, applied: false };
    if (error.message.includes('FROM_SESSION_NOT_FOUND')) return { error: 'The source session could not be found.', summary: null, applied: false };
    if (error.message.includes('TO_SESSION_NOT_FOUND')) return { error: 'The target session could not be found.', summary: null, applied: false };
    if (error.message.includes('CAMPUS_NOT_FOUND')) return { error: 'This campus could not be found.', summary: null, applied: false };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to roll over the academic structure.', summary: null, applied: false };
    return { error: 'Could not run the rollover.', summary: null, applied: false };
  }

  if (!dryRun) revalidatePath('/academic-setup/rollover');
  return { error: null, summary: data as RolloverSummary, applied: !dryRun };
}

// FR-E11: preview what a rollover would create, writing nothing.
export async function previewRollover(_prev: RolloverState, formData: FormData): Promise<RolloverState> {
  return runClone(formData, true);
}

// FR-E11: apply the rollover for real — idempotent, safe to click again.
export async function applyRollover(_prev: RolloverState, formData: FormData): Promise<RolloverState> {
  return runClone(formData, false);
}
