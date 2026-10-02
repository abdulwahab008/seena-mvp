import { env } from '../env';
import { supabaseServiceRole } from '../supabase/server';

/**
 * Mints a password-recovery link that points at OUR /reset-password page.
 *
 * WHY NOT resetPasswordForEmail(): that hands the send to Supabase's own SMTP
 * (Mailpit locally), so the mail never touches Resend and the branded template
 * in lib/email/templates.ts is never used.
 *
 * WHY THE action_link IS DISCARDED: generateLink() returns an action_link of
 * the form
 *   http://127.0.0.1:54321/auth/v1/verify?token=<hash>&type=recovery&redirect_to=<url>
 * and GoTrue rewrites that redirect_to to auth.site_url unless the exact URL
 * is listed in auth.additional_redirect_urls. Verified against this stack:
 * passing options.redirectTo = 'http://localhost:3011/reset-password' came
 * back with redirect_to = 'http://127.0.0.1:3011' — silently ignored, no
 * error. Depending on it would mean the reset link's destination is really
 * controlled by supabase/config.toml rather than by this app.
 *
 * So we take only properties.hashed_token — the actual secret — and build the
 * URL ourselves. /reset-password then redeems it with
 * auth.verifyOtp({ type: 'recovery', token_hash }), which needs no
 * allow-listing because the browser never visits GoTrue's /verify endpoint.
 */
export type RecoveryLink =
  | { ok: true; url: string; tokenHash: string; userId: string | null }
  | { ok: false; reason: 'no_account' | 'throttled' | 'failed'; detail: string };

export function siteUrl(): string {
  // Falls back to the dev port rather than throwing: NEXT_PUBLIC_SITE_URL is
  // optional in lib/env.ts so existing deploys keep booting.
  return (env().NEXT_PUBLIC_SITE_URL ?? 'http://localhost:3011').replace(/\/+$/, '');
}

export async function issueRecoveryLink(email: string): Promise<RecoveryLink> {
  const admin = supabaseServiceRole();

  const { data: throttled } = await admin.rpc('is_password_reset_throttled', { p_email: email });
  if (throttled) {
    return { ok: false, reason: 'throttled', detail: 'too many reset requests for this address' };
  }

  const { data, error } = await admin.auth.admin.generateLink({ type: 'recovery', email });

  if (error) {
    // GoTrue answers a recovery link for an unknown address with a 4xx. That
    // is not an error condition for the caller — /forgot-password must look
    // identical either way — so it is reported as its own reason rather than
    // as a failure.
    const status = error.status ?? 0;
    if (status === 404 || status === 400 || /user not found/i.test(error.message)) {
      return { ok: false, reason: 'no_account', detail: error.message };
    }
    return { ok: false, reason: 'failed', detail: error.message };
  }

  const tokenHash = data?.properties?.hashed_token;
  if (!tokenHash) {
    return { ok: false, reason: 'failed', detail: 'generateLink returned no hashed_token' };
  }

  const { error: ledgerError } = await admin.rpc('register_password_reset', {
    p_email: email,
    p_token_hash: tokenHash,
  });
  // A ledger write failure only costs the precise "already used" message
  // later, so the reset itself still goes ahead.
  if (ledgerError) {
    console.error('[recovery] could not record reset request:', ledgerError.message);
  }

  return {
    ok: true,
    tokenHash,
    userId: data.user?.id ?? null,
    url: `${siteUrl()}/reset-password?token_hash=${encodeURIComponent(tokenHash)}`,
  };
}
