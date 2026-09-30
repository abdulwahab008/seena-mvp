import { createHmac } from 'node:crypto';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { verifyWebhookSignature } from './comm-webhook-verifier';

const SECRET = 'unit-test-secret-0123456789';
const sign = (body: string, secret = SECRET) => createHmac('sha256', secret).update(body, 'utf8').digest('hex');

describe('verifyWebhookSignature', () => {
  const original = process.env.COMM_WEBHOOK_SECRET;
  beforeEach(() => {
    process.env.COMM_WEBHOOK_SECRET = SECRET;
  });
  afterEach(() => {
    if (original === undefined) delete process.env.COMM_WEBHOOK_SECRET;
    else process.env.COMM_WEBHOOK_SECRET = original;
  });

  it('accepts a correct signature, with or without the sha256= prefix', () => {
    const body = '{"id":"1"}';
    expect(verifyWebhookSignature(body, sign(body))).toBe(true);
    expect(verifyWebhookSignature(body, `sha256=${sign(body)}`)).toBe(true);
  });

  it('rejects a wrong, empty or malformed signature', () => {
    expect(verifyWebhookSignature('{"id":"1"}', sign('{"id":"2"}'))).toBe(false);
    expect(verifyWebhookSignature('{"id":"1"}', '')).toBe(false);
    expect(verifyWebhookSignature('{"id":"1"}', null)).toBe(false);
    expect(verifyWebhookSignature('{"id":"1"}', 'not-hex')).toBe(false);
  });

  it('fails closed when the secret is unset or too short — there is no default secret', () => {
    const body = '{"id":"1"}';
    const old = 'seena-comm-webhook-secret-key-2026';
    delete process.env.COMM_WEBHOOK_SECRET;
    expect(verifyWebhookSignature(body, sign(body, old))).toBe(false);
    process.env.COMM_WEBHOOK_SECRET = 'short';
    expect(verifyWebhookSignature(body, sign(body, 'short'))).toBe(false);
  });
});
