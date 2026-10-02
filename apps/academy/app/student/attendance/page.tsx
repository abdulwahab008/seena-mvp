import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Calendar, CheckCircle2, XCircle, Clock, AlertTriangle } from 'lucide-react';

const STATUS_CONFIG: Record<
  string,
  { label: string; badgeClass: string; icon: typeof CheckCircle2 }
> = {
  present: {
    label: 'Present',
    badgeClass: 'bg-emerald-100 text-emerald-800 border-emerald-200 dark:bg-emerald-950/40 dark:text-emerald-400',
    icon: CheckCircle2,
  },
  absent: {
    label: 'Absent',
    badgeClass: 'bg-rose-100 text-rose-800 border-rose-200 dark:bg-rose-950/40 dark:text-rose-400',
    icon: XCircle,
  },
  late: {
    label: 'Late',
    badgeClass: 'bg-amber-100 text-amber-800 border-amber-200 dark:bg-amber-950/40 dark:text-amber-400',
    icon: Clock,
  },
  half_day: {
    label: 'Half Day',
    badgeClass: 'bg-orange-100 text-orange-800 border-orange-200 dark:bg-orange-950/40 dark:text-orange-400',
    icon: AlertTriangle,
  },
  excused: {
    label: 'Excused',
    badgeClass: 'bg-sky-100 text-sky-800 border-sky-200 dark:bg-sky-950/40 dark:text-sky-400',
    icon: CheckCircle2,
  },
};

export default async function StudentAttendancePage() {
  const supabase = await supabaseServer();

  // Query own attendance records (scoped by RLS attendance_day_student_self)
  const { data: records } = await supabase
    .from('attendance_day')
    .select('id, attendance_date, status, arrival_time, departure_time')
    .order('attendance_date', { ascending: false })
    .limit(60);

  const days = records ?? [];
  const presentCount = days.filter((d) => d.status === 'present' || d.status === 'excused').length;
  const totalCount = days.length;
  const attendanceRate = totalCount > 0 ? Math.round((presentCount / totalCount) * 100) : 100;

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-xl font-bold tracking-tight">Attendance Record</h2>
        <p className="text-sm text-muted-foreground">
          Your recorded daily attendance and session summary.
        </p>
      </div>

      <div className="grid gap-4 sm:grid-cols-3">
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-xs font-medium text-muted-foreground">Attendance Rate</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{attendanceRate}%</div>
            <p className="text-xs text-muted-foreground mt-1">Based on recent {totalCount} school days</p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-xs font-medium text-muted-foreground">Days Present</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-emerald-600">{presentCount}</div>
            <p className="text-xs text-muted-foreground mt-1">Present or Excused</p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-xs font-medium text-muted-foreground">Days Absent</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-rose-600">
              {days.filter((d) => d.status === 'absent').length}
            </div>
            <p className="text-xs text-muted-foreground mt-1">Unexcused absences</p>
          </CardContent>
        </Card>
      </div>

      {days.length === 0 ? (
        <div className="rounded-lg border bg-card p-12 text-center text-muted-foreground">
          <Calendar className="mx-auto h-10 w-10 mb-3 opacity-40" />
          <p className="font-medium">No attendance records logged yet.</p>
          <p className="text-xs mt-1">Attendance records will appear here as daily registers are marked.</p>
        </div>
      ) : (
        <div className="overflow-hidden rounded-lg border bg-card shadow-sm">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b bg-muted/50 text-left">
                <th className="p-3 font-semibold text-muted-foreground">Date</th>
                <th className="p-3 font-semibold text-muted-foreground">Status</th>
                <th className="p-3 font-semibold text-muted-foreground">Arrival</th>
              </tr>
            </thead>
            <tbody>
              {days.map((record) => {
                const cfg = STATUS_CONFIG[record.status] ?? STATUS_CONFIG.present!;
                const Icon = cfg.icon;
                return (
                  <tr key={record.id} className="border-b last:border-b-0 hover:bg-muted/20">
                    <td className="p-3 font-medium">{record.attendance_date}</td>
                    <td className="p-3">
                      <span className={`inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium border ${cfg.badgeClass}`}>
                        <Icon className="h-3 w-3" />
                        {cfg.label}
                      </span>
                    </td>
                    <td className="p-3 text-muted-foreground">
                      {record.arrival_time ? record.arrival_time.slice(0, 5) : '—'}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
