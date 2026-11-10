'use server';

import { z } from 'zod';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { STAFF_STATUSES } from './statuses';


const schema = z.object({
  campusId: z.string().uuid(),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  rows: z.array(z.object({ staff_id: z.string().uuid(), status: z.enum(STAFF_STATUSES) })).min(1),
});

export async function saveStaffAttendance(input: z.input<typeof schema>): Promise<{ error: string | null; written?: number; locked?: number }> {
  const parsed = schema.safeParse(input);
  if (!parsed.success) return { error: 'Mark at least one staff member.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('mark_staff_attendance_bulk', {
    p_campus_id: parsed.data.campusId,
    p_date: parsed.data.date,
    p_rows: parsed.data.rows,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'Only HR, the Principal or the Owner can mark staff attendance.' };
    if (error.message.includes('CORRECTION_WINDOW_EXPIRED')) return { error: 'HR can only correct the last 7 days. Ask the Principal.' };
    return { error: 'Could not save attendance. Try again.' };
  }
  const result = data as { written: number; locked_staff_ids: string[] };
  revalidatePath('/attendance/staff');
  return { error: null, written: result.written, locked: result.locked_staff_ids.length };
}
