import { supabaseServer } from '@/lib/supabase/server';
import { CorrectionsList, type CorrectionRow } from './corrections-list';

function one<T>(v: T | T[] | null): T | null {
  return Array.isArray(v) ? (v[0] ?? null) : v;
}

export default async function AttendanceCorrectionsPage() {
  const supabase = await supabaseServer();

  const { data: rows } = await supabase
    .from('attendance_correction_request')
    .select('id, attendance_date, old_status, new_status, reason, status, requested_at, enrolment(student(name_en, gr_number))')
    .order('requested_at', { ascending: false });

  const corrections: CorrectionRow[] = (rows ?? []).map((r) => ({
    id: r.id,
    studentName: one(one(r.enrolment)?.student)?.name_en ?? 'Unknown',
    grNumber: one(one(r.enrolment)?.student)?.gr_number ?? '',
    attendanceDate: r.attendance_date,
    oldStatus: r.old_status,
    newStatus: r.new_status,
    reason: r.reason,
    status: r.status,
  }));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Attendance Corrections</h1>
        <p className="text-sm text-muted-foreground">
          FR-G11 — approve or reject a class teacher&apos;s request to change an already-locked day. Every approval is permanently audited.
        </p>
      </div>
      <CorrectionsList corrections={corrections} />
    </div>
  );
}
