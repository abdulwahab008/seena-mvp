'use server';

import { z } from 'zod';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import type { SpecResult } from '@/components/spec-form';

const schema = z.object({
  studentId: z.string().uuid('Choose your child.'),
  kind: z.enum(['start', 'stop', 'change_route', 'change_stop'], { message: 'Choose what you need.' }),
  note: z.string().trim().max(300, 'At most 300 characters').optional(),
});

export async function requestTransportChange(values: Record<string, string>): Promise<SpecResult> {
  const parsed = schema.safeParse(values);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('submit_transport_request', {
    p_student_id: parsed.data.studentId,
    p_kind: parsed.data.kind,
    p_note: parsed.data.note || undefined,
  });
  if (error) {
    if (error.message.includes('REQUEST_PENDING')) return { error: 'You already have a request waiting for this child.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You cannot make this request.' };
    return { error: 'Could not send the request. Try again.' };
  }
  revalidatePath('/portal/transport');
  return { error: null, message: 'Request sent.' };
}
