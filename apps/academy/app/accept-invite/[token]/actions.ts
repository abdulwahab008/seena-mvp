'use server';

import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';

const AcceptSchema = z.object({
  token: z.string().min(1),
  password: z.string().min(10, 'Must be at least 10 characters'),
  fullName: z.string().trim().min(2, 'Enter your full name').max(120),
  username: z.union([z.literal(''), z.string().trim().toLowerCase().regex(/^[a-z0-9][a-z0-9._-]{2,31}$/, 'Usernames are 3 to 32 letters, numbers, dots, dashes or underscores')]),
});

export type AcceptState = { error: string | null; ok: boolean };

type InviteState = { email: string; valid: boolean; tenant_id: string; school_code: string; user_id: string | null; confirmed: boolean | null };

function mapError(message: string): string {
  if (message.includes('INVITE_EXPIRED')) return 'This invitation has expired. Ask your school to send a new one.';
  if (message.includes('INVITE_ALREADY_USED')) return 'This invitation has already been used.';
  if (message.includes('INVITE_EMAIL_MISMATCH')) return 'This invitation was issued to a different email address.';
  if (message.includes('ALREADY_A_MEMBER')) return 'You already have an account. Try signing in instead.';
  if (message.includes('INVITE_NOT_FOUND')) return 'This invitation link is not valid.';
  if (message.includes('USERNAME_TAKEN')) return 'That username is already used in this school. Choose another.';
  if (message.includes('USERNAME_INVALID')) return 'Usernames are 3 to 32 letters, numbers, dots, dashes or underscores.';
  return 'Something went wrong. Please try again.';
}

// FR-A07: create the invitee's account and bind it to the inviting school in
// one request. The account is created server-side as already confirmed: the
// invitation link went to this address, which is the proof a confirmation
// email would give. (A browser sign-up gets no session while the project
// requires confirmation, which is what used to fail here.)
export async function acceptInvite(_email: string, _prev: AcceptState, formData: FormData): Promise<AcceptState> {
  const parsed = AcceptSchema.safeParse({
    token: formData.get('token'),
    password: formData.get('password'),
    fullName: formData.get('fullName'),
    username: formData.get('username') ?? '',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', ok: false };
  const { token, password, fullName, username } = parsed.data;

  const admin = supabaseServiceRole();
  const { data: state } = await admin.rpc('invite_account_state', { p_token: token }).maybeSingle<InviteState>();
  if (!state) return { error: 'This invitation link is not valid.', ok: false };
  if (!state.valid) return { error: 'This invitation has expired or was already used. Ask your school to send a new one.', ok: false };

  if (username) {
    const { data: check } = await admin.rpc('invite_username_check', { p_token: token, p_username: username });
    if (check === 'taken') return { error: 'That username is already used in this school. Choose another.', ok: false };
    if (check !== 'ok') return { error: 'Usernames are 3 to 32 letters, numbers, dots, dashes or underscores.', ok: false };
  }

  if (!state.user_id) {
    const { error } = await admin.auth.admin.createUser({ email: state.email, password, email_confirm: true, user_metadata: { full_name: fullName } });
    if (error) return { error: 'Could not create your account. Please try again.', ok: false };
  } else if (!state.confirmed) {
    // An account was started for this address but never confirmed (an older
    // sign-up, or a failed try at this page). Nobody has used it, and the
    // invitation proves the address, so finish it with this password.
    const { error } = await admin.auth.admin.updateUserById(state.user_id, { password, email_confirm: true, user_metadata: { full_name: fullName } });
    if (error) return { error: 'Could not set up your account. Please try again.', ok: false };
  }

  const supabase = await supabaseServer();
  const { error: signInError } = await supabase.auth.signInWithPassword({ email: state.email, password });
  if (signInError) {
    // A confirmed account already exists: only its own password may link it.
    return {
      error: 'An account with this email already exists. Enter its password to accept this invitation, or sign in and reset it.',
      ok: false,
    };
  }

  const { error: acceptError } = await supabase.rpc('accept_invitation', { p_token: token });
  if (acceptError) return { error: mapError(acceptError.message), ok: false };

  const { error: profileError } = await supabase.rpc('update_my_profile', { p_full_name: fullName, p_username: username || undefined });
  if (profileError) return { error: mapError(profileError.message), ok: false };

  // The session was minted before accept_invitation() created the membership,
  // so its JWT still says "no school". Refresh now so the next request sees it.
  const { error: refreshError } = await supabase.auth.refreshSession();
  if (refreshError) return { error: 'Account created, but please sign in again to continue.', ok: false };

  return { error: null, ok: true };
}
