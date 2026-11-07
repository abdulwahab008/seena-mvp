'use server';

import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { passwordSchema, passwordsMatch } from '@/lib/auth/password';

const ChangeSchema = z
  .object({ password: passwordSchema, confirmPassword: z.string() })
  .refine(...passwordsMatch);

export async function changeTemporaryPassword(input: z.input<typeof ChangeSchema>): Promise<{ error: string | null }> {
  const parsed = ChangeSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Check the form and try again.' };

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: 'Your session has ended. Sign in again.' };

  const { error } = await supabase.auth.updateUser({ password: parsed.data.password });
  if (error) {
    if (error.code === 'same_password') return { error: 'Choose a password different from the temporary one.' };
    return { error: 'Could not change your password. Try again.' };
  }

  const { error: metaError } = await supabaseServiceRole().auth.admin.updateUserById(user.id, {
    app_metadata: { must_change_password: false },
  });
  if (metaError) return { error: 'Your password changed, but we could not finish. Sign in again.' };

  await supabase.auth.refreshSession();
  return { error: null };
}
