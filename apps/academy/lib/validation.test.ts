import { describe, expect, it } from 'vitest';
import {
  provisionTenantSchema,
  slugSchema,
  createCampusSchema,
  createSessionSchema,
  termsSchema,
  createEnquirySchema,
  createStudentSchema,
  issueOfferSchema,
  respondToOfferSchema,
  createFeeHeadSchema,
  addStructureLineSchema,
  proposeFeePlanOverrideSchema,
  createConcessionSchemeSchema,
  requestConcessionAwardSchema,
  decideConcessionAwardSchema,
  postLedgerEntrySchema,
  reverseLedgerEntrySchema,
  generateChallansSchema,
  createLateFeeRuleSchema,
  previewLateFeeSchema,
} from './validation';

describe('slugSchema', () => {
  it('accepts a valid lowercase slug', () => {
    expect(slugSchema.safeParse('beaconhouse-gulberg').success).toBe(true);
  });

  it('rejects uppercase (must match tenant_slug_format DB constraint)', () => {
    expect(slugSchema.safeParse('Beaconhouse').success).toBe(false);
  });

  it('rejects spaces', () => {
    expect(slugSchema.safeParse('not a valid slug!').success).toBe(false);
  });

  it('rejects a leading hyphen', () => {
    expect(slugSchema.safeParse('-beaconhouse').success).toBe(false);
  });

  it('rejects fewer than 3 characters', () => {
    expect(slugSchema.safeParse('ab').success).toBe(false);
  });

  it('rejects more than 50 characters', () => {
    expect(slugSchema.safeParse('a'.repeat(51)).success).toBe(false);
  });
});

describe('provisionTenantSchema', () => {
  const valid = { slug: 'city-school-dha', legalName: 'City School DHA', ownerEmail: 'owner@city.test' };

  it('accepts a fully valid payload', () => {
    expect(provisionTenantSchema.safeParse(valid).success).toBe(true);
  });

  it('rejects a missing legal name', () => {
    expect(provisionTenantSchema.safeParse({ ...valid, legalName: '' }).success).toBe(false);
  });

  it('rejects a malformed email', () => {
    expect(provisionTenantSchema.safeParse({ ...valid, ownerEmail: 'not-an-email' }).success).toBe(false);
  });
});

describe('createCampusSchema', () => {
  it('accepts a short alphanumeric code', () => {
    expect(createCampusSchema.safeParse({ code: 'GUL', name: 'Gulberg Campus' }).success).toBe(true);
  });

  it('rejects a code with punctuation', () => {
    expect(createCampusSchema.safeParse({ code: 'GUL-1', name: 'Gulberg Campus' }).success).toBe(false);
  });

  it('rejects an empty name', () => {
    expect(createCampusSchema.safeParse({ code: 'GUL', name: '' }).success).toBe(false);
  });
});

describe('createSessionSchema', () => {
  it('accepts a valid range', () => {
    expect(createSessionSchema.safeParse({ name: '2027-28', startsOn: '2027-01-01', endsOn: '2027-12-31' }).success).toBe(true);
  });

  it('rejects an end date on or before the start date', () => {
    expect(createSessionSchema.safeParse({ name: '2027-28', startsOn: '2027-06-01', endsOn: '2027-01-01' }).success).toBe(false);
  });
});

describe('termsSchema', () => {
  const term = (name: string, weightage: number) => ({ name, startsOn: '2027-01-01', endsOn: '2027-04-30', weightage });

  it('accepts terms summing to exactly 100', () => {
    expect(termsSchema.safeParse({ terms: [term('First', 30), term('Mid', 30), term('Final', 40)] }).success).toBe(true);
  });

  it('rejects terms summing to 95 (matches the DB TERM_WEIGHTAGE_SUM check)', () => {
    expect(termsSchema.safeParse({ terms: [term('First', 30), term('Mid', 30), term('Final', 35)] }).success).toBe(false);
  });

  it('rejects zero terms', () => {
    expect(termsSchema.safeParse({ terms: [] }).success).toBe(false);
  });

  it('rejects more than 4 terms even if they sum to 100', () => {
    expect(
      termsSchema.safeParse({ terms: [term('A', 20), term('B', 20), term('C', 20), term('D', 20), term('E', 20)] }).success,
    ).toBe(false);
  });
});

describe('createEnquirySchema', () => {
  const base = {
    campusId: '11111111-1111-1111-1111-111111111111',
    sessionId: '22222222-2222-2222-2222-222222222222',
    childName: 'Ali Khan',
    dob: '2020-01-01',
    classAppliedId: '33333333-3333-3333-3333-333333333333',
    parentName: 'Ahmed Khan',
    phone: '03001234567',
    whatsappOptIn: false,
    source: 'walk_in' as const,
  };

  it('accepts a valid walk-in enquiry', () => {
    expect(createEnquirySchema.safeParse(base).success).toBe(true);
  });

  it('rejects a referral enquiry with no referrer name (matches the DB check)', () => {
    expect(createEnquirySchema.safeParse({ ...base, source: 'referral' }).success).toBe(false);
  });

  it('accepts a referral enquiry once a referrer name is given', () => {
    expect(createEnquirySchema.safeParse({ ...base, source: 'referral', referrerName: 'A. Student' }).success).toBe(true);
  });

  it('rejects a non-UUID campusId', () => {
    expect(createEnquirySchema.safeParse({ ...base, campusId: 'not-a-uuid' }).success).toBe(false);
  });
});

describe('createStudentSchema', () => {
  const base = {
    campusId: '11111111-1111-1111-1111-111111111111',
    nameEn: 'Ali Khan',
    dob: '2015-01-01',
    gender: 'male' as const,
  };

  it('accepts the minimal required fields', () => {
    expect(createStudentSchema.safeParse(base).success).toBe(true);
  });

  it('rejects a missing name', () => {
    expect(createStudentSchema.safeParse({ ...base, nameEn: '' }).success).toBe(false);
  });

  it('rejects an invalid gender value', () => {
    expect(createStudentSchema.safeParse({ ...base, gender: 'unknown' }).success).toBe(false);
  });
});

describe('issueOfferSchema', () => {
  const base = { applicationId: '11111111-1111-1111-1111-111111111111', feeAmount: 5000 };

  it('accepts a valid fee amount', () => {
    expect(issueOfferSchema.safeParse(base).success).toBe(true);
  });

  it('rejects a zero fee amount', () => {
    expect(issueOfferSchema.safeParse({ ...base, feeAmount: 0 }).success).toBe(false);
  });

  it('rejects a negative fee amount', () => {
    expect(issueOfferSchema.safeParse({ ...base, feeAmount: -100 }).success).toBe(false);
  });
});

describe('respondToOfferSchema', () => {
  const base = { offerId: '11111111-1111-1111-1111-111111111111', response: 'accepted' as const };

  it('accepts an acceptance with no reason', () => {
    expect(respondToOfferSchema.safeParse(base).success).toBe(true);
  });

  it('rejects a decline with no reason (matches DECLINE_REASON_REQUIRED)', () => {
    expect(respondToOfferSchema.safeParse({ ...base, response: 'declined' }).success).toBe(false);
  });

  it('accepts a decline once a reason is given', () => {
    expect(respondToOfferSchema.safeParse({ ...base, response: 'declined', declineReason: 'fee_too_high' }).success).toBe(true);
  });
});

describe('createFeeHeadSchema', () => {
  const base = { code: 'TUITION', nameEn: 'Tuition Fee', nameUr: 'فیس تعلیم', isRefundable: false, defaultFrequency: 'monthly' as const };

  it('accepts a valid fee head', () => {
    expect(createFeeHeadSchema.safeParse(base).success).toBe(true);
  });

  it('rejects a code with spaces or punctuation', () => {
    expect(createFeeHeadSchema.safeParse({ ...base, code: 'TUITION FEE!' }).success).toBe(false);
  });

  it('rejects a missing Urdu name (mandatory from day one, per FR-K01)', () => {
    expect(createFeeHeadSchema.safeParse({ ...base, nameUr: '' }).success).toBe(false);
  });

  it('rejects an invalid frequency', () => {
    expect(createFeeHeadSchema.safeParse({ ...base, defaultFrequency: 'weekly' }).success).toBe(false);
  });
});

describe('addStructureLineSchema', () => {
  const base = {
    structureId: '11111111-1111-1111-1111-111111111111',
    classId: '22222222-2222-2222-2222-222222222222',
    feeHeadId: '33333333-3333-3333-3333-333333333333',
    amountRupees: 5000,
    frequency: 'monthly' as const,
    months: [0, 1, 2],
  };

  it('accepts a valid line', () => {
    expect(addStructureLineSchema.safeParse(base).success).toBe(true);
  });

  it('accepts a zero amount (a waived/free head)', () => {
    expect(addStructureLineSchema.safeParse({ ...base, amountRupees: 0 }).success).toBe(true);
  });

  it('rejects a negative amount — money as bigint paisa is never negative on a structure line', () => {
    expect(addStructureLineSchema.safeParse({ ...base, amountRupees: -100 }).success).toBe(false);
  });

  it('rejects no months selected', () => {
    expect(addStructureLineSchema.safeParse({ ...base, months: [] }).success).toBe(false);
  });
});

describe('proposeFeePlanOverrideSchema', () => {
  const base = { lineId: '11111111-1111-1111-1111-111111111111', amountRupees: 4000, reason: 'board approved staff rate' };

  it('accepts a valid override proposal', () => {
    expect(proposeFeePlanOverrideSchema.safeParse(base).success).toBe(true);
  });

  it('rejects a missing reason — matches REASON_REQUIRED', () => {
    expect(proposeFeePlanOverrideSchema.safeParse({ ...base, reason: '' }).success).toBe(false);
  });
});

describe('createConcessionSchemeSchema', () => {
  const base = {
    code: 'SIBLING2',
    nameEn: 'Sibling 2nd Child',
    nameUr: 'دوسرا بہن بھائی',
    calcType: 'percentage' as const,
    value: 10,
    applicableHeadIds: ['11111111-1111-1111-1111-111111111111'],
    requiresDocument: false,
  };

  it('accepts a valid percentage scheme', () => {
    expect(createConcessionSchemeSchema.safeParse(base).success).toBe(true);
  });

  it('rejects a percentage over 100', () => {
    expect(createConcessionSchemeSchema.safeParse({ ...base, value: 150 }).success).toBe(false);
  });

  it('accepts a fixed_amount value over 100 — it is paisa, not a percentage', () => {
    expect(createConcessionSchemeSchema.safeParse({ ...base, calcType: 'fixed_amount', value: 150000 }).success).toBe(true);
  });

  it('rejects zero applicable heads', () => {
    expect(createConcessionSchemeSchema.safeParse({ ...base, applicableHeadIds: [] }).success).toBe(false);
  });
});

describe('requestConcessionAwardSchema', () => {
  const base = {
    schemeId: '11111111-1111-1111-1111-111111111111',
    value: 10,
    effectiveFrom: '2026-09-01',
    effectiveTo: '2027-03-31',
  };

  it('accepts a valid request', () => {
    expect(requestConcessionAwardSchema.safeParse(base).success).toBe(true);
  });

  it('rejects effectiveTo not after effectiveFrom', () => {
    expect(requestConcessionAwardSchema.safeParse({ ...base, effectiveTo: '2026-09-01' }).success).toBe(false);
  });
});

describe('decideConcessionAwardSchema', () => {
  const base = { awardId: '11111111-1111-1111-1111-111111111111', approve: true };

  it('accepts an approval with no reason', () => {
    expect(decideConcessionAwardSchema.safeParse(base).success).toBe(true);
  });

  it('rejects a rejection with a reason under 10 characters', () => {
    expect(decideConcessionAwardSchema.safeParse({ ...base, approve: false, rejectionReason: 'too short' }).success).toBe(false);
  });

  it('accepts a rejection with a reason of 10+ characters', () => {
    expect(
      decideConcessionAwardSchema.safeParse({ ...base, approve: false, rejectionReason: 'insufficient supporting evidence' }).success
    ).toBe(true);
  });
});

describe('postLedgerEntrySchema', () => {
  const base = { entryType: 'charge' as const, amountRupees: 5000, direction: 'debit' as const };

  it('accepts a valid entry', () => {
    expect(postLedgerEntrySchema.safeParse(base).success).toBe(true);
  });

  it('rejects a zero amount — amount_paisa must be positive, direction carries the sign', () => {
    expect(postLedgerEntrySchema.safeParse({ ...base, amountRupees: 0 }).success).toBe(false);
  });
});

describe('reverseLedgerEntrySchema', () => {
  const base = { ledgerId: '11111111-1111-1111-1111-111111111111', reason: 'cheque returned unpaid by MCB 12-08' };

  it('accepts a reason of 15+ characters', () => {
    expect(reverseLedgerEntrySchema.safeParse(base).success).toBe(true);
  });

  it('rejects a reason under 15 characters', () => {
    expect(reverseLedgerEntrySchema.safeParse({ ...base, reason: 'too short' }).success).toBe(false);
  });
});

describe('generateChallansSchema', () => {
  const base = {
    campusId: '11111111-1111-1111-1111-111111111111',
    sessionId: '22222222-2222-2222-2222-222222222222',
    period: '2026-08',
    dryRun: false,
  };

  it('accepts a valid YYYY-MM period', () => {
    expect(generateChallansSchema.safeParse(base).success).toBe(true);
  });

  it('rejects a period with a day component', () => {
    expect(generateChallansSchema.safeParse({ ...base, period: '2026-08-01' }).success).toBe(false);
  });

  it('rejects a malformed period', () => {
    expect(generateChallansSchema.safeParse({ ...base, period: 'August 2026' }).success).toBe(false);
  });
});

describe('createLateFeeRuleSchema', () => {
  const base = {
    campusId: '11111111-1111-1111-1111-111111111111',
    sessionId: '22222222-2222-2222-2222-222222222222',
    graceDays: 3,
  };

  it('accepts a per_day rule with an amount', () => {
    expect(createLateFeeRuleSchema.safeParse({ ...base, basis: 'per_day', amountRupees: 50 }).success).toBe(true);
  });

  it('rejects a per_day rule with no amount', () => {
    expect(createLateFeeRuleSchema.safeParse({ ...base, basis: 'per_day' }).success).toBe(false);
  });

  it('accepts a percentage rule with a percentage', () => {
    expect(createLateFeeRuleSchema.safeParse({ ...base, basis: 'percentage', percentage: 2 }).success).toBe(true);
  });

  it('rejects a percentage rule with no percentage', () => {
    expect(createLateFeeRuleSchema.safeParse({ ...base, basis: 'percentage' }).success).toBe(false);
  });

  it('rejects a percentage over 100', () => {
    expect(createLateFeeRuleSchema.safeParse({ ...base, basis: 'percentage', percentage: 140 }).success).toBe(false);
  });
});

describe('previewLateFeeSchema', () => {
  it('accepts a valid challan id and date', () => {
    expect(
      previewLateFeeSchema.safeParse({ challanId: '11111111-1111-1111-1111-111111111111', asOf: '2026-08-20' }).success
    ).toBe(true);
  });

  it('rejects a missing challan id', () => {
    expect(previewLateFeeSchema.safeParse({ challanId: '', asOf: '2026-08-20' }).success).toBe(false);
  });
});
