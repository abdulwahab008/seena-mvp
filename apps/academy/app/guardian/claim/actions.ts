'use server';

import { cookies, headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { guardianClaimSchema, type GuardianClaimInput } from '@/lib/validation';
import { CLAIM_DEVICE_COOKIE, claimDeviceKey, claimResultSchema, newClaimDeviceId } from '@/lib/guardian-claim';
import { clientIpFromHeaders } from '@/lib/request-ip';

export type ClaimActionState = { error: string | null; notice: string | null };

// The same sentence for "no such school", "no such GR" and "wrong CNIC" — the
// form must never say which half was wrong (FR-N01 Notes).
const NOT_FOUND = 'We could not match those details. Check them and try again.';

export async function startGuardianClaim(input: GuardianClaimInput): Promise<ClaimActionState> {
  const parsed = guardianClaimSchema.safeParse(input);
  if (!parsed.success) return { error: NOT_FOUND, notice: null };

  const jar = await cookies();
  let deviceId = jar.get(CLAIM_DEVICE_COOKIE)?.value;
  if (!deviceId) {
    deviceId = newClaimDeviceId();
    jar.set(CLAIM_DEVICE_COOKIE, deviceId, { httpOnly: true, sameSite: 'lax', secure: process.env.NODE_ENV === 'production', path: '/guardian', maxAge: 60 * 60 * 24 * 365 });
  }
  const ip = clientIpFromHeaders(await headers());

  const { data, error } = await supabaseServiceRole().rpc('start_guardian_claim', {
    p_school_code: parsed.data.schoolCode,
    p_gr_no: parsed.data.grNumber,
    p_cnic_last6: parsed.data.cnicLast6,
    p_device_hash: claimDeviceKey(deviceId, ip),
  });
  const result = claimResultSchema.safeParse(data);
  if (error || !result.success) return { error: 'Something went wrong. Please try again.', notice: null };

  switch (result.data.status) {
    case 'otp':
      redirect(`/guardian/activate/${result.data.token}`);
    case 'manual_review':
      return { error: null, notice: 'We could not send a code to a phone number on file. The school office will verify your claim and contact you.' };
    case 'already_active':
      return { error: null, notice: 'This parent account is already active. Sign in with your phone number instead.' };
    case 'locked':
      return { error: 'Too many attempts. Try again in 30 minutes.', notice: null };
    case 'not_found':
      return { error: NOT_FOUND, notice: null };
  }
}
