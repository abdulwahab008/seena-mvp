'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

export type QueueState = { error: string | null; queued: number | null };

async function runQueueRpc(rpcName: 'fn_queue_followup_reminders' | 'fn_queue_appointment_reminders' | 'fn_process_sms_fallbacks'): Promise<QueueState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc(rpcName);
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to run the reminder queue.', queued: null };
    return { error: 'Could not run the reminder queue.', queued: null };
  }
  revalidatePath('/admissions/reminders');
  return { error: null, queued: data as number };
}

// FR-B05: these stand in for the "*/5 * * * *" cron this environment has
// no pg_cron to run — an officer triggers the same queueing logic
// manually. The dedupe key makes repeated runs safe either way.
export async function queueFollowupReminders(): Promise<QueueState> {
  return runQueueRpc('fn_queue_followup_reminders');
}

export async function queueAppointmentReminders(): Promise<QueueState> {
  return runQueueRpc('fn_queue_appointment_reminders');
}

export async function processSmsFallbacks(): Promise<QueueState> {
  return runQueueRpc('fn_process_sms_fallbacks');
}

export async function markMessageFailed(messageId: string, failureCode: string): Promise<{ error: string | null }> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('mark_outbound_message_failed', { p_message_id: messageId, p_failure_code: failureCode });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to update this message.' };
    return { error: 'Could not mark the message failed.' };
  }
  revalidatePath('/admissions/reminders');
  return { error: null };
}
