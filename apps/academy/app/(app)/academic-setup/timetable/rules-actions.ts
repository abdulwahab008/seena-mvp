'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { timetableRulesSchema } from '@/lib/validation';
import { loose, parseValues, rpcError, type ActionResult } from '@/lib/transport/rpc';

export async function saveTimetableRules(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(timetableRulesSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const rules: [string, number | null, boolean][] = [
    ['max_periods_per_day', p.data.maxPerDay, true],
    ['max_consecutive_periods', p.data.maxConsecutive, true],
    ['flag_isolated_free_period', null, p.data.flagIsolated === 'yes'],
  ];
  for (const [key, value, enabled] of rules) {
    const { error } = await supabase.rpc('set_timetable_constraint', { p_campus_id: p.data.campusId, p_key: key, p_int_value: value, p_is_enabled: enabled });
    if (error) return { error: rpcError(error.message) };
  }
  revalidatePath('/academic-setup/timetable');
  return { error: null, message: 'Timetable rules saved.' };
}
