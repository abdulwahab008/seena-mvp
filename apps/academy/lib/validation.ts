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

// Mirrors request_concession_award()'s own checks in
// supabase/migrations/20260731090000_concession_awards.sql.
export const requestConcessionAwardSchema = z
  .object({
    schemeId: z.string().uuid('Choose a scheme'),
    value: z.coerce.number().nonnegative('Enter a value'),
    effectiveFrom: z.string().min(1, 'Required'),
    effectiveTo: z.string().min(1, 'Required'),
    documentPath: z.string().max(500).optional(),
  })
  .refine((v) => v.effectiveTo > v.effectiveFrom, {
    message: 'End date must be after the start date',
    path: ['effectiveTo'],
  });
export type RequestConcessionAwardInput = z.infer<typeof requestConcessionAwardSchema>;

// Mirrors decide_concession_award()'s REJECTION_REASON_TOO_SHORT check.
export const decideConcessionAwardSchema = z
  .object({
    awardId: z.string().uuid(),
    approve: z.boolean(),
    rejectionReason: z.string().max(500).optional(),
  })
  .refine((v) => v.approve || (v.rejectionReason?.trim().length ?? 0) >= 10, {
    message: 'Rejection reason must be at least 10 characters',
    path: ['rejectionReason'],
  });
export type DecideConcessionAwardInput = z.infer<typeof decideConcessionAwardSchema>;

export const LEDGER_ENTRY_TYPES = ['charge', 'concession', 'late_fee', 'payment', 'refund', 'adjustment', 'write_off'] as const;
export const LEDGER_DIRECTIONS = ['debit', 'credit'] as const;

// Mirrors post_ledger_entry()'s own checks in
// supabase/migrations/20260731100000_fee_ledger.sql.
export const postLedgerEntrySchema = z.object({
  entryType: z.enum(LEDGER_ENTRY_TYPES),
  amountRupees: z.coerce.number().positive('Enter an amount'),
  direction: z.enum(LEDGER_DIRECTIONS),
});
export type PostLedgerEntryInput = z.infer<typeof postLedgerEntrySchema>;

// Mirrors reverse_ledger_entry()'s REASON_TOO_SHORT check.
export const reverseLedgerEntrySchema = z.object({
  ledgerId: z.string().uuid(),
  reason: z.string().min(15, 'Reason must be at least 15 characters').max(500),
});
export type ReverseLedgerEntryInput = z.infer<typeof reverseLedgerEntrySchema>;

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

// Mirrors generate_challans()'s own checks in
// supabase/migrations/20260731120000_bulk_challan_generation.sql. period is
// a plain "YYYY-MM" month picker value — the '-01' day is appended at the
// server-action boundary before it reaches the p_period date parameter.
export const generateChallansSchema = z.object({
  campusId: z.string().uuid(),
  sessionId: z.string().uuid(),
  period: z.string().regex(/^\d{4}-\d{2}$/, 'Use YYYY-MM'),
  dryRun: z.boolean(),
});
export type GenerateChallansInput = z.infer<typeof generateChallansSchema>;

// Mirrors public.late_fee_basis and create_late_fee_rule()'s own
// PERCENTAGE_REQUIRED / AMOUNT_REQUIRED checks in
// supabase/migrations/20260731130000_late_fee_rules.sql.
export const LATE_FEE_BASES = ['flat', 'per_day', 'percentage'] as const;

export const createLateFeeRuleSchema = z
  .object({
    campusId: z.string().uuid(),
    sessionId: z.string().uuid(),
    basis: z.enum(LATE_FEE_BASES),
    graceDays: z.coerce.number().int().nonnegative(),
    amountRupees: z.coerce.number().nonnegative().optional(),
    percentage: z.coerce.number().min(0).max(100).optional(),
    capRupees: z.coerce.number().nonnegative().optional(),
  })
  .refine((v) => v.basis !== 'percentage' || v.percentage !== undefined, {
    message: 'Enter a percentage',
    path: ['percentage'],
  })
  .refine((v) => v.basis === 'percentage' || v.amountRupees !== undefined, {
    message: 'Enter an amount',
    path: ['amountRupees'],
  });
export type CreateLateFeeRuleInput = z.infer<typeof createLateFeeRuleSchema>;

// Mirrors compute_late_fee()'s own signature — a read-only preview, no
// state changes, so there's nothing here to mirror beyond "both fields
// are required".
export const previewLateFeeSchema = z.object({
  challanId: z.string().uuid('Choose a challan'),
  asOf: z.string().min(1, 'Required'),
});
export type PreviewLateFeeInput = z.infer<typeof previewLateFeeSchema>;

// Mirrors set_fee_policy()'s own signature in
// supabase/migrations/20260731170000_concession_stacking_cap.sql.
export const setFeePolicySchema = z.object({
  maxStackedConcessionPct: z.coerce.number().min(0).max(100).optional(),
  allowNegativeNet: z.boolean(),
});
export type SetFeePolicyInput = z.infer<typeof setFeePolicySchema>;

// Mirrors set_sibling_discount_scheme()'s own check constraint
// (sibling_rank >= 2 — rank 1 is the eldest, who never gets a discount)
// in supabase/migrations/20260731180000_sibling_discount_detection.sql.
export const setSiblingDiscountSchemeSchema = z.object({
  siblingRank: z.coerce.number().int().min(2, 'Rank 1 is the eldest — they never get a sibling discount'),
  schemeId: z.string().uuid('Choose a scheme'),
});
export type SetSiblingDiscountSchemeInput = z.infer<typeof setSiblingDiscountSchemeSchema>;

export const detectSiblingGroupsSchema = z.object({
  campusId: z.string().uuid(),
  sessionId: z.string().uuid(),
});
export type DetectSiblingGroupsInput = z.infer<typeof detectSiblingGroupsSchema>;

// Mirrors create_next_structure_version()'s own signature in
// supabase/migrations/20260731190000_fee_structure_versioning.sql.
export const createNextStructureVersionSchema = z.object({
  priorStructureId: z.string().uuid(),
  effectiveFrom: z.string().min(1, 'Required'),
});
export type CreateNextStructureVersionInput = z.infer<typeof createNextStructureVersionSchema>;

export const updateStructureLineAmountSchema = z.object({
  lineId: z.string().uuid(),
  amountRupees: z.coerce.number().nonnegative('Enter an amount'),
});
export type UpdateStructureLineAmountInput = z.infer<typeof updateStructureLineAmountSchema>;

// Mirrors publish_fee_structure()'s own REGULATOR_REFERENCE_REQUIRED
// check — required only when the DB rejects a publish for exceeding the
// tenant's configured increase cap, so this stays optional here too.
export const publishStructureSchema = z.object({
  structureId: z.string().uuid(),
  regulatorReference: z.string().max(200).optional(),
});
export type PublishStructureInput = z.infer<typeof publishStructureSchema>;

// Mirrors set_challan_template()'s own signature in
// supabase/migrations/20260731200000_challan_pdf_data_layer.sql.
export const setChallanTemplateSchema = z.object({
  campusId: z.string().uuid(),
  bankName: z.string().min(1, 'Required').max(200),
  bankAccountTitle: z.string().min(1, 'Required').max(200),
  bankAccountNo: z.string().min(1, 'Required').max(50),
  footerNoteEn: z.string().max(500).optional(),
  footerNoteUr: z.string().max(500).optional(),
});
export type SetChallanTemplateInput = z.infer<typeof setChallanTemplateSchema>;

export const buildChallanRenderPayloadSchema = z.object({ challanId: z.string().uuid() });
export type BuildChallanRenderPayloadInput = z.infer<typeof buildChallanRenderPayloadSchema>;

export const FEE_PAYMENT_MODES = ['cash', 'bank_challan', 'online', 'cheque', 'adjustment'] as const;

// Mirrors record_payment()'s own checks in
// supabase/migrations/20260731250000_payment_allocation_waterfall.sql.
export const recordPaymentSchema = z.object({
  amountRupees: z.coerce.number().positive('Enter an amount'),
  mode: z.enum(FEE_PAYMENT_MODES),
  referenceNo: z.string().max(100).optional(),
});
export type RecordPaymentInput = z.infer<typeof recordPaymentSchema>;

// Mirrors lookup_challan_for_counter()'s own signature in
// supabase/migrations/20260731270000_cash_counter_receipt.sql.
export const lookupChallanSchema = z.object({
  challanNo: z.string().min(1, 'Scan or enter a challan number'),
});
export type LookupChallanInput = z.infer<typeof lookupChallanSchema>;

// Mirrors collect_cash_payment()'s own checks — the client idempotency
// key is generated once per lookup and reused across retries of the
// same attempt, never regenerated on its own.
export const collectCashPaymentSchema = z.object({
  challanId: z.string().uuid(),
  amountRupees: z.coerce.number().positive('Enter an amount'),
  mode: z.enum(FEE_PAYMENT_MODES),
  clientIdempotencyKey: z.string().min(1),
  referenceNo: z.string().max(100).optional(),
});
export type CollectCashPaymentInput = z.infer<typeof collectCashPaymentSchema>;

export const printReceiptSchema = z.object({ receiptId: z.string().uuid() });
export type PrintReceiptInput = z.infer<typeof printReceiptSchema>;

// Mirrors build_collection_report_payload()'s own signature in
// supabase/migrations/20260731280000_daily_collection_report.sql.
export const collectionReportSchema = z
  .object({
    campusId: z.string().uuid(),
    from: z.string().min(1, 'Required'),
    to: z.string().min(1, 'Required'),
  })
  .refine((v) => v.to >= v.from, { message: 'End date must be on or after the start date', path: ['to'] });
export type CollectionReportInput = z.infer<typeof collectionReportSchema>;

export const finaliseCashBookDaySchema = z.object({
  campusId: z.string().uuid(),
  bookDate: z.string().min(1, 'Required'),
});
export type FinaliseCashBookDayInput = z.infer<typeof finaliseCashBookDaySchema>;

// Mirrors upsert_class_subject()'s own checks in
// supabase/migrations/20260730103544_class_subject_map.sql /
// 20260731310000_module_e_review_fixes.sql (weekly periods 1-12,
// elective subjects need a bucket). An empty text input arrives as '',
// which Number() coerces to 0 rather than undefined — preprocessed to
// undefined first so an unset optional field doesn't fail .positive().
const optionalPositiveInt = z.preprocess(
  (v) => (v === '' || v === undefined || v === null ? undefined : Number(v)),
  z.number().int().positive().optional(),
);
export const upsertClassSubjectSchema = z
  .object({
    subjectId: z.string().uuid('Choose a subject'),
    weeklyPeriods: z.coerce.number().int().min(1, 'Must be at least 1').max(12, 'Must be at most 12'),
    isCompulsory: z.boolean(),
    electiveBucket: optionalPositiveInt,
    chooseN: optionalPositiveInt,
  })
  .refine((v) => v.isCompulsory || v.electiveBucket !== undefined, {
    message: 'Elective subjects need a bucket number',
    path: ['electiveBucket'],
  });
export type UpsertClassSubjectInput = z.infer<typeof upsertClassSubjectSchema>;

export const ROOM_TYPES = ['CLASSROOM', 'SCIENCE_LAB', 'COMPUTER_LAB', 'HALL', 'LIBRARY', 'PRAYER_AREA'] as const;

// Mirrors create_room()'s own checks in
// supabase/migrations/20260731320000_room_registry.sql — room codes are
// only unique per campus (the DB's uq_room_campus_code), not checked here.
export const createRoomSchema = z.object({
  code: z.string().min(1, 'Required').max(50),
  name: z.string().min(1, 'Required').max(200),
  roomType: z.enum(ROOM_TYPES),
  capacity: z.coerce.number().int().positive('Must be at least 1'),
  blockLabel: z.string().max(100).optional(),
});
export type CreateRoomInput = z.infer<typeof createRoomSchema>;

// Mirrors declare_competency()'s own INVALID_ORDINAL_RANGE check in
// supabase/migrations/20260731330000_teacher_competency_registry.sql.
export const declareCompetencySchema = z
  .object({
    staffId: z.string().uuid('Choose a teacher'),
    subjectId: z.string().uuid('Choose a subject'),
    minClassOrdinal: z.coerce.number().int(),
    maxClassOrdinal: z.coerce.number().int(),
  })
  .refine((v) => v.minClassOrdinal <= v.maxClassOrdinal, {
    message: 'The starting class must be at or before the ending class',
    path: ['maxClassOrdinal'],
  });
export type DeclareCompetencyInput = z.infer<typeof declareCompetencySchema>;

export const verifyCompetencySchema = z.object({
  staffId: z.string().uuid(),
  subjectId: z.string().uuid(),
  documentPath: z.string().max(500).optional(),
});
export type VerifyCompetencyInput = z.infer<typeof verifyCompetencySchema>;

export const suggestSubstitutesSchema = z.object({
  subjectId: z.string().uuid('Choose a subject'),
  classLevelId: z.string().uuid('Choose a class'),
});
export type SuggestSubstitutesInput = z.infer<typeof suggestSubstitutesSchema>;

// Mirrors clone_academic_structure()'s own SAME_SESSION check in
// supabase/migrations/20260731340000_academic_structure_rollover.sql.
export const cloneAcademicStructureSchema = z
  .object({
    campusId: z.string().uuid('Choose a campus'),
    fromSessionId: z.string().uuid('Choose the source session'),
    toSessionId: z.string().uuid('Choose the target session'),
  })
  .refine((v) => v.fromSessionId !== v.toSessionId, {
    message: 'The source and target sessions must be different',
    path: ['toSessionId'],
  });
export type CloneAcademicStructureInput = z.infer<typeof cloneAcademicStructureSchema>;

export const DOCUMENT_TYPES = [
  'birth_certificate',
  'transfer_certificate',
  'passport_photo',
  'b_form',
  'previous_report_card',
  'medical_certificate',
  'other',
] as const;
export const DOC_STATUSES = ['pending', 'uploaded', 'verified', 'rejected', 'promised'] as const;

// Mirrors set_document_requirement()'s own checks in
// supabase/migrations/20260731370000_admission_document_checklist.sql.
export const setDocumentRequirementSchema = z
  .object({
    campusId: z.string().uuid('Choose a campus'),
    minClassOrdinal: z.coerce.number().int(),
    maxClassOrdinal: z.coerce.number().int(),
    docType: z.enum(DOCUMENT_TYPES),
    isMandatory: z.boolean(),
    minCount: z.coerce.number().int().positive('Must be at least 1'),
  })
  .refine((v) => v.minClassOrdinal <= v.maxClassOrdinal, {
    message: 'The starting class must be at or before the ending class',
    path: ['maxClassOrdinal'],
  });
export type SetDocumentRequirementInput = z.infer<typeof setDocumentRequirementSchema>;

// Mirrors set_document_submission()'s own PROMISED_DEADLINE_* checks.
export const setDocumentSubmissionSchema = z
  .object({
    applicationId: z.string().uuid(),
    docType: z.enum(DOCUMENT_TYPES),
    status: z.enum(DOC_STATUSES),
    uploadedCount: z.coerce.number().int().nonnegative().optional(),
    promisedDeadline: z.string().optional(),
  })
  .refine((v) => v.status !== 'promised' || !!v.promisedDeadline, {
    message: 'A promised document needs a deadline',
    path: ['promisedDeadline'],
  });
export type SetDocumentSubmissionInput = z.infer<typeof setDocumentSubmissionSchema>;

// Mirrors create_test_sitting()'s own checks in
// supabase/migrations/20260731380000_admission_test_sitting.sql.
export const createTestSittingSchema = z.object({
  campusId: z.string().uuid('Choose a campus'),
  sessionId: z.string().uuid('Choose a session'),
  classLevelId: z.string().uuid('Choose a class'),
  startsAt: z.string().min(1, 'Choose a date and time'),
  capacity: z.coerce.number().int().positive('Must be at least 1'),
  venue: z.string().max(200).optional(),
});
export type CreateTestSittingInput = z.infer<typeof createTestSittingSchema>;

export const allocateTestSeatSchema = z.object({
  sittingId: z.string().uuid(),
  applicationId: z.string().uuid('Choose an application'),
});
export type AllocateTestSeatInput = z.infer<typeof allocateTestSeatSchema>;

export const TEST_ATTENDANCES = ['pending', 'present', 'absent'] as const;

// Mirrors set_test_score()'s own chk_score_range check constraint in
// supabase/migrations/20260731400000_admission_test_scores_merit.sql.
export const setTestScoreSchema = z
  .object({
    candidateId: z.string().uuid(),
    subjectCode: z.string().min(1, 'Required').max(50),
    obtained: z.coerce.number().min(0, 'Cannot be negative'),
    total: z.coerce.number().positive('Must be more than 0'),
  })
  .refine((v) => v.obtained <= v.total, { message: 'Obtained cannot exceed total', path: ['obtained'] });
export type SetTestScoreInput = z.infer<typeof setTestScoreSchema>;

export const setTestAttendanceSchema = z.object({
  candidateId: z.string().uuid(),
  attendance: z.enum(TEST_ATTENDANCES),
});
export type SetTestAttendanceInput = z.infer<typeof setTestAttendanceSchema>;

// Mirrors book_interview()'s own END_MUST_BE_AFTER_START check in
// supabase/migrations/20260731410000_admission_interview_booking.sql.
export const bookInterviewSchema = z
  .object({
    applicationId: z.string().uuid('Choose an application'),
    panelUserId: z.string().uuid('Choose a panel member'),
    startsAt: z.string().min(1, 'Choose a start time'),
    endsAt: z.string().min(1, 'Choose an end time'),
    venue: z.string().max(200).optional(),
  })
  .refine((v) => !v.startsAt || !v.endsAt || v.endsAt > v.startsAt, {
    message: 'End time must be after the start time',
    path: ['endsAt'],
  });
export type BookInterviewInput = z.infer<typeof bookInterviewSchema>;

export const cancelInterviewSchema = z.object({ interviewId: z.string().uuid() });
export type CancelInterviewInput = z.infer<typeof cancelInterviewSchema>;

export const INTERVIEW_CRITERIA = [
  'communication',
  'confidence',
  'academic_readiness',
  'parental_engagement',
  'overall_impression',
] as const;
export const INTERVIEW_RECOMMENDATIONS = ['accept', 'waitlist', 'reject'] as const;

// Mirrors submit_interview_scorecard()'s own MISSING_CRITERIA check —
// whether a justification is mandatory depends on the applicant's merit
// rank (server-side only, see fn_is_merit_override in
// supabase/migrations/20260731420000_admission_interview_scorecard.sql),
// so this schema can't pre-validate that part; the server error surfaces it.
const criterionScore = z.coerce.number().int().min(1).max(5);
export const submitScorecardSchema = z.object({
  interviewId: z.string().uuid(),
  scores: z.object({
    communication: criterionScore,
    confidence: criterionScore,
    academic_readiness: criterionScore,
    parental_engagement: criterionScore,
    overall_impression: criterionScore,
  }),
  recommendation: z.enum(INTERVIEW_RECOMMENDATIONS),
  justification: z.string().max(2000).optional(),
});
export type SubmitScorecardInput = z.infer<typeof submitScorecardSchema>;

// Mirrors create_admission_document()'s own checks in
// supabase/migrations/20260731430000_admission_document_upload.sql, and
// the admission-docs bucket's own file_size_limit/allowed_mime_types.
export const MAX_DOCUMENT_FILE_SIZE = 5 * 1024 * 1024;
export const ALLOWED_DOCUMENT_MIME_TYPES = ['image/jpeg', 'image/png', 'application/pdf'] as const;
export const B_FORM_NO_REGEX = /^[0-9]{5}-[0-9]{7}-[0-9]$/;

export const uploadDocumentSchema = z.object({
  applicationId: z.string().uuid(),
  docType: z.enum(DOCUMENT_TYPES),
  bFormNo: z.string().regex(B_FORM_NO_REGEX, 'Must be 13 digits, e.g. 42101-1234567-8').optional().or(z.literal('')),
});
export type UploadDocumentInput = z.infer<typeof uploadDocumentSchema>;

export const rejectDocumentSchema = z.object({
  documentId: z.string().uuid(),
  reason: z.string().min(1, 'A reason is required'),
});
export type RejectDocumentInput = z.infer<typeof rejectDocumentSchema>;

// Mirrors submit_public_enquiry()'s own checks in
// supabase/migrations/20260731440000_public_enquiry_form.sql.
export const publicEnquirySchema = z.object({
  childName: z.string().min(1, "Child's name is required").max(200),
  childNameUr: z.string().max(200).optional(),
  dob: z.string().min(1, 'Date of birth is required'),
  classCode: z.string().min(1, 'Choose a class'),
  parentName: z.string().min(1, "Parent/guardian's name is required").max(200),
  phone: z.string().min(1, 'Phone number is required'),
  whatsappOptIn: z.boolean().default(false),
});
export type PublicEnquiryInput = z.infer<typeof publicEnquirySchema>;

// Mirrors record_admission_fee_payment()'s own checks in
// supabase/migrations/20260731460000_gate_enrolment_on_admission_fee.sql.
export const recordAdmissionFeePaymentSchema = z.object({
  offerId: z.string().uuid(),
  amountRupees: z.coerce.number().positive('Enter an amount'),
  mode: z.enum(FEE_PAYMENT_MODES),
  referenceNo: z.string().max(100).optional(),
});
export type RecordAdmissionFeePaymentInput = z.infer<typeof recordAdmissionFeePaymentSchema>;

export const waiveAdmissionFeeSchema = z.object({
  offerId: z.string().uuid(),
  reason: z.string().min(10, 'Explain the waiver in at least 10 characters'),
});
export type WaiveAdmissionFeeInput = z.infer<typeof waiveAdmissionFeeSchema>;

export const enrolFromOfferSchema = z
  .object({
    offerId: z.string().uuid(),
    sectionId: z.string().uuid('Choose a section'),
    gender: z.enum(['male', 'female', 'other']),
    paymentId: z.string().uuid().optional(),
    waiverId: z.string().uuid().optional(),
  })
  .refine((v) => Boolean(v.paymentId) !== Boolean(v.waiverId), {
    message: 'Choose exactly one payment or waiver to enrol with',
    path: ['paymentId'],
  });
export type EnrolFromOfferInput = z.infer<typeof enrolFromOfferSchema>;

// Mirrors create_branding_asset()'s own checks in
// supabase/migrations/20260731470000_tenant_branding_assets.sql.
export const BRANDING_ASSET_TYPES = ['logo', 'letterhead', 'signature', 'stamp'] as const;
export const MAX_BRANDING_FILE_SIZE = 3 * 1024 * 1024;
export const ALLOWED_BRANDING_MIME_TYPES = ['image/jpeg', 'image/png'] as const;

// Mirrors create_branding_asset()'s v_min_width case exactly.
export const BRANDING_MIN_WIDTH_PX: Record<(typeof BRANDING_ASSET_TYPES)[number], number> = {
  logo: 600,
  letterhead: 1000,
  signature: 200,
  stamp: 200,
};

export const uploadBrandingAssetSchema = z.object({
  assetType: z.enum(BRANDING_ASSET_TYPES),
  campusId: z.string().uuid().optional(),
  widthPx: z.coerce.number().int().positive(),
  heightPx: z.coerce.number().int().positive(),
});
export type UploadBrandingAssetInput = z.infer<typeof uploadBrandingAssetSchema>;

const HEX_COLOR_REGEX = /^#[0-9a-fA-F]{6}$/;
export const setTenantThemeSchema = z.object({
  primaryHex: z.string().regex(HEX_COLOR_REGEX, 'Use a 6-digit hex colour, e.g. #112233').optional().or(z.literal('')),
  secondaryHex: z.string().regex(HEX_COLOR_REGEX, 'Use a 6-digit hex colour, e.g. #112233').optional().or(z.literal('')),
});
export type SetTenantThemeInput = z.infer<typeof setTenantThemeSchema>;

// Mirrors set_attendance_policy()'s own checks in
// supabase/migrations/20260731480000_attendance_policy.sql.
export const ATTENDANCE_MODES = ['daily', 'period'] as const;
const TIME_REGEX = /^([01]\d|2[0-3]):[0-5]\d$/;

export const setAttendancePolicySchema = z.object({
  campusId: z.string().uuid(),
  sessionId: z.string().uuid(),
  mode: z.enum(ATTENDANCE_MODES),
  startTime: z.string().regex(TIME_REGEX, 'Use HH:MM, e.g. 08:00'),
  lateThresholdMinutes: z.coerce.number().int().min(0, 'Cannot be negative'),
  halfDayCutoffTime: z.string().regex(TIME_REGEX, 'Use HH:MM, e.g. 12:30').optional().or(z.literal('')),
  lockWindowHours: z.coerce.number().int().positive('Must be at least 1 hour'),
  minAttendancePct: z.coerce.number().min(0).max(100).optional(),
  saturdayWorking: z.boolean().default(false),
});
export type SetAttendancePolicyInput = z.infer<typeof setAttendancePolicySchema>;

// Mirrors save_attendance_register()'s own checks in
// supabase/migrations/20260731490000_daily_attendance_register.sql.
export const STUDENT_ATTENDANCE_STATUSES = ['present', 'absent', 'late', 'half_day', 'excused'] as const;

// Mirrors rpc_bulk_mark_attendance()'s own signature in
// supabase/migrations/20260731500000_bulk_mark_attendance.sql —
// exceptions only; every un-listed active enrolment defaults to present.
export const bulkMarkAttendanceSchema = z.object({
  sectionId: z.string().uuid(),
  attendanceDate: z.string().min(1, 'Choose a date'),
  exceptions: z.array(z.object({ enrolmentId: z.string().uuid(), status: z.enum(STUDENT_ATTENDANCE_STATUSES) })),
});
export type BulkMarkAttendanceInput = z.infer<typeof bulkMarkAttendanceSchema>;

// Mirrors request_attendance_correction()'s own checks in
// supabase/migrations/20260731520000_attendance_correction_approval.sql.
export const requestAttendanceCorrectionSchema = z.object({
  enrolmentId: z.string().uuid(),
  attendanceDate: z.string().min(1, 'Choose a date'),
  newStatus: z.enum(STUDENT_ATTENDANCE_STATUSES),
  reason: z.string().min(10, 'Explain the correction in at least 10 characters'),
});
export type RequestAttendanceCorrectionInput = z.infer<typeof requestAttendanceCorrectionSchema>;

export const decideAttendanceCorrectionSchema = z.object({
  correctionId: z.string().uuid(),
  note: z.string().min(10, 'Explain the decision in at least 10 characters'),
});
export type DecideAttendanceCorrectionInput = z.infer<typeof decideAttendanceCorrectionSchema>;

// Mirrors compute_month_attendance()'s own signature in
// supabase/migrations/20260731530000_monthly_attendance_summary.sql.
export const recomputeMonthlyAttendanceSchema = z.object({
  campusId: z.string().uuid(),
  year: z.coerce.number().int().min(2000).max(2100),
  month: z.coerce.number().int().min(1).max(12),
});
export type RecomputeMonthlyAttendanceInput = z.infer<typeof recomputeMonthlyAttendanceSchema>;

// Mirrors dispatch_absentee_notifications()'s own signature in
// supabase/migrations/20260731540000_absentee_sms_notification.sql.
export const dispatchAbsenteeNotificationsSchema = z.object({
  campusId: z.string().uuid(),
  date: z.string().min(1, 'Choose a date'),
});
export type DispatchAbsenteeNotificationsInput = z.infer<typeof dispatchAbsenteeNotificationsSchema>;

// Mirrors create_homework()'s own signature in
// supabase/migrations/20260731570000_homework.sql. dueDate/assignedDate
// stay as plain strings (native <input type="date">, same as this app's
// other date fields) — the DB's own chk_hw_dates constraint plus
// create_homework()'s DUE_BEFORE_ASSIGNED check are the real validation;
// this schema only catches an empty field before it ever reaches the RPC.
export const createHomeworkSchema = z.object({
  sectionId: z.string().uuid(),
  subjectId: z.string().uuid(),
  title: z.string().min(1, 'Required').max(120),
  description: z.string().max(4000, 'Must be 4000 characters or fewer').optional(),
  assignedDate: z.string().min(1, 'Choose a date'),
  dueDate: z.string().min(1, 'Choose a date'),
  // preprocess first: a blank number input reaches RHF as '', which
  // z.coerce.number() turns into 0 (Number('') === 0) — 0 then fails
  // .positive() with no visible error (this field renders none), silently
  // blocking submission for anyone who leaves this genuinely optional
  // field empty. Blank out to undefined before coercion instead.
  estimatedMinutes: z.preprocess(
    (v) => (v === '' || v === null || v === undefined ? undefined : v),
    z.coerce.number().int().positive().optional(),
  ),
});
export type CreateHomeworkInput = z.infer<typeof createHomeworkSchema>;

// Mirrors create_bell_template()'s own signature in
// supabase/migrations/20260731580000_bell_template.sql. period_no
// numbering and overlap checks are the DB's job — this schema only
// catches empty fields and a backwards start/end pair before the RPC.
export const BELL_SHIFTS = ['MORNING', 'AFTERNOON'] as const;
export const BELL_SEGMENT_KINDS = ['TEACHING', 'BREAK', 'ASSEMBLY', 'PRAYER'] as const;

export const bellSegmentSchema = z
  .object({
    kind: z.enum(BELL_SEGMENT_KINDS),
    startTime: z.string().min(1, 'Required'),
    endTime: z.string().min(1, 'Required'),
  })
  .refine((v) => v.endTime > v.startTime, { message: 'End time must be after start time', path: ['endTime'] });

export const createBellTemplateSchema = z.object({
  shift: z.enum(BELL_SHIFTS),
  code: z.string().min(1, 'Required').max(50),
  name: z.string().min(1, 'Required').max(200),
  segments: z.array(bellSegmentSchema).min(1, 'At least one segment'),
  isDefault: z.boolean().optional(),
});
export type CreateBellTemplateInput = z.infer<typeof createBellTemplateSchema>;

// Mirrors create_bell_calendar_rule()'s own signature in
// supabase/migrations/20260731590000_bell_calendar_rule.sql. This form
// only ever creates weekday rules (dateFrom/dateTo are FR-F03's own,
// Ramadan-override, scope) — weekday is required here even though the DB
// function itself allows a date-range-only rule instead.
export const WEEKDAY_LABELS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'] as const;

export const createBellCalendarRuleSchema = z.object({
  shift: z.enum(BELL_SHIFTS),
  bellTemplateId: z.string().uuid('Choose a template'),
  weekday: z.coerce.number().int().min(0).max(6),
  precedence: z.coerce.number().int().min(0).max(1000).default(50),
  note: z.string().max(500).optional(),
});
export type CreateBellCalendarRuleInput = z.infer<typeof createBellCalendarRuleSchema>;

// Mirrors create_timetable_version()'s own signature in
// supabase/migrations/20260731600000_timetable_draft_slot_assignment.sql.
export const createTimetableVersionSchema = z.object({
  shift: z.enum(BELL_SHIFTS),
  name: z.string().min(1, 'Required').max(200),
});
export type CreateTimetableVersionInput = z.infer<typeof createTimetableVersionSchema>;

// Mirrors upsert_timetable_slot()'s own signature. staffId/roomId stay
// optional blank strings from the <select> reach here as '' — preprocess
// blank to undefined the same way createHomeworkSchema treats a blank
// optional number, so an intentionally-cleared assignment isn't coerced
// into a validation error.
const optionalUuid = z.preprocess((v) => (v === '' || v === null || v === undefined ? undefined : v), z.string().uuid().optional());

export const upsertTimetableSlotSchema = z.object({
  weekday: z.coerce.number().int().min(0).max(6),
  periodNo: z.coerce.number().int().positive(),
  subjectId: z.string().uuid('Choose a subject'),
  staffId: optionalUuid,
  roomId: optionalUuid,
  // FR-D03: only sent on a retry after a TEACH_SCOPE_VIOLATION.
  overrideReason: z.string().max(500).optional(),
});
export type UpsertTimetableSlotInput = z.infer<typeof upsertTimetableSlotSchema>;

// Mirrors create_staff_teachable_subject()'s own signature in
// supabase/migrations/20260731620000_teachable_subject_grade_matrix.sql.
// classLevelFrom/To are class_level FKs, not raw grade numbers — see that
// migration's own header for why (no numeric "grade" column exists;
// class_level.ordinal isn't 1:1 with human grade numbers once
// nursery/KG are counted).
export const createTeachableSubjectSchema = z.object({
  staffId: z.string().uuid('Choose a teacher'),
  subjectId: z.string().uuid('Choose a subject'),
  classLevelFromId: z.string().uuid('Choose a starting class'),
  classLevelToId: z.string().uuid('Choose an ending class'),
  streamId: optionalUuid,
});
export type CreateTeachableSubjectInput = z.infer<typeof createTeachableSubjectSchema>;
