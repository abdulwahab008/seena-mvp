'use server';

import { supabaseServer } from '@/lib/supabase/server';

export type UnmarkedSection = {
  sectionId: string;
  sectionLabel: string;
  classTeacherName: string;
  enrolledCount: number;
  markedCount: number;
  status: string;
};
export type RunCheckState = {
  error: string | null;
  skipped: boolean;
  holidayReason: string | null;
  sections: UnmarkedSection[];
};

// FR-G13: run_unmarked_attendance_check() is itself the idempotency
// boundary (attendance_gap_log) — a re-run for a date already checked
// simply returns an empty section list, so this action has nothing extra
// to gate.
export async function runUnmarkedAttendanceCheck(campusId: string, date: string): Promise<RunCheckState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('run_unmarked_attendance_check', { p_campus_id: campusId, p_date: date });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to run this check.', skipped: false, holidayReason: null, sections: [] };
    if (error.message.includes('CAMPUS_NOT_FOUND')) return { error: 'Campus not found.', skipped: false, holidayReason: null, sections: [] };
    return { error: 'Could not run the unmarked-attendance check.', skipped: false, holidayReason: null, sections: [] };
  }

  const result = data as { skipped: boolean; reason?: string; sections: Array<Record<string, unknown>> };
  return {
    error: null,
    skipped: result.skipped,
    holidayReason: result.reason ?? null,
    sections: result.sections.map((s) => ({
      sectionId: s.section_id as string,
      sectionLabel: s.section_label as string,
      classTeacherName: s.class_teacher_name as string,
      enrolledCount: s.enrolled_count as number,
      markedCount: s.marked_count as number,
      status: s.status as string,
    })),
  };
}
