'use server';

import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { passwordSchema, passwordsMatch } from '@/lib/auth/password';

const ResetSchema = z.object({
  tokenHash: z.string().trim().min(1),
  password: passwordSchema,
  confirmPassword: z.string(),
}).refine(...passwordsMatch);

export type ResetState = { error: string | null; ok: boolean };

/**
 * Redeems a recovery token and sets the new password.
 *
 * verifyOtp() is the ONLY authority on whether the token is good. The
 * classification shown on the page came from our own ledger
 * (classify_password_reset_token), which exists purely so the user can be
 * told *why* a link failed — it is advisory, is re-checked here, and grants
 * nothing on its own.
 */
export async function resetPassword(_prev: ResetState, formData: FormData): Promise<ResetState> {
  const parsed = ResetSchema.safeParse({
    tokenHash: formData.get('tokenHash'),
    password: formData.get('password'),
    confirmPassword: formData.get('confirmPassword'),
  });
  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Check the form and try again.', ok: false };
  }

  const supabase = await supabaseServer();

  const { error: verifyError } = await supabase.auth.verifyOtp({
    type: 'recovery',
    token_hash: parsed.data.tokenHash,
  });
  if (verifyError) {
    // GoTrue answers expired, already-spent and forged tokens identically
    // (403 otp_expired), so this message cannot be more specific than the
    // page's own — reached only when the ledger and GoTrue disagree, e.g. a
    // link redeemed in another tab a moment ago.
    console.error('[reset-password] verifyOtp failed:', verifyError.message);
    return {
      error: 'This reset link is no longer valid. Request a new one to continue.',
      ok: false,
    };
  }

  const { error: updateError } = await supabase.auth.updateUser({ password: parsed.data.password });
  if (updateError) {
    console.error('[reset-password] updateUser failed:', updateError.message);
    if (/should be different|same as the old/i.test(updateError.message)) {
      return { error: 'Choose a password you have not used before.', ok: false };
    }
    return { error: 'Could not update your password. Please try again.', ok: false };
  }

  const { error: consumeError } = await supabaseServiceRole().rpc('consume_password_reset', {
    p_token_hash: parsed.data.tokenHash,
  });
  if (consumeError) {
    // The password did change, so this must not fail the request — it only
    // costs the "already used" wording if the link is opened again.
    console.error('[reset-password] could not mark token consumed:', consumeError.message);
  }

  // verifyOtp() left this browser holding a live session for the account.
  // Ending it means the new password is actually proven at /login rather than
  // assumed, and no session minted by a mailed link outlives the reset.
  await supabase.auth.signOut();

  return { error: null, ok: true };
}
