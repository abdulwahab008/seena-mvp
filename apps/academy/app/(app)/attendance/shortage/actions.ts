'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { closeShortageSchema, type CloseShortageInput } from '@/lib/validation';

const resultSchema = z.object({ raised: z.number(), escalated: z.number(), recovered: z.number(), skipped: z.number() });

function mapError(message: string): string {
  if (message.includes('FORBIDDEN')) return 'You do not have permission for this step.';
  if (message.includes('WARNING_NOT_FOUND')) return 'That warning is already closed.';
  if (message.includes('REASON_MIN_LENGTH_10')) return 'Give a reason of at least 10 characters.';
  return 'Something went wrong. Please try again.';
}

export async function runEvaluation(): Promise<{ error: string | null; summary?: string }> {
  const supabase = await supabaseServer();
  const [{ data: campuses }, { data: sessions }] = await Promise.all([
    supabase.from('campus').select('id').eq('status', 'active'),
    supabase.from('academic_session').select('id').eq('status', 'active'),
  ]);
  const total = { raised: 0, escalated: 0, recovered: 0, skipped: 0 };
  for (const c of campuses ?? []) {
    for (const s of sessions ?? []) {
      const { data, error } = await supabase.rpc('evaluate_attendance_shortage', { p_campus_id: c.id, p_session_id: s.id });
      if (error) return { error: mapError(error.message) };
      const r = resultSchema.safeParse(data);
      if (r.success) for (const k of Object.keys(total) as (keyof typeof total)[]) total[k] += r.data[k];
    }
  }
  revalidatePath('/attendance/shortage');
  return { error: null, summary: `${total.raised} raised, ${total.escalated} escalated, ${total.recovered} recovered, ${total.skipped} skipped for too little data.` };
}

export async function closeWarning(input: CloseShortageInput): Promise<{ error: string | null }> {
  const p = closeShortageSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('close_shortage_warning', { p_warning_id: p.data.warningId, p_reason: p.data.reason });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/attendance/shortage');
  return { error: null };
}
