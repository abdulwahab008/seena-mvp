'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { schemeThresholdSchema, type SchemeThresholdInput } from '@/lib/validation';

type Result = { error: string | null };
const refreshResultSchema = z.object({ evaluated: z.number(), flipped: z.number(), tasks: z.number() });

function mapError(message: string): string {
  if (message.includes('FORBIDDEN')) return 'You do not have permission for this step.';
  if (message.includes('TASK_NOT_FOUND')) return 'That task is already resolved.';
  if (message.includes('PERCENTAGE_OUT_OF_RANGE')) return 'The percentage must be above 0 and at most 100.';
  return 'Something went wrong. Please try again.';
}

export async function setSchemeThreshold(input: SchemeThresholdInput): Promise<Result> {
  const p = schemeThresholdSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_scheme_min_attendance', { p_scheme_id: p.data.schemeId, p_min_pct: p.data.minPct ?? undefined });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/fees/attendance-concessions');
  return { error: null };
}

export async function refreshEligibility(): Promise<{ error: string | null; summary?: string }> {
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active');
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
  const year = Number(today.slice(0, 4));
  const month = Number(today.slice(5, 7));
  let evaluated = 0;
  let tasks = 0;
  for (const c of campuses ?? []) {
    const { data, error } = await supabase.rpc('refresh_attendance_eligibility', { p_campus_id: c.id, p_year: year, p_month: month });
    if (error) return { error: mapError(error.message) };
    const r = refreshResultSchema.parse(data);
    evaluated += r.evaluated;
    tasks += r.tasks;
  }
  revalidatePath('/fees/attendance-concessions');
  return { error: null, summary: `${evaluated} awards evaluated, ${tasks} adjustment tasks raised.` };
}

export async function resolveAdjustment(taskId: string, note: string): Promise<Result> {
  if (!z.string().uuid().safeParse(taskId).success) return { error: 'Invalid task.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('resolve_eligibility_adjustment', { p_task_id: taskId, p_note: note.trim().slice(0, 300) || undefined });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/fees/attendance-concessions');
  return { error: null };
}
