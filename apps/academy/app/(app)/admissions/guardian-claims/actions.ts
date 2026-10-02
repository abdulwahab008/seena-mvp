'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { resolveGuardianClaimSchema, type ResolveGuardianClaimInput } from '@/lib/validation';

const resolvedSchema = z.object({
  status: z.enum(['approved', 'rejected']),
  token: z.string().optional(),
  phone_e164: z.string().optional(),
  guardian_name: z.string().optional(),
});

export type ResolveClaimResult =
  | { error: string }
  | { error: null; status: 'approved' | 'rejected'; inviteUrlPath: string | null; phone: string | null };

function mapError(message: string): string {
  if (message.includes('PHONE_REQUIRED')) return 'Add a verified phone number to the guardian record first, then approve.';
  if (message.includes('CLAIM_NOT_PENDING_REVIEW')) return 'This claim has already been resolved.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to resolve claims.';
  return 'Could not resolve the claim. Please try again.';
}

export async function resolveGuardianClaim(input: ResolveGuardianClaimInput): Promise<ResolveClaimResult> {
  const parsed = resolveGuardianClaimSchema.safeParse(input);
  if (!parsed.success) return { error: 'Invalid request.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('resolve_guardian_claim', {
    p_claim_id: parsed.data.claimId,
    p_approve: parsed.data.approve,
    p_note: parsed.data.note,
  });
  if (error) return { error: mapError(error.message) };

  const result = resolvedSchema.safeParse(data);
  if (!result.success) return { error: 'Unexpected response from the server.' };

  revalidatePath('/admissions/guardian-claims');
  return {
    error: null,
    status: result.data.status,
    inviteUrlPath: result.data.token ? `/guardian/activate/${result.data.token}` : null,
    phone: result.data.phone_e164 ?? null,
  };
}
