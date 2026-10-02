'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { notifyNonSubmittersSchema, type NotifyNonSubmittersInput } from '@/lib/validation';

export type NonSubmitter = { enrolmentId: string; name: string; grNumber: string; guardianName: string | null; guardianPhone: string | null; onLeave: boolean; notifiedToday: boolean };
export type LoadResult = { error: string | null; rows: NonSubmitter[] };
export type NotifyResult = { error: string | null; summary?: string };

export async function loadNonSubmitters(homeworkId: string): Promise<LoadResult> {
  if (!z.string().uuid().safeParse(homeworkId).success) return { error: 'Invalid assignment.', rows: [] };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('homework_non_submitters', { p_homework_id: homeworkId });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'You are not assigned to this section and subject.' : 'Could not load the list.', rows: [] };
  return {
    error: null,
    rows: (data ?? []).map((r) => ({
      enrolmentId: r.enrolment_id,
      name: r.student_name,
      grNumber: r.gr_number,
      guardianName: r.guardian_name,
      guardianPhone: r.guardian_phone,
      onLeave: r.on_leave,
      notifiedToday: r.notified_today,
    })),
  };
}

export async function notifyNonSubmitters(input: NotifyNonSubmittersInput): Promise<NotifyResult> {
  const p = notifyNonSubmittersSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('notify_non_submitters', { p_homework_id: p.data.homeworkId, p_enrolment_ids: p.data.enrolmentIds, p_include_on_leave: p.data.includeOnLeave });
  if (error) {
    if (error.message.includes('NOT_YET_DUE')) return { error: 'Parents can be notified only after the due date has passed.' };
    if (error.message.includes('DAILY_CAP_REACHED')) return { error: 'Today\'s limit of homework messages for this campus has been reached.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You are not assigned to this section and subject.' };
    return { error: 'Could not send the notifications.' };
  }
  const r = z.object({ queued: z.number(), duplicates: z.number(), no_phone: z.number(), on_leave: z.number() }).parse(data);
  revalidatePath('/homework');
  return { error: null, summary: `${r.queued} queued, ${r.duplicates} already notified today, ${r.no_phone} without a phone number, ${r.on_leave} on leave left out.` };
}
