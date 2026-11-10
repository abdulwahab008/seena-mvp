'use server';

import { z } from 'zod';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

const schema = z.object({ id: z.string().uuid(), approve: z.boolean(), note: z.string().trim().max(300).optional() });

export async function decideTransportRequest(input: z.input<typeof schema>): Promise<{ error: string | null }> {
  const parsed = schema.safeParse(input);
  if (!parsed.success) return { error: 'Keep the note under 300 characters.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('decide_transport_request', { p_request_id: parsed.data.id, p_approve: parsed.data.approve, p_note: parsed.data.note || undefined });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'Only the transport office can decide bus requests.' };
    if (error.message.includes('REQUEST_NOT_PENDING')) return { error: 'This request was already decided.' };
    return { error: 'Could not save the decision. Try again.' };
  }
  revalidatePath('/transport/requests');
  return { error: null };
}
