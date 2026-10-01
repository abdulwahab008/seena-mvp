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
// supabase/migrations/20260731280000_daily_collection_report.sql /
// 20260731760000_per_campus_role_scoping.sql. campusId is '' for FR-A12
// AC2's "All campuses" filter option, converted to a null p_campus_id
// (aggregate across the caller's whole campus scope) before the RPC call.
export const collectionReportSchema = z
  .object({
    campusId: z.union([z.string().uuid(), z.literal('')]),
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
export type RoomType = (typeof ROOM_TYPES)[number];

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

// FR-A06: session rollover and promotion engine. Mirrors
// start_session_rollover()'s own SAME_SESSION check in
// supabase/migrations/20260731810000_session_rollover_and_promotion.sql.
export const startRolloverSchema = z
  .object({
    campusId: z.string().uuid('Choose a campus'),
    fromSessionId: z.string().uuid('Choose the source session'),
    toSessionId: z.string().uuid('Choose the target session'),
  })
  .refine((v) => v.fromSessionId !== v.toSessionId, {
    message: 'The source and target sessions must be different',
    path: ['toSessionId'],
  });
export type StartRolloverInput = z.infer<typeof startRolloverSchema>;

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

// FR-T09. Mirrors create_signing_identity()'s own checks in
// supabase/migrations/20260731910000_certificate_digital_signature.sql. The
// pixel floors are app.min_px_for_mm(45, 300) and app.min_px_for_mm(35, 300)
// — the default anchor boxes at 300 DPI — restated as literals rather than
// imported from lib/certificates/seal.ts, which pulls in node:crypto and has
// no business in a client bundle.
export const SEAL_REQUIRED_DPI = 300;
export const SIGNING_IDENTITY_MIN_WIDTH_PX = { signature: 532, stamp: 414 } as const;

export const createSigningIdentitySchema = z.object({
  campusId: z.string().uuid('Choose a campus'),
  holderName: z.string().trim().min(1, 'A name is printed under the signature').max(120),
  designation: z.string().trim().min(1, 'A designation is printed under the signature').max(120),
  validFrom: z
    .string()
    .regex(/^\d{4}-\d{2}-\d{2}$/, 'Use YYYY-MM-DD')
    .optional()
    .or(z.literal('')),
  signatureWidthPx: z.coerce.number().int().positive(),
  signatureHeightPx: z.coerce.number().int().positive(),
  stampWidthPx: z.coerce.number().int().positive().optional(),
  stampHeightPx: z.coerce.number().int().positive().optional(),
});
export type CreateSigningIdentityInput = z.infer<typeof createSigningIdentitySchema>;

export const retireSigningIdentitySchema = z.object({
  identityId: z.string().uuid(),
  validTo: z
    .string()
    .regex(/^\d{4}-\d{2}-\d{2}$/, 'Use YYYY-MM-DD')
    .optional()
    .or(z.literal('')),
});
export type RetireSigningIdentityInput = z.infer<typeof retireSigningIdentitySchema>;

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
  exceptions: z.array(
    z.object({ enrolmentId: z.string().uuid(), status: z.enum(STUDENT_ATTENDANCE_STATUSES), arrivalTime: z.string().optional() })
  ),
});
export type BulkMarkAttendanceInput = z.infer<typeof bulkMarkAttendanceSchema>;

// FR-G05: the same payload, plus the two facts a queued submission
// carries that a live one does not — the key that makes replaying it
// exactly-once, and the device clock reading from when it was captured.
export const syncQueuedRegisterSchema = bulkMarkAttendanceSchema.extend({
  idempotencyKey: z.string().uuid(),
  capturedAt: z.string().datetime(),
});
export type SyncQueuedRegisterInput = z.infer<typeof syncQueuedRegisterSchema>;

// Mirrors request_attendance_correction()'s own checks in
// supabase/migrations/20260731520000_attendance_correction_approval.sql
// and 20260731690000_attendance_correction_request_hardening.sql (FR-G10's
// own 15-character minimum, tightened from FR-G11's original 10).
export const requestAttendanceCorrectionSchema = z.object({
  enrolmentId: z.string().uuid(),
  attendanceDate: z.string().min(1, 'Choose a date'),
  newStatus: z.enum(STUDENT_ATTENDANCE_STATUSES),
  reason: z.string().min(15, 'Explain the correction in at least 15 characters'),
});
export type RequestAttendanceCorrectionInput = z.infer<typeof requestAttendanceCorrectionSchema>;

export const decideAttendanceCorrectionSchema = z.object({
  correctionId: z.string().uuid(),
  note: z.string().min(10, 'Explain the decision in at least 10 characters'),
});
export type DecideAttendanceCorrectionInput = z.infer<typeof decideAttendanceCorrectionSchema>;

// Mirrors add_staff_qualification()/verify_staff_qualification()'s own
// checks in supabase/migrations/20260731700000_staff_qualification_register.sql.
export const QUALIFICATION_LEVELS = ['matric', 'intermediate', 'diploma', 'certification', 'bachelor', 'master', 'mphil', 'phd'] as const;

export const addStaffQualificationSchema = z.object({
  staffId: z.string().uuid(),
  level: z.enum(QUALIFICATION_LEVELS),
  discipline: z.string().min(1, 'Discipline is required'),
  institution: z.string().min(1, 'Institution is required'),
  yearCompleted: z.coerce.number().int().min(1960, 'Enter a real year').max(new Date().getFullYear(), 'Year cannot be in the future'),
});
export type AddStaffQualificationInput = z.infer<typeof addStaffQualificationSchema>;

export const verifyStaffQualificationSchema = z.object({
  qualificationId: z.string().uuid(),
  status: z.enum(['verified', 'rejected']),
});
export type VerifyStaffQualificationInput = z.infer<typeof verifyStaffQualificationSchema>;

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

// FR-F03: the date-range half of the same DB function. Separate schema
// rather than making weekday optional on the one above, because the two
// forms are genuinely different shapes — a weekday rule has no dates and
// a Ramadan override has no required weekday — and merging them would
// make every field on both conditionally required.
//
// weekday IS accepted here, and optional: a rule carrying both is the
// "Ramadan Friday" case, shorter still than an ordinary Ramadan day.
const bellRuleDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Use YYYY-MM-DD');
const optionalBellRuleDate = z.preprocess(
  (v) => (v === '' || v === null || v === undefined ? undefined : v),
  bellRuleDate.optional(),
);

export const createDateRangeBellRuleSchema = z
  .object({
    shift: z.enum(BELL_SHIFTS),
    bellTemplateId: z.string().uuid('Choose a template'),
    weekday: z.preprocess(
      (v) => (v === '' || v === null || v === undefined || v === 'ANY' ? undefined : v),
      z.coerce.number().int().min(0).max(6).optional(),
    ),
    dateFrom: bellRuleDate,
    dateTo: optionalBellRuleDate,
    // Above FR-F02's weekday rules (50), matching the DB function's own
    // default for a date-range rule.
    precedence: z.coerce.number().int().min(0).max(1000).default(100),
    note: z.string().max(500).optional(),
  })
  .refine((v) => !v.dateTo || v.dateTo >= v.dateFrom, { message: 'End date must not precede the start date', path: ['dateTo'] });
export type CreateDateRangeBellRuleInput = z.infer<typeof createDateRangeBellRuleSchema>;

// The moon-sighting correction: the only fields a Principal ever edits
// on an already-activated Ramadan rule.
export const updateBellRuleDatesSchema = z
  .object({ dateFrom: bellRuleDate, dateTo: optionalBellRuleDate })
  .refine((v) => !v.dateTo || v.dateTo >= v.dateFrom, { message: 'End date must not precede the start date', path: ['dateTo'] });
export type UpdateBellRuleDatesInput = z.infer<typeof updateBellRuleDatesSchema>;

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
  // FR-F07: set together, only when building/joining an elective parallel
  // block — see createTimetableParallelGroupSchema for the group itself.
  electiveBucket: z.preprocess((v) => (v === '' || v === null || v === undefined ? undefined : v), z.coerce.number().int().optional()),
  parallelGroupId: optionalUuid,
});
export type UpsertTimetableSlotInput = z.infer<typeof upsertTimetableSlotSchema>;

// Mirrors create_timetable_parallel_group()'s own signature.
export const createTimetableParallelGroupSchema = z.object({
  weekday: z.coerce.number().int().min(0).max(6),
  periodNo: z.coerce.number().int().positive(),
  electiveBucket: z.coerce.number().int(),
});
export type CreateTimetableParallelGroupInput = z.infer<typeof createTimetableParallelGroupSchema>;

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

// Mirrors create_substitution()'s own signature in
// supabase/migrations/20260731630000_substitute_teacher_assignment.sql.
export const SUBSTITUTION_REASONS = ['leave', 'official_duty', 'suspension', 'other'] as const;

export const assignSubstitutionSchema = z.object({
  slotId: z.string().uuid(),
  subDate: z.string().min(1, 'Required'),
  substituteStaffId: z.string().uuid('Choose a substitute'),
  reason: z.enum(SUBSTITUTION_REASONS),
});
export type AssignSubstitutionInput = z.infer<typeof assignSubstitutionSchema>;

// Mirrors publish_timetable()'s own signature in
// supabase/migrations/20260731640000_timetable_publish_and_version_lifecycle.sql.
export const publishTimetableSchema = z.object({
  effectiveFrom: z.string().min(1, 'Required'),
  overrideReason: z.string().max(500).optional(),
});
export type PublishTimetableInput = z.infer<typeof publishTimetableSchema>;

// Mirrors set_student_elective_choice()'s own signature in
// supabase/migrations/20260731670000_section_double_booking_prevention.sql.
export const setStudentElectiveChoiceSchema = z.object({
  sessionId: z.string().uuid(),
  classLevelId: z.string().uuid(),
  electiveBucket: z.coerce.number().int(),
  subjectId: z.string().uuid('Choose a subject'),
});
export type SetStudentElectiveChoiceInput = z.infer<typeof setStudentElectiveChoiceSchema>;

// Mirrors search_staff()'s own signature in
// supabase/migrations/20260731720000_staff_directory_search.sql.
export const searchStaffSchema = z.object({
  q: z.string().max(200).optional(),
  includeFormer: z.boolean().optional(),
});
export type SearchStaffInput = z.infer<typeof searchStaffSchema>;

// Mirrors global_search()'s own signature in
// supabase/migrations/20260801130000_system_wide_search.sql. The
// 2-character floor mirrors that function's own guard: one character
// trigram-matches most of the school.
export const globalSearchSchema = z.object({
  q: z.string().trim().min(2, 'Type at least 2 characters.').max(200),
  limit: z.coerce.number().int().min(1).max(50).optional(),
});
export type GlobalSearchInput = z.infer<typeof globalSearchSchema>;

// Mirrors set_attendance_status_weight()'s own signature in
// supabase/migrations/20260731730000_attendance_status_weight.sql.
export const setAttendanceStatusWeightSchema = z.object({
  campusId: z.string().uuid(),
  sessionId: z.string().uuid(),
  status: z.enum(STUDENT_ATTENDANCE_STATUSES),
  weight: z.coerce.number().min(0, 'Weight must be between 0 and 1').max(1, 'Weight must be between 0 and 1'),
});
export type SetAttendanceStatusWeightInput = z.infer<typeof setAttendanceStatusWeightSchema>;

// Mirrors request_audit_export()'s own signature in
// supabase/migrations/20260731790000_audit_trail_export.sql. The entity
// list is a fixed, curated set rather than every audited table name in
// the schema — 'certificate_issue' is included even though no such table
// exists yet (module T's first shipped FR), a real filter parameter that
// simply matches nothing today; see that migration's own header.
export const AUDIT_EXPORT_ENTITIES = [
  'certificate_issue',
  'fee_challan',
  'fee_payment',
  'concession_award',
  'student',
  'enrolment',
  'app_user',
] as const;

export const requestAuditExportSchema = z
  .object({
    from: z.string().min(1, 'Required'),
    to: z.string().min(1, 'Required'),
    tableNames: z.array(z.enum(AUDIT_EXPORT_ENTITIES)).min(1, 'Choose at least one entity'),
    campusId: z.union([z.string().uuid(), z.literal('')]).optional(),
  })
  .refine((v) => v.to >= v.from, { message: 'End date must be on or after the start date', path: ['to'] });
export type RequestAuditExportInput = z.infer<typeof requestAuditExportSchema>;

// FR-F15: mirrors public.timetable_export_layout.
export const TIMETABLE_EXPORT_LAYOUTS = ['section', 'teacher', 'master'] as const;
export type TimetableExportLayout = (typeof TIMETABLE_EXPORT_LAYOUTS)[number];

export const requestTimetableExportSchema = z.object({
  versionId: z.string().uuid('Choose a timetable version'),
  layout: z.enum(TIMETABLE_EXPORT_LAYOUTS),
  staffId: z.union([z.string().uuid(), z.literal('')]).optional(),
});
export type RequestTimetableExportInput = z.infer<typeof requestTimetableExportSchema>;

// FR-T01: mirrors public.certificate_type / certificate_language /
// certificate_page_size and create_certificate_template()'s own signature
// in supabase/migrations/20260731860000_certificate_template_designer.sql.
export const CERTIFICATE_TYPES = ['transfer', 'character', 'bonafide'] as const;
export type CertificateType = (typeof CERTIFICATE_TYPES)[number];
export const CERTIFICATE_LANGUAGES = ['en', 'ur'] as const;
export type CertificateLanguageCode = (typeof CERTIFICATE_LANGUAGES)[number];
export const CERTIFICATE_PAGE_SIZES = ['A4', 'A5', 'Legal'] as const;
export type CertificatePageSize = (typeof CERTIFICATE_PAGE_SIZES)[number];

// Same shape as chk_cert_template_board: an empty string means "any board",
// which is how a bonafide or character certificate is authored.
const boardCodeSchema = z
  .string()
  .regex(/^[A-Z0-9][A-Z0-9-]{1,23}$/, 'Use capitals, digits and dashes, e.g. FBISE')
  .or(z.literal(''));

export const createCertificateTemplateSchema = z.object({
  certificateType: z.enum(CERTIFICATE_TYPES),
  title: z.string().min(1, 'Required').max(200),
  bodyHtml: z.string().min(1, 'Required').max(50000),
  boardCode: boardCodeSchema.optional(),
  language: z.enum(CERTIFICATE_LANGUAGES),
  pageSize: z.enum(CERTIFICATE_PAGE_SIZES),
  campusId: z.union([z.string().uuid(), z.literal('')]).optional(),
});
export type CreateCertificateTemplateInput = z.infer<typeof createCertificateTemplateSchema>;

export const saveCertificateTemplateSchema = z.object({
  templateId: z.string().uuid(),
  title: z.string().min(1, 'Required').max(200),
  bodyHtml: z.string().min(1, 'Required').max(50000),
  pageSize: z.enum(CERTIFICATE_PAGE_SIZES),
});
export type SaveCertificateTemplateInput = z.infer<typeof saveCertificateTemplateSchema>;

// FR-T03: mirrors issue_transfer_certificate()'s signature in
// supabase/migrations/20260731880000_transfer_certificate_issuance.sql. The
// database re-checks every one of these — the leaving date against the date
// of admission, the enrolment's state, the campus scope — so this exists
// only to keep an obviously incomplete form out of a transaction that would
// consume nothing but still raise.
export const issueTransferCertificateSchema = z.object({
  enrolmentId: z.string().uuid('Choose a student'),
  leavingDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a leaving date'),
  reason: z.string().max(500).optional(),
  conduct: z.string().max(120).optional(),
  boardCode: boardCodeSchema.optional(),
  language: z.enum(CERTIFICATE_LANGUAGES),
  overrideReason: z.string().max(500).optional(),
});
export type IssueTransferCertificateInput = z.infer<typeof issueTransferCertificateSchema>;

// FR-T05: mirrors issue_character_certificate()'s own guard and
// chk_conduct_grade in
// supabase/migrations/20260731890000_character_certificate_issuance.sql.
// Both of those still fire — this only keeps an obviously wrong form out of
// a transaction.
export const CHARACTER_CONDUCT_GRADES = ['Excellent', 'Very Good', 'Good', 'Satisfactory'] as const;
export type CharacterConductGrade = (typeof CHARACTER_CONDUCT_GRADES)[number];

const optionalDateSchema = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Use a full date')
  .or(z.literal(''))
  .optional();

// periodFrom/periodTo are OVERRIDES: left blank, the database derives the
// attendance period from the student's whole enrolment history (AC1).
export const issueCharacterCertificateSchema = z.object({
  studentId: z.string().uuid('Choose a student'),
  conduct: z.enum(CHARACTER_CONDUCT_GRADES, {
    errorMap: () => ({ message: 'Conduct must be Excellent, Very Good, Good or Satisfactory' }),
  }),
  periodFrom: optionalDateSchema,
  periodTo: optionalDateSchema,
  remarks: z.string().max(500).optional(),
  boardCode: boardCodeSchema.optional(),
  language: z.enum(CERTIFICATE_LANGUAGES),
});
export type IssueCharacterCertificateInput = z.infer<typeof issueCharacterCertificateSchema>;

// FR-T08: mirrors revoke_certificate() and set_certificate_replacement() in
// supabase/migrations/20260731900000_certificate_register_immutability.sql.
// The database re-checks all of it — the role, the campus scope, that the
// entry is still live, that the replacement is a live certificate of the
// same type for the same student — and the append-only trigger refuses
// anything these functions did not do, so this only keeps an obviously
// incomplete form out of a transaction.
export const revokeCertificateSchema = z.object({
  issueId: z.string().uuid(),
  reason: z.string().trim().min(3, 'Say why the certificate is being cancelled').max(500),
  replacementIssueId: z.union([z.string().uuid(), z.literal('')]).optional(),
});
export type RevokeCertificateInput = z.infer<typeof revokeCertificateSchema>;

export const setCertificateReplacementSchema = z.object({
  cancelledIssueId: z.string().uuid(),
  replacementIssueId: z.string().uuid('Choose the certificate that replaced it'),
});
export type SetCertificateReplacementInput = z.infer<typeof setCertificateReplacementSchema>;

// AC3's filter: a certificate type and an academic year, optionally one
// campus. The year range is the same one FR-T02's counter accepts.
export const certificateRegisterFilterSchema = z.object({
  campusId: z.union([z.string().uuid(), z.literal('')]).optional(),
  certificateType: z.enum(CERTIFICATE_TYPES),
  academicYear: z.coerce.number().int().min(1900).max(2999),
});
export type CertificateRegisterFilterInput = z.infer<typeof certificateRegisterFilterSchema>;

// FR-T15: mirrors record_consent() and reserve_consent_evidence_path() in
// supabase/migrations/20260731920000_consent_capture.sql. Every one of
// these is re-checked there — the guardian link, the campus scope, the
// paper-needs-a-scan rule, the file size and type — so this only keeps an
// obviously incomplete form out of a transaction that would raise anyway.
export const CONSENT_DECISIONS = ['granted', 'denied', 'withdrawn'] as const;
export type ConsentDecision = (typeof CONSENT_DECISIONS)[number];

export const CONSENT_CHANNELS = ['portal', 'paper', 'counter', 'whatsapp'] as const;
export type ConsentChannel = (typeof CONSENT_CHANNELS)[number];

export const recordConsentSchema = z.object({
  studentId: z.string().uuid('Choose a student'),
  purposeCode: z.string().min(1, 'Choose a purpose'),
  guardianId: z.string().uuid('Choose the guardian whose decision this is'),
  decision: z.enum(CONSENT_DECISIONS),
  channel: z.enum(CONSENT_CHANNELS),
});
export type RecordConsentInput = z.infer<typeof recordConsentSchema>;

export const buildGalleryExportSchema = z.object({
  campusId: z.string().uuid('Choose a campus'),
  sectionId: z.union([z.string().uuid(), z.literal('')]).optional(),
});
export type BuildGalleryExportInput = z.infer<typeof buildGalleryExportSchema>;

// FR-L11: mirrors submit_expense_voucher(), decide_expense_voucher() and
// mark_expense_voucher_paid() in
// supabase/migrations/20260731940000_expense_voucher_approval_chain.sql.
// Every one of these is re-checked there — the role, the campus scope, the
// head, the future date, the ten-character rejection reason — and the
// status guard refuses anything those functions did not do, so this only
// keeps an obviously incomplete form out of a transaction that would raise.
//
// Amounts are entered in RUPEES and sent as PAISA: the database stores paisa
// as bigint everywhere (fee_ledger.amount_paisa), and a form that posted
// rupees would be one rounding decision away from disagreeing with it.
export const rupeesToPaisa = (rupees: number): number => Math.round(rupees * 100);
export const formatPaisa = (paisa: number): string => (paisa / 100).toLocaleString('en-PK');

export const submitExpenseVoucherSchema = z.object({
  campusId: z.string().uuid('Choose a campus'),
  headId: z.string().uuid('Choose an expense head'),
  payeeName: z.string().trim().min(1, 'Name who is being paid').max(200),
  payeeNtn: z.string().trim().max(30).optional(),
  amountRupees: z.coerce.number().positive('Enter an amount above zero').max(99999999),
  voucherDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Use a full date'),
  narrative: z.string().trim().max(500).optional(),
});
export type SubmitExpenseVoucherInput = z.infer<typeof submitExpenseVoucherSchema>;

export const EXPENSE_DECISIONS = ['approved', 'rejected'] as const;
export type ExpenseDecision = (typeof EXPENSE_DECISIONS)[number];

// AC2's ten characters. chk_expense_approval_reason enforces the same bound
// as a CHECK constraint, so a short reason cannot be written by any path;
// this is the message somebody reads before they get there.
export const decideExpenseVoucherSchema = z
  .object({
    voucherId: z.string().uuid(),
    decision: z.enum(EXPENSE_DECISIONS),
    reason: z.string().trim().max(1000).optional(),
  })
  .refine((v) => v.decision !== 'rejected' || (v.reason ?? '').length >= 10, {
    message: 'A rejection has to say why, in at least 10 characters',
    path: ['reason'],
  });
export type DecideExpenseVoucherInput = z.infer<typeof decideExpenseVoucherSchema>;

export const markExpenseVoucherPaidSchema = z.object({
  voucherId: z.string().uuid(),
  paidReference: z.string().trim().max(100).optional(),
});
export type MarkExpenseVoucherPaidInput = z.infer<typeof markExpenseVoucherPaidSchema>;

// FR-I01: mirrors upsert_exam_term() in
// supabase/migrations/20260731950000_exam_term_definition_and_weightage.sql.
// Weightage is entered as a PERCENTAGE and stored as basis points (1 bp =
// 0.01%), the same smallest-unit discipline as paisa above. The two-decimal
// bound is the basis-point floor, re-raised as WEIGHT_PRECISION by
// app.exam_term_weight_bp() — this only keeps an obviously wrong form out
// of a transaction that would raise.
export const EXAM_TERM_WEIGHT_BP_TOTAL = 10000;
export const pctToBasisPoints = (pct: number): number => Math.round(pct * 100);
export const formatWeightPct = (pct: number): string => pct.toFixed(2);

export const upsertExamTermSchema = z.object({
  campusId: z.string().uuid('Choose a campus'),
  sessionId: z.string().uuid('Choose an academic session'),
  code: z
    .string()
    .trim()
    .min(1, 'Required')
    .max(20, 'At most 20 characters')
    .regex(/^[A-Za-z0-9_-]+$/, 'Letters, numbers, hyphens and underscores only'),
  name: z.string().trim().min(1, 'Required').max(100),
  nameUr: z.string().trim().max(100).optional(),
  sequence: z.coerce.number().int().min(1, 'From 1').max(40, 'At most 40'),
  weightPct: z.coerce
    .number()
    .min(0, 'Between 0 and 100')
    .max(100, 'Between 0 and 100')
    .refine((v) => Math.abs(v * 100 - Math.round(v * 100)) < 1e-9, {
      message: 'At most two decimal places',
    }),
  countsTowardAnnual: z.boolean(),
});
export type UpsertExamTermInput = z.infer<typeof upsertExamTermSchema>;

export const activateExamTermsSchema = z.object({
  campusId: z.string().uuid(),
  sessionId: z.string().uuid(),
});
export type ActivateExamTermsInput = z.infer<typeof activateExamTermsSchema>;

export const examTermIdSchema = z.object({ examTermId: z.string().uuid() });

// FR-I02: mirrors upsert_exam_subject() in
// supabase/migrations/20260731960000_exam_subject_and_component_setup.sql.
// Marks are integers, matching subject.default_max_marks and
// class_subject.max_marks, which are already int — half marks are not
// representable and that is module E's existing decision.
export const MARK_COMPONENT_CODES = ['theory', 'practical', 'internal', 'project', 'viva'] as const;
export type MarkComponentCode = (typeof MARK_COMPONENT_CODES)[number];

// AC4's wording, asserted by pgTAP against fn_exam_entry_readiness(). Kept
// here so a screen rendering the disabled grid without calling the function
// still says the same thing.
export const EXAM_SETUP_PENDING = 'exam setup pending — contact the exam office';

// AC2's wording. The database raises it too — this is the copy a form can
// show before a round trip.
export const PASS_EXCEEDS_MAX = 'pass marks cannot exceed maximum marks';

export const examComponentSchema = z
  .object({
    component: z.enum(MARK_COMPONENT_CODES),
    maxMarks: z.coerce.number().int().min(1, 'Above zero').max(1000),
    passMarks: z.coerce.number().int().min(0, 'Cannot be negative').max(1000),
  })
  .refine((c) => c.passMarks <= c.maxMarks, { message: PASS_EXCEEDS_MAX, path: ['passMarks'] });
export type ExamComponentInput = z.infer<typeof examComponentSchema>;

export const upsertExamSubjectSchema = z
  .object({
    examTermId: z.string().uuid('Choose an exam term'),
    classSubjectId: z.string().uuid('Choose a class subject'),
    components: z.array(examComponentSchema).min(1, 'Add at least one component').max(MARK_COMPONENT_CODES.length),
  })
  .refine((v) => new Set(v.components.map((c) => c.component)).size === v.components.length, {
    message: 'Each component can only be configured once',
    path: ['components'],
  });
export type UpsertExamSubjectInput = z.infer<typeof upsertExamSubjectSchema>;

export const examSubjectTotalMax = (components: { maxMarks: number }[]): number =>
  components.reduce((sum, c) => sum + (Number.isFinite(c.maxMarks) ? c.maxMarks : 0), 0);

export const examSubjectIdSchema = z.object({ examSubjectId: z.string().uuid() });

// FR-I12: teacher mark entry. Mirrors
// supabase/migrations/20260731970000_teacher_mark_entry.sql — the trigger
// trg_mark_range_check is the real gate for every one of these rules; this is
// the copy the grid shows in the cell, before any round trip, which is what
// AC1's "keyboard focus stays in the cell" needs.
export const MARK_STATUSES = ['draft', 'submitted', 'moderated', 'approved', 'locked'] as const;
export type MarkStatus = (typeof MARK_STATUSES)[number];

// AC2's wording, and its own default: a campus that never set mark_precision
// awards whole marks.
export const DEFAULT_MARK_PRECISION = 0;
export const WHOLE_NUMBERS_ONLY = 'whole numbers only';
export const MARKS_NEGATIVE = 'marks cannot be negative';
export const MARKS_NOT_A_NUMBER = 'numbers only';

// AC1's wording. The database raises exactly this too.
export const markMaxMessage = (maxMarks: number): string => `max ${maxMarks}`;
export const markPrecisionMessage = (precision: number): string =>
  precision === 0 ? WHOLE_NUMBERS_ONLY : `at most ${precision} decimal place${precision === 1 ? '' : 's'}`;

/**
 * AC1 and AC2 in one place. Returns the message to show in the cell, or null
 * when the value may be saved. An empty cell is valid — it means "no mark
 * yet", which is a delete, not a zero.
 */
export function validateMarkCell(raw: string, maxMarks: number, precision: number): string | null {
  const value = raw.trim();
  if (value === '') return null;
  if (!/^-?\d+(\.\d+)?$/.test(value)) return MARKS_NOT_A_NUMBER;

  const n = Number(value);
  if (n < 0) return MARKS_NEGATIVE;
  if (n > maxMarks) return markMaxMessage(maxMarks);
  // By value, not by typing: 45.00 is a whole number, 45.5 is not.
  const scaled = Math.round(n * 10 ** precision) / 10 ** precision;
  if (scaled !== n) return markPrecisionMessage(precision);
  return null;
}

export const markCellSchema = z.object({
  enrolmentId: z.string().uuid(),
  component: z.enum(MARK_COMPONENT_CODES),
  // null clears the cell — fn_upsert_marks deletes the row rather than
  // storing a null, because marks_obtained has no "no mark" value.
  marksObtained: z.number().min(0).max(1000).nullable(),
});

export const upsertMarksSchema = z.object({
  examSubjectId: z.string().uuid(),
  cells: z.array(markCellSchema).min(1),
  // Minted once per queued submission by the offline queue and reused across
  // every retry of that submission, never regenerated — the same discipline
  // as collectCashPaymentSchema's clientIdempotencyKey.
  clientBatchId: z.string().uuid().optional(),
});
export type UpsertMarksInput = z.infer<typeof upsertMarksSchema>;

export const setMarkPrecisionSchema = z.object({
  campusId: z.string().uuid(),
  precision: z.coerce.number().int().min(0).max(2),
});
export type SetMarkPrecisionInput = z.infer<typeof setMarkPrecisionSchema>;

// FR-I11: absent, exempt and debarred handling. Mirrors
// supabase/migrations/20260731980000_exam_absence_exemption_debarment.sql.
export const EXAM_ATTENDANCE_STATUSES = ['present', 'absent', 'exempt', 'debarred'] as const;
export type ExamAttendanceStatus = (typeof EXAM_ATTENDANCE_STATUSES)[number];

export const EXAM_ABSENCE_REASONS = [
  'medical',
  'unauthorised',
  'fee_default',
  'religious_exemption',
  'board_exemption',
  'disciplinary',
] as const;
export type ExamAbsenceReason = (typeof EXAM_ABSENCE_REASONS)[number];

// A UI convenience only: the database accepts any reason with any
// non-present status, deliberately, because a school will eventually have a
// case none of these pairings anticipated. This narrows the dropdown to the
// ones that make sense together so the common case is one click.
export const ABSENCE_REASONS_BY_STATUS: Record<
  Exclude<ExamAttendanceStatus, 'present'>,
  readonly ExamAbsenceReason[]
> = {
  absent: ['medical', 'unauthorised'],
  exempt: ['religious_exemption', 'board_exemption'],
  debarred: ['fee_default', 'disciplinary'],
};

/** AC3's 'AB', and its two siblings. Null for a candidate who sat the paper. */
export const examReportSymbol = (status: ExamAttendanceStatus): string | null =>
  status === 'absent' ? 'AB' : status === 'exempt' ? 'EX' : status === 'debarred' ? 'DEB' : null;

export const setExamAttendanceSchema = z
  .object({
    examSubjectId: z.string().uuid(),
    enrolmentId: z.string().uuid(),
    status: z.enum(EXAM_ATTENDANCE_STATUSES),
    reason: z.enum(EXAM_ABSENCE_REASONS).nullable(),
    note: z.string().max(500).optional(),
  })
  // chk_exam_attendance_reason, both ways: the requirement's mandatory reason
  // code, and no reason at all on a candidate who sat the paper.
  .refine((v) => (v.status === 'present') === (v.reason === null), {
    message: 'Absent, exempt and debarred each need a reason code',
    path: ['reason'],
  });
export type SetExamAttendanceInput = z.infer<typeof setExamAttendanceSchema>;

// FR-I16: mark approval and locking. Mirrors
// supabase/migrations/20260731990000_mark_approval_and_locking.sql.
//
// AC3's own token, raised by trg_mark_entry_block_when_locked for every
// caller. Kept here so a grid that already knows the set is locked says the
// same thing as the refusal it would get.
export const MARKS_LOCKED = 'marks_locked';

/** The roles fn_approve_marks() accepts — FR-I01's lock_exam_term() gate. */
export const MARK_APPROVER_ROLES = ['super_admin', 'owner', 'principal', 'exam_controller'] as const;

export const approveMarksSchema = z.object({
  examSubjectId: z.string().uuid(),
  sectionId: z.string().uuid(),
});
export type ApproveMarksInput = z.infer<typeof approveMarksSchema>;

// FR-I17: break-glass mark unlock. Mirrors
// supabase/migrations/20260731991000_break_glass_mark_unlock.sql.
//
// Two role lists, and the gap between them IS the control: the person who
// wants the marks open is never the person who opens them. A user in both
// lists still cannot approve their OWN request — chk_unlock_no_self_approve is
// a table constraint, so that holds for every caller, not just this form.
export const MARK_UNLOCK_REQUESTER_ROLES = [
  'super_admin',
  'owner',
  'principal',
  'vice_principal',
  'exam_controller',
] as const;
export const MARK_UNLOCK_APPROVER_ROLES = ['super_admin', 'owner', 'principal'] as const;

export const UNLOCK_REASON_MIN = 10;
export const DEFAULT_UNLOCK_WINDOW_MINUTES = 60;
export const MIN_UNLOCK_WINDOW_MINUTES = 1;
export const MAX_UNLOCK_WINDOW_MINUTES = 240;

export const requestMarkUnlockSchema = z.object({
  examSubjectId: z.string().uuid(),
  sectionId: z.string().uuid(),
  reason: z
    .string()
    .trim()
    .min(UNLOCK_REASON_MIN, `Say why in at least ${UNLOCK_REASON_MIN} characters`)
    .max(2000),
});
export type RequestMarkUnlockInput = z.infer<typeof requestMarkUnlockSchema>;

export const breakGlassUnlockSchema = z.object({
  requestId: z.string().uuid(),
  windowMinutes: z.coerce
    .number()
    .int()
    .min(MIN_UNLOCK_WINDOW_MINUTES)
    .max(MAX_UNLOCK_WINDOW_MINUTES)
    .default(DEFAULT_UNLOCK_WINDOW_MINUTES),
});
export type BreakGlassUnlockInput = z.infer<typeof breakGlassUnlockSchema>;

export const rejectMarkUnlockSchema = z.object({
  requestId: z.string().uuid(),
  note: z.string().trim().max(2000).optional(),
});
export type RejectMarkUnlockInput = z.infer<typeof rejectMarkUnlockSchema>;

/** Minutes left in an open window, floored at 0. Null when there is no window. */
export function unlockMinutesLeft(expiresAt: string | null | undefined, now: number = Date.now()): number | null {
  if (!expiresAt) return null;
  return Math.max(0, Math.ceil((new Date(expiresAt).getTime() - now) / 60_000));
}

// FR-I14: mandatory teacher override of OCR marks. Mirrors
// supabase/migrations/20260731992000_mandatory_ocr_mark_override.sql.
//
// The three values mark_entry.source can hold. There is deliberately no
// "suggested" or "pending" value: an unreviewed machine mark is not a
// mark_entry row at all, it is an ocr_mark_suggestion, and only
// fn_promote_ocr_marks() can move it across.
export const MARK_SOURCES = ['manual', 'ocr_confirmed', 'ocr_overridden'] as const;
export type MarkSource = (typeof MARK_SOURCES)[number];

/** What the cell badge says. Null for a mark somebody typed. */
export const markSourceLabel = (source: MarkSource | undefined): string | null =>
  source === 'ocr_confirmed' ? 'OCR confirmed' : source === 'ocr_overridden' ? 'OCR amended' : null;

export const OCR_CANCEL_REASON_MIN = 10;

/**
 * AC1's sentence, built here so the button can say what the refusal would say
 * before anyone presses it. fn_promote_ocr_marks() raises exactly this.
 */
export const ocrReviewProgressMessage = (reviewed: number, total: number): string =>
  `${reviewed} of ${total} scripts reviewed`;

export const ocrReviewEntrySchema = z.object({
  enrolmentId: z.string().uuid(),
  questionNo: z.number().int().min(1),
  // Omitted means "accept what the machine said". The value the machine
  // actually read is never sent from the client — fn_record_ocr_review() copies
  // it from the suggestion, so "the teacher changed it" stays falsifiable.
  finalValue: z.number().min(0).max(1000).optional(),
});

export const recordOcrReviewSchema = z.object({
  jobId: z.string().uuid(),
  // AC3: a bulk accept of a page sends one entry per script, and one review row
  // lands per entry. There is no payload shape that means "a page".
  reviews: z.array(ocrReviewEntrySchema).min(1),
});
export type RecordOcrReviewInput = z.infer<typeof recordOcrReviewSchema>;

export const promoteOcrMarksSchema = z.object({ jobId: z.string().uuid() });
export type PromoteOcrMarksInput = z.infer<typeof promoteOcrMarksSchema>;

export const cancelOcrJobSchema = z.object({
  jobId: z.string().uuid(),
  reason: z
    .string()
    .trim()
    .min(OCR_CANCEL_REASON_MIN, `Say why in at least ${OCR_CANCEL_REASON_MIN} characters`)
    .max(2000),
});
export type CancelOcrJobInput = z.infer<typeof cancelOcrJobSchema>;

// FR-J01: board grading scheme configuration. Mirrors
// supabase/migrations/20260731995000_board_grading_scheme.sql.
//
// Percentages and band bounds live on a two-decimal grid. That is not a
// display choice: FR-J02 rounds a percentage to two decimals once and grades
// THAT number, so a boundary is only unambiguous if the boundary is on the
// same grid. 32.995% is 33.00% and grades as such.
export const BOARDS = ['FBISE', 'PUNJAB', 'SINDH', 'KPK', 'BALOCHISTAN', 'AKU_EB', 'CAMBRIDGE'] as const;
export type Board = (typeof BOARDS)[number];

export const GRADING_SCHEME_STATUSES = ['draft', 'active', 'retired'] as const;
export type GradingSchemeStatus = (typeof GRADING_SCHEME_STATUSES)[number];

/** save_grading_scheme(), activate_grading_scheme(), new_grading_scheme_version(). */
export const GRADING_SCHEME_ROLES = ['super_admin', 'owner', 'principal', 'exam_controller'] as const;

/** One step on the two-decimal grid — the distance between adjacent bands. */
export const PCT_STEP = 0.01;

/**
 * Round half away from zero at two decimals, matching Postgres
 * round(numeric, 2).
 *
 * The shift is done on the DECIMAL representation rather than by multiplying,
 * because a double cannot hold 32.995: `32.995 * 100` is 3299.4999999999995 and
 * Math.round would give 32.99 where Postgres numeric gives 33.00. Parsing
 * "32.995e2" instead asks the number parser for the nearest double to 3299.5,
 * which is exact — the same answer the database reaches, on the value the user
 * actually typed.
 *
 * This is a preview. The percentage a result is graded on is computed in
 * numeric, in the database, and never here.
 */
export function roundPct(pct: number): number {
  if (!Number.isFinite(pct)) return pct;
  const literal = `${pct}`;
  if (literal.includes('e') || literal.includes('E')) return Math.round(pct * 100) / 100;
  const shifted = Number(`${literal}e2`);
  return Number(`${Math.sign(shifted) * Math.round(Math.abs(shifted))}e-2`);
}

const pct2 = (n: number) => n.toFixed(2);

export const gradingBandSchema = z
  .object({
    gradeLabel: z.string().trim().min(1, 'A band needs a grade').max(8),
    minPct: z.coerce.number().min(0, 'Not below 0').max(100, 'Not above 100'),
    maxPct: z.coerce.number().min(0, 'Not below 0').max(100, 'Not above 100'),
    gpaPoint: z.coerce.number().min(0).max(9.99).nullable().optional(),
    isPass: z.boolean().default(true),
    remarkEn: z.string().trim().max(160).optional(),
    remarkUr: z.string().trim().max(160).optional(),
  })
  .refine((b) => b.minPct <= b.maxPct, { message: 'The lower bound cannot exceed the upper', path: ['maxPct'] });
export type GradingBandInput = z.infer<typeof gradingBandSchema>;

export const saveGradingSchemeSchema = z.object({
  schemeId: z.string().uuid().optional(),
  board: z.enum(BOARDS),
  name: z.string().trim().min(1, 'A scheme needs a name').max(120),
  effectiveFrom: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the date this scale starts applying'),
  bands: z.array(gradingBandSchema).min(1, 'A grading scheme needs at least one band'),
});
export type SaveGradingSchemeInput = z.infer<typeof saveGradingSchemeSchema>;

export const gradingSchemeIdSchema = z.object({ schemeId: z.string().uuid() });

export const newGradingSchemeVersionSchema = z.object({
  schemeId: z.string().uuid(),
  effectiveFrom: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the date the new version starts applying'),
});
export type NewGradingSchemeVersionInput = z.infer<typeof newGradingSchemeVersionSchema>;

/**
 * The same gap/overlap rule app.fn_grading_band_coverage_error() holds, so the
 * editor can name the uncovered range while the controller is still typing.
 * The database is still the gate — save_grading_scheme() re-runs it before
 * writing a row — but a boundary is much easier to fix while you can see it.
 *
 * Returns null when the bands cover 0.00-100.00 exactly once, else the same
 * sentence the database would refuse with.
 */
export function gradingBandCoverageError(bands: { gradeLabel: string; minPct: number; maxPct: number }[]): string | null {
  if (bands.length === 0) return 'a grading scheme needs at least one band';

  const bad = bands.find((b) => b.minPct > b.maxPct || b.minPct < 0 || b.maxPct > 100);
  if (bad) {
    return `band ${bad.gradeLabel} has bounds ${pct2(bad.minPct)}-${pct2(bad.maxPct)}, which is not a range inside 0.00-100.00`;
  }
  const imprecise = bands.find((b) => roundPct(b.minPct) !== b.minPct || roundPct(b.maxPct) !== b.maxPct);
  if (imprecise) return `band ${imprecise.gradeLabel} bounds must have at most two decimal places`;

  const sorted = [...bands].sort((a, b) => a.minPct - b.minPct);
  if (sorted[0]!.minPct > 0) return `grading bands leave 0.00-${pct2(sorted[0]!.minPct)} uncovered`;

  const ceiling = Math.max(...bands.map((b) => b.maxPct));
  if (ceiling < 100) return `grading bands leave ${pct2(ceiling)}-100.00 uncovered`;

  for (let i = 1; i < sorted.length; i += 1) {
    const prev = sorted[i - 1]!;
    const band = sorted[i]!;
    const expected = roundPct(prev.maxPct + PCT_STEP);
    if (band.minPct === expected) continue;
    if (band.minPct > expected) {
      return `grading bands leave ${pct2(prev.maxPct)}-${pct2(band.minPct)} uncovered`;
    }
    return `grading bands ${prev.gradeLabel} and ${band.gradeLabel} overlap between ${pct2(band.minPct)} and ${pct2(prev.maxPct)}`;
  }
  return null;
}

/** The band a percentage falls in, on the same two-decimal grid the database uses. */
export function bandForPct<T extends { minPct: number; maxPct: number }>(bands: T[], pct: number | null): T | null {
  if (pct === null || Number.isNaN(pct)) return null;
  const p = roundPct(pct);
  return bands.find((b) => p >= b.minPct && p <= b.maxPct) ?? null;
}

/**
 * The published FBISE scale, as the configuration screen's preset. It is here
 * and not seeded into the database on purpose: a board's bands are a fact
 * about a particular gazette in a particular year, and a scale nobody chose
 * quietly grading transcripts is exactly what FR-J01's Notes warn about. A
 * human clicks this, reads it, and saves it.
 */
export const FBISE_PRESET_BANDS: GradingBandInput[] = [
  { gradeLabel: 'A1', minPct: 80, maxPct: 100, gpaPoint: 4.0, isPass: true, remarkEn: 'Outstanding' },
  { gradeLabel: 'A', minPct: 70, maxPct: 79.99, gpaPoint: 3.7, isPass: true, remarkEn: 'Excellent' },
  { gradeLabel: 'B', minPct: 60, maxPct: 69.99, gpaPoint: 3.3, isPass: true, remarkEn: 'Very good' },
  { gradeLabel: 'C', minPct: 50, maxPct: 59.99, gpaPoint: 3.0, isPass: true, remarkEn: 'Good' },
  { gradeLabel: 'D', minPct: 40, maxPct: 49.99, gpaPoint: 2.5, isPass: true, remarkEn: 'Fair' },
  { gradeLabel: 'E', minPct: 33, maxPct: 39.99, gpaPoint: 2.0, isPass: true, remarkEn: 'Satisfactory' },
  { gradeLabel: 'F', minPct: 0, maxPct: 32.99, gpaPoint: 0, isPass: false, remarkEn: 'Fail' },
];

// FR-J02: subject term result computation. Mirrors
// supabase/migrations/20260731996000_subject_term_result_computation.sql.
//
// The Actors are System and Exam Controller; a Vice Principal is in the list
// because fn_compute_subject_result() accepts one and a screen that hid the
// button from a role the database allows would be lying about the rule.
export const RESULT_COMPUTE_ROLES = [
  'super_admin',
  'owner',
  'principal',
  'vice_principal',
  'exam_controller',
] as const;

export const computeSubjectResultSchema = z.object({
  examTermId: z.string().uuid(),
  sectionId: z.string().uuid(),
});
export type ComputeSubjectResultInput = z.infer<typeof computeSubjectResultSchema>;

// FR-J03: weighted aggregation across terms. Mirrors
// supabase/migrations/20260731997000_weighted_annual_aggregation.sql.
//
// The recompute is per CLASS, not per section: an annual result spans every
// section of the class, because FR-I02's exam_subject is per class and only
// the class has one answer for what a subject was worth this year.
export const computeAnnualResultSchema = z.object({
  sessionId: z.string().uuid(),
  classLevelId: z.string().uuid(),
});
export type ComputeAnnualResultInput = z.infer<typeof computeAnnualResultSchema>;

// FR-J05: class and section position. Mirrors
// supabase/migrations/20260731998000_class_and_section_position.sql.
//
// Ranking is per CLASS for the reason the annual aggregate is: a class
// position is against every section of the class, and one taken while a
// section is still marking would move the day that section landed.
export const RANK_POLICIES = ['exclude_absentees', 'include_all'] as const;

export const computePositionsSchema = z.object({
  examTermId: z.string().uuid(),
  classLevelId: z.string().uuid(),
});
export type ComputePositionsInput = z.infer<typeof computePositionsSchema>;

export const setRankPolicySchema = z.object({
  campusId: z.string().uuid(),
  policy: z.enum(RANK_POLICIES),
});
export type SetRankPolicyInput = z.infer<typeof setRankPolicySchema>;

// FR-J08. A withhold is per (candidate, term); the screen that manages them
// is per class, because that is the list the accounts office works through.
export const WITHHOLD_MANUAL_REASONS = ['discipline', 'document_pending'] as const;

export const withholdSheetSchema = z.object({
  examTermId: z.string().uuid(),
  classLevelId: z.string().uuid(),
});
export type WithholdSheetInput = z.infer<typeof withholdSheetSchema>;

export const syncFeeWithholdsSchema = z.object({
  examTermId: z.string().uuid(),
});
export type SyncFeeWithholdsInput = z.infer<typeof syncFeeWithholdsSchema>;

// The reason is compulsory here as well as in the database: an override with
// no explanation is the one thing AC3 is asking to be recorded.
export const releaseWithholdSchema = z.object({
  withholdId: z.string().uuid(),
  reason: z.string().trim().min(10, 'Say why the dues are being set aside — at least a sentence.').max(500),
});
export type ReleaseWithholdInput = z.infer<typeof releaseWithholdSchema>;

export const raiseWithholdSchema = z.object({
  enrolmentId: z.string().uuid(),
  examTermId: z.string().uuid(),
  reason: z.enum(WITHHOLD_MANUAL_REASONS),
  note: z.string().trim().min(5, 'Say why this result is being held.').max(500),
});
export type RaiseWithholdInput = z.infer<typeof raiseWithholdSchema>;

// Rupees on the screen, paisa in the database — the conversion happens once,
// in the action, so no component has to remember which unit it is holding.
export const setWithholdThresholdSchema = z.object({
  campusId: z.string().uuid(),
  rupees: z.coerce.number().int().min(0).max(100_000_000),
});
export type SetWithholdThresholdInput = z.infer<typeof setWithholdThresholdSchema>;

// FR-J09. A report card is per (candidate, term); the screen that prints them
// is per section, because that is the pile a class teacher hands out.
export const reportCardSheetSchema = z.object({
  examTermId: z.string().uuid(),
  sectionId: z.string().uuid(),
});
export type ReportCardSheetInput = z.infer<typeof reportCardSheetSchema>;

// The remark is optional: a regeneration after a marks correction carries the
// previous revision's words forward rather than silently dropping them.
export const generateReportCardSchema = z.object({
  enrolmentId: z.string().uuid(),
  examTermId: z.string().uuid(),
  remark: z.string().trim().max(500).optional(),
});
export type GenerateReportCardInput = z.infer<typeof generateReportCardSchema>;

// FR-J12. The remarks travel WITH the batch rather than being typed into each
// card afterwards: AC2 counts a candidate with no remark among the skipped, so
// the map the screen has already collected is what decides which six they are.
export const REPORT_CARD_BATCH_SCOPES = ['section', 'class', 'campus'] as const;

const batchRemarks = z.record(z.string().uuid(), z.string().trim().max(500)).optional();

export const startReportCardBatchSchema = z.object({
  examTermId: z.string().uuid(),
  scope: z.enum(REPORT_CARD_BATCH_SCOPES),
  targetId: z.string().uuid(),
  remarks: batchRemarks,
  requireRemark: z.boolean().optional(),
});
export type StartReportCardBatchInput = z.infer<typeof startReportCardBatchSchema>;

export const reportCardBatchSchema = z.object({ batchId: z.string().uuid() });
export type ReportCardBatchInput = z.infer<typeof reportCardBatchSchema>;

export const retryReportCardBatchSchema = z.object({
  batchId: z.string().uuid(),
  remarks: batchRemarks,
});
export type RetryReportCardBatchInput = z.infer<typeof retryReportCardBatchSchema>;

export const latestReportCardBatchSchema = z.object({
  examTermId: z.string().uuid(),
  scope: z.enum(REPORT_CARD_BATCH_SCOPES),
  targetId: z.string().uuid(),
});
export type LatestReportCardBatchInput = z.infer<typeof latestReportCardBatchSchema>;

// FR-A16. Both bounds mirror table CHECKs (chk_consent_window,
// chk_impersonation_window) rather than standing in for them — the database
// refuses a 30-day consent or a 90-minute session for service_role too.
export const grantImpersonationConsentSchema = z.object({
  /** Absent means tenant scope: any eligible user, for a school that cannot yet say which login is broken. */
  targetUserId: z.string().uuid().optional(),
  hours: z.coerce.number().int().min(1, 'Between 1 and 24 hours').max(24, 'Between 1 and 24 hours'),
});
export type GrantImpersonationConsentInput = z.infer<typeof grantImpersonationConsentSchema>;

export const revokeImpersonationConsentSchema = z.object({ consentId: z.string().uuid() });
export type RevokeImpersonationConsentInput = z.infer<typeof revokeImpersonationConsentSchema>;

export const startImpersonationSchema = z.object({
  targetUserId: z.string().uuid(),
  minutes: z.coerce.number().int().min(1, 'Between 1 and 60 minutes').max(60, 'Between 1 and 60 minutes'),
});
export type StartImpersonationInput = z.infer<typeof startImpersonationSchema>;

export const endImpersonationSchema = z.object({ sessionId: z.string().uuid().optional() });
export type EndImpersonationInput = z.infer<typeof endImpersonationSchema>;

// FR-N01: the anonymous guardian claim form. The CNIC is never asked for in
// full — six digits are enough to match and far less to leak.
export const guardianClaimSchema = z.object({
  schoolCode: z
    .string()
    .trim()
    .min(3, 'Enter your school code')
    .max(50, 'Enter your school code')
    .transform((s) => s.toLowerCase()),
  grNumber: z
    .string()
    .trim()
    .max(30, 'Enter the GR number')
    .regex(/\d/, 'Enter the GR number'),
  cnicLast6: z.string().trim().regex(/^\d{6}$/, 'Enter the last 6 digits of your CNIC'),
});
export type GuardianClaimInput = z.input<typeof guardianClaimSchema>;
export type GuardianClaimParsed = z.output<typeof guardianClaimSchema>;

export const resolveGuardianClaimSchema = z.object({
  claimId: z.string().uuid(),
  approve: z.boolean(),
  note: z.string().trim().max(500).optional(),
});
export type ResolveGuardianClaimInput = z.infer<typeof resolveGuardianClaimSchema>;

// FR-K21: a gateway is configured with the NAME of the env var holding its
// signing secret — the secret value itself is never accepted or stored.
export const paymentGatewayConfigSchema = z.object({
  gateway: z.enum(['jazzcash', 'easypaisa', 'onelink']),
  merchantId: z.string().trim().min(1, 'Required').max(100),
  secretRef: z.string().trim().regex(/^[A-Z][A-Z0-9_]{2,63}$/, 'An environment variable name, e.g. PAY_SECRET_JAZZCASH'),
  isLive: z.boolean(),
  isEnabled: z.boolean(),
});
export type PaymentGatewayConfigInput = z.infer<typeof paymentGatewayConfigSchema>;

export const bankMappingProfileSchema = z
  .object({
    bankAccountId: z.string().uuid('Choose a bank account'),
    name: z.string().trim().min(1, 'Required').max(100),
    dateFormat: z.enum(['DD/MM/YYYY', 'DD-MM-YYYY', 'YYYY-MM-DD', 'DD-Mon-YYYY']),
    amountSignRule: z.enum(['credit_positive', 'separate_columns', 'absolute']),
    txnDate: z.string().min(1, 'Choose the date column'),
    challanRef: z.string().min(1, 'Choose the challan reference column'),
    bankRef: z.string().min(1, 'Choose the bank reference column'),
    amount: z.string().optional(),
    debit: z.string().optional(),
    credit: z.string().optional(),
  })
  .superRefine((v, ctx) => {
    if (v.amountSignRule === 'separate_columns') {
      if (!v.debit) ctx.addIssue({ code: 'custom', path: ['debit'], message: 'Choose the debit column' });
      if (!v.credit) ctx.addIssue({ code: 'custom', path: ['credit'], message: 'Choose the credit column' });
    } else if (!v.amount) {
      ctx.addIssue({ code: 'custom', path: ['amount'], message: 'Choose the amount column' });
    }
  });
export type BankMappingProfileInput = z.infer<typeof bankMappingProfileSchema>;

export const resolveBankExceptionSchema = z.object({
  exceptionId: z.string().uuid(),
  action: z.enum(['post', 'dismiss']),
  note: z.string().trim().min(5, 'Write a short note (at least 5 characters)').max(500),
  challanNo: z
    .string()
    .trim()
    .regex(/^\d{12}$|^$/, 'A challan number is 12 digits')
    .optional(),
});
export type ResolveBankExceptionInput = z.infer<typeof resolveBankExceptionSchema>;

// FR-S08: requesting an asynchronous export. The reason is enforced again in
// the database (FR-S11) for PII-bearing datasets; the form just says so early.
export const exportRequestSchema = z.object({
  datasetKey: z.enum(['students', 'fee_collection', 'fee_defaulters', 'fee_collection_monthly']),
  from: z.string().optional(),
  to: z.string().optional(),
  classId: z.string().uuid().optional(),
  bucket: z.enum(['1-30', '31-60', '61-90', '90+']).optional(),
  hideHardship: z.boolean().optional(),
  reason: z.string().trim().max(500).optional(),
});
export type ExportRequestInput = z.infer<typeof exportRequestSchema>;

// FR-K27: withdrawal settlement.
export const proposeSettlementSchema = z.object({
  grNumber: z.string().trim().min(1, 'Enter the GR number').max(30),
  leavingDate: z.string().min(1, 'Choose the leaving date'),
  basis: z.enum(['full_month', 'half_month', 'daily']),
  note: z.string().trim().max(500).optional(),
});
export type ProposeSettlementInput = z.infer<typeof proposeSettlementSchema>;

export const disburseSettlementSchema = z
  .object({
    settlementId: z.string().uuid(),
    instrumentType: z.enum(['cash', 'cheque', 'transfer']),
    instrumentRef: z.string().trim().max(100).optional(),
  })
  .refine((v) => v.instrumentType === 'cash' || Boolean(v.instrumentRef), { path: ['instrumentRef'], message: 'A cheque or transfer needs its reference number' });
export type DisburseSettlementInput = z.infer<typeof disburseSettlementSchema>;

// FR-K28: security deposit and no-dues clearance.
export const startClearanceSchema = z.object({ grNumber: z.string().trim().min(1, 'Enter the GR number').max(30) });
export type StartClearanceInput = z.infer<typeof startClearanceSchema>;

export const recordDepositSchema = z.object({
  grNumber: z.string().trim().min(1, 'Enter the GR number').max(30),
  amountPkr: z.number({ message: 'Enter the amount' }).positive('Amount must be above zero').max(10_000_000),
  receivedOn: z.string().min(1, 'Choose the date received'),
  mode: z.enum(['cash', 'cheque', 'transfer', 'bank_challan']),
  receiptRef: z.string().trim().max(60).optional(),
});
export type RecordDepositInput = z.infer<typeof recordDepositSchema>;

export const noDuesItemSchema = z.object({
  itemId: z.string().uuid(),
  outstandingPkr: z.number({ message: 'Enter the amount' }).min(0).max(10_000_000),
  note: z.string().trim().max(200).optional(),
});
export type NoDuesItemInput = z.infer<typeof noDuesItemSchema>;

export const decisionReasonSchema = z.object({ reason: z.string().trim().min(20, 'Give a reason of at least 20 characters').max(500) });
export type DecisionReasonInput = z.infer<typeof decisionReasonSchema>;

export const disburseDepositSchema = z
  .object({
    enrolmentId: z.string().uuid(),
    instrumentType: z.enum(['cash', 'cheque', 'transfer']),
    instrumentRef: z.string().trim().max(100).optional(),
  })
  .refine((v) => v.instrumentType === 'cash' || Boolean(v.instrumentRef), { path: ['instrumentRef'], message: 'A cheque or transfer needs its reference number' });
export type DisburseDepositInput = z.infer<typeof disburseDepositSchema>;

// FR-K23: gateway settlement reconciliation.
export const unsettledDaysSchema = z.object({ days: z.number({ message: 'Enter a number of days' }).int('Whole days only').min(1, 'At least 1 day').max(30, 'At most 30 days') });
export type UnsettledDaysInput = z.infer<typeof unsettledDaysSchema>;

// FR-L12: petty cash imprest.
export const pettyCashPaymentSchema = z.object({
  accountId: z.string().uuid(),
  amountPkr: z.number({ message: 'Enter the amount' }).positive('Amount must be above zero').max(1_000_000),
  headId: z.string().uuid('Choose an expense head'),
  narrative: z.string().trim().max(200).optional(),
});
export type PettyCashPaymentInput = z.infer<typeof pettyCashPaymentSchema>;

export const pettyCashReplenishSchema = z.object({
  accountId: z.string().uuid(),
  countedPkr: z.number({ message: 'Enter the cash counted in the tin' }).min(0, 'Cannot be negative').max(10_000_000),
  explanation: z.string().trim().max(500).optional(),
});
export type PettyCashReplenishInput = z.infer<typeof pettyCashReplenishSchema>;

export const pettyCashAccountSchema = z
  .object({
    campusId: z.string().uuid('Choose a campus'),
    floatPkr: z.number({ message: 'Enter the float' }).positive('Float must be above zero').max(10_000_000),
    capPkr: z.number({ message: 'Enter the per-payment cap' }).positive('Cap must be above zero').max(10_000_000),
    custodianId: z.string().uuid('Choose the custodian'),
  })
  .refine((v) => v.capPkr <= v.floatPkr, { path: ['capPkr'], message: 'The cap cannot exceed the float' });
export type PettyCashAccountInput = z.infer<typeof pettyCashAccountSchema>;

// FR-G17: attendance-linked concession eligibility.
export const schemeThresholdSchema = z.object({
  schemeId: z.string().uuid(),
  minPct: z.number({ message: 'Enter a percentage, or clear the threshold' }).gt(0, 'Above 0').max(100, 'At most 100').nullable(),
});
export type SchemeThresholdInput = z.infer<typeof schemeThresholdSchema>;

// FR-G03: period-wise attendance.
export const periodAttendanceSchema = z.object({
  slotId: z.string().uuid(),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a date'),
  marks: z.array(z.object({ enrolmentId: z.string().uuid(), status: z.enum(['present', 'absent', 'late', 'half_day', 'excused']) })).min(1, 'No students to mark').max(300),
});
export type PeriodAttendanceInput = z.infer<typeof periodAttendanceSchema>;

// FR-G07: leave application. Messages are portal message keys, rendered in the parent's language.
export const leaveApplicationSchema = z
  .object({
    enrolmentId: z.string().uuid('leave.errChooseChild'),
    fromDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'leave.errDates'),
    toDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'leave.errDates'),
    category: z.enum(['medical', 'family', 'travel', 'religious', 'other']),
    remarks: z.string().max(500, 'leave.errRemarks').optional(),
  })
  .refine((v) => v.toDate >= v.fromDate, { path: ['toDate'], message: 'leave.errEndBeforeStart' });
export type LeaveApplicationInput = z.infer<typeof leaveApplicationSchema>;

// FR-G16: closing an attendance shortage warning.
export const closeShortageSchema = z.object({
  warningId: z.string().uuid(),
  reason: z.string().trim().min(10, 'Give a reason of at least 10 characters').max(300),
});
export type CloseShortageInput = z.infer<typeof closeShortageSchema>;

// FR-H06: teacher review of homework submissions.
export const FEEDBACK_CODES = ['excellent', 'good', 'satisfactory', 'needs_improvement', 'incomplete'] as const;
export const checkSubmissionSchema = z.object({
  submissionId: z.string().uuid(),
  feedbackCode: z.enum(FEEDBACK_CODES, { message: 'Choose a feedback' }),
  remark: z.string().trim().max(500, 'Remark can be at most 500 characters').optional(),
  score: z.number().min(0, 'Score cannot be negative').max(999.99).nullable().optional(),
});
export type CheckSubmissionInput = z.infer<typeof checkSubmissionSchema>;
export const bulkCheckSchema = z.object({
  homeworkId: z.string().uuid(),
  submissionIds: z.array(z.string().uuid()).min(1, 'Nothing to check').max(300),
  feedbackCode: z.enum(FEEDBACK_CODES, { message: 'Choose a feedback' }),
  remark: z.string().trim().max(500).optional(),
});
export type BulkCheckInput = z.infer<typeof bulkCheckSchema>;

// FR-H07: non-submission follow-up.
export const notifyNonSubmittersSchema = z.object({
  homeworkId: z.string().uuid(),
  enrolmentIds: z.array(z.string().uuid()).min(1, 'Select at least one student').max(300),
  includeOnLeave: z.boolean().optional(),
});
export type NotifyNonSubmittersInput = z.infer<typeof notifyNonSubmittersSchema>;

// FR-H08: syllabus units and topics.
export const syllabusUnitSchema = z.object({
  title: z.string().trim().min(1, 'Enter a title').max(200),
  titleUr: z.string().trim().max(200).optional(),
  plannedPeriods: z.number({ message: 'Enter the planned periods' }).int('Whole periods only').min(0).max(500),
  targetMonth: z.string().regex(/^\d{4}-\d{2}$/, 'Choose a month').optional().or(z.literal('')),
});
export type SyllabusUnitInput = z.infer<typeof syllabusUnitSchema>;
export const syllabusTopicSchema = z.object({
  title: z.string().trim().min(1, 'Enter a title').max(200),
  titleUr: z.string().trim().max(200).optional(),
  plannedPeriods: z.number({ message: 'Enter the planned periods' }).int('Whole periods only').min(0).max(100),
});
export type SyllabusTopicInput = z.infer<typeof syllabusTopicSchema>;

// FR-H10: weekly lesson plan.
export const lessonPlanSchema = z.object({
  sectionId: z.string().uuid(),
  subjectId: z.string().uuid(),
  weekStart: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a week'),
  objectives: z.string().trim().max(1000, 'At most 1000 characters').optional(),
  resources: z.string().trim().max(1000, 'At most 1000 characters').optional(),
  topicIds: z.array(z.string().uuid()).default([]),
});
export type LessonPlanInput = z.input<typeof lessonPlanSchema>;

// FR-C06: houses.
export const houseSchema = z.object({
  name: z.string().trim().min(1, 'Enter a house name').max(60),
  colourHex: z.string().regex(/^#[0-9a-fA-F]{6}$/, 'Choose a colour'),
  motto: z.string().trim().max(120).optional(),
});
export type HouseInput = z.infer<typeof houseSchema>;
export const houseMoveSchema = z.object({
  grNumber: z.string().trim().min(1, 'Enter the GR number'),
  houseId: z.string().uuid('Choose a house'),
  effectiveDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the date the move takes effect'),
});
export type HouseMoveInput = z.infer<typeof houseMoveSchema>;
export const housePointsSchema = z.object({
  grNumber: z.string().trim().min(1, 'Enter the GR number'),
  points: z.number({ message: 'Enter the points' }).int('Whole points only').min(-100).max(1000).refine((n) => n !== 0, 'Points cannot be zero'),
  awardedOn: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a date'),
  category: z.enum(['sports', 'academic', 'discipline', 'other']),
  note: z.string().trim().max(200).optional(),
});
export type HousePointsInput = z.infer<typeof housePointsSchema>;
