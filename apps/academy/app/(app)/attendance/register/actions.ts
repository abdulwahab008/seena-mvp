'use server';

import { saveAttendanceRegisterSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type RosterStudent = { enrolmentId: string; name: string; grNumber: string; currentStatus: string | null };
export type LoadRegisterState = {
  error: string | null;
  holiday: string | null;
  students: RosterStudent[];
};

// FR-G02: loads the holiday state and the active roster (with any
// already-saved marks for that date pre-filled) for one section/date —
// a fresh server round trip on every section/date change, same as the
// "Check checklist" on-demand pattern (FR-B09) rather than a client
// cache that could drift from what save_attendance_register() would
// actually see.
export async function loadRegisterRoster(
  campusId: string,
  sectionId: string,
  attendanceDate: string
): Promise<LoadRegisterState> {
  const supabase = await supabaseServer();

  const { data: holiday } = await supabase.rpc('resolve_attendance_holiday', { p_campus_id: campusId, p_date: attendanceDate });

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

  return { error: null, holiday: holiday ?? null, students };
}

export type SaveRegisterState = { error: string | null; saved: number | null };

export async function saveAttendanceRegister(_prev: SaveRegisterState, formData: FormData): Promise<SaveRegisterState> {
  const marksRaw = formData.get('marks');
  let marks: unknown;
  try {
    marks = JSON.parse(String(marksRaw));
  } catch {
    return { error: 'Invalid input.', saved: null };
  }

  const parsed = saveAttendanceRegisterSchema.safeParse({
    sectionId: formData.get('sectionId'),
    attendanceDate: formData.get('attendanceDate'),
    marks,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', saved: null };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('save_attendance_register', {
    p_section_id: parsed.data.sectionId,
    p_attendance_date: parsed.data.attendanceDate,
    p_marks: parsed.data.marks.map((m) => ({ enrolment_id: m.enrolmentId, status: m.status })),
  });
  if (error) {
    if (error.message.startsWith('HOLIDAY:')) return { error: `This is a declared holiday (${error.message.split(':')[1]}).`, saved: null };
    if (error.message.includes('ATTENDANCE_LOCKED')) return { error: 'This date is locked and can no longer be edited.', saved: null };
    if (error.message.includes('POLICY_NOT_CONFIGURED'))
      return { error: 'Attendance policy not configured for this session — contact your Principal.', saved: null };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to mark this section.', saved: null };
    if (error.message.includes('SECTION_NOT_FOUND')) return { error: 'Section not found.', saved: null };
    return { error: 'Could not save the register.', saved: null };
  }

  return { error: null, saved: (data as { saved: number } | null)?.saved ?? null };
}
