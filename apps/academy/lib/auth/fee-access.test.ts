import { describe, expect, it } from 'vitest';
import {
  canCollectFees,
  canOpenFeesPath,
  canSeeConcessionAwards,
  hasFeeAccess,
  FEE_STAFF_ROLES,
} from './fee-access';

// Every value of the app_role enum. If a role is added to the enum, add it here: the point of
// the test is that a new role has no fee access until it is given some on purpose.
const OTHER_ROLES = [
  'vice_principal',
  'admissions_officer',
  'exam_controller',
  'head_of_department',
  'class_teacher',
  'subject_teacher',
  'hr_manager',
  'librarian',
  'transport_manager',
  'receptionist',
  'nurse',
  'parent',
  'student',
  'none',
];

describe('hasFeeAccess', () => {
  it.each(FEE_STAFF_ROLES)('lets %s into the fees area', (role) => {
    expect(hasFeeAccess(role)).toBe(true);
  });

  it.each(OTHER_ROLES)('keeps %s out of the fees area', (role) => {
    expect(hasFeeAccess(role)).toBe(false);
  });

  it('keeps out a missing or unknown role', () => {
    for (const role of [undefined, null, '', 'wizard', 42]) expect(hasFeeAccess(role)).toBe(false);
  });
});

describe('canOpenFeesPath', () => {
  it('lets the fee staff open any fees page', () => {
    for (const role of FEE_STAFF_ROLES) {
      expect(canOpenFeesPath(role, '/fees/challans')).toBe(true);
      expect(canOpenFeesPath(role, '/fees/bank-statements/abc')).toBe(true);
    }
  });

  it('lets an admissions officer open only the two pages their admissions work uses', () => {
    expect(canOpenFeesPath('admissions_officer', '/fees/concessions')).toBe(true);
    expect(canOpenFeesPath('admissions_officer', '/fees/sibling-discounts')).toBe(true);
    expect(canOpenFeesPath('admissions_officer', '/fees/concessions?tab=pending')).toBe(true);
    expect(canOpenFeesPath('admissions_officer', '/fees/challans')).toBe(false);
    expect(canOpenFeesPath('admissions_officer', '/fees/counter')).toBe(false);
    expect(canOpenFeesPath('admissions_officer', '/fees/concessions-report')).toBe(false);
  });

  it.each(OTHER_ROLES.filter((r) => r !== 'admissions_officer'))('sends %s home from every fees page', (role) => {
    for (const path of ['/fees/challans', '/fees/concessions', '/fees/counter', '/fees/reports']) {
      expect(canOpenFeesPath(role, path)).toBe(false);
    }
  });

  it('refuses a missing role', () => {
    expect(canOpenFeesPath(undefined, '/fees/challans')).toBe(false);
  });
});

describe('canCollectFees', () => {
  it('is the roles that can post a payment', () => {
    expect(canCollectFees('super_admin')).toBe(true);
    expect(canCollectFees('owner')).toBe(true);
    expect(canCollectFees('accountant')).toBe(true);
    expect(canCollectFees('principal')).toBe(false);
    expect(canCollectFees('subject_teacher')).toBe(false);
  });
});

describe('canSeeConcessionAwards', () => {
  it('is the fee staff and the admissions officer', () => {
    for (const role of [...FEE_STAFF_ROLES, 'admissions_officer']) expect(canSeeConcessionAwards(role)).toBe(true);
    for (const role of ['class_teacher', 'librarian', 'vice_principal', 'parent']) expect(canSeeConcessionAwards(role)).toBe(false);
  });
});
