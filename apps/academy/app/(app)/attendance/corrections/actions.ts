'use server';

import { revalidatePath } from 'next/cache';
import { decideAttendanceCorrectionSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type DecideCorrectionState = { error: string | null };

async function decide(command: 'approve' | 'reject', formData: FormData): Promise<DecideCorrectionState> {
  const parsed = decideAttendanceCorrectionSchema.safeParse({
    correctionId: formData.get('correctionId'),
    note: formData.get('note'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } =
    command === 'approve'
      ? await supabase.rpc('approve_attendance_correction', { p_correction_id: parsed.data.correctionId, p_note: parsed.data.note })
      : await supabase.rpc('reject_attendance_correction', { p_correction_id: parsed.data.correctionId, p_note: parsed.data.note });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'Only an Owner or Principal can decide correction requests.' };
    if (error.message.includes('CORRECTION_NOT_PENDING')) return { error: 'This request has already been decided.' };
    if (error.message.includes('CORRECTION_NOT_FOUND')) return { error: 'Request not found.' };
    if (error.message.includes('ATTENDANCE_DAY_NOT_FOUND')) return { error: 'The original attendance record no longer exists.' };
    return { error: `Could not ${command} this request.` };
  }

  revalidatePath('/attendance/corrections');
  return { error: null };
}

// FR-G11: approve_attendance_correction() writes attendance_day and
// exactly one attendance_audit row in the same transaction — this
// action only shapes the client-facing error.
export async function approveAttendanceCorrection(_prev: DecideCorrectionState, formData: FormData): Promise<DecideCorrectionState> {
  return decide('approve', formData);
}

export async function rejectAttendanceCorrection(_prev: DecideCorrectionState, formData: FormData): Promise<DecideCorrectionState> {
  return decide('reject', formData);
}
