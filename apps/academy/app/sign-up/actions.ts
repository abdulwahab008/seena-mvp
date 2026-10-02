'use server';

import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { passwordSchema, passwordsMatch } from '@/lib/auth/password';

const SignUpSchema = z.object({
  fullName: z.string().trim().min(2, 'Enter your full name').max(120, 'That name is too long'),
  email: z.string().trim().email('Enter a valid email address'),
  password: passwordSchema,
  confirmPassword: z.string(),
}).refine(...passwordsMatch);

export type SignUpState = { error: string | null; ok: boolean };

/**
 * Creates the Supabase Auth account only. It deliberately does NOT create a
 * tenant and does NOT bind the new user to one — see app/sign-up/page.tsx for
 * the full reasoning. The account lands on /no-school until an invitation is
 * redeemed at /accept-invite/[token].
 *
 * Account enumeration: this form tells the user plainly when an address is
 * already registered. That is a considered choice, not an oversight — a
 * sign-up form has to say "that address is taken" to be usable at all, and
 * pretending otherwise would strand someone who simply forgot they had an
 * account. It also matches app/accept-invite/[token]/actions.ts, which
 * already answers the same way. The flow where enumeration actually buys an
 * attacker something — /forgot-password — is strictly neutral instead.
 */
export async function signUp(_prev: SignUpState, formData: FormData): Promise<SignUpState> {
  const parsed = SignUpSchema.safeParse({
    fullName: formData.get('fullName'),
    email: formData.get('email'),
    password: formData.get('password'),
    confirmPassword: formData.get('confirmPassword'),
  });
  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Check the form and try again.', ok: false };
  }

  const supabase = await supabaseServer();
  const { data, error } = await supabase.auth.signUp({
    email: parsed.data.email,
    password: parsed.data.password,
    options: { data: { full_name: parsed.data.fullName } },
  });

  if (error) {
    if (/already registered|already been registered/i.test(error.message)) {
      return { error: 'An account with this email already exists. Sign in instead.', ok: false };
    }
    if (/password/i.test(error.message)) {
      return { error: 'That password does not meet the requirements.', ok: false };
    }
    console.error('[sign-up] signUp failed:', error.message);
    return { error: 'Could not create your account. Please try again.', ok: false };
  }

  // supabase.auth.signUp() answers a duplicate address with a 200 and an
  // obfuscated user (identities: []) rather than an error, whenever the
  // project has confirmations on. Treat that shape the same as the explicit
  // "already registered" error so the message stays consistent either way.
  if (data.user && data.user.identities && data.user.identities.length === 0) {
    return { error: 'An account with this email already exists. Sign in instead.', ok: false };
  }

  return { error: null, ok: true };
}
