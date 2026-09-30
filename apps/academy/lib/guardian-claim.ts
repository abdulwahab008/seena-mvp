import { createHash, randomBytes } from 'node:crypto';
import { z } from 'zod';

export const CLAIM_DEVICE_COOKIE = 'seena_claim_device';

export function newClaimDeviceId(): string {
  return randomBytes(24).toString('hex');
}

// One key per (browser, network). start_guardian_claim() locks on it after
// 3 failures; the per-GR cap in the database is what actually stops a
// distributed guesser, so this only has to be stable, not unforgeable.
export function claimDeviceKey(deviceId: string, ip: string | null): string {
  return createHash('sha256').update(`${deviceId}|${ip ?? 'no-ip'}`).digest('hex');
}

export const claimResultSchema = z.discriminatedUnion('status', [
  z.object({ status: z.literal('otp'), claim_id: z.string().uuid(), token: z.string().min(1), phone_masked: z.string().nullable() }),
  z.object({ status: z.literal('manual_review'), claim_id: z.string().uuid() }),
  z.object({ status: z.literal('already_active') }),
  z.object({ status: z.literal('locked') }),
  z.object({ status: z.literal('not_found') }),
]);
export type ClaimResult = z.infer<typeof claimResultSchema>;
