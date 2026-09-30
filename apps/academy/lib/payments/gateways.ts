import { createHmac, timingSafeEqual } from 'node:crypto';

export const GATEWAYS = ['jazzcash', 'easypaisa', 'onelink'] as const;
export type Gateway = (typeof GATEWAYS)[number];

export function isGateway(value: string): value is Gateway {
  return (GATEWAYS as readonly string[]).includes(value);
}

export function hmacHex(secret: string, message: string): string {
  return createHmac('sha256', secret).update(message, 'utf8').digest('hex');
}

// Canonical string for signing form fields: key-sorted `k=v` pairs, empty
// values dropped, so both sides derive identical bytes regardless of order.
export function signFields(secret: string, fields: Record<string, string>): string {
  const canonical = Object.keys(fields)
    .filter((k) => fields[k] !== '')
    .sort()
    .map((k) => `${k}=${fields[k]}`)
    .join('&');
  return hmacHex(secret, canonical);
}

export function verifySignature(secret: string, rawBody: string, signature: string | null): boolean {
  if (!secret || !signature) return false;
  const given = signature.replace(/^sha256=/, '').trim().toLowerCase();
  const expected = hmacHex(secret, rawBody);
  if (given.length !== expected.length || !/^[0-9a-f]+$/.test(given)) return false;
  return timingSafeEqual(Buffer.from(given, 'hex'), Buffer.from(expected, 'hex'));
}

export type Checkout =
  | { kind: 'redirect'; url: string; fields: Record<string, string> }
  | { kind: 'voucher'; reference: string };

type CheckoutInput = {
  gateway: Gateway;
  baseUrl: string | undefined;
  merchantId: string;
  secret: string;
  intent: { gateway_ref: string; amount_paisa: number; expires_at: string };
  returnUrl: string;
};

// Gateway-agnostic signed checkout. Field names are the integration point for
// each gateway's own contract; the parts that must not vary — who may pay,
// the amount, the expiry, the exactly-once callback — live in the database.
// Nothing returned here contains the secret.
export function buildCheckout(input: CheckoutInput): Checkout | null {
  if (input.gateway === 'onelink') {
    return { kind: 'voucher', reference: input.intent.gateway_ref };
  }
  if (!input.baseUrl) return null;
  const fields: Record<string, string> = {
    merchant_id: input.merchantId,
    txn_ref: input.intent.gateway_ref,
    amount_paisa: String(input.intent.amount_paisa),
    currency: 'PKR',
    expires_at: input.intent.expires_at,
    return_url: input.returnUrl,
  };
  return { kind: 'redirect', url: input.baseUrl, fields: { ...fields, signature: signFields(input.secret, fields) } };
}
