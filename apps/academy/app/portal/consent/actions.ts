'use server';

import { revalidatePath } from 'next/cache';
import { recordConsentSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type PortalConsentState = { error: string | null; effective?: boolean };

// The channel is forced to 'portal' here and again inside record_consent(),
// which also refuses to accept a guardian id the signed-in user does not
// own and refuses any evidence file from a parent — a guardian recording
// their own decision must not be able to manufacture a signed paper form.
export async function recordPortalConsent(_prev: PortalConsentState, formData: FormData): Promise<PortalConsentState> {
  const parsed = recordConsentSchema.safeParse({
    studentId: formData.get('studentId'),
    purposeCode: formData.get('purposeCode'),
    guardianId: formData.get('guardianId'),
    decision: formData.get('decision'),
    channel: 'portal',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('record_consent', {
    p_student_id: parsed.data.studentId,
    p_purpose_code: parsed.data.purposeCode,
    p_guardian_id: parsed.data.guardianId,
    p_decision: parsed.data.decision,
    p_channel: 'portal',
  });
  if (error) {
    if (error.message.includes('GUARDIAN_NOT_LINKED')) return { error: 'You are not currently listed as a guardian for this child.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You can only record your own decision for your own child.' };
    return { error: 'Could not save your choice.' };
  }

  revalidatePath('/portal/consent');
  return { error: null, effective: (data as { effective: boolean }).effective };
}
