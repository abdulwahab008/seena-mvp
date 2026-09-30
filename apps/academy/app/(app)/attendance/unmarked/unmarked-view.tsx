'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { runUnmarkedAttendanceCheck, type UnmarkedSection } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { DatePicker } from '@/components/ui/date-picker';

function todayIso() {
  return new Date().toISOString().slice(0, 10);
}

export function UnmarkedView({ campusId }: { campusId: string }) {
  const [pending, startTransition] = useTransition();
  const [date, setDate] = useState(todayIso());
  const [ran, setRan] = useState(false);
  const [skipped, setSkipped] = useState(false);
  const [holidayReason, setHolidayReason] = useState<string | null>(null);
  const [sections, setSections] = useState<UnmarkedSection[]>([]);

  const onRun = () => {
    startTransition(async () => {
      const result = await runUnmarkedAttendanceCheck(campusId, date);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      setRan(true);
      setSkipped(result.skipped);
      setHolidayReason(result.holidayReason);
      setSections(result.sections);
    });
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-2 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="unmarked-date">Date</Label>
          <DatePicker id="unmarked-date" className="w-40" value={date} onChange={setDate} data-testid="unmarked-date" />
        </div>
        <Button type="button" disabled={pending} onClick={onRun} data-testid="unmarked-run">
          {pending ? 'Checking…' : 'Run check'}
        </Button>
      </div>

      {ran && skipped && (
        <p className="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-800" data-testid="unmarked-holiday-banner">
          Skipped — {holidayReason} is a declared holiday.
        </p>
      )}

      {ran && !skipped && sections.length === 0 && (
        <p className="text-sm text-muted-foreground" data-testid="unmarked-none">
          Every active section has attendance marked for this date.
        </p>
      )}

      {ran && !skipped && sections.length > 0 && (
        <div className="overflow-x-auto rounded-lg border">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b bg-muted/50 text-left">
                <th className="p-2">Section</th>
                <th className="p-2">Class teacher</th>
                <th className="p-2">Status</th>
              </tr>
            </thead>
            <tbody>
              {sections.map((s) => (
                <tr key={s.sectionId} className="border-b" data-testid={`unmarked-row-${s.sectionId}`}>
                  <td className="p-2">{s.sectionLabel}</td>
                  <td className="p-2">{s.classTeacherName}</td>
                  <td className="p-2" data-testid={`unmarked-status-${s.sectionId}`}>
                    {s.status}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
