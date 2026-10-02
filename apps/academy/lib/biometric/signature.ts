import { createHash, createHmac, timingSafeEqual } from 'node:crypto';

/**
 * FR-D08: the on-premise agent signs each batch with HMAC-SHA256 over the raw
 * request body. The secret is sha256(raw device key) in hex - the same value
 * the database stores as biometric_device.api_key_hash - so the raw key is
 * shown once at registration and never kept on the server.
 */
export function deriveSigningSecret(rawDeviceKey: string): string {
  return createHash('sha256').update(rawDeviceKey, 'utf8').digest('hex');
}

export function signBody(signingSecret: string, rawBody: string): string {
  return createHmac('sha256', signingSecret).update(rawBody, 'utf8').digest('hex');
}

/** Constant-time check of an `x-signature` header (hex, optionally prefixed `sha256=`). */
export function verifySignature(signingSecret: string | null | undefined, rawBody: string, header: string | null | undefined): boolean {
  if (!signingSecret || !header) return false;
  const given = header.trim().replace(/^sha256=/i, '').toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(given)) return false;
  const expected = signBody(signingSecret, rawBody);
  return timingSafeEqual(Buffer.from(given, 'hex'), Buffer.from(expected, 'hex'));
}
