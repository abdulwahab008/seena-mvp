'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { passwordSchema } from '@/lib/auth/password';
import { STAFF_ROLES } from '@/lib/staff-roles';
import { newAccountSchema, type NewAccountInput } from './schema';

type Result = { error: string | null };

function rpcError(message: string): string {
  if (message.includes('USERNAME_TAKEN')) return 'That username is already used in this school.';
  if (message.includes('USERNAME_INVALID')) return 'Usernames are 3 to 32 letters, numbers, dots, dashes or underscores.';
  if (message.includes('CAMPUS_NOT_FOUND')) return 'One of the campuses no longer exists.';
  if (message.includes('NOT_SUPPORTED')) return 'That cannot be done for this kind of account.';
  if (message.includes('FORBIDDEN')) return 'You are not allowed to do that for this account.';
  return 'Something went wrong. Try again.';
}

export async function createAccount(input: NewAccountInput): Promise<Result> {
  const parsed = newAccountSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Check the form.' };
  const v = parsed.data;
  const username = v.loginType === 'username' ? v.username.toLowerCase() : null;
  const email = v.loginType === 'email' ? v.email.toLowerCase() : null;

  const supabase = await supabaseServer();
  const { data: hiddenEmail, error: checkError } = await supabase.rpc('user_account_login_email', {
    p_username: username,
    p_role: v.role,
    p_campus_ids: v.campusIds,
  });
  if (checkError) return { error: rpcError(checkError.message) };

  const admin = supabaseServiceRole();
  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email: (hiddenEmail ?? email)!,
    password: v.password,
    email_confirm: true,
    app_metadata: { must_change_password: true },
  });
  if (createError || !created.user) {
    if (createError?.code === 'email_exists') return { error: 'An account with that email already exists. Invite them from Staff instead.' };
    return { error: 'Could not create the login. Try again.' };
  }

  const { error: linkError } = await supabase.rpc('create_user_account', {
    p_user_id: created.user.id,
    p_full_name: v.fullName,
    p_role: v.role,
    p_campus_ids: v.campusIds,
    p_username: username,
  });
  if (linkError) {
    await admin.auth.admin.deleteUser(created.user.id);
    return { error: rpcError(linkError.message) };
  }

  revalidatePath('/users');
  return { error: null };
}

export async function resetAccountPassword(userId: string, password: string): Promise<Result> {
  const parsed = z.object({ userId: z.string().uuid(), password: passwordSchema }).safeParse({ userId, password });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Check the password.' };

  const supabase = await supabaseServer();
  const { data: kind, error } = await supabase.rpc('user_account_kind', { p_user_id: userId });
  if (error) return { error: rpcError(error.message) };

  const admin = supabaseServiceRole();
  const { error: updateError } = await admin.auth.admin.updateUserById(userId, {
    password,
    // Students are sent to their own password screen by student_portal_account.must_change_password.
    app_metadata: { must_change_password: kind !== 'student' },
  });
  if (updateError) return { error: 'Could not set the password. Try again.' };
  if (kind === 'student') {
    await admin.from('student_portal_account').update({ must_change_password: true }).eq('user_id', userId);
  }
  return { error: null };
}

export async function setAccountActive(userId: string, active: boolean): Promise<Result> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_user_account_active', { p_user_id: userId, p_active: active });
  if (error) return { error: rpcError(error.message) };
  revalidatePath('/users');
  return { error: null };
}

export async function setAccountRole(userId: string, role: string): Promise<Result> {
  const parsed = z.enum(STAFF_ROLES).safeParse(role);
  if (!parsed.success) return { error: 'Choose a role.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_user_account_role', { p_user_id: userId, p_role: parsed.data });
  if (error) return { error: rpcError(error.message) };
  revalidatePath('/users');
  return { error: null };
}
