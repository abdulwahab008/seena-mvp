import { afterEach, describe, expect, it } from 'vitest';
import { verifyCronSecret } from './cron-auth';

describe('verifyCronSecret', () => {
  afterEach(() => {
    delete process.env.CRON_SECRET;
  });
  it('accepts only the exact bearer secret', () => {
    process.env.CRON_SECRET = 'a-long-enough-cron-secret';
    expect(verifyCronSecret('Bearer a-long-enough-cron-secret')).toBe(true);
    expect(verifyCronSecret('Bearer wrong')).toBe(false);
    expect(verifyCronSecret(null)).toBe(false);
  });
  it('rejects everything when the secret is unset or short', () => {
    expect(verifyCronSecret('Bearer ')).toBe(false);
    process.env.CRON_SECRET = 'short';
    expect(verifyCronSecret('Bearer short')).toBe(false);
  });
});
