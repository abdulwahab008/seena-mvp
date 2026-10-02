import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { verifyWorkerSecret } from './worker-secret';

describe('verifyWorkerSecret', () => {
  const original = process.env.EXPORT_WORKER_SECRET;
  beforeEach(() => {
    process.env.EXPORT_WORKER_SECRET = 'unit-test-worker-secret-123';
  });
  afterEach(() => {
    if (original === undefined) delete process.env.EXPORT_WORKER_SECRET;
    else process.env.EXPORT_WORKER_SECRET = original;
  });

  it('accepts only the exact secret', () => {
    expect(verifyWorkerSecret('unit-test-worker-secret-123')).toBe(true);
    expect(verifyWorkerSecret('unit-test-worker-secret-124')).toBe(false);
    expect(verifyWorkerSecret('short')).toBe(false);
    expect(verifyWorkerSecret(null)).toBe(false);
    expect(verifyWorkerSecret('')).toBe(false);
  });

  it('fails closed when the secret is unset or too short', () => {
    delete process.env.EXPORT_WORKER_SECRET;
    expect(verifyWorkerSecret('anything-at-all-long-enough')).toBe(false);
    process.env.EXPORT_WORKER_SECRET = 'tiny';
    expect(verifyWorkerSecret('tiny')).toBe(false);
  });
});
