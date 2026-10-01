'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { periodAttendanceSchema, type PeriodAttendanceInput } from '@/lib/validation';

function mapError(message: string): string {
  const known: [string, string][] = [
    ['NOT_ASSIGNED_TO_THIS_PERIOD', 'You are not assigned to this period.'],
    ['CAMPUS_NOT_IN_PERIOD_MODE', 'This campus takes attendance daily, not by period.'],
    ['TIMETABLE_NOT_PUBLISHED', 'The timetable for this period is not published.'],
    ['DATE_IN_FUTURE', 'You cannot mark attendance for a future date.'],
    ['DATE_NOT_ON_SLOT_WEEKDAY', 'This period does not run on that weekday.'],
    ['HOLIDAY', 'That day is a holiday.'],
    ['ATTENDANCE_LOCKED', 'Attendance for that day is locked.'],
    ['STUDENT_NOT_ON_THIS_ROSTER', 'A student in the list is not part of this class group.'],
  ];
  return known.find(([k]) => message.includes(k))?.[1] ?? 'Something went wrong. Please try again.';
}

export async function savePeriodAttendance(input: PeriodAttendanceInput): Promise<{ error: string | null }> {
  const p = periodAttendanceSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_period_attendance', {
    p_slot_id: p.data.slotId,
    p_date: p.data.date,
    p_marks: p.data.marks.map((m) => ({ enrolment_id: m.enrolmentId, status: m.status })),
  });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/attendance/periods');
  return { error: null };
}
