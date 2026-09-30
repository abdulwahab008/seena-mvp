'use server';

import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { requireSession } from '@/lib/auth/require-session';
import { revalidatePath } from 'next/cache';

const PasswordChangeSchema = z.object({
  newPassword: z.string().min(6, 'Password must be at least 6 characters long'),
  confirmPassword: z.string().min(6, 'Confirm password must match'),
}).refine((data) => data.newPassword === data.confirmPassword, {
  message: 'Passwords do not match',
  path: ['confirmPassword'],
});

export type PasswordChangeState = {
  error: string | null;
  success: boolean;
};

export async function changeStudentPasswordAction(
  _prevState: PasswordChangeState,
  formData: FormData
): Promise<PasswordChangeState> {
  await requireSession();
  const parsed = PasswordChangeSchema.safeParse({
    newPassword: formData.get('newPassword'),
    confirmPassword: formData.get('confirmPassword'),
  });

  if (!parsed.success) {
    const errorMsg = parsed.error.issues[0]?.message ?? 'Invalid password input';
    return { error: errorMsg, success: false };
  }

  const supabase = await supabaseServer();

  // Call security-definer RPC change_student_password
  const { error } = await supabase.rpc('change_student_password', {
    p_new_password: parsed.data.newPassword,
  });

  if (error) {
    return { error: error.message || 'Failed to update password', success: false };
  }

  revalidatePath('/student', 'layout');
  return { error: null, success: true };
}
