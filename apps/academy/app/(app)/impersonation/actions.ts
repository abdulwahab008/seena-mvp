'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { consentError, startImpersonationError } from '@/lib/impersonation';
import {
  endImpersonationSchema,
  grantImpersonationConsentSchema,
  revokeImpersonationConsentSchema,
  startImpersonationSchema,
} from '@/lib/validation';

const PATH = '/impersonation';

export type ImpersonationActionState = { error: string | null };

/**
 * The `imp` claim only appears in a token minted while the session is live, so
 * starting or ending one has to re-mint. Everything the banner, the write
 * block and every RLS policy read comes off that token, and none of it moves
 * until it is refreshed — which is also why `revalidatePath('/', 'layout')`
 * follows: the (app) shell is cached per token and would otherwise keep
 * rendering the previous one.
 */
async function reissueToken() {
  const supabase = await supabaseServer();
  await supabase.auth.refreshSession();
  revalidatePath('/', 'layout');
}

export async function grantConsent(
  _prev: ImpersonationActionState,
  formData: FormData,
): Promise<ImpersonationActionState> {
  const parsed = grantImpersonationConsentSchema.safeParse({
    targetUserId: formData.get('targetUserId') || undefined,
    hours: formData.get('hours'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('grant_impersonation_consent', {
    p_target_user_id: parsed.data.targetUserId,
    p_hours: parsed.data.hours,
  });
  if (error) return { error: consentError(error.message) };

  revalidatePath(PATH);
  return { error: null };
}

export async function withdrawConsent(
  _prev: ImpersonationActionState,
  formData: FormData,
): Promise<ImpersonationActionState> {
  const parsed = revokeImpersonationConsentSchema.safeParse({ consentId: formData.get('consentId') });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('revoke_impersonation_consent', { p_consent_id: parsed.data.consentId });
  if (error) return { error: consentError(error.message) };

  revalidatePath(PATH);
  return { error: null };
}

export async function startSession(
  _prev: ImpersonationActionState,
  formData: FormData,
): Promise<ImpersonationActionState> {
  const parsed = startImpersonationSchema.safeParse({
    targetUserId: formData.get('targetUserId'),
    minutes: formData.get('minutes'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('start_impersonation', {
    p_target_user_id: parsed.data.targetUserId,
    p_minutes: parsed.data.minutes,
  });
  if (error) return { error: startImpersonationError(error.message) };

  await reissueToken();
  redirect('/dashboard');
}

/**
 * Callable from the banner (the engineer leaving) and from the log (an Owner
 * throwing someone out) — end_impersonation() decides which of the two the
 * caller is, and refuses anyone who is neither.
 */
export async function endSession(
  _prev: ImpersonationActionState,
  formData: FormData,
): Promise<ImpersonationActionState> {
  const parsed = endImpersonationSchema.safeParse({ sessionId: formData.get('sessionId') || undefined });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('end_impersonation', { p_session_id: parsed.data.sessionId });
  if (error) {
    if (error.message.includes('IMPERSONATION_SESSION_NOT_FOUND')) return { error: 'That session no longer exists.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'Only the engineer inside the session, or an Owner, can end it.' };
    return { error: 'Could not end the session.' };
  }

  await reissueToken();
  redirect(PATH);
}

/**
 * The way out of a session the database has already closed underneath the
 * engineer: their token still carries `imp`, so every read raises PT401 until
 * it is re-minted without it.
 */
export async function returnToSelf(): Promise<void> {
  await reissueToken();
  redirect('/dashboard');
}

/**
 * AC6's read count. PostgREST runs a GET inside a READ ONLY transaction and an
 * RLS SELECT policy cannot write, so no trigger can count rows read — this is
 * the app-reported approximation the migration documents, called once per page
 * view from the banner.
 */
export async function noteImpersonationPageView(): Promise<void> {
  const supabase = await supabaseServer();
  await supabase.rpc('impersonation_note_reads', { p_rows: 1 });
}
