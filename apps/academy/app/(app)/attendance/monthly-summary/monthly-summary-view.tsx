'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { loadMonthlySummary, recomputeMonthlyAttendance, type SummaryRow } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export function MonthlySummaryView({
  campusId,
  sections,
  isAdmin,
}: {
  campusId: string;
  sections: { id: string; label: string }[];
  isAdmin: boolean;
}) {
  const [pending, startTransition] = useTransition();
  const [sectionId, setSectionId] = useState(sections[0]?.id ?? '');
  const [year, setYear] = useState(new Date().getFullYear());
  const [month, setMonth] = useState(new Date().getMonth() + 1);
  const [rows, setRows] = useState<SummaryRow[]>([]);
  const [loaded, setLoaded] = useState(false);

  const onLoad = () => {
    if (!sectionId) return;
    startTransition(async () => {
      const result = await loadMonthlySummary(sectionId, year, month);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      setRows(result.rows);
      setLoaded(true);
    });
  };

  const onRecompute = () => {
    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('year', String(year));
    fd.set('month', String(month));
    startTransition(async () => {
      const result = await recomputeMonthlyAttendance({ error: null, count: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`Recomputed ${result.count} enrolment(s).`);
        onLoad();
      }
    });
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-2 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="section">Section</Label>
          <Select value={sectionId} onValueChange={setSectionId}>
            <SelectTrigger id="section" className="w-48" data-testid="summary-section-trigger">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {sections.map((s) => (
                <SelectItem key={s.id} value={s.id}>
                  {s.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="year">Year</Label>
          <Input
            id="year"
            type="number"
            className="w-24"
            value={year}
            onChange={(e) => setYear(Number(e.target.value))}
            data-testid="summary-year"
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="month">Month</Label>
          <Input
            id="month"
            type="number"
            min={1}
            max={12}
            className="w-20"
            value={month}
            onChange={(e) => setMonth(Number(e.target.value))}
            data-testid="summary-month"
          />
        </div>
        <Button type="button" disabled={pending} onClick={onLoad} data-testid="summary-load">
          Load
        </Button>
        {isAdmin && (
          <Button type="button" variant="outline" disabled={pending} onClick={onRecompute} data-testid="summary-recompute">
            Recompute
          </Button>
        )}
      </div>

      {loaded &&
        (rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">No summary computed yet for this section/month.</p>
        ) : (
          <div className="overflow-x-auto rounded-lg border">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b bg-muted/50 text-left">
                  <th className="p-2">Student</th>
                  <th className="p-2">Working days</th>
                  <th className="p-2">Present</th>
                  <th className="p-2">Absent</th>
                  <th className="p-2">Late</th>
                  <th className="p-2">Half day</th>
                  <th className="p-2">Leave</th>
                  <th className="p-2">Attendance %</th>
                  <th className="p-2">Status</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.enrolmentId} className="border-b" data-testid={`summary-row-${r.enrolmentId}`}>
                    <td className="p-2">
                      {r.name} <span className="text-muted-foreground">({r.grNumber})</span>
                    </td>
                    <td className="p-2">{r.workingDays}</td>
                    <td className="p-2">{r.presentDays}</td>
                    <td className="p-2">{r.absentDays}</td>
                    <td className="p-2">{r.lateCount}</td>
                    <td className="p-2">{r.halfDayCount}</td>
                    <td className="p-2">{r.leaveDays}</td>
                    <td className="p-2" data-testid={`summary-pct-${r.enrolmentId}`}>
                      {r.attendancePct === null ? '—' : `${r.attendancePct}%`}
                    </td>
                    <td className="p-2">{r.stale ? <span className="text-amber-700">Stale</span> : 'Current'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ))}
    </div>
  );
}
