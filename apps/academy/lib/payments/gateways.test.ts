import { describe, expect, it } from 'vitest';
import { buildCheckout, hmacHex, isGateway, signFields, verifySignature } from './gateways';

const SECRET = 'unit-test-gateway-secret';

describe('signFields', () => {
  it('is independent of key order and ignores empty values', () => {
    expect(signFields(SECRET, { b: '2', a: '1' })).toBe(signFields(SECRET, { a: '1', b: '2', c: '' }));
  });
  it('changes when any value changes', () => {
    expect(signFields(SECRET, { a: '1' })).not.toBe(signFields(SECRET, { a: '2' }));
  });
});

describe('verifySignature', () => {
  const body = '{"gateway_ref":"JA-1","amount_paisa":850000}';
  it('accepts the right signature with or without a sha256= prefix', () => {
    expect(verifySignature(SECRET, body, hmacHex(SECRET, body))).toBe(true);
    expect(verifySignature(SECRET, body, `sha256=${hmacHex(SECRET, body).toUpperCase()}`)).toBe(true);
  });
  it('rejects tampering, wrong secret, missing or malformed signatures', () => {
    expect(verifySignature(SECRET, `${body} `, hmacHex(SECRET, body))).toBe(false);
    expect(verifySignature('other-secret', body, hmacHex(SECRET, body))).toBe(false);
    expect(verifySignature(SECRET, body, null)).toBe(false);
    expect(verifySignature(SECRET, body, 'zz')).toBe(false);
    expect(verifySignature('', body, hmacHex('', body))).toBe(false);
  });
});

describe('buildCheckout', () => {
  const intent = { gateway_ref: 'JA-abc', amount_paisa: 850000, expires_at: '2026-10-01T10:30:00Z' };
  it('returns a 1LINK voucher reference only', () => {
    expect(buildCheckout({ gateway: 'onelink', baseUrl: undefined, merchantId: 'M', secret: SECRET, intent: { ...intent, gateway_ref: 'CH-0001' }, returnUrl: 'https://x' })).toEqual({
      kind: 'voucher',
      reference: 'CH-0001',
    });
  });
  it('signs a redirect without ever including the secret', () => {
    const c = buildCheckout({ gateway: 'jazzcash', baseUrl: 'https://sandbox.example/pay', merchantId: 'M1', secret: SECRET, intent, returnUrl: 'https://school/portal/fees' });
    expect(c?.kind).toBe('redirect');
    if (c?.kind !== 'redirect') return;
    expect(JSON.stringify(c)).not.toContain(SECRET);
    const { signature, ...rest } = c.fields;
    expect(signature).toBe(signFields(SECRET, rest));
    expect(c.fields.amount_paisa).toBe('850000');
  });
  it('is unavailable for redirect gateways with no checkout URL configured', () => {
    expect(buildCheckout({ gateway: 'easypaisa', baseUrl: undefined, merchantId: 'M', secret: SECRET, intent, returnUrl: 'https://x' })).toBeNull();
  });
});

describe('isGateway', () => {
  it('only accepts the three supported gateways', () => {
    expect(isGateway('jazzcash')).toBe(true);
    expect(isGateway('stripe')).toBe(false);
  });
});
