import { describe, expect, it } from 'vitest';
import { coverageSchema } from './validation';

const base = { sectionId: crypto.randomUUID(), subjectId: crypto.randomUUID(), unitId: crypto.randomUUID() };

describe('coverageSchema (FR-H11)', () => {
  it('accepts a completed unit with no start date', () => {
    expect(coverageSchema.safeParse({ ...base, status: 'completed', completedOn: '2026-10-12' }).success).toBe(true);
  });
  it('rejects a completion date before the start date with the spec message', () => {
    const r = coverageSchema.safeParse({ ...base, status: 'completed', startedOn: '2026-10-10', completedOn: '2026-10-05' });
    expect(r.success).toBe(false);
    if (!r.success) expect(r.error.issues[0]?.message).toBe('Completion date cannot precede start date');
  });
  it('accepts the same day for start and completion', () => {
    expect(coverageSchema.safeParse({ ...base, status: 'completed', startedOn: '2026-10-05', completedOn: '2026-10-05' }).success).toBe(true);
  });
  it('rejects negative or fractional periods used', () => {
    expect(coverageSchema.safeParse({ ...base, status: 'in_progress', periodsUsed: -1 }).success).toBe(false);
    expect(coverageSchema.safeParse({ ...base, status: 'in_progress', periodsUsed: 1.5 }).success).toBe(false);
  });
  it('rejects an unknown status', () => {
    expect(coverageSchema.safeParse({ ...base, status: 'done' }).success).toBe(false);
  });
});
