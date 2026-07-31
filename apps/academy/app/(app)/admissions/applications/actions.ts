'use server';

import { revalidatePath } from 'next/cache';
import { issueOfferSchema, respondToOfferSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type IssueOfferState = { error: string | null };

// FR-B15/B06: issue an offer. Seat availability (now offer-aware, see
// FR-B06's fix) and every authorization check live inside fn_issue_offer()
// — this action only shapes the client-facing error.
export async function issueOffer(applicationId: string, _prev: IssueOfferState, formData: FormData): Promise<IssueOfferState> {
  const parsed = issueOfferSchema.safeParse({
    applicationId,
    feeAmount: formData.get('feeAmount'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('fn_issue_offer', {
    p_application_id: parsed.data.applicationId,
    p_admission_fee_amount: parsed.data.feeAmount,
  });
  if (error) {
    if (error.message.includes('NO_SEATS_AVAILABLE')) return { error: 'No seats available for this class.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to issue offers.' };
    if (error.message.includes('duplicate key')) return { error: 'An active offer already exists for this application.' };
    return { error: 'Could not issue the offer.' };
  }

  revalidatePath('/admissions/applications');
  return { error: null };
}

export type RespondToOfferState = { error: string | null };

// FR-B16: record a guardian's response to an offer. Staff-side action for
// now — there is no guardian portal yet for them to do this themselves.
export async function respondToOffer(_prev: RespondToOfferState, formData: FormData): Promise<RespondToOfferState> {
  const parsed = respondToOfferSchema.safeParse({
    offerId: formData.get('offerId'),
    response: formData.get('response'),
    declineReason: formData.get('declineReason') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('fn_respond_to_offer', {
    p_offer_id: parsed.data.offerId,
    p_response: parsed.data.response,
    p_decline_reason: parsed.data.declineReason,
  });
  if (error) {
    if (error.message.includes('DECLINE_REASON_REQUIRED')) return { error: 'Choose a reason for declining.' };
    if (error.message.includes('OFFER_NOT_RESPONDABLE')) return { error: 'This offer can no longer be responded to.' };
    if (error.message.includes('OFFER_NOT_FOUND')) return { error: 'Offer not found.' };
    return { error: 'Could not record the response.' };
  }

  revalidatePath('/admissions/applications');
  return { error: null };
}

export type JoinWaitlistState = { error: string | null };

// FR-B07: queue an applicant for the next seat that opens up.
export async function joinWaitlist(applicationId: string): Promise<JoinWaitlistState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('join_waitlist', { p_application_id: applicationId });
  if (error) {
    if (error.message.includes('ALREADY_WAITLISTED')) return { error: 'This application is already on the waitlist.' };
    if (error.message.includes('APPLICATION_NOT_WAITLISTABLE')) return { error: 'This application can no longer join the waitlist.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to manage the waitlist.' };
    return { error: 'Could not add to the waitlist.' };
  }

  revalidatePath('/admissions/applications');
  return { error: null };
}

export type RemoveFromWaitlistState = { error: string | null };

// FR-B07: a family withdraws, or the officer removes them manually — the
// reason is recorded on the audit trail.
export async function removeFromWaitlist(waitlistId: string, reason: string): Promise<RemoveFromWaitlistState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('remove_from_waitlist', { p_waitlist_id: waitlistId, p_reason: reason });
  if (error) {
    if (error.message.includes('REMOVAL_REASON_REQUIRED')) return { error: 'Enter a reason for removing this applicant.' };
    if (error.message.includes('NOT_WAITING')) return { error: 'This applicant is no longer waiting.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to manage the waitlist.' };
    return { error: 'Could not remove this applicant from the waitlist.' };
  }

  revalidatePath('/admissions/applications');
  return { error: null };
}
