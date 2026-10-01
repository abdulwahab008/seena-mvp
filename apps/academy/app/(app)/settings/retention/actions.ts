'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { retentionPolicySchema, type RetentionPolicyInput } from '@/lib/validation';

type Result = { error: string | null };

function mapError(message: string): string {
  if (message.includes('FORBIDDEN')) return 'Only a Super Admin can change retention or start a purge.';
  if (message.includes('RETENTION_YEARS_INVALID')) return 'Retention must be between 1 and 50 years.';
  return 'Something went wrong. Please try again.';
}

export async function savePolicy(input: RetentionPolicyInput): Promise<Result> {
  const p = retentionPolicySchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_retention_policy', { p_category: p.data.category, p_years: p.data.years });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/settings/retention');
  return { error: null };
}

// A dry run lists what the next live run would do (counts per category, exemptions) and changes nothing.
export async function startDryRun(): Promise<Result> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('start_retention_run', { p_dry_run: true });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/settings/retention');
  return { error: null };
}
