'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import type { OnboardingStepKey } from './step-meta';

export type ActionState = { error: string | null };

// FR-A03: mark a step done or skipped. Never 'pending' — resetting a step
// back is not a supported action (complete_onboarding_step rejects it).
export async function markOnboardingStep(
  stepKey: OnboardingStepKey,
  status: 'done' | 'skipped',
  _prev: ActionState,
  _formData: FormData,
): Promise<ActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('complete_onboarding_step', { p_step_key: stepKey, p_status: status });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to update onboarding progress.' };
    return { error: 'Could not update this step.' };
  }

  revalidatePath('/onboarding');
  return { error: null };
}

// apply_class_preset() is idempotent (FR-A03's own notes) — re-applying
// after picking the wrong preset, or widening/narrowing later, is safe.
export async function applyClassPreset(
  tenantId: string,
  campusId: string,
  sessionId: string,
  presetCode: string,
  _prev: ActionState,
  _formData: FormData,
): Promise<ActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('apply_class_preset', {
    p_tenant_id: tenantId,
    p_campus_id: campusId,
    p_session_id: sessionId,
    p_preset_code: presetCode,
  });
  if (error) {
    if (error.message.includes('PRESET_NOT_FOUND')) return { error: 'Unknown class structure preset.' };
    if (error.message.includes('CAMPUS_NOT_FOUND')) return { error: 'Campus not found.' };
    if (error.message.includes('SESSION_NOT_FOUND')) return { error: 'Academic session not found.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to apply a class structure preset.' };
    return { error: 'Could not apply the preset.' };
  }

  await supabase.rpc('complete_onboarding_step', { p_step_key: 'class_structure', p_status: 'done' });
  revalidatePath('/onboarding');
  return { error: null };
}
