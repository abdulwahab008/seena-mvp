import { describe, expect, it } from 'vitest';
import { ALL_CAMPUSES_VALUE, buildCampusFilterOptions, hasNoCampusAssigned, isTenantWideRole } from './campus-scope';

describe('isTenantWideRole', () => {
  it('is true for owner and super_admin', () => {
    expect(isTenantWideRole('owner')).toBe(true);
    expect(isTenantWideRole('super_admin')).toBe(true);
  });

  it('is false for every campus-scoped role', () => {
    expect(isTenantWideRole('principal')).toBe(false);
    expect(isTenantWideRole('accountant')).toBe(false);
    expect(isTenantWideRole('class_teacher')).toBe(false);
  });
});

describe('hasNoCampusAssigned', () => {
  it('AC4: a campus-scoped role with zero active campuses has no campus assigned', () => {
    expect(hasNoCampusAssigned('principal', 0)).toBe(true);
  });

  it('a campus-scoped role with at least one active campus is fine', () => {
    expect(hasNoCampusAssigned('principal', 1)).toBe(false);
    expect(hasNoCampusAssigned('accountant', 4)).toBe(false);
  });

  it('owner/super_admin are never "no campus assigned", even with zero user_campus rows', () => {
    expect(hasNoCampusAssigned('owner', 0)).toBe(false);
    expect(hasNoCampusAssigned('super_admin', 0)).toBe(false);
  });
});

describe('buildCampusFilterOptions', () => {
  const gulberg = { id: 'c1', code: 'GUL', name: 'Gulberg' };
  const campuses = [gulberg, { id: 'c2', code: 'DHA', name: 'DHA' }, { id: 'c3', code: 'JOH', name: 'Johar Town' }, { id: 'c4', code: 'MDN', name: 'Model Town' }];

  it('AC2: an accountant scoped to 4 campuses gets 4 options plus "All campuses"', () => {
    const options = buildCampusFilterOptions(campuses);
    expect(options).toHaveLength(5);
    expect(options.filter((o) => o.value !== ALL_CAMPUSES_VALUE)).toHaveLength(4);
    expect(options.at(-1)).toEqual({ value: ALL_CAMPUSES_VALUE, label: 'All campuses' });
  });

  it('AC1: a principal scoped to a single campus gets that one option plus "All campuses"', () => {
    const options = buildCampusFilterOptions([gulberg]);
    expect(options).toEqual([
      { value: 'c1', label: 'Gulberg (GUL)' },
      { value: ALL_CAMPUSES_VALUE, label: 'All campuses' },
    ]);
  });

  it('offers no options at all when the caller has no accessible campuses', () => {
    expect(buildCampusFilterOptions([])).toEqual([]);
  });
});
