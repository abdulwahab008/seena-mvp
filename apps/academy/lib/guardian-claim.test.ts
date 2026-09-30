import { describe, expect, it } from 'vitest';
import { claimDeviceKey, claimResultSchema, newClaimDeviceId } from './guardian-claim';
import { guardianClaimSchema } from './validation';

describe('guardianClaimSchema', () => {
  it('normalises the school code and accepts a 6-digit CNIC tail', () => {
    const r = guardianClaimSchema.parse({ schoolCode: '  Seena-Model ', grNumber: 'GR-0042', cnicLast6: '345671' });
    expect(r.schoolCode).toBe('seena-model');
  });

  it.each(['12345', '1234567', 'abcdef', '12 456', ''])('rejects CNIC tail %j', (cnicLast6) => {
    expect(guardianClaimSchema.safeParse({ schoolCode: 'abc', grNumber: '1', cnicLast6 }).success).toBe(false);
  });

  it('requires a GR number containing a digit', () => {
    expect(guardianClaimSchema.safeParse({ schoolCode: 'abc', grNumber: 'none', cnicLast6: '123456' }).success).toBe(false);
  });
});

describe('claimDeviceKey', () => {
  it('is stable for the same device and network, different otherwise', () => {
    const d = newClaimDeviceId();
    expect(claimDeviceKey(d, '1.2.3.4')).toBe(claimDeviceKey(d, '1.2.3.4'));
    expect(claimDeviceKey(d, '1.2.3.4')).not.toBe(claimDeviceKey(d, '5.6.7.8'));
    expect(claimDeviceKey(d, null)).not.toBe(claimDeviceKey(newClaimDeviceId(), null));
    expect(claimDeviceKey(d, '1.2.3.4')).toHaveLength(64);
  });

  it('generates device ids long enough for the database minimum', () => {
    expect(newClaimDeviceId().length).toBeGreaterThanOrEqual(16);
  });
});

describe('claimResultSchema', () => {
  it('accepts every status the database can return and rejects unknown ones', () => {
    expect(claimResultSchema.safeParse({ status: 'not_found' }).success).toBe(true);
    expect(claimResultSchema.safeParse({ status: 'locked' }).success).toBe(true);
    expect(claimResultSchema.safeParse({ status: 'otp', claim_id: crypto.randomUUID(), token: 't', phone_masked: '+92*******33' }).success).toBe(true);
    expect(claimResultSchema.safeParse({ status: 'wrong_cnic' }).success).toBe(false);
  });
});
