import { z } from 'zod';

// Mirrors the `tenant_slug_format` CHECK constraint in
// supabase/migrations/20260729135955_foundation.sql — keep these in sync.
export const SLUG_REGEX = /^[a-z0-9][a-z0-9-]{2,49}$/;

export const slugSchema = z
  .string()
  .min(3, 'Must be at least 3 characters')
  .max(50, 'Must be at most 50 characters')
  .regex(SLUG_REGEX, 'Lowercase letters, numbers and hyphens only, must start with a letter or number');

export const provisionTenantSchema = z.object({
  slug: slugSchema,
  legalName: z.string().min(1, 'Required').max(200),
  ownerEmail: z.string().email('Must be a valid email address'),
});
export type ProvisionTenantInput = z.infer<typeof provisionTenantSchema>;

// Mirrors campus.code's implicit format (upper-cased, unique per tenant) —
// no DB regex constraint exists yet, this is the app-side floor.
export const campusCodeSchema = z
  .string()
  .min(2, 'At least 2 characters')
  .max(10, 'At most 10 characters')
  .regex(/^[A-Za-z0-9]+$/, 'Letters and numbers only');

export const createCampusSchema = z.object({
  code: campusCodeSchema,
  name: z.string().min(1, 'Required').max(200),
  city: z.string().max(100).optional(),
});
export type CreateCampusInput = z.infer<typeof createCampusSchema>;

export const createSessionSchema = z
  .object({
    name: z.string().min(1, 'Required').max(100),
    startsOn: z.string().min(1, 'Required'),
    endsOn: z.string().min(1, 'Required'),
  })
  .refine((v) => v.endsOn > v.startsOn, { message: 'End date must be after start date', path: ['endsOn'] });
export type CreateSessionInput = z.infer<typeof createSessionSchema>;

// Mirrors set_academic_terms()'s validation in
// supabase/migrations/20260729155339_session_lifecycle_and_terms.sql —
// client-side check is a UX nicety, the function is the real gate.
export const termSchema = z.object({
  name: z.string().min(1, 'Required').max(100),
  startsOn: z.string().min(1, 'Required'),
  endsOn: z.string().min(1, 'Required'),
  weightage: z.coerce.number().min(0.01).max(100),
});
export const termsSchema = z
  .object({ terms: z.array(termSchema).min(1, 'At least one term').max(4, 'At most 4 terms') })
  .refine((v) => Math.round(v.terms.reduce((s, t) => s + t.weightage, 0) * 100) / 100 === 100, {
    message: 'Weightages must sum to exactly 100',
    path: ['terms'],
  });
export type TermsInput = z.infer<typeof termsSchema>;

// Format itself is enforced by normalize_pk_phone() server-side (which
// knows the actual accepted input shapes) — this is just a non-empty floor.
export const otpPhoneSchema = z.object({ phone: z.string().min(1, 'Required') });
export type OtpPhoneInput = z.infer<typeof otpPhoneSchema>;

export const otpCodeSchema = z.object({
  code: z
    .string()
    .length(6, 'Enter the 6-digit code')
    .regex(/^\d{6}$/, 'Digits only'),
});
export type OtpCodeInput = z.infer<typeof otpCodeSchema>;

// Mirrors public.enquiry_source in
// supabase/migrations/20260730060512_class_levels_and_enquiries.sql.
export const ENQUIRY_SOURCES = ['walk_in', 'phone', 'web', 'referral', 'other'] as const;

// Phone format itself is enforced by normalize_pk_phone() server-side; the
// referral->referrer requirement mirrors create_enquiry()'s own check, kept
// here too as an earlier, friendlier UX signal.
export const createEnquirySchema = z
  .object({
    campusId: z.string().uuid('Choose a campus'),
    sessionId: z.string().uuid('Choose a session'),
    childName: z.string().min(1, 'Required').max(200),
    childNameUr: z.string().max(200).optional(),
    dob: z.string().min(1, 'Required'),
    classAppliedId: z.string().uuid('Choose a class'),
    parentName: z.string().min(1, 'Required').max(200),
    parentCnic: z.string().max(20).optional(),
    phone: z.string().min(1, 'Required'),
    whatsappOptIn: z.boolean(),
    source: z.enum(ENQUIRY_SOURCES),
    referrerName: z.string().max(200).optional(),
    ageOverrideReason: z.string().max(500).optional(),
  })
  .refine((v) => v.source !== 'referral' || !!v.referrerName?.trim(), {
    message: 'Referrer required for referral enquiries',
    path: ['referrerName'],
  });
export type CreateEnquiryInput = z.infer<typeof createEnquirySchema>;

// Mirrors create_student()'s own checks in
// supabase/migrations/20260730121905_students.sql — B-Form normalization
// and the DOB sanity check are the DB's job; this is the earlier UX floor.
export const createStudentSchema = z.object({
  campusId: z.string().uuid('Choose a campus'),
  nameEn: z.string().min(1, 'Required').max(200),
  nameUr: z.string().max(200).optional(),
  dob: z.string().min(1, 'Required'),
  gender: z.enum(['male', 'female', 'other']),
  fatherNameEn: z.string().max(200).optional(),
  fatherNameUr: z.string().max(200).optional(),
  bFormNo: z.string().max(20).optional(),
});
export type CreateStudentInput = z.infer<typeof createStudentSchema>;

// Mirrors public.guardian_relationship in
// supabase/migrations/20260730151340_guardians_and_families.sql.
export const GUARDIAN_RELATIONSHIPS = [
  'father', 'mother', 'grandparent', 'uncle', 'aunt', 'sibling', 'legal_guardian', 'other',
] as const;

export const linkGuardianSchema = z.object({
  nameEn: z.string().min(1, 'Required').max(200),
  cnic: z.string().max(20).optional(),
  phone: z.string().max(20).optional(),
  relationship: z.enum(GUARDIAN_RELATIONSHIPS),
  isPrimary: z.boolean(),
  receivesBilling: z.boolean(),
  mayCollectChild: z.boolean(),
});
export type LinkGuardianInput = z.infer<typeof linkGuardianSchema>;

export const enrolStudentSchema = z.object({ sectionId: z.string().uuid('Choose a section') });
export type EnrolStudentInput = z.infer<typeof enrolStudentSchema>;

// Mirrors public.fee_frequency in supabase/migrations/20260731050000_fee_heads.sql.
export const FEE_FREQUENCIES = ['monthly', 'quarterly', 'annual', 'one_time'] as const;

// Mirrors create_fee_head()'s own shape — the fee_head_tenant_code_uq
// case-insensitive uniqueness check is the DB's job, not duplicated here.
export const createFeeHeadSchema = z.object({
  code: z
    .string()
    .min(1, 'Required')
    .max(50)
    .regex(/^[A-Za-z0-9_]+$/, 'Letters, numbers and underscores only'),
  nameEn: z.string().min(1, 'Required').max(200),
  nameUr: z.string().min(1, 'Urdu name is required').max(200),
  isRefundable: z.boolean(),
  defaultFrequency: z.enum(FEE_FREQUENCIES),
});
export type CreateFeeHeadInput = z.infer<typeof createFeeHeadSchema>;

export const MONTH_LABELS = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
] as const;

// Mirrors add_structure_line()'s own checks in
// supabase/migrations/20260731060000_fee_structure.sql — amountRupees is
// converted to paisa (amount * 100) only at the server-action boundary,
// never carried as a float through the schema itself.
export const addStructureLineSchema = z.object({
  structureId: z.string().uuid(),
  classId: z.string().uuid('Choose a class'),
  groupCode: z.string().max(50).optional(),
  feeHeadId: z.string().uuid('Choose a fee head'),
  amountRupees: z.coerce.number().nonnegative('Enter an amount'),
  frequency: z.enum(FEE_FREQUENCIES),
  // Checkbox groups hand React Hook Form an array of string values
  // ("0".."11") — coerce rather than expect numbers already.
  months: z.array(z.coerce.number().int().min(0).max(11)).min(1, 'Choose at least one month'),
});
export type AddStructureLineInput = z.infer<typeof addStructureLineSchema>;

export const createDraftStructureSchema = z.object({ campusId: z.string().uuid(), sessionId: z.string().uuid() });
export type CreateDraftStructureInput = z.infer<typeof createDraftStructureSchema>;

// Mirrors propose_fee_plan_override()'s own REASON_REQUIRED check.
export const proposeFeePlanOverrideSchema = z.object({
  lineId: z.string().uuid(),
  amountRupees: z.coerce.number().nonnegative('Enter an amount'),
  reason: z.string().min(1, 'A reason is required').max(500),
});
export type ProposeFeePlanOverrideInput = z.infer<typeof proposeFeePlanOverrideSchema>;

export const CONCESSION_CALC_TYPES = ['percentage', 'fixed_amount'] as const;

// Mirrors create_concession_scheme()'s own checks in
// supabase/migrations/20260731080000_concession_schemes.sql — the DB's
// ck_concession_value_range and ck_concession_applicable_heads_not_empty
// constraints are the real gate, this is the earlier UX floor.
export const createConcessionSchemeSchema = z
  .object({
    code: z
      .string()
      .min(1, 'Required')
      .max(50)
      .regex(/^[A-Za-z0-9_]+$/, 'Letters, numbers and underscores only'),
    nameEn: z.string().min(1, 'Required').max(200),
    nameUr: z.string().min(1, 'Urdu name is required').max(200),
    calcType: z.enum(CONCESSION_CALC_TYPES),
    value: z.coerce.number().nonnegative('Enter a value'),
    applicableHeadIds: z.array(z.string().uuid()).min(1, 'Choose at least one fee head'),
    requiresDocument: z.boolean(),
  })
  .refine((v) => v.calcType !== 'percentage' || v.value <= 100, {
    message: 'A percentage cannot exceed 100',
    path: ['value'],
  });
export type CreateConcessionSchemeInput = z.infer<typeof createConcessionSchemeSchema>;

// Mirrors apply_for_leave()'s own checks in
// supabase/migrations/20260730220544_leave_ledger_and_application.sql — the
// RPC (balance, dates) is the real gate, this is the earlier UX floor.
// toDate is only required/range-checked when not a half day: the half-day
// field is hidden client-side and mirrored to fromDate before submit.
export const applyLeaveSchema = z
  .object({
    leaveTypeId: z.string().uuid('Choose a leave type'),
    fromDate: z.string().min(1, 'Required'),
    toDate: z.string(),
    isHalfDay: z.boolean(),
    reason: z.string().max(500).optional(),
  })
  .refine((v) => v.isHalfDay || v.toDate.length > 0, { message: 'Required', path: ['toDate'] })
  .refine((v) => v.isHalfDay || v.toDate >= v.fromDate, {
    message: 'End date must be on or after the start date',
    path: ['toDate'],
  });
export type ApplyLeaveInput = z.infer<typeof applyLeaveSchema>;

// Mirrors advance_leave_approval() / fn_decide_leave_application()'s shared
// decision domain in
// supabase/migrations/20260730231822_leave_approval_chain.sql.
export const LEAVE_DECISIONS = ['approved', 'rejected'] as const;

export const decideLeaveSchema = z.object({
  applicationId: z.string().uuid(),
  decision: z.enum(LEAVE_DECISIONS),
  comment: z.string().max(500).optional(),
});
export type DecideLeaveInput = z.infer<typeof decideLeaveSchema>;

// Mirrors public.academic_group in
// supabase/migrations/20260730163812_admissions_pipeline.sql.
export const ACADEMIC_GROUPS = ['pre_medical', 'pre_engineering', 'computer_science', 'commerce', 'arts'] as const;

// Mirrors fn_submit_application()'s own "group required for classes 9-12"
// check — a group given for a lower class is harmlessly cleared server-side,
// so there's no client-side conditional here either.
export const submitApplicationSchema = z.object({
  enquiryId: z.string().uuid(),
  groupApplied: z.enum(ACADEMIC_GROUPS).optional(),
});
export type SubmitApplicationInput = z.infer<typeof submitApplicationSchema>;

// Mirrors fn_issue_offer()'s own checks in
// supabase/migrations/20260730163812_admissions_pipeline.sql — the RPC
// (seat availability) is the real gate, this is the earlier UX floor.
export const issueOfferSchema = z.object({
  applicationId: z.string().uuid(),
  feeAmount: z.coerce.number().positive('Enter a fee amount'),
});
export type IssueOfferInput = z.infer<typeof issueOfferSchema>;

// Mirrors public.offer_decline_reason in the same migration.
export const OFFER_DECLINE_REASONS = ['fee_too_high', 'chose_other_school', 'relocation', 'distance', 'other'] as const;

// Mirrors fn_respond_to_offer()'s DECLINE_REASON_REQUIRED check.
export const respondToOfferSchema = z
  .object({
    offerId: z.string().uuid(),
    response: z.enum(['accepted', 'declined']),
    declineReason: z.enum(OFFER_DECLINE_REASONS).optional(),
  })
  .refine((v) => v.response !== 'declined' || !!v.declineReason, {
    message: 'Choose a reason for declining',
    path: ['declineReason'],
  });
export type RespondToOfferInput = z.infer<typeof respondToOfferSchema>;
