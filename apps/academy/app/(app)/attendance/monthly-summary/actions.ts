'use server';

import { recomputeMonthlyAttendanceSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type SummaryRow = {
  enrolmentId: string;
  name: string;
  grNumber: string;
  workingDays: number;
  presentDays: number;
  absentDays: number;
  lateCount: number;
  halfDayCount: number;
  leaveDays: number;
  attendancePct: number | null;
  stale: boolean;
  recomputedAt: string | null;
};
export type LoadSummaryState = { error: string | null; rows: SummaryRow[] };

// FR-G14: attendance_month_summary carries no section_id of its own —
// it's keyed by enrolment, campus, year, month — so the section's
// roster is resolved first and the summary rows joined in by
// enrolment_id, the same two-query-then-merge shape loadRegisterRoster()
// (FR-G02) already uses for the identical reason.
export async function loadMonthlySummary(sectionId: string, year: number, month: number): Promise<LoadSummaryState> {
  const supabase = await supabaseServer();

  const { data: enrolments } = await supabase.from('enrolment').select('id, student(name_en, gr_number)').eq('section_id', sectionId);
  const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);
  const enrolmentIds = (enrolments ?? []).map((e) => e.id);

  if (enrolmentIds.length === 0) return { error: null, rows: [] };

  const { data: summaries } = await supabase
    .from('attendance_month_summary')
    .select('enrolment_id, working_days, present_days, absent_days, late_count, half_day_count, leave_days, attendance_pct, stale, recomputed_at')
    .eq('year', year)
    .eq('month', month)
    .in('enrolment_id', enrolmentIds);

  const summaryByEnrolment = new Map((summaries ?? []).map((s) => [s.enrolment_id, s]));

  const rows: SummaryRow[] = (enrolments ?? [])
    .map((e) => {
      const s = summaryByEnrolment.get(e.id);
      if (!s) return null;
      return {
        enrolmentId: e.id,
        name: one(e.student)?.name_en ?? 'Unknown',
        grNumber: one(e.student)?.gr_number ?? '',
        workingDays: s.working_days,
        presentDays: Number(s.present_days),
        absentDays: s.absent_days,
        lateCount: s.late_count,
        halfDayCount: s.half_day_count,
        leaveDays: s.leave_days,
        attendancePct: s.attendance_pct === null ? null : Number(s.attendance_pct),
        stale: s.stale,
        recomputedAt: s.recomputed_at,
      };
    })
    .filter((r): r is SummaryRow => r !== null);

  return { error: null, rows };
}

export type RecomputeMonthlyAttendanceState = { error: string | null; count: number | null };

// FR-G14: compute_month_attendance() itself enforces the Owner/Principal
// role — there's no pg_cron locally to schedule the daily run this would
// eventually get, same as every other "System"-actor function this
// session has built without wiring a real schedule.
export async function recomputeMonthlyAttendance(
  _prev: RecomputeMonthlyAttendanceState,
  formData: FormData
): Promise<RecomputeMonthlyAttendanceState> {
  const parsed = recomputeMonthlyAttendanceSchema.safeParse({
    campusId: formData.get('campusId'),
    year: formData.get('year'),
    month: formData.get('month'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', count: null };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('compute_month_attendance', {
    p_campus_id: parsed.data.campusId,
    p_year: parsed.data.year,
    p_month: parsed.data.month,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'Only an Owner or Principal can recompute monthly attendance.', count: null };
    if (error.message.includes('CAMPUS_NOT_FOUND')) return { error: 'Campus not found.', count: null };
    return { error: 'Could not recompute the monthly summary.', count: null };
  }

  return { error: null, count: data as number };
}
