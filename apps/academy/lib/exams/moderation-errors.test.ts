import { describe, expect, it } from 'vitest';
import { moderationError } from './moderation-errors';

describe('moderationError', () => {
  it('names the cap when the adjustment is too large (AC2)', () => {
    expect(moderationError('MODERATION_CAP_EXCEEDED: 5', 'The maximum moderation is 5 marks.')).toBe('The adjustment is above the cap. The maximum moderation is 5 marks.');
  });

  it('still names the cap when the detail is missing', () => {
    expect(moderationError('MODERATION_CAP_EXCEEDED: 5%')).toBe('The adjustment is above the cap. The maximum is 5%.');
  });

  it('points at break-glass for approved marks (AC4)', () => {
    const text = moderationError('MARKS_APPROVED', 'These marks are approved. Moderation after approval needs a break-glass unlock.');
    expect(text).toContain('already approved');
    expect(text).toContain('break-glass');
  });

  it('tells the controller to reverse before moderating again (AC3)', () => {
    expect(moderationError('MODERATION_EXISTS')).toMatch(/Reverse that moderation/);
  });

  it('passes the reason requirement through', () => {
    expect(moderationError('REASON_TOO_SHORT', 'Record why the paper was unfair: at least 20 characters.')).toContain('at least 20 characters');
  });

  it('is generic, and never leaks internals, for anything unknown', () => {
    expect(moderationError('relation "mark_entry" exploded')).toBe('Could not complete that action.');
  });
});
