'use server';

import { bulkMarkAttendanceSchema, requestAttendanceCorrectionSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type RosterStudent = { enrolmentId: string; name: string; grNumber: string; currentStatus: string | null };
export type LoadRegisterState = {
  error: string | null;
  holiday: string | null;
  students: RosterStudent[];
  locked: boolean;
  lockedAt: string | null;
};

// FR-G02: loads the holiday state and the active roster (with any
// already-saved marks for that date pre-filled) for one section/date —
// a fresh server round trip on every section/date change, same as the
// "Check checklist" on-demand pattern (FR-B09) rather than a client
// cache that could drift from what save_attendance_register() would
// actually see.
// FR-G09: also resolves the lock state (AC3) — computed live even if
// nothing has swept/manually locked this date yet.
export async function loadRegisterRoster(
  campusId: string,
  sectionId: string,
  attendanceDate: string
): Promise<LoadRegisterState> {
  const supabase = await supabaseServer();

  const [{ data: holiday }, { data: lockInfo }] = await Promise.all([
    supabase.rpc('resolve_attendance_holiday', { p_campus_id: campusId, p_date: attendanceDate }),
    supabase.rpc('resolve_attendance_lock_info', { p_section_id: sectionId, p_date: attendanceDate }),
  ]);

  const [{ data: enrolments }, { data: marks }] = await Promise.all([
    supabase
      .from('enrolment')
      .select('id, student(name_en, gr_number, status)')
      .eq('section_id', sectionId)
      .eq('status', 'active'),
    supabase.from('attendance_day').select('enrolment_id, status').eq('section_id', sectionId).eq('attendance_date', attendanceDate),
  ]);

  const statusByEnrolment = new Map((marks ?? []).map((m) => [m.enrolment_id, m.status]));
  const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

  const students: RosterStudent[] = (enrolments ?? [])
    .filter((e) => one(e.student)?.status === 'active')
    .map((e) => ({
      enrolmentId: e.id,
      name: one(e.student)?.name_en ?? 'Unknown',
      grNumber: one(e.student)?.gr_number ?? '',
      currentStatus: statusByEnrolment.get(e.id) ?? null,
    }));

  const lock = lockInfo as { locked: boolean; locked_at?: string | null } | null;
  return { error: null, holiday: holiday ?? null, students, locked: lock?.locked ?? false, lockedAt: lock?.locked_at ?? null };
}

export type LockAttendanceNowState = { error: string | null };

// FR-G09 AC3: a Principal can force an early lock ahead of the
// window elapsing — lock_attendance_now() itself enforces the role.
export async function lockAttendanceNow(sectionId: string, attendanceDate: string): Promise<LockAttendanceNowState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('lock_attendance_now', { p_section_id: sectionId, p_date: attendanceDate });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'Only an Owner or Principal can lock a register early.' };
    if (error.message.includes('SECTION_NOT_FOUND')) return { error: 'Section not found.' };
    return { error: 'Could not lock this date.' };
  }
  return { error: null };
}

export type SaveRegisterState = { error: string | null; saved: number | null };

// FR-G04: everyone active defaults to present server-side — only
// exceptions are ever sent over the wire, so a zero-touch submit (the
// common case) is a small, fixed-size payload regardless of section size.
export async function bulkMarkAttendance(_prev: SaveRegisterState, formData: FormData): Promise<SaveRegisterState> {
  const exceptionsRaw = formData.get('exceptions');
  let exceptions: unknown;
  try {
    exceptions = JSON.parse(String(exceptionsRaw));
  } catch {
    return { error: 'Invalid input.', saved: null };
  }

  const parsed = bulkMarkAttendanceSchema.safeParse({
    sectionId: formData.get('sectionId'),
    attendanceDate: formData.get('attendanceDate'),
    exceptions,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', saved: null };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('rpc_bulk_mark_attendance', {
    p_section_id: parsed.data.sectionId,
    p_date: parsed.data.attendanceDate,
    p_exceptions: parsed.data.exceptions.map((m) => ({ enrolment_id: m.enrolmentId, status: m.status })),
  });
  if (error) {
    if (error.message.startsWith('HOLIDAY:')) return { error: `This is a declared holiday (${error.message.split(':')[1]}).`, saved: null };
    if (error.message.includes('ATT_LOCKED')) return { error: 'This date is locked and can no longer be edited.', saved: null };
    if (error.message.includes('POLICY_NOT_CONFIGURED'))
      return { error: 'Attendance policy not configured for this session — contact your Principal.', saved: null };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to mark this section.', saved: null };
    if (error.message.includes('SECTION_NOT_FOUND')) return { error: 'Section not found.', saved: null };
    return { error: 'Could not save the register.', saved: null };
  }

  return { error: null, saved: (data as { saved: number } | null)?.saved ?? null };
}

export type RequestCorrectionState = { error: string | null };

// FR-G11: the only way to change a locked date — request_attendance_
// correction() itself never checks is_attendance_locked().
export async function requestAttendanceCorrection(_prev: RequestCorrectionState, formData: FormData): Promise<RequestCorrectionState> {
  const parsed = requestAttendanceCorrectionSchema.safeParse({
    enrolmentId: formData.get('enrolmentId'),
    attendanceDate: formData.get('attendanceDate'),
    newStatus: formData.get('newStatus'),
    reason: formData.get('reason'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('request_attendance_correction', {
    p_enrolment_id: parsed.data.enrolmentId,
    p_attendance_date: parsed.data.attendanceDate,
    p_new_status: parsed.data.newStatus,
    p_reason: parsed.data.reason,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to request a correction for this section.' };
    if (error.message.includes('ENROLMENT_NOT_FOUND')) return { error: 'Student not found.' };
    return { error: 'Could not submit the correction request.' };
  }

  return { error: null };
}
