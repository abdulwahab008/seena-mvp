'use server';

import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';

function toGoTruePhone(phoneE164: string): string {
  return phoneE164.replace(/^\+/, '');
}

function mapActivateError(message: string): string {
  if (message.includes('INVITE_EXPIRED')) return 'This invite has expired. Ask the school to send a new one.';
  if (message.includes('INVITE_ALREADY_USED')) return 'This invite has already been used.';
  if (message.includes('INVITE_NOT_FOUND')) return 'This invite link is not valid.';
  if (message.includes('INVITE_PHONE_MISMATCH')) return 'This code was not sent to the phone number on this invite.';
  if (message.includes('GUARDIAN_ALREADY_ACTIVE')) return 'This account is already active. Try signing in instead.';
  return 'Something went wrong. Please try again.';
}

export type RequestActivationCodeState = { error: string | null; phone: string | null };

// FR-C11: the phone is never taken from the client — it's re-derived from
// the invite token every time, so a tampered request can't redirect the
// code to a different number than the one on the guardian's own record.
export async function requestActivationCode(token: string, _prev: RequestActivationCodeState, _formData: FormData): Promise<RequestActivationCodeState> {
  const supabase = await supabaseServer();
  const { data: preview } = await supabase.rpc('get_guardian_invite_preview', { p_token: token }).maybeSingle();
  if (!preview || !preview.valid) return { error: 'This invite link is not valid.', phone: null };
  if (preview.locked) return { error: 'Too many wrong attempts. Try again in 30 minutes.', phone: null };
  if (!preview.phone_e164) return { error: 'No phone number on file for this invite.', phone: null };

  const { error } = await supabase.auth.signInWithOtp({
    phone: toGoTruePhone(preview.phone_e164),
    // shouldCreateUser:true — this IS the deferred self-serve-signup path
    // FR-A08's own OTP flow deliberately left out (see otp_auth.sql).
    options: { shouldCreateUser: true },
  });
  if (error) return { error: 'Could not send the code. Try again shortly.', phone: null };

  return { error: null, phone: preview.phone_e164 };
}

export type VerifyActivationCodeState = { error: string | null; ok: boolean };

export async function verifyActivationCode(
  token: string,
  phone: string,
  _prev: VerifyActivationCodeState,
  formData: FormData,
): Promise<VerifyActivationCodeState> {
  const code = formData.get('code');
  if (typeof code !== 'string' || !/^\d{6}$/.test(code)) return { error: 'Enter the 6-digit code.', ok: false };

  const supabase = await supabaseServer();

  const { data: preview } = await supabase.rpc('get_guardian_invite_preview', { p_token: token }).maybeSingle();
  if (preview?.locked) return { error: 'Too many wrong attempts. Try again in 30 minutes.', ok: false };

  const { error: verifyError } = await supabase.auth.verifyOtp({ phone: toGoTruePhone(phone), token: code, type: 'sms' });
  // Ground truth from this action's own verifyOtp call, written via the
  // service-role client — same reasoning as register_otp_attempt in
  // app/login/otp/actions.ts.
  await supabaseServiceRole().rpc('register_guardian_otp_attempt', { p_token: token, p_kind: verifyError ? 'verify_failed' : 'verify_succeeded' });
  if (verifyError) return { error: 'Incorrect or expired code.', ok: false };

  const { error: activateError } = await supabase.rpc('activate_guardian_account', { p_token: token });
  if (activateError) return { error: mapActivateError(activateError.message), ok: false };

  // The session verifyOtp() minted was issued before activate_guardian_
  // account() set guardian.auth_user_id, so its JWT still carries the "no
  // tenant" claims — same stale-token gotcha accept_invitation's own
  // action already documents, same fix.
  const { error: refreshError } = await supabase.auth.refreshSession();
  if (refreshError) return { error: 'Account activated, but please sign in again to continue.', ok: false };

  return { error: null, ok: true };
}
