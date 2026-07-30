'use server';

import { revalidatePath } from 'next/cache';
import { createEnquirySchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type CreateEnquiryState = { error: string | null };

// FR-B01: capture an admissions enquiry. Authorization (admissions-adjacent
// role, campus in the caller's JWT campus_ids) and every business rule
// (referral needs a referrer, phone format, the Nursery-only age gate) are
// enforced inside create_enquiry() itself — this action only shapes the
// client-facing error.
export async function createEnquiry(_prev: CreateEnquiryState, formData: FormData): Promise<CreateEnquiryState> {
  const parsed = createEnquirySchema.safeParse({
    campusId: formData.get('campusId'),
    sessionId: formData.get('sessionId'),
    childName: formData.get('childName'),
    childNameUr: formData.get('childNameUr') || undefined,
    dob: formData.get('dob'),
    classAppliedId: formData.get('classAppliedId'),
    parentName: formData.get('parentName'),
    parentCnic: formData.get('parentCnic') || undefined,
    phone: formData.get('phone'),
    whatsappOptIn: formData.get('whatsappOptIn') === 'on',
    source: formData.get('source'),
    referrerName: formData.get('referrerName') || undefined,
    ageOverrideReason: formData.get('ageOverrideReason') || undefined,
  });
  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  }

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_enquiry', {
    p_campus_id: parsed.data.campusId,
    p_session_id: parsed.data.sessionId,
    p_child_name: parsed.data.childName,
    p_child_name_ur: parsed.data.childNameUr,
    p_dob: parsed.data.dob,
    p_class_applied_id: parsed.data.classAppliedId,
    p_parent_name: parsed.data.parentName,
    p_parent_cnic: parsed.data.parentCnic,
    p_phone: parsed.data.phone,
    p_whatsapp_opt_in: parsed.data.whatsappOptIn,
    p_source: parsed.data.source,
    p_referrer_name: parsed.data.referrerName,
    p_age_override_reason: parsed.data.ageOverrideReason,
  });

  if (error) {
    if (error.message.includes('Referrer required')) return { error: 'Referrer required for referral enquiries.' };
    if (error.message.includes('PHONE_INVALID')) return { error: 'Enter a valid phone number, e.g. 03001234567.' };
    if (error.message.includes('AGE_BELOW_MINIMUM_NEEDS_OVERRIDE'))
      return { error: 'This child is under 2y6m for Nursery — add an override reason to proceed.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to record enquiries for this campus.' };
    return { error: 'Could not save the enquiry.' };
  }

  revalidatePath('/admissions/enquiries');
  return { error: null };
}
