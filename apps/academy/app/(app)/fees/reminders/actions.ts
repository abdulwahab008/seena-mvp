'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

const idSchema = z.string().uuid();

export async function seedDefaultLadder(): Promise<{ error: string | null }> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('seed_default_fee_reminder_rules', {});
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'Only accounts staff can configure reminders.' : 'Could not create the ladder.' };
  revalidatePath('/fees/reminders');
  return { error: null };
}

export async function toggleRule(ruleId: string, active: boolean): Promise<{ error: string | null }> {
  if (!idSchema.safeParse(ruleId).success) return { error: 'Invalid rule.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_fee_reminder_rule_active', { p_rule_id: ruleId, p_active: active });
  if (error) return { error: 'Could not update the rule.' };
  revalidatePath('/fees/reminders');
  return { error: null };
}
