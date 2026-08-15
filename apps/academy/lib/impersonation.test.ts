import { describe, expect, it } from 'vitest';
import {
  consentError,
  endReasonLabel,
  formatCountdown,
  isImpersonatable,
  isImpersonationSessionEnded,
  isImpersonationWriteBlocked,
  parseImpersonationClaim,
  startImpersonationError,
} from './impersonation';

const CLAIM = {
  sid: '11111111-1111-1111-1111-111111111111',
  sub: '22222222-2222-2222-2222-222222222222',
  by: '33333333-3333-3333-3333-333333333333',
  exp: '2026-08-14T09:00:00+00:00',
};

describe('parseImpersonationClaim', () => {
  it('reads the imp object the access token hook adds', () => {
    expect(parseImpersonationClaim({ sub: CLAIM.by, imp: CLAIM })).toEqual(CLAIM);
  });

  it('is null for an ordinary token — which is the banner’s off switch', () => {
    expect(parseImpersonationClaim({ sub: CLAIM.by, app_role: 'teacher' })).toBeNull();
    expect(parseImpersonationClaim(null)).toBeNull();
    expect(parseImpersonationClaim(undefined)).toBeNull();
  });

  it('refuses a half-formed claim rather than rendering a banner with holes in it', () => {
    expect(parseImpersonationClaim({ imp: { sid: CLAIM.sid } })).toBeNull();
    expect(parseImpersonationClaim({ imp: { ...CLAIM, exp: '' } })).toBeNull();
    expect(parseImpersonationClaim({ imp: 'yes' })).toBeNull();
    expect(parseImpersonationClaim({ imp: [CLAIM] })).toBeNull();
  });
});

describe('isImpersonatable', () => {
  it('mirrors chk_impersonation_role_ceiling', () => {
    expect(isImpersonatable('super_admin')).toBe(false);
    expect(isImpersonatable('owner')).toBe(false);
    expect(isImpersonatable('parent')).toBe(false);
    expect(isImpersonatable('student')).toBe(false);
  });

  it('allows the staff roles support is actually asked to diagnose', () => {
    expect(isImpersonatable('principal')).toBe(true);
    expect(isImpersonatable('accountant')).toBe(true);
    expect(isImpersonatable('class_teacher')).toBe(true);
  });
});

describe('error classification', () => {
  it('recognises the write block and the closed window separately', () => {
    expect(isImpersonationWriteBlocked('IMPERSONATION_WRITE_BLOCKED')).toBe(true);
    expect(isImpersonationWriteBlocked('IMPERSONATION_SESSION_ENDED')).toBe(false);
    expect(isImpersonationSessionEnded('IMPERSONATION_SESSION_ENDED')).toBe(true);
    expect(isImpersonationSessionEnded('FORBIDDEN')).toBe(false);
  });

  it('tells the three "no consent" conversations apart, because they are three conversations', () => {
    expect(startImpersonationError('IMPERSONATION_NOT_CONSENTED')).toContain('has not granted');
    expect(startImpersonationError('CONSENT_REVOKED')).toContain('withdrew');
    expect(startImpersonationError('CONSENT_EXPIRED')).toContain('expired');
  });

  it('falls back rather than leaking a Postgres message into the UI', () => {
    expect(startImpersonationError('null value in column "x"')).toBe('Could not start the session.');
    expect(consentError('deadlock detected')).toBe('Could not change support access.');
  });

  it('maps the owner-only refusals', () => {
    expect(consentError('FORBIDDEN')).toContain('Owner');
    expect(startImpersonationError('FORBIDDEN')).toContain('platform support');
  });
});

describe('formatCountdown', () => {
  it('renders mm:ss', () => {
    expect(formatCountdown(60_000)).toBe('01:00');
    expect(formatCountdown(59 * 60_000 + 5_000)).toBe('59:05');
  });

  it('floors at zero — a negative countdown reads as a bug, not as urgency', () => {
    expect(formatCountdown(0)).toBe('00:00');
    expect(formatCountdown(-90_000)).toBe('00:00');
  });
});

describe('endReasonLabel', () => {
  it('reads a live session as live', () => {
    expect(endReasonLabel(null)).toBe('Live');
  });

  it('names every end_reason the CHECK allows', () => {
    expect(endReasonLabel('ended_by_support')).toBe('Ended by support');
    expect(endReasonLabel('ended_by_owner')).toBe('Ended by the school');
    expect(endReasonLabel('expired')).toBe('Window expired');
    expect(endReasonLabel('consent_revoked')).toBe('Consent withdrawn');
    expect(endReasonLabel('consent_expired')).toBe('Consent expired');
  });
});
