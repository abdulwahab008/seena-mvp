'use server';

import { z } from 'zod';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

const schema = z.object({ id: z.string().uuid(), approve: z.boolean(), note: z.string().trim().max(500).optional() });

export async function decideStudentLeave(input: z.input<typeof schema>): Promise<{ error: string | null }> {
  const parsed = schema.safeParse(input);
  if (!parsed.success) return { error: 'Keep the note under 500 characters.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('decide_student_leave', { p_leave_id: parsed.data.id, p_approve: parsed.data.approve, p_note: parsed.data.note || undefined });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You cannot decide leave requests.' };
    if (error.message.includes('LEAVE_NOT_PENDING')) return { error: 'This request was already decided or cancelled.' };
    return { error: 'Could not save the decision. Try again.' };
  }
  revalidatePath('/attendance/student-leaves');
  return { error: null };
}
