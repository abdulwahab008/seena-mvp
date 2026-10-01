import { timingSafeEqual } from 'node:crypto';

// Internal worker endpoints have no user session: a shared secret in the
// environment is their only authentication. Unset or short means "reject
// everything", never "allow everything".
export function verifyWorkerSecret(header: string | null | undefined): boolean {
  const secret = process.env.EXPORT_WORKER_SECRET;
  if (!secret || secret.length < 16 || !header) return false;
  const a = Buffer.from(header);
  const b = Buffer.from(secret);
  return a.length === b.length && timingSafeEqual(a, b);
}
