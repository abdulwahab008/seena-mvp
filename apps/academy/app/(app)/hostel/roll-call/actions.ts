'use server';

import { z } from 'zod';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { ROLL_SESSIONS, ROLL_STATUSES } from './statuses';

const schema = z.object({
  campusId: z.string().uuid(),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  session: z.enum(ROLL_SESSIONS),
  rows: z.array(z.object({ student_id: z.string().uuid(), status: z.enum(ROLL_STATUSES) })).min(1),
});

export async function saveRollCall(input: z.input<typeof schema>): Promise<{ error: string | null; saved?: number }> {
  const parsed = schema.safeParse(input);
  if (!parsed.success) return { error: 'Nothing to save.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('mark_hostel_roll_call', {
    p_campus_id: parsed.data.campusId,
    p_date: parsed.data.date,
    p_session: parsed.data.session,
    p_rows: parsed.data.rows,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'Only the warden or the Principal can mark roll call.' };
    if (error.message.includes('FUTURE_DATE')) return { error: 'Roll call cannot be marked for a future date.' };
    return { error: 'Could not save roll call. Try again.' };
  }
  revalidatePath('/hostel/roll-call');
  return { error: null, saved: data };
}
