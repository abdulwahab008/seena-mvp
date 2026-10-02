'use server';

import { revalidatePath } from 'next/cache';
import { setAttendancePolicySchema, setAttendanceStatusWeightSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

// FR-G01: every save inserts a new effective-dated row — set_attendance_
// policy() never updates one in place, so a past date always still
// resolves whichever policy actually governed it.
export async function setAttendancePolicy(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = setAttendancePolicySchema.safeParse({
    campusId: formData.get('campusId'),
    sessionId: formData.get('sessionId'),
    mode: formData.get('mode'),
    startTime: formData.get('startTime'),
    lateThresholdMinutes: formData.get('lateThresholdMinutes'),
    halfDayCutoffTime: formData.get('halfDayCutoffTime') || undefined,
    lockWindowHours: formData.get('lockWindowHours'),
    minAttendancePct: formData.get('minAttendancePct') || undefined,
    saturdayWorking: formData.get('saturdayWorking') === 'true',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_attendance_policy', {
    p_campus_id: parsed.data.campusId,
    p_session_id: parsed.data.sessionId,
    p_mode: parsed.data.mode,
    p_start_time: parsed.data.startTime,
    p_late_threshold_minutes: parsed.data.lateThresholdMinutes,
    p_half_day_cutoff_time: parsed.data.halfDayCutoffTime || undefined,
    p_lock_window_hours: parsed.data.lockWindowHours,
    p_min_attendance_pct: parsed.data.minAttendancePct,
    p_saturday_working: parsed.data.saturdayWorking,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to configure the attendance policy.' };
    if (error.message.includes('CAMPUS_NOT_FOUND')) return { error: 'Campus not found.' };
    if (error.message.includes('SESSION_NOT_FOUND')) return { error: 'Session not found.' };
    return { error: 'Could not save the attendance policy.' };
  }

  revalidatePath('/academic-setup/attendance-policy');
  return { error: null };
}

// FR-G06: an unconfigured status keeps attendance_weight()'s own
// built-in default (present=1, late=1, half_day=0.5, else 0) — this
// action only arms an explicit override.
export async function setAttendanceStatusWeight(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = setAttendanceStatusWeightSchema.safeParse({
    campusId: formData.get('campusId'),
    sessionId: formData.get('sessionId'),
    status: formData.get('status'),
    weight: formData.get('weight'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_attendance_status_weight', {
    p_campus_id: parsed.data.campusId,
    p_session_id: parsed.data.sessionId,
    p_status: parsed.data.status,
    p_weight: parsed.data.weight,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to configure attendance status weights.' };
    if (error.message.includes('WEIGHT_OUT_OF_RANGE')) return { error: 'Weight must be between 0 and 1.' };
    return { error: 'Could not save the status weight.' };
  }

  revalidatePath('/academic-setup/attendance-policy');
  return { error: null };
}

export async function previewAttendanceStatus(
  campusId: string,
  sessionId: string,
  markedTime: string
): Promise<{ error: string | null; status: string | null }> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('resolve_attendance_status', {
    p_campus_id: campusId,
    p_session_id: sessionId,
    p_marked_time: markedTime,
  });
  if (error) return { error: 'Could not resolve attendance status.', status: null };
  return { error: null, status: data };
}
