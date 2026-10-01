'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { digestSubscriptionSchema, type DigestSubscriptionInput } from '@/lib/validation';

type Result = { error: string | null };

function mapError(message: string): string {
  if (message.includes('REPORT_NOT_AVAILABLE')) return 'Your role cannot subscribe to this report.';
  if (message.includes('TIMEZONE_INVALID')) return 'That timezone is not recognised.';
  if (message.includes('CHANNEL_CONTACT_MISSING')) return 'Add a mobile number to your profile before choosing SMS or WhatsApp.';
  if (message.includes('WA_TEMPLATE_MISSING')) {
    const named = /WA_TEMPLATE_MISSING:\s*([^|\n]+)/.exec(message)?.[1]?.trim();
    return `WhatsApp is not set up for this report and language yet — no approved template${named ? ` (${named})` : ''}. Choose SMS or email, or ask the school owner to register the template.`;
  }
  return 'Something went wrong. Please try again.';
}

export async function subscribe(input: DigestSubscriptionInput): Promise<Result> {
  const p = digestSubscriptionSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('upsert_digest_subscription', {
    p_report_key: p.data.reportKey,
    p_cadence: p.data.cadence,
    p_run_at_local: p.data.runAtLocal,
    p_channel: p.data.channel,
    p_timezone: p.data.timezone,
    p_language_code: p.data.languageCode,
  });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/reports/digests');
  return { error: null };
}

export async function setActive(subscriptionId: string, active: boolean): Promise<Result> {
  if (!z.string().uuid().safeParse(subscriptionId).success) return { error: 'Invalid subscription.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_digest_subscription_active', { p_subscription_id: subscriptionId, p_active: active });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/reports/digests');
  return { error: null };
}

export async function remove(subscriptionId: string): Promise<Result> {
  if (!z.string().uuid().safeParse(subscriptionId).success) return { error: 'Invalid subscription.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('delete_digest_subscription', { p_subscription_id: subscriptionId });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/reports/digests');
  return { error: null };
}
