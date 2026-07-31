'use server';

import { revalidatePath } from 'next/cache';
import {
  issueOfferSchema,
  respondToOfferSchema,
  setDocumentSubmissionSchema,
  uploadDocumentSchema,
  rejectDocumentSchema,
  MAX_DOCUMENT_FILE_SIZE,
  ALLOWED_DOCUMENT_MIME_TYPES,
  recordAdmissionFeePaymentSchema,
  waiveAdmissionFeeSchema,
  enrolFromOfferSchema,
} from '@/lib/validation';
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

export type ChecklistItem = { doc_type: string; is_mandatory: boolean; min_count: number };
export type MissingItem = { doc_type: string; required: number; have: number; missing: number };
export type ChecklistState = { error: string | null; complete: boolean | null; missing: MissingItem[] | null };

// FR-B09: the checklist an application was actually submitted under —
// frozen at submission time, never re-evaluated against today's config.
export async function checkChecklistCompleteness(applicationId: string): Promise<ChecklistState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_checklist_completeness', { p_application_id: applicationId });
  if (error) return { error: 'Could not check the checklist.', complete: null, missing: null };

  const result = data as { complete: boolean; missing: MissingItem[] };
  return { error: null, complete: result.complete, missing: result.missing };
}

export type SetDocumentSubmissionState = { error: string | null };

// FR-B09: record a document's status against an application's frozen
// checklist. 'promised' also creates a follow-up task for the deadline
// (set_document_submission()'s own job, not this action's).
export async function setDocumentSubmission(_prev: SetDocumentSubmissionState, formData: FormData): Promise<SetDocumentSubmissionState> {
  const parsed = setDocumentSubmissionSchema.safeParse({
    applicationId: formData.get('applicationId'),
    docType: formData.get('docType'),
    status: formData.get('status'),
    uploadedCount: formData.get('uploadedCount') || undefined,
    promisedDeadline: formData.get('promisedDeadline') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_document_submission', {
    p_application_id: parsed.data.applicationId,
    p_doc_type: parsed.data.docType,
    p_status: parsed.data.status,
    p_uploaded_count: parsed.data.uploadedCount,
    p_promised_deadline: parsed.data.promisedDeadline,
  });
  if (error) {
    if (error.message.includes('PROMISED_DEADLINE_REQUIRED')) return { error: 'Enter a deadline for the promised document.' };
    if (error.message.includes('PROMISED_DEADLINE_TOO_FAR')) return { error: 'The deadline must be within 30 days.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to update this checklist.' };
    return { error: 'Could not save the document status.' };
  }

  revalidatePath('/admissions/applications');
  return { error: null };
}

export type UploadDocumentState = { error: string | null };

// FR-B10: create_admission_document() reserves the metadata row (and
// therefore the exact storage_path) first; only then is the file itself
// uploaded to that path, so the admission_docs_insert_officer storage
// policy has a row to match against. If the upload itself fails,
// delete_admission_document() is the compensating rollback.
export async function uploadAdmissionDocument(_prev: UploadDocumentState, formData: FormData): Promise<UploadDocumentState> {
  const file = formData.get('file');
  if (!(file instanceof File) || file.size === 0) return { error: 'Choose a file to upload.' };

  const parsed = uploadDocumentSchema.safeParse({
    applicationId: formData.get('applicationId'),
    docType: formData.get('docType'),
    bFormNo: formData.get('bFormNo') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  // AC: rejected both client-side (the form checks this too) and
  // server-side — no object is stored either way.
  if (file.size > MAX_DOCUMENT_FILE_SIZE) return { error: 'Maximum file size 5 MB' };
  if (!ALLOWED_DOCUMENT_MIME_TYPES.includes(file.type as (typeof ALLOWED_DOCUMENT_MIME_TYPES)[number])) {
    return { error: 'Only JPEG, PNG, and PDF files are accepted.' };
  }

  const ext = file.name.includes('.') ? file.name.split('.').pop()! : 'bin';
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('create_admission_document', {
    p_application_id: parsed.data.applicationId,
    p_doc_type: parsed.data.docType,
    p_file_size: file.size,
    p_mime_type: file.type,
    p_file_ext: ext,
    p_b_form_no: parsed.data.bFormNo || undefined,
  });
  if (error) {
    if (error.message.includes('chk_admission_document_bform')) return { error: 'B-Form number must be 13 digits, e.g. 42101-1234567-8.' };
    if (error.message.includes('FILE_TOO_LARGE')) return { error: 'Maximum file size 5 MB' };
    if (error.message.includes('UNSUPPORTED_FILE_TYPE')) return { error: 'Only JPEG, PNG, and PDF files are accepted.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to upload documents.' };
    return { error: 'Could not start the upload.' };
  }

  const { document_id: documentId, storage_path: storagePath } = data as { document_id: string; storage_path: string };

  const { error: uploadError } = await supabase.storage
    .from('admission-docs')
    .upload(storagePath, file, { contentType: file.type, upsert: false });
  if (uploadError) {
    await supabase.rpc('delete_admission_document', { p_document_id: documentId });
    return { error: 'The file failed to upload. Please try again.' };
  }

  revalidatePath('/admissions/applications');
  return { error: null };
}

export async function verifyDocument(documentId: string): Promise<{ error: string | null }> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('verify_admission_document', { p_document_id: documentId });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to verify documents.' };
    return { error: 'Could not verify the document.' };
  }
  revalidatePath('/admissions/applications');
  return { error: null };
}

export type RejectDocumentState = { error: string | null };

export async function rejectDocument(_prev: RejectDocumentState, formData: FormData): Promise<RejectDocumentState> {
  const parsed = rejectDocumentSchema.safeParse({
    documentId: formData.get('documentId'),
    reason: formData.get('reason'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('reject_admission_document', {
    p_document_id: parsed.data.documentId,
    p_reason: parsed.data.reason,
  });
  if (error) {
    if (error.message.includes('REASON_REQUIRED')) return { error: 'Enter a reason for rejecting this document.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to reject documents.' };
    return { error: 'Could not reject the document.' };
  }
  revalidatePath('/admissions/applications');
  return { error: null };
}

export async function deleteDocument(documentId: string): Promise<{ error: string | null }> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('delete_admission_document', { p_document_id: documentId });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'Only a Principal can delete a verified document.' };
    return { error: 'Could not delete the document.' };
  }
  revalidatePath('/admissions/applications');
  return { error: null };
}

// AC: a signed URL is valid for 60 minutes, regardless of role.
export async function getDocumentSignedUrl(documentId: string): Promise<{ error: string | null; url: string | null }> {
  const supabase = await supabaseServer();
  const { data: doc, error: fetchError } = await supabase
    .from('admission_document')
    .select('storage_path')
    .eq('id', documentId)
    .single();
  if (fetchError || !doc) return { error: 'Document not found.', url: null };

  const { data, error } = await supabase.storage.from('admission-docs').createSignedUrl(doc.storage_path, 3600);
  if (error || !data) return { error: 'Could not generate a preview link.', url: null };
  return { error: null, url: data.signedUrl };
}

export type RecordAdmissionFeePaymentState = { error: string | null };

// FR-B17: record money against an accepted offer's admission fee.
// amountRupees converts to paisa only here, at the server-action
// boundary — record_admission_fee_payment() is bigint-paisa end to end.
export async function recordAdmissionFeePayment(
  _prev: RecordAdmissionFeePaymentState,
  formData: FormData
): Promise<RecordAdmissionFeePaymentState> {
  const parsed = recordAdmissionFeePaymentSchema.safeParse({
    offerId: formData.get('offerId'),
    amountRupees: formData.get('amountRupees'),
    mode: formData.get('mode'),
    referenceNo: formData.get('referenceNo') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('record_admission_fee_payment', {
    p_offer_id: parsed.data.offerId,
    p_amount_paisa: Math.round(parsed.data.amountRupees * 100),
    p_mode: parsed.data.mode,
    p_reference_no: parsed.data.referenceNo,
  });
  if (error) {
    if (error.message.includes('OFFER_NOT_ACCEPTED')) return { error: 'The offer must be accepted before recording a payment.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to record admission fee payments.' };
    return { error: 'Could not record the payment.' };
  }

  revalidatePath('/admissions/applications');
  return { error: null };
}

export async function reconcileAdmissionFeePayment(paymentId: string): Promise<{ error: string | null }> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('reconcile_admission_fee_payment', { p_payment_id: paymentId });
  if (error) {
    if (error.message.includes('PAYMENT_NOT_RECONCILABLE')) return { error: 'This payment is already reconciled.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to reconcile payments.' };
    return { error: 'Could not reconcile the payment.' };
  }
  revalidatePath('/admissions/applications');
  return { error: null };
}

export type WaiveAdmissionFeeState = { error: string | null };

export async function waiveAdmissionFee(_prev: WaiveAdmissionFeeState, formData: FormData): Promise<WaiveAdmissionFeeState> {
  const parsed = waiveAdmissionFeeSchema.safeParse({
    offerId: formData.get('offerId'),
    reason: formData.get('reason'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('waive_admission_fee', {
    p_offer_id: parsed.data.offerId,
    p_reason: parsed.data.reason,
  });
  if (error) {
    if (error.message.includes('OFFER_NOT_ACCEPTED')) return { error: 'The offer must be accepted before waiving its fee.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'Only an Owner or Principal can waive the admission fee.' };
    return { error: 'Could not record the waiver.' };
  }

  revalidatePath('/admissions/applications');
  return { error: null };
}

export type EnrolFromOfferState = { error: string | null; grNumber: string | null };

// FR-B17: the gate itself. fn_enrol_from_offer() checks the fee is fully
// covered (or waived) and creates the student/GR/enrolment/ledger rows
// atomically — this action only shapes the client-facing error.
export async function enrolFromOffer(_prev: EnrolFromOfferState, formData: FormData): Promise<EnrolFromOfferState> {
  const parsed = enrolFromOfferSchema.safeParse({
    offerId: formData.get('offerId'),
    sectionId: formData.get('sectionId'),
    gender: formData.get('gender'),
    paymentId: formData.get('paymentId') || undefined,
    waiverId: formData.get('waiverId') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', grNumber: null };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_enrol_from_offer', {
    p_offer_id: parsed.data.offerId,
    p_gender: parsed.data.gender,
    p_section_id: parsed.data.sectionId,
    p_payment_id: parsed.data.paymentId,
    p_waiver_id: parsed.data.waiverId,
  });
  if (error) {
    if (error.message.startsWith('OUTSTANDING_BALANCE:')) return { error: `Outstanding PKR ${error.message.split(':')[1]}.`, grNumber: null };
    if (error.message.includes('PAYMENT_NOT_RECONCILED'))
      return { error: 'This payment has not been reconciled against the bank statement yet.', grNumber: null };
    if (error.message.includes('PAYMENT_ALREADY_CONSUMED') || error.message.includes('WAIVER_ALREADY_CONSUMED'))
      return { error: 'This payment or waiver has already been used to enrol a student.', grNumber: null };
    if (error.message.includes('SECTION_REQUIRED')) return { error: 'Choose a section.', grNumber: null };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to enrol students.', grNumber: null };
    return { error: 'Could not enrol the student.', grNumber: null };
  }

  revalidatePath('/admissions/applications');
  revalidatePath('/students');
  return { error: null, grNumber: (data as { gr_number: string } | null)?.gr_number ?? null };
}
