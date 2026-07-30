'use server';

import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { otpPhoneSchema, otpCodeSchema } from '@/lib/validation';

// normalize_pk_phone() (and this app's own otp_attempt rate-limit/lockout
// tracking) uses +92-prefixed E.164, per FR-A08's acceptance criteria.
// Supabase Auth's own phone-auth convention is bare digits, no leading "+" —
// this is the one place those two formats meet.
function toGoTruePhone(phoneE164: string): string {
  return phoneE164.replace(/^\+/, '');
}

export type RequestOtpState = { error: string | null; phone: string | null };

export async function requestOtp(_prev: RequestOtpState, formData: FormData): Promise<RequestOtpState> {
  const parsed = otpPhoneSchema.safeParse({ phone: formData.get('phone') });
  if (!parsed.success) return { error: 'Enter a phone number.', phone: null };

  const supabase = await supabaseServer();

  const { data, error: issueError } = await supabase.rpc('issue_otp', { p_phone: parsed.data.phone });
  if (issueError) {
    const message = issueError.message.includes('OTP_RATE_LIMITED')
      ? 'Too many codes requested. Try again in an hour.'
      : 'Enter a valid phone number, e.g. 03001234567.';
    return { error: message, phone: null };
  }

  const phoneE164 = (data as { phone_e164: string }).phone_e164;
  const { error: sendError } = await supabase.auth.signInWithOtp({
    phone: toGoTruePhone(phoneE164),
    // [auth.sms].enable_signup has to be true for phone sign-in to work at
    // all (see config.toml) — this is the actual "existing users only" gate
    // FR-A08 wants: a phone with no matching auth.users row is rejected
    // rather than silently creating a fresh, tenant-less account.
    options: { shouldCreateUser: false },
  });
  if (sendError) return { error: 'Could not send the code. Try again shortly.', phone: null };

  return { error: null, phone: phoneE164 };
}

export type VerifyOtpState = { error: string | null; ok: boolean };

export async function verifyOtpCode(_prev: VerifyOtpState, formData: FormData): Promise<VerifyOtpState> {
  const phone = formData.get('phone');
  const parsed = otpCodeSchema.safeParse({ code: formData.get('code') });
  if (typeof phone !== 'string' || !phone) return { error: 'Request a new code first.', ok: false };
  if (!parsed.success) return { error: 'Enter the 6-digit code.', ok: false };

  const supabase = await supabaseServer();

  const { data: locked } = await supabase.rpc('is_otp_locked', { p_phone: phone });
  if (locked) return { error: 'Too many wrong attempts. Request a new code.', ok: false };

  const { error } = await supabase.auth.verifyOtp({ phone: toGoTruePhone(phone), token: parsed.data.code, type: 'sms' });
  // Same reasoning as register_login_attempt: ground truth from this
  // action's own verifyOtp call, written via the service-role client so a
  // direct RPC caller can't assert their own outcome.
  await supabaseServiceRole().rpc('register_otp_attempt', {
    p_phone: phone,
    p_kind: error ? 'verify_failed' : 'verify_succeeded',
  });
  if (error) return { error: 'Incorrect or expired code.', ok: false };

  return { error: null, ok: true };
}
