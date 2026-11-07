import { timingSafeEqual } from 'node:crypto';

// Vercel Cron calls with "Authorization: Bearer <CRON_SECRET>". Unset or short
// means reject everything.
export function verifyCronSecret(header: string | null | undefined): boolean {
  const secret = process.env.CRON_SECRET;
  if (!secret || secret.length < 16 || !header) return false;
  const a = Buffer.from(header);
  const b = Buffer.from(`Bearer ${secret}`);
  return a.length === b.length && timingSafeEqual(a, b);
}
