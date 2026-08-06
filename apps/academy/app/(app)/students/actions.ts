'use server';

import { revalidatePath } from 'next/cache';
import {
  createStudentSchema,
  linkGuardianSchema,
  enrolStudentSchema,
  proposeFeePlanOverrideSchema,
  requestConcessionAwardSchema,
  decideConcessionAwardSchema,
  postLedgerEntrySchema,
  reverseLedgerEntrySchema,
  recordPaymentSchema,
} from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type CreateStudentState = { error: string | null; studentId: string | null };

// FR-C04: create a student profile. GR allocation (FR-C01), B-Form
// normalization and duplicate detection all happen inside create_student()
// itself — this action only shapes the client-facing error.
export async function createStudent(_prev: CreateStudentState, formData: FormData): Promise<CreateStudentState> {
  const parsed = createStudentSchema.safeParse({
    campusId: formData.get('campusId'),
    nameEn: formData.get('nameEn'),
    nameUr: formData.get('nameUr') || undefined,
    dob: formData.get('dob'),
    gender: formData.get('gender'),
    fatherNameEn: formData.get('fatherNameEn') || undefined,
    fatherNameUr: formData.get('fatherNameUr') || undefined,
    bFormNo: formData.get('bFormNo') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', studentId: null };

  const supabase = await supabaseServer();
  const { data: studentId, error } = await supabase.rpc('create_student', {
    p_campus_id: parsed.data.campusId,
    p_name_en: parsed.data.nameEn,
    p_dob: parsed.data.dob,
    p_gender: parsed.data.gender,
    p_name_ur: parsed.data.nameUr,
    p_father_name_en: parsed.data.fatherNameEn,
    p_father_name_ur: parsed.data.fatherNameUr,
    p_b_form_no: parsed.data.bFormNo,
  });

  if (error) {
    if (error.message.includes('BFORM_INVALID_FORMAT')) return { error: 'B-Form number must resolve to 13 digits.', studentId: null };
    if (error.message.includes('BFORM_DUPLICATE')) return { error: 'Another student already holds this B-Form number.', studentId: null };
    if (error.message.includes('chk_dob_reasonable'))
      return { error: 'Date of birth must be in the past and imply an age under 25.', studentId: null };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to admit students at this campus.', studentId: null };
    return { error: 'Could not save the student.', studentId: null };
  }

  revalidatePath('/students');
  return { error: null, studentId };
}

export type LinkGuardianState = { error: string | null };

// FR-C09/C10: find-or-create the guardian by CNIC (dedup), then link them
// to the student. Both RPCs enforce their own authorization and business
// rules (billing-recipient requirement, primary-guardian exclusivity).
export async function linkGuardianToStudent(studentId: string, _prev: LinkGuardianState, formData: FormData): Promise<LinkGuardianState> {
  const parsed = linkGuardianSchema.safeParse({
    nameEn: formData.get('nameEn'),
    cnic: formData.get('cnic') || undefined,
    phone: formData.get('phone') || undefined,
    relationship: formData.get('relationship'),
    isPrimary: formData.get('isPrimary') === 'on',
    receivesBilling: formData.get('receivesBilling') === 'on',
    mayCollectChild: formData.get('mayCollectChild') === 'on',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data: guardianId, error: findError } = await supabase.rpc('fn_find_or_create_guardian', {
    p_name_en: parsed.data.nameEn,
    p_cnic: parsed.data.cnic,
    p_phone_e164: parsed.data.phone,
  });
  if (findError) {
    if (findError.message.includes('ID_INVALID_FORMAT')) return { error: 'CNIC must resolve to 13 digits.' };
    return { error: 'Could not save the guardian.' };
  }

  const { error: linkError } = await supabase.rpc('link_guardian', {
    p_student_id: studentId,
    p_guardian_id: guardianId,
    p_relationship: parsed.data.relationship,
    p_is_primary: parsed.data.isPrimary,
    p_receives_billing: parsed.data.receivesBilling,
    p_may_collect_child: parsed.data.mayCollectChild,
  });
  if (linkError) {
    if (linkError.message.includes('PRIMARY_GUARDIAN_EXISTS')) return { error: 'This student already has a primary guardian.' };
    if (linkError.message.includes('fee notices')) return { error: 'At least one guardian must receive fee notices.' };
    return { error: 'Could not link the guardian.' };
  }

  revalidatePath(`/students/${studentId}`);
  return { error: null };
}

export type SendGuardianInviteState = { error: string | null; result: { token: string; expiresAt: string } | null };

// FR-C11: send (or re-send, superseding any outstanding one) a portal
// activation link. The raw token only ever exists in this one response —
// only its hash is stored — so a 'print' channel result is shown once here
// for the officer to hand the guardian a slip, never persisted or re-
// fetchable afterward.
export async function sendGuardianPortalInvite(
  guardianId: string,
  channel: 'whatsapp' | 'sms' | 'print',
  _prev: SendGuardianInviteState,
  _formData: FormData,
): Promise<SendGuardianInviteState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('send_guardian_invite', { p_guardian_id: guardianId, p_channel: channel });
  if (error) {
    if (error.message.includes('GUARDIAN_PHONE_MISSING')) return { error: 'This guardian has no phone number on file.', result: null };
    if (error.message.includes('GUARDIAN_ALREADY_ACTIVE')) return { error: 'This guardian already has a portal account.', result: null };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to send portal invites.', result: null };
    return { error: 'Could not send the invite.', result: null };
  }

  const payload = data as { token: string; expires_at: string };
  return { error: null, result: { token: payload.token, expiresAt: payload.expires_at } };
}

export type EnrolStudentState = { error: string | null };

// FR-E03/C02: enrol into a section. Capacity, gender restriction and the
// advisory-lock race guard all live inside enrol_student() itself.
export async function enrolStudentIntoSection(studentId: string, _prev: EnrolStudentState, formData: FormData): Promise<EnrolStudentState> {
  const parsed = enrolStudentSchema.safeParse({ sectionId: formData.get('sectionId') });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('enrol_student', { p_section_id: parsed.data.sectionId, p_student_id: studentId });

  if (error) {
    if (error.message.includes('SECTION_FULL')) return { error: 'This section is full.' };
    if (error.message.includes('SECTION_GENDER_RESTRICTED')) return { error: 'This section does not admit this student’s gender.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to enrol students at this campus.' };
    return { error: 'Could not enrol the student.' };
  }

  revalidatePath(`/students/${studentId}`);
  return { error: null };
}

export type FeePlanActionState = { error: string | null };

// FR-K04: propose lowering (or raising) a fee plan line's amount.
// amountRupees converts to paisa only here, at the server-action boundary
// — never touches the live amount_paisa until a Principal approves.
export async function proposeFeePlanOverride(studentId: string, _prev: FeePlanActionState, formData: FormData): Promise<FeePlanActionState> {
  const parsed = proposeFeePlanOverrideSchema.safeParse({
    lineId: formData.get('lineId'),
    amountRupees: formData.get('amountRupees'),
    reason: formData.get('reason'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('propose_fee_plan_override', {
    p_line_id: parsed.data.lineId,
    p_new_amount_paisa: Math.round(parsed.data.amountRupees * 100),
    p_reason: parsed.data.reason,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to adjust fee plan lines.' };
    return { error: 'Could not propose the adjustment.' };
  }

  revalidatePath(`/students/${studentId}`);
  return { error: null };
}

// FR-K04: approve or reject a pending override. Approval is the only path
// that ever moves amount_paisa after the plan's initial snapshot.
export async function decideFeePlanOverride(studentId: string, lineId: string, approve: boolean): Promise<FeePlanActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('decide_fee_plan_override', { p_line_id: lineId, p_approve: approve });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to decide fee plan overrides.' };
    if (error.message.includes('OVERRIDE_NOT_PENDING')) return { error: 'This override was already decided.' };
    return { error: 'Could not record the decision.' };
  }

  revalidatePath(`/students/${studentId}`);
  return { error: null };
}

// FR-K04: remove a fee plan line. End-dated to the close of the current
// billing month inside remove_fee_plan_line() — never deleted, so a
// challan already issued this month stays correct.
export async function removeFeePlanLine(studentId: string, lineId: string): Promise<FeePlanActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('remove_fee_plan_line', { p_line_id: lineId });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to remove fee plan lines.' };
    if (error.message.includes('ALREADY_REMOVED')) return { error: 'This line was already removed.' };
    return { error: 'Could not remove the line.' };
  }

  revalidatePath(`/students/${studentId}`);
  return { error: null };
}

// FR-K06: request a concession award against a published scheme.
// Value-vs-scheme-max_value and requires_document are enforced inside
// request_concession_award() itself.
export async function requestConcessionAward(
  studentId: string,
  enrolmentId: string,
  _prev: FeePlanActionState,
  formData: FormData
): Promise<FeePlanActionState> {
  const parsed = requestConcessionAwardSchema.safeParse({
    schemeId: formData.get('schemeId'),
    value: formData.get('value'),
    effectiveFrom: formData.get('effectiveFrom'),
    effectiveTo: formData.get('effectiveTo'),
    documentPath: formData.get('documentPath') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('request_concession_award', {
    p_enrolment_id: enrolmentId,
    p_scheme_id: parsed.data.schemeId,
    p_value: parsed.data.value,
    p_effective_from: parsed.data.effectiveFrom,
    p_effective_to: parsed.data.effectiveTo,
    p_document_paths: parsed.data.documentPath ? [parsed.data.documentPath] : [],
  });
  if (error) {
    if (error.message.includes('VALUE_EXCEEDS_MAXIMUM')) return { error: 'This value exceeds the scheme’s maximum.' };
    if (error.message.includes('DOCUMENT_REQUIRED')) return { error: 'This scheme requires a supporting document.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to request concession awards.' };
    return { error: 'Could not submit the request.' };
  }

  revalidatePath(`/students/${studentId}`);
  return { error: null };
}

// FR-K06: approve or reject a pending award. Gated inside
// decide_concession_award() to the scheme's own approver_role.
export async function decideConcessionAward(
  studentId: string,
  awardId: string,
  approve: boolean,
  rejectionReason?: string
): Promise<FeePlanActionState> {
  const parsed = decideConcessionAwardSchema.safeParse({ awardId, approve, rejectionReason });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('decide_concession_award', {
    p_award_id: parsed.data.awardId,
    p_approve: parsed.data.approve,
    p_rejection_reason: parsed.data.rejectionReason,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to decide this award.' };
    if (error.message.includes('AWARD_NOT_PENDING')) return { error: 'This award was already decided.' };
    return { error: 'Could not record the decision.' };
  }

  revalidatePath(`/students/${studentId}`);
  return { error: null };
}

// FR-K14: post a ledger entry. amountRupees converts to paisa only here —
// amount_paisa is bigint end to end, direction carries the sign.
export async function postLedgerEntry(studentId: string, enrolmentId: string, _prev: FeePlanActionState, formData: FormData): Promise<FeePlanActionState> {
  const parsed = postLedgerEntrySchema.safeParse({
    entryType: formData.get('entryType'),
    amountRupees: formData.get('amountRupees'),
    direction: formData.get('direction'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('post_ledger_entry', {
    p_enrolment_id: enrolmentId,
    p_entry_type: parsed.data.entryType,
    p_amount_paisa: Math.round(parsed.data.amountRupees * 100),
    p_direction: parsed.data.direction,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to post ledger entries.' };
    return { error: 'Could not post the entry.' };
  }

  revalidatePath(`/students/${studentId}`);
  return { error: null };
}

// FR-K15: reverse a ledger entry — the only correction path for an
// append-only ledger. Owner-only, gated inside reverse_ledger_entry().
export async function reverseLedgerEntry(studentId: string, _prev: FeePlanActionState, formData: FormData): Promise<FeePlanActionState> {
  const parsed = reverseLedgerEntrySchema.safeParse({
    ledgerId: formData.get('ledgerId'),
    reason: formData.get('reason'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('reverse_ledger_entry', {
    p_ledger_id: parsed.data.ledgerId,
    p_reason: parsed.data.reason,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to reverse ledger entries — Owner only.' };
    if (error.message.includes('CANNOT_REVERSE_A_REVERSAL')) return { error: 'A reversal entry cannot itself be reversed.' };
    if (error.message.includes('duplicate key')) return { error: 'This entry was already reversed.' };
    return { error: 'Could not reverse the entry.' };
  }

  revalidatePath(`/students/${studentId}`);
  return { error: null };
}

// FR-K16: record a payment. The waterfall allocation across outstanding
// challans/heads runs inside record_payment() itself, in the same
// transaction as the payment insert — this action only shapes the
// client-facing error.
export async function recordPayment(studentId: string, enrolmentId: string, _prev: FeePlanActionState, formData: FormData): Promise<FeePlanActionState> {
  const parsed = recordPaymentSchema.safeParse({
    amountRupees: formData.get('amountRupees'),
    mode: formData.get('mode'),
    referenceNo: formData.get('referenceNo') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('record_payment', {
    p_enrolment_id: enrolmentId,
    p_amount_paisa: Math.round(parsed.data.amountRupees * 100),
    p_mode: parsed.data.mode,
    p_reference_no: parsed.data.referenceNo,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to record payments.' };
    if (error.message.includes('AMOUNT_MUST_BE_POSITIVE')) return { error: 'Enter a positive amount.' };
    return { error: 'Could not record the payment.' };
  }

  revalidatePath(`/students/${studentId}`);
  return { error: null };
}
