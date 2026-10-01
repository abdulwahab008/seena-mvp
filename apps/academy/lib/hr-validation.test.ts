import { describe, expect, it } from 'vitest';
import { complianceDocumentSchema, issueDisciplinarySchema, staffAttendanceRuleSchema } from './validation';

const uuid = '3f0c1c0e-5a4e-4d0b-9d6b-0e6f1e6a2b11';

describe('FR-D06 compliance document input', () => {
  it('needs a staff member, a snake_case document type and an ISO expiry date', () => {
    expect(complianceDocumentSchema.safeParse({ staffUserId: uuid, documentType: 'police_verification', expiresOn: '2026-09-30' }).success).toBe(true);
    expect(complianceDocumentSchema.safeParse({ staffUserId: 'x', documentType: 'police_verification', expiresOn: '2026-09-30' }).success).toBe(false);
    expect(complianceDocumentSchema.safeParse({ staffUserId: uuid, documentType: 'Police Verification', expiresOn: '2026-09-30' }).success).toBe(false);
    expect(complianceDocumentSchema.safeParse({ staffUserId: uuid, documentType: 'degree', expiresOn: '30/09/2026' }).success).toBe(false);
  });
});

describe('FR-D08 attendance rule input', () => {
  it('accepts HH:MM and a bounded grace period', () => {
    expect(staffAttendanceRuleSchema.safeParse({ campusId: uuid, startTime: '08:00', graceMinutes: '10' }).success).toBe(true);
    expect(staffAttendanceRuleSchema.safeParse({ campusId: uuid, startTime: '8am', graceMinutes: 10 }).success).toBe(false);
    expect(staffAttendanceRuleSchema.safeParse({ campusId: uuid, startTime: '08:00', graceMinutes: 600 }).success).toBe(false);
  });
});

describe('FR-D15 issue disciplinary action input', () => {
  const base = { staffId: uuid, description: 'Absent without notice' };

  it('a warning needs only a description', () => {
    expect(issueDisciplinarySchema.safeParse({ ...base, actionType: 'warning' }).success).toBe(true);
    expect(issueDisciplinarySchema.safeParse({ ...base, actionType: 'warning', description: '   ' }).success).toBe(false);
  });

  it('a show-cause notice needs a response deadline in days', () => {
    expect(issueDisciplinarySchema.safeParse({ ...base, actionType: 'show_cause' }).success).toBe(false);
    expect(issueDisciplinarySchema.safeParse({ ...base, actionType: 'show_cause', responseDays: '7' }).success).toBe(true);
    expect(issueDisciplinarySchema.safeParse({ ...base, actionType: 'show_cause', responseDays: 90 }).success).toBe(false);
  });

  it('a suspension needs an ordered date range', () => {
    expect(issueDisciplinarySchema.safeParse({ ...base, actionType: 'suspension' }).success).toBe(false);
    expect(issueDisciplinarySchema.safeParse({ ...base, actionType: 'suspension', suspendFrom: '2026-08-15', suspendTo: '2026-08-01' }).success).toBe(false);
    expect(issueDisciplinarySchema.safeParse({ ...base, actionType: 'suspension', suspendFrom: '2026-08-01', suspendTo: '2026-08-15' }).success).toBe(true);
  });

  it('refuses an unknown action type', () => {
    expect(issueDisciplinarySchema.safeParse({ ...base, actionType: 'demotion' }).success).toBe(false);
  });
});
