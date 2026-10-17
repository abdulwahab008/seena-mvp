import { describe, expect, it } from 'vitest';
import { isNoSchoolRedirect, portalRedirectFor } from './portal-access';

// Every value of the app_role enum except the two portal audiences. If a role is
// added to the enum, add it here: the point of the test is that no staff role can
// ever render the parent portal.
const STAFF_ROLES = [
  'super_admin',
  'owner',
  'principal',
  'vice_principal',
  'admissions_officer',
  'accountant',
  'exam_controller',
  'head_of_department',
  'class_teacher',
  'subject_teacher',
  'hr_manager',
  'librarian',
  'transport_manager',
  'receptionist',
  'nurse',
];

describe('portalRedirectFor', () => {
  it('lets a guardian stay in the parent portal', () => {
    expect(portalRedirectFor('parent')).toBeNull();
  });

  it('sends a student to the student portal rather than the parent one', () => {
    expect(portalRedirectFor('student')).toBe('/student/timetable');
  });

  it.each(STAFF_ROLES)('sends %s back to the staff dashboard', (role) => {
    expect(portalRedirectFor(role)).toBe('/dashboard');
  });

  it('treats a missing, empty or "none" role as no school', () => {
    for (const role of [undefined, null, '', 'none']) {
      expect(portalRedirectFor(role)).toBe('/no-school');
    }
  });

  it('never lets an unrecognised role into the portal', () => {
    for (const role of ['PARENT', 'Parent', 'guardian', 'admin', 42, {}, ['parent']]) {
      expect(portalRedirectFor(role)).not.toBeNull();
    }
  });
});

describe('isNoSchoolRedirect', () => {
  it('only matches the no-school destination', () => {
    expect(isNoSchoolRedirect('/no-school')).toBe(true);
    expect(isNoSchoolRedirect('/dashboard')).toBe(false);
    expect(isNoSchoolRedirect('/student/timetable')).toBe(false);
  });
});
