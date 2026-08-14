'use server';

import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

const AcceptSchema = z.object({
  token: z.string().min(1),
  password: z.string().min(10, 'Must be at least 10 characters'),
});

export type AcceptState = { error: string | null; ok: boolean };

function mapError(message: string): string {
  if (message.includes('INVITE_EXPIRED')) return 'This invitation has expired. Ask your school to send a new one.';
  if (message.includes('INVITE_ALREADY_USED')) return 'This invitation has already been used.';
  if (message.includes('INVITE_EMAIL_MISMATCH')) return 'This invitation was issued to a different email address.';
  if (message.includes('ALREADY_A_MEMBER')) return 'You already have an account. Try signing in instead.';
  if (message.includes('INVITE_NOT_FOUND')) return 'This invitation link is not valid.';
  return 'Something went wrong. Please try again.';
}

// FR-A07: create the invitee's Supabase Auth account, then immediately bind
// it to the inviting tenant via accept_invitation() while the fresh session
// is active — both steps have to happen in the same request or the user is
// left with an account but no tenant membership.
export async function acceptInvite(
  email: string,
  _prev: AcceptState,
  formData: FormData,
): Promise<AcceptState> {
  const parsed = AcceptSchema.safeParse({ token: formData.get('token'), password: formData.get('password') });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', ok: false };

  const supabase = await supabaseServer();

  const { error: signUpError } = await supabase.auth.signUp({ email, password: parsed.data.password });
  if (signUpError) {
    if (signUpError.message.toLowerCase().includes('already registered')) {
      // Since /sign-up exists, "I made an account, then my school invited me"
      // is a normal order of events — and it used to dead-end here, because
      // the invitation can only be redeemed with a session and this action
      // only ever created one via signUp(). Sign the existing account in with
      // the password they just typed and carry on to accept_invitation()
      // below; a wrong password still fails closed.
      const { error: signInError } = await supabase.auth.signInWithPassword({
        email,
        password: parsed.data.password,
      });
      if (signInError) {
        return {
          error:
            'An account with this email already exists. Enter its password to accept this invitation, or sign in and reset it.',
          ok: false,
        };
      }
    } else {
      return { error: 'Could not create your account.', ok: false };
    }
  }

  const { error: acceptError } = await supabase.rpc('accept_invitation', { p_token: parsed.data.token });
  if (acceptError) return { error: mapError(acceptError.message), ok: false };

  // The session signUp() issued was minted before accept_invitation() created
  // the app_user/user_campus rows, so its JWT still carries the "no tenant"
  // claims from custom_access_token_hook's not-found branch. Force a new
  // token now so the very next request sees the real tenant_id/campus_ids —
  // otherwise every table's RLS hides everything until the 15-minute-later
  // natural refresh.
  const { error: refreshError } = await supabase.auth.refreshSession();
  if (refreshError) return { error: 'Account created, but please sign in again to continue.', ok: false };

  return { error: null, ok: true };
}
