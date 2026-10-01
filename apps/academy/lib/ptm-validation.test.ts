import { describe, expect, it } from 'vitest';
import { karachiLocalToIso, ptmEventSchema, ptmSlotsSchema } from './validation';

describe('PTM validation (FR-N11)', () => {
  it('converts a Karachi wall-clock time to the right instant (UTC+5, no DST)', () => {
    expect(karachiLocalToIso('2026-11-07T09:00')).toBe('2026-11-07T04:00:00.000Z');
    expect(karachiLocalToIso('')).toBeUndefined();
    expect(karachiLocalToIso(undefined)).toBeUndefined();
  });

  it('accepts a 10-minute event with a 24-hour cutoff', () => {
    expect(ptmEventSchema.safeParse({ title: 'Term 1 PTM', eventDate: '2026-11-07', startTime: '10:00', cutoffHours: 24, slotMinutes: 10 }).success).toBe(true);
  });

  it('rejects slots shorter than 5 or longer than 60 minutes and a negative cutoff', () => {
    expect(ptmEventSchema.safeParse({ title: 'x', eventDate: '2026-11-07', startTime: '10:00', cutoffHours: 24, slotMinutes: 3 }).success).toBe(false);
    expect(ptmEventSchema.safeParse({ title: 'x', eventDate: '2026-11-07', startTime: '10:00', cutoffHours: 24, slotMinutes: 90 }).success).toBe(false);
    expect(ptmEventSchema.safeParse({ title: 'x', eventDate: '2026-11-07', startTime: '10:00', cutoffHours: -1, slotMinutes: 10 }).success).toBe(false);
  });

  it('requires the slot window to end after it starts and at least one teacher', () => {
    const base = { eventId: crypto.randomUUID(), teacherIds: [crypto.randomUUID()], startTime: '10:00', endTime: '12:00' };
    expect(ptmSlotsSchema.safeParse(base).success).toBe(true);
    expect(ptmSlotsSchema.safeParse({ ...base, endTime: '09:00' }).success).toBe(false);
    expect(ptmSlotsSchema.safeParse({ ...base, teacherIds: [] }).success).toBe(false);
  });
});
