'use server';

import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

export async function sendResultMessages(termId: string, sectionId: string): Promise<{ error: string | null; queued?: number; noPhone?: number }> {
  const p = z.object({ termId: z.string().uuid(), sectionId: z.string().uuid() }).safeParse({ termId, sectionId });
  if (!p.success) return { error: 'Choose a section and term.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('queue_result_messages', { p_exam_term_id: p.data.termId, p_section_id: p.data.sectionId });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'Only the exam controller or Principal can send results.' : 'Something went wrong. Try again.' };
  const r = data as { queued: number; no_phone: number };
  return { error: null, queued: r.queued, noPhone: r.no_phone };
}
