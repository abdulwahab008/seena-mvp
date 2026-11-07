'use server';

import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { kickMessageWorker } from '@/lib/comm/kick';

export async function remindOverdue(campusId: string): Promise<{ error: string | null; queued?: number; noPhone?: number }> {
  if (!z.string().uuid().safeParse(campusId).success) return { error: 'Choose a campus.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('queue_library_overdue_messages', { p_campus_id: campusId });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'Only the librarian or Principal can send reminders.' : 'Something went wrong. Try again.' };
  const r = data as { queued: number; no_phone: number };
  if (r.queued > 0) await kickMessageWorker();
  return { error: null, queued: r.queued, noPhone: r.no_phone };
}
