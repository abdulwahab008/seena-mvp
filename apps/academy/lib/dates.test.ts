import { describe, expect, it } from 'vitest';
import { formatDatePk, formatDateTimePk, toPkDate } from './dates';

describe('toPkDate', () => {
  it('is already tomorrow in Karachi at 22:30 UTC', () => {
    expect(toPkDate(new Date('2026-11-05T22:30:00Z'))).toBe('2026-11-06');
  });
  it('is the same day after 19:00 UTC rolls back', () => {
    expect(toPkDate(new Date('2026-11-05T18:59:00Z'))).toBe('2026-11-05');
  });
});

describe('formatDatePk', () => {
  it('prints day, short month and year in Karachi time', () => {
    expect(formatDatePk('2026-11-05T22:30:00Z')).toBe('06 Nov 2026');
    expect(formatDateTimePk('2026-11-05T22:30:00Z')).toBe('06 Nov 2026, 03:30');
  });
});
