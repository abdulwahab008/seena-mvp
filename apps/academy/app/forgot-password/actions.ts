'use server';

import { z } from 'zod';
import { issueRecoveryLink } from '@/lib/auth/recovery';
import { emailConfigured, sendEmail } from '@/lib/email/send';
import { passwordResetEmail } from '@/lib/email/templates';
import { supabaseServiceRole } from '@/lib/supabase/server';

const ForgotSchema = z.object({ email: z.string().trim().email() });

export type ForgotState = { error: string | null; sent: boolean };

/**
 * The response is IDENTICAL whether or not the address has an account — the
 * caller only ever learns "if that address is registered, mail is on its
 * way". Every branch below that is not a genuine server-side misconfiguration
 * returns { sent: true }, including "no such user" and "throttled".
 *
 * The one deliberate exception is an unconfigured mailer: silently claiming
 * to have sent mail that could never be sent would leave a user waiting for
 * an email that does not exist, so that surfaces as a real error.
 */
export async function requestPasswordReset(
  _prev: ForgotState,
  formData: FormData,
): Promise<ForgotState> {
  const parsed = ForgotSchema.safeParse({ email: formData.get('email') });
  if (!parsed.success) return { error: 'Enter a valid email address.', sent: false };

  if (!emailConfigured()) {
    console.error('[forgot-password] RESEND_API_KEY is not set — cannot send reset mail.');
    return {
      error: 'Password reset email is not configured on this server. Contact your administrator.',
      sent: false,
    };
  }

  const email = parsed.data.email;
  const link = await issueRecoveryLink(email);

  if (!link.ok) {
    // no_account / throttled are both normal outcomes that must stay
    // indistinguishable from success. Only the detail is logged.
    console.info(`[forgot-password] no mail sent for a request (${link.reason}).`);
    return { error: null, sent: true };
  }

  const schoolName = await tenantNameFor(link.userId);
  const message = passwordResetEmail({ url: link.url, schoolName });
  const result = await sendEmail({
    to: email,
    subject: message.subject,
    html: message.html,
    text: message.text,
  });

  if (!result.ok) {
    // Logged with the provider's own wording (never the API key) so an
    // operator can tell a bounced address from a broken key, while the user
    // still sees the neutral confirmation.
    console.error(`[forgot-password] Resend ${result.reason}: ${result.detail}`);
  }

  return { error: null, sent: true };
}

/**
 * Best-effort branding for the email. A user with no app_user row (signed up
 * but not yet invited into a school) simply gets the product name.
 */
async function tenantNameFor(userId: string | null): Promise<string> {
  if (!userId) return 'Seena Academy';
  const admin = supabaseServiceRole();
  const { data } = await admin
    .from('app_user')
    .select('tenant:tenant_id(name)')
    .eq('user_id', userId)
    .maybeSingle();
  return data?.tenant?.name ?? 'Seena Academy';
}
