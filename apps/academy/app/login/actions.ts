'use server';

import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { expandUsernameLogin } from '@/lib/auth/login-id';

const SignInSchema = z.object({
  email: z.string().min(1, 'Enter email or GR number'),
  password: z.string().min(1),
});

export type SignInState = { error: string | null; ok: boolean };

// Deliberately does NOT call next/navigation's redirect() here: this action
// is invoked directly from a client component (inside startTransition), not
// via <form action={...}> or useActionState's dispatch — redirect()'s
// special throw only gets intercepted by the client router through those
// two paths, and a bare call crashes with an unhandled client exception.
// The caller navigates on { ok: true } instead.
export async function signIn(_prev: SignInState, formData: FormData): Promise<SignInState> {
  const parsed = SignInSchema.safeParse({
    email: formData.get('email'),
    password: formData.get('password'),
  });
  if (!parsed.success) return { error: 'Enter a valid email or GR number and password.', ok: false };

  const supabase = await supabaseServer();

  let targetEmail = expandUsernameLogin(parsed.data.email);
  // username@school-code: any member with a username, whatever address their
  // login uses (invited staff keep their real email).
  const usernameAtSchool = parsed.data.email.trim().match(/^([a-z0-9][a-z0-9._-]{2,31})@([a-z0-9][a-z0-9-]{2,49})$/i);
  if (usernameAtSchool) {
    const { data: resolvedEmail } = await supabaseServiceRole().rpc('resolve_username_login', {
      p_username: usernameAtSchool[1]!,
      p_school_code: usernameAtSchool[2]!,
    });
    if (typeof resolvedEmail === 'string' && resolvedEmail) targetEmail = resolvedEmail;
  }
  // A bare identifier is a student's GR number; failing that, on a school's
  // own sign-in link (/login?school=code), a staff username at that school.
  if (!targetEmail.includes('@')) {
    const { data: resolved } = await supabaseServiceRole().rpc('resolve_student_login', {
      p_identifier: targetEmail,
    });
    const school = String(formData.get('school') ?? '');
    if (resolved && (resolved as any).email) {
      targetEmail = (resolved as any).email;
    } else if (/^[a-z0-9-]{3,50}$/.test(school)) {
      const { data: resolvedEmail } = await supabaseServiceRole().rpc('resolve_username_login', { p_username: targetEmail, p_school_code: school });
      targetEmail = typeof resolvedEmail === 'string' && resolvedEmail ? resolvedEmail : expandUsernameLogin(`${targetEmail}@${school}`);
    }
  }

  const { data: locked } = await supabase.rpc('is_login_locked', { p_identifier: targetEmail });
  if (locked) {
    return { error: 'Too many failed attempts. Try again in 15 minutes.', ok: false };
  }

  const { error } = await supabase.auth.signInWithPassword({
    email: targetEmail,
    password: parsed.data.password,
  });
  // Written via the service-role client, not the anon-key client above: the
  // outcome must be ground truth from this action's own signInWithPassword
  // call, not something a direct RPC caller could assert for themselves.
  await supabaseServiceRole().rpc('register_login_attempt', { p_identifier: targetEmail, p_succeeded: !error });
  if (error) {
    if (error.code === 'email_not_confirmed') {
      return { error: 'Your email is not confirmed yet. Open the confirmation email we sent you, or ask your school to send the invitation again.', ok: false };
    }
    return { error: 'That sign-in did not match. Check your email, username or GR number and your password.', ok: false };
  }

  return { error: null, ok: true };
}
