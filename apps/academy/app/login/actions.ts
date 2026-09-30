'use server';

import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';

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

  let targetEmail = parsed.data.email.trim();
  // Support student login by GR number
  if (!targetEmail.includes('@')) {
    const { data: resolved } = await supabaseServiceRole().rpc('resolve_student_login', {
      p_identifier: targetEmail,
    });
    if (resolved && (resolved as any).email) {
      targetEmail = (resolved as any).email;
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
  if (error) return { error: 'Incorrect email or password.', ok: false };

  return { error: null, ok: true };
}
