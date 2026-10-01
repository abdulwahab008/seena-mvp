import crypto from 'node:crypto';

/**
 * Vendor HMAC: hex SHA-256 of the raw body keyed with the shared secret,
 * optionally prefixed "sha256=". Fails closed when the secret is unset or short.
 */
export function verifyHmacSignature(secret: string | undefined, rawBody: string, signature: string | null): boolean {
  if (!secret || secret.length < 16 || !signature) return false;
  const given = signature.replace(/^sha256=/, '').trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(given)) return false;
  const expected = crypto.createHmac('sha256', secret).update(rawBody, 'utf8').digest();
  return crypto.timingSafeEqual(Buffer.from(given, 'hex'), expected);
}

export function signBody(secret: string, rawBody: string): string {
  return crypto.createHmac('sha256', secret).update(rawBody, 'utf8').digest('hex');
}
