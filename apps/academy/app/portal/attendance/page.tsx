import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';

/**
 * FR-N03: Child attendance view for parents/guardians.
 *
 * Allows parents with one or more children to view daily attendance, monthly summary,
 * and overall session attendance percentage.
 */

type SearchParams = {
  enrolment?: string;
  month?: string; // YYYY-MM format
};

type Child = {
  enrolmentId: string;
  studentId: string;
  studentName: string;
  sectionLabel: string;
};

type AttendanceRecord = {
  id: string;
  attendance_date: string;
  status: 'present' | 'absent' | 'late' | 'half_day' | 'excused';
  arrival_time: string | null;
  departure_time: string | null;
  corrected: boolean;
};

const STATUS_CONFIG: Record<
  string,
  { label: string; badgeClass: string; dotClass: string }
> = {
  present: {
    label: 'Present',
    badgeClass: 'bg-emerald-100 text-emerald-800 border-emerald-200 dark:bg-emerald-950/40 dark:text-emerald-400 dark:border-emerald-800',
    dotClass: 'bg-emerald-500',
  },
  absent: {
    label: 'Absent',
    badgeClass: 'bg-rose-100 text-rose-800 border-rose-200 dark:bg-rose-950/40 dark:text-rose-400 dark:border-rose-800',
    dotClass: 'bg-rose-500',
  },
  late: {
    label: 'Late',
    badgeClass: 'bg-amber-100 text-amber-800 border-amber-200 dark:bg-amber-950/40 dark:text-amber-400 dark:border-amber-800',
    dotClass: 'bg-amber-500',
  },
  half_day: {
    label: 'Half Day',
    badgeClass: 'bg-orange-100 text-orange-800 border-orange-200 dark:bg-orange-950/40 dark:text-orange-400 dark:border-orange-800',
    dotClass: 'bg-orange-500',
  },
  excused: {
    label: 'Excused',
    badgeClass: 'bg-sky-100 text-sky-800 border-sky-200 dark:bg-sky-950/40 dark:text-sky-400 dark:border-sky-800',
    dotClass: 'bg-sky-500',
  },
};

export default async function PortalAttendancePage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const params = await searchParams;
  const supabase = await supabaseServer();

  // 1. Fetch children for the signed-in guardian
  const { data: enrolments } = await supabase
    .from('enrolment')
    .select('id, student_id, student:student_id(id, name_en), class_section:section_id(name, class_level(name_en))')
    .eq('status', 'active');

  const children: Child[] = (enrolments ?? [])
    .map((e) => {
      const student = Array.isArray(e.student) ? e.student[0] : e.student;
      const section = Array.isArray(e.class_section) ? e.class_section[0] : e.class_section;
      const level = section ? (Array.isArray(section.class_level) ? section.class_level[0] : section.class_level) : null;
      if (!student || !section) return null;
      return {
        enrolmentId: e.id,
        studentId: student.id,
        studentName: student.name_en,
        sectionLabel: `${level?.name_en ?? ''} · ${section.name}`,
      };
    })
    .filter((c): c is Child => !!c);

  const child = children.find((c) => c.enrolmentId === params.enrolment) ?? children[0];

  // 2. Determine target month (defaults to current month or latest available attendance)
  const now = new Date();
  const defaultYearMonth = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
  const selectedMonth = params.month ?? defaultYearMonth;

  const [yearStr, monthStr] = selectedMonth.split('-');
  const year = parseInt(yearStr || '', 10) || now.getFullYear();
  const month = parseInt(monthStr || '', 10) || now.getMonth() + 1;

  const monthStart = `${year}-${String(month).padStart(2, '0')}-01`;
  const nextMonthDate = new Date(year, month, 1);
  const nextMonthYear = nextMonthDate.getFullYear();
  const nextMonthNum = nextMonthDate.getMonth() + 1;
  const monthEnd = `${nextMonthYear}-${String(nextMonthNum).padStart(2, '0')}-01`;

  // 3. Fetch attendance for the selected child for the whole session and for this month
  let records: AttendanceRecord[] = [];
  let allSessionRecords: AttendanceRecord[] = [];

  if (child) {
    const { data: monthData } = await supabase
      .from('attendance_day')
      .select('id, attendance_date, status, arrival_time, departure_time, corrected')
      .eq('enrolment_id', child.enrolmentId)
      .gte('attendance_date', monthStart)
      .lt('attendance_date', monthEnd)
      .order('attendance_date', { ascending: false });

    records = (monthData ?? []) as AttendanceRecord[];

    const { data: sessionData } = await supabase
      .from('attendance_day')
      .select('id, attendance_date, status, arrival_time, departure_time, corrected')
      .eq('enrolment_id', child.enrolmentId);

    allSessionRecords = (sessionData ?? []) as AttendanceRecord[];
  }

  // Calculate statistics for selected month
  const monthTotal = records.length;
  const monthPresent = records.filter((r) => r.status === 'present').length;
  const monthAbsent = records.filter((r) => r.status === 'absent').length;
  const monthLate = records.filter((r) => r.status === 'late').length;
  const monthHalfDay = records.filter((r) => r.status === 'half_day').length;
  const monthExcused = records.filter((r) => r.status === 'excused').length;

  const monthPct = monthTotal > 0 ? Math.round(((monthPresent + monthLate * 0.8 + monthHalfDay * 0.5) / monthTotal) * 100) : 0;

  // Calculate overall session statistics
  const sessionTotal = allSessionRecords.length;
  const sessionPresent = allSessionRecords.filter((r) => r.status === 'present').length;
  const sessionLate = allSessionRecords.filter((r) => r.status === 'late').length;
  const sessionHalfDay = allSessionRecords.filter((r) => r.status === 'half_day').length;
  const sessionPct = sessionTotal > 0 ? Math.round(((sessionPresent + sessionLate * 0.8 + sessionHalfDay * 0.5) / sessionTotal) * 100) : 0;

  // Month navigation helpers
  const prevMonthDate = new Date(year, month - 2, 1);
  const prevMonthParam = `${prevMonthDate.getFullYear()}-${String(prevMonthDate.getMonth() + 1).padStart(2, '0')}`;
  const nextMonthParam = `${nextMonthDate.getFullYear()}-${String(nextMonthDate.getMonth() + 1).padStart(2, '0')}`;
  const monthDisplayName = new Date(year, month - 1, 1).toLocaleString('default', { month: 'long', year: 'numeric' });

  return (
    <div className="space-y-6" data-testid="portal-attendance-page">
      <div>
        <h2 className="text-2xl font-semibold tracking-tight">Attendance</h2>
        <p className="text-sm text-muted-foreground">FR-N03 — Child attendance history and session percentage.</p>
      </div>

      {children.length === 0 ? (
        <p className="text-sm text-muted-foreground" data-testid="portal-attendance-empty">
          No enrolled child found on this account.
        </p>
      ) : (
        <>
          {/* Multi-child switcher */}
          {children.length > 1 && (
            <div className="flex flex-wrap gap-2" data-testid="attendance-child-selector">
              {children.map((c) => (
                <Link
                  key={c.enrolmentId}
                  href={`/portal/attendance?enrolment=${c.enrolmentId}&month=${selectedMonth}`}
                  data-testid={`attendance-child-${c.studentName}`}
                  className={`rounded-full border px-3 py-1 text-sm transition-colors ${
                    c.enrolmentId === child?.enrolmentId
                      ? 'bg-primary text-primary-foreground'
                      : 'text-muted-foreground hover:bg-muted'
                  }`}
                >
                  {c.studentName} ({c.sectionLabel})
                </Link>
              ))}
            </div>
          )}

          {/* Month Navigator */}
          <div className="flex items-center justify-between rounded-lg border bg-card p-3">
            <Link
              href={`/portal/attendance?enrolment=${child?.enrolmentId ?? ''}&month=${prevMonthParam}`}
              className="rounded-md border px-3 py-1.5 text-xs font-medium hover:bg-muted transition-colors"
              data-testid="attendance-prev-month"
            >
              &larr; Previous Month
            </Link>
            <span className="font-semibold text-sm" data-testid="attendance-current-month-label">
              {monthDisplayName}
            </span>
            <Link
              href={`/portal/attendance?enrolment=${child?.enrolmentId ?? ''}&month=${nextMonthParam}`}
              className="rounded-md border px-3 py-1.5 text-xs font-medium hover:bg-muted transition-colors"
              data-testid="attendance-next-month"
            >
              Next Month &rarr;
            </Link>
          </div>

          {/* Key KPI Statistics */}
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <Card className="p-4 shadow-sm border-muted">
              <div className="text-xs font-medium text-muted-foreground">Session Attendance</div>
              <div className="mt-1 text-2xl font-bold" data-testid="attendance-session-pct">
                {sessionPct}%
              </div>
              <div className="text-xs text-muted-foreground mt-0.5">
                {sessionPresent} / {sessionTotal} days
              </div>
            </Card>

            <Card className="p-4 shadow-sm border-muted">
              <div className="text-xs font-medium text-muted-foreground">Month Present</div>
              <div className="mt-1 text-2xl font-bold text-emerald-600 dark:text-emerald-400" data-testid="attendance-month-present">
                {monthPresent}
              </div>
              <div className="text-xs text-muted-foreground mt-0.5">of {monthTotal} working days</div>
            </Card>

            <Card className="p-4 shadow-sm border-muted">
              <div className="text-xs font-medium text-muted-foreground">Month Absent</div>
              <div className="mt-1 text-2xl font-bold text-rose-600 dark:text-rose-400" data-testid="attendance-month-absent">
                {monthAbsent}
              </div>
              <div className="text-xs text-muted-foreground mt-0.5">unexcused days</div>
            </Card>

            <Card className="p-4 shadow-sm border-muted">
              <div className="text-xs font-medium text-muted-foreground">Late / Excused</div>
              <div className="mt-1 text-2xl font-bold text-amber-600 dark:text-amber-400" data-testid="attendance-month-late">
                {monthLate + monthExcused}
              </div>
              <div className="text-xs text-muted-foreground mt-0.5">
                {monthLate} late, {monthExcused} excused
              </div>
            </Card>
          </div>

          {/* Daily Records List */}
          <Card className="shadow-sm border-muted">
            <CardHeader className="pb-3 border-b">
              <CardTitle className="text-base font-semibold">Daily Attendance Log</CardTitle>
            </CardHeader>
            <CardContent className="pt-4">
              {records.length === 0 ? (
                <div className="py-8 text-center text-sm text-muted-foreground" data-testid="attendance-no-records">
                  No attendance records logged for {monthDisplayName}.
                </div>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm" data-testid="attendance-records-table">
                    <thead>
                      <tr className="border-b text-left text-xs font-medium text-muted-foreground">
                        <th className="pb-2">Date</th>
                        <th className="pb-2">Day</th>
                        <th className="pb-2">Status</th>
                        <th className="pb-2 text-right">Time In</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y">
                      {records.map((r) => {
                        const dateObj = new Date(`${r.attendance_date}T00:00:00`);
                        const dayName = dateObj.toLocaleDateString('default', { weekday: 'short' });
                        const cfg = STATUS_CONFIG[r.status] ?? {
                          label: r.status,
                          badgeClass: 'bg-muted text-muted-foreground',
                          dotClass: 'bg-muted',
                        };

                        return (
                          <tr key={r.id} className="hover:bg-muted/40 transition-colors" data-testid={`attendance-row-${r.attendance_date}`}>
                            <td className="py-2.5 font-medium">{r.attendance_date}</td>
                            <td className="py-2.5 text-muted-foreground">{dayName}</td>
                            <td className="py-2.5">
                              <span
                                className={`inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium border ${cfg.badgeClass}`}
                                data-testid={`attendance-status-${r.attendance_date}`}
                              >
                                <span className={`h-1.5 w-1.5 rounded-full ${cfg.dotClass}`} />
                                {cfg.label}
                              </span>
                            </td>
                            <td className="py-2.5 text-right font-mono text-xs text-muted-foreground">
                              {r.arrival_time ?? '—'}
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}
