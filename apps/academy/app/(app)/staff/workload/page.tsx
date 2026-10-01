import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { todayKarachi } from '@/lib/hr/current-role';
import { formatVariance, isoWeekOf, mondayOfIsoWeek, shiftIsoWeek, workloadFlag, type WorkloadRow } from '@/lib/reports/teacher-workload';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { RefreshButton } from './refresh-button';

export const dynamic = 'force-dynamic';

export default async function TeacherWorkloadPage({ searchParams }: { searchParams: Promise<{ campus?: string; week?: string }> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').order('name');
  const campus = (campuses ?? []).find((c) => c.id === sp.campus) ?? (campuses ?? [])[0];
  if (!campus) return <p className="text-sm text-muted-foreground">No campus is available to your account.</p>;

  const week = sp.week && mondayOfIsoWeek(sp.week) ? sp.week : isoWeekOf(todayKarachi());
  const { data, error } = await supabase.rpc('get_teacher_workload', { p_campus: campus.id, p_iso_week: week });
  const rows = (data ?? []) as WorkloadRow[];
  const prev = shiftIsoWeek(week, -1);
  const next = shiftIsoWeek(week, 1);
  const base = `/staff/workload?campus=${campus.id}`;

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold">Teacher workload</h1>
          <p className="text-sm text-muted-foreground">
            FR-D20 — periods taught against periods contracted, per teacher and week. Substitution periods are shown separately and are never added to a teacher&apos;s own load.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <RefreshButton campusId={campus.id} />
          <a href={`/api/reports/teacher-workload?campus=${campus.id}&week=${week}`} className="inline-flex h-10 items-center rounded-md border px-4 text-sm font-medium" data-testid="export-workload">
            Export XLSX
          </a>
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-3 text-sm">
        {prev && (
          <Link href={`${base}&week=${prev}`} className="underline">
            ← {prev}
          </Link>
        )}
        <span className="font-medium" data-testid="workload-week">
          {week} (week of {mondayOfIsoWeek(week)})
        </span>
        {next && (
          <Link href={`${base}&week=${next}`} className="underline">
            {next} →
          </Link>
        )}
        <span className="text-muted-foreground">{campus.name}</span>
      </div>

      {error && <p role="alert" className="text-sm text-destructive">You cannot view the workload report for this campus.</p>}

      {!error && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Teachers ({rows.length})</CardTitle>
          </CardHeader>
          <CardContent className="overflow-x-auto text-sm">
            <table className="w-full min-w-[720px]" data-testid="workload-table">
              <thead>
                <tr className="border-b text-left text-muted-foreground">
                  <th className="py-2">Teacher</th>
                  <th className="py-2 text-right">Contracted</th>
                  <th className="py-2 text-right">Timetabled</th>
                  <th className="py-2 text-right">Variance</th>
                  <th className="py-2 text-right">Delivered</th>
                  <th className="py-2 text-right">Not delivered</th>
                  <th className="py-2 text-right">Substitution covered</th>
                  <th className="py-2" />
                </tr>
              </thead>
              <tbody>
                {rows.length === 0 && (
                  <tr>
                    <td colSpan={8} className="py-4 text-muted-foreground">
                      No published timetable periods or substitutions for this week. Refresh if the timetable was just published.
                    </td>
                  </tr>
                )}
                {rows.map((r) => (
                  <tr key={r.staff_id} className="border-b" data-testid={`workload-row-${r.employee_code}`}>
                    <td className="py-2">
                      {r.staff_name} <span className="text-xs text-muted-foreground">({r.employee_code})</span>
                    </td>
                    <td className="py-2 text-right tabular-nums">{r.contracted_periods ?? '—'}</td>
                    <td className="py-2 text-right tabular-nums">{r.timetabled_periods}</td>
                    <td className="py-2 text-right tabular-nums" data-testid="variance">{formatVariance(r.variance)}</td>
                    <td className="py-2 text-right tabular-nums">{r.delivered_periods}</td>
                    <td className="py-2 text-right tabular-nums">{r.not_delivered_periods}</td>
                    <td className="py-2 text-right tabular-nums" data-testid="substituted">{r.substituted_periods}</td>
                    <td className="py-2">
                      {workloadFlag(r) && <Badge variant={r.all_not_delivered ? 'warning' : 'destructive'}>{workloadFlag(r)}</Badge>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            <p className="mt-3 text-xs text-muted-foreground">Figures are as of the last refresh (daily at 02:30 PKT, or use Refresh now after publishing a timetable or approving leave).</p>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
