'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { loadAbsenteeNotifications, runAbsenteeDispatch, type NotificationRow, type SectionNotMarked } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { DatePicker } from '@/components/ui/date-picker';

function todayIso() {
  return new Date().toISOString().slice(0, 10);
}

export function AbsenteeNotificationsView({ campusId, isAdmin }: { campusId: string; isAdmin: boolean }) {
  const [pending, startTransition] = useTransition();
  const [date, setDate] = useState(todayIso());
  const [rows, setRows] = useState<NotificationRow[]>([]);
  const [sectionsNotMarked, setSectionsNotMarked] = useState<SectionNotMarked[]>([]);
  const [loaded, setLoaded] = useState(false);

  const onLoad = () => {
    startTransition(async () => {
      const result = await loadAbsenteeNotifications(campusId, date);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      setRows(result.rows);
      setSectionsNotMarked(result.sectionsNotMarked);
      setLoaded(true);
    });
  };

  const onDispatch = () => {
    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('date', date);
    startTransition(async () => {
      const result = await runAbsenteeDispatch({ error: null, queued: null, skippedNoContact: null, sectionsNotMarked: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`Queued ${result.queued}, skipped ${result.skippedNoContact} (no contact).`);
        onLoad();
      }
    });
  };

  const exceptions = rows.filter((r) => r.status === 'skipped_no_contact');

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-2 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="date">Date</Label>
          <DatePicker id="date" className="w-40" value={date} onChange={setDate} data-testid="absentee-date" />
        </div>
        <Button type="button" disabled={pending} onClick={onLoad} data-testid="absentee-load">
          Load
        </Button>
        {isAdmin && (
          <Button type="button" variant="outline" disabled={pending} onClick={onDispatch} data-testid="absentee-dispatch">
            Run now
          </Button>
        )}
      </div>

      {loaded && sectionsNotMarked.length > 0 && (
        <div className="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-800" data-testid="absentee-not-marked">
          <p className="font-medium">Attendance not marked for {sectionsNotMarked.length} section(s):</p>
          <ul className="list-inside list-disc">
            {sectionsNotMarked.map((s) => (
              <li key={s.sectionId}>{s.sectionLabel}</li>
            ))}
          </ul>
        </div>
      )}

      {loaded &&
        (rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">No notifications for this date yet.</p>
        ) : (
          <div className="space-y-4">
            <div className="overflow-x-auto rounded-lg border">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b bg-muted/50 text-left">
                    <th className="p-2">Student</th>
                    <th className="p-2">Status</th>
                    <th className="p-2">Language</th>
                    <th className="p-2">Recipient</th>
                    <th className="p-2">Cost (paisa)</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr key={r.enrolmentId} className="border-b" data-testid={`absentee-row-${r.enrolmentId}`}>
                      <td className="p-2">
                        {r.studentName} <span className="text-muted-foreground">({r.grNumber})</span>
                      </td>
                      <td className="p-2" data-testid={`absentee-status-${r.enrolmentId}`}>
                        {r.status}
                      </td>
                      <td className="p-2">{r.language}</td>
                      <td className="p-2">{r.recipientMsisdn ?? '—'}</td>
                      <td className="p-2">{r.costPaisa}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {exceptions.length > 0 && (
              <div className="rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-800" data-testid="absentee-exceptions">
                <p className="font-medium">{exceptions.length} guardian(s) with no contact on file:</p>
                <ul className="list-inside list-disc">
                  {exceptions.map((r) => (
                    <li key={r.enrolmentId}>
                      {r.studentName} ({r.grNumber})
                    </li>
                  ))}
                </ul>
              </div>
            )}
          </div>
        ))}
    </div>
  );
}
