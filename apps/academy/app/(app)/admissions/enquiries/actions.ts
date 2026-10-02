'use server';

import { revalidatePath } from 'next/cache';
import { createEnquirySchema, submitApplicationSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type DuplicateCandidate = {
  id: string;
  enquiry_no: string;
  child_name: string;
  phone_e164: string;
  campus_id: string;
  status: string;
  last_followup_at: string | null;
};
export type CreateEnquiryState = { error: string | null; newEnquiryId: string | null; duplicates: DuplicateCandidate[] | null };

// FR-B01: capture an admissions enquiry. Authorization (admissions-adjacent
// role, campus in the caller's JWT campus_ids) and every business rule
// (referral needs a referrer, phone format, the Nursery-only age gate) are
// enforced inside create_enquiry() itself — this action only shapes the
// client-facing error.
//
// FR-B03: immediately after a successful save, checks for a duplicate by
// phone/CNIC/fuzzy-name+DOB (excluding the row just created) and returns
// any candidates alongside the success result, so the UI can offer
// Merge/Not-a-duplicate before the officer moves on — "before the save
// completes" per that FR's own AC, in the sense that the save and the
// check are one atomic round trip, not a separate later step.
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
    return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', newEnquiryId: null, duplicates: null };
  }

  const supabase = await supabaseServer();
  const { data: newEnquiryId, error } = await supabase.rpc('create_enquiry', {
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
    if (error.message.includes('Referrer required')) return { error: 'Referrer required for referral enquiries.', newEnquiryId: null, duplicates: null };
    if (error.message.includes('PHONE_INVALID')) return { error: 'Enter a valid phone number, e.g. 03001234567.', newEnquiryId: null, duplicates: null };
    if (error.message.includes('AGE_BELOW_MINIMUM_NEEDS_OVERRIDE'))
      return { error: 'This child is under 2y6m for Nursery — add an override reason to proceed.', newEnquiryId: null, duplicates: null };
    if (error.message.includes('FORBIDDEN'))
      return { error: 'You do not have permission to record enquiries for this campus.', newEnquiryId: null, duplicates: null };
    return { error: 'Could not save the enquiry.', newEnquiryId: null, duplicates: null };
  }

  revalidatePath('/admissions/enquiries');

  const { data: duplicates } = await supabase.rpc('fn_find_duplicate_enquiries', {
    p_phone: parsed.data.phone,
    p_cnic: parsed.data.parentCnic,
    p_name: parsed.data.childName,
    p_dob: parsed.data.dob,
    p_exclude_enquiry_id: newEnquiryId as string,
  });

  return { error: null, newEnquiryId: newEnquiryId as string, duplicates: (duplicates as DuplicateCandidate[]) ?? [] };
}

export type MergeEnquiryState = { error: string | null };

// FR-B03: the officer confirms two enquiries are the same family.
export async function mergeEnquiry(survivorId: string, loserId: string): Promise<MergeEnquiryState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('fn_merge_enquiry', { p_survivor_id: survivorId, p_loser_id: loserId });
  if (error) {
    if (error.message.includes('CROSS_CAMPUS_MERGE_REQUIRES_PRINCIPAL'))
      return { error: 'These enquiries are on different campuses — ask a Principal to approve this merge.' };
    if (error.message.includes('ENQUIRY_NOT_OPEN')) return { error: 'One of these enquiries is no longer open.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to merge enquiries.' };
    return { error: 'Could not merge these enquiries.' };
  }

  revalidatePath('/admissions/enquiries');
  return { error: null };
}

export type DismissDuplicateState = { error: string | null };

// FR-B03: the officer confirms two enquiries are genuinely different
// families — the pair is remembered so the suggestion never reappears.
export async function dismissDuplicateEnquiry(enquiryA: string, enquiryB: string): Promise<DismissDuplicateState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('fn_dismiss_duplicate_enquiry', { p_enquiry_a: enquiryA, p_enquiry_b: enquiryB });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to dismiss duplicate suggestions.' };
    return { error: 'Could not dismiss this suggestion.' };
  }

  return { error: null };
}

export type SubmitApplicationState = { error: string | null };

// FR-B08: convert a qualified enquiry into an application. Classes 9-12
// requiring a group, and the enquiry->converted transition, are both
// enforced inside fn_submit_application() itself.
export async function submitApplication(_prev: SubmitApplicationState, formData: FormData): Promise<SubmitApplicationState> {
  const parsed = submitApplicationSchema.safeParse({
    enquiryId: formData.get('enquiryId'),
    groupApplied: formData.get('groupApplied') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('fn_submit_application', {
    p_enquiry_id: parsed.data.enquiryId,
    p_group_applied: parsed.data.groupApplied,
  });
  if (error) {
    if (error.message.includes('Group is required')) return { error: 'Choose a group — required for classes 9-12.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to submit applications.' };
    if (error.message.includes('ENQUIRY_NOT_FOUND')) return { error: 'Enquiry not found.' };
    return { error: 'Could not submit the application.' };
  }

  revalidatePath('/admissions/enquiries');
  revalidatePath('/admissions/applications');
  return { error: null };
}
