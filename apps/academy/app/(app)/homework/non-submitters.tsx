'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { loadNonSubmitters, notifyNonSubmitters, type NonSubmitter } from './non-submitter-actions';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';

export function NonSubmitters({ homeworkId, pastDue }: { homeworkId: string; pastDue: boolean }) {
  const [pending, startTransition] = useTransition();
  const [rows, setRows] = useState<NonSubmitter[] | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [error, setError] = useState<string | null>(null);

  const load = () =>
    startTransition(async () => {
      const r = await loadNonSubmitters(homeworkId);
      setError(r.error);
      setRows(r.error ? null : r.rows);
      setSelected(new Set(r.rows.filter((x) => !x.onLeave && !x.notifiedToday).map((x) => x.enrolmentId)));
    });

  const notify = () =>
    startTransition(async () => {
      const ids = [...selected];
      const includeOnLeave = (rows ?? []).some((r) => r.onLeave && selected.has(r.enrolmentId));
      const r = await notifyNonSubmitters({ homeworkId, enrolmentIds: ids, includeOnLeave });
      setError(r.error);
      if (!r.error) {
        toast.success(r.summary ?? 'Done.');
        const reload = await loadNonSubmitters(homeworkId);
        if (!reload.error) setRows(reload.rows);
      }
    });

  const toggle = (id: string) =>
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  return (
    <div className="mt-3 space-y-2 border-t pt-3 text-sm" data-testid="non-submitters">
      <Button size="sm" variant="outline" disabled={pending} onClick={load} data-testid="show-non-submitters">
        {rows ? 'Refresh not-submitted list' : 'Show students who have not submitted'}
      </Button>
      {error && <p role="alert" className="text-xs text-destructive">{error}</p>}
      {rows && (
        <div className="space-y-1">
          <p className="font-medium" data-testid="non-submitter-count">
            {rows.length} not submitted{pastDue ? '' : ' (so far — informational until the due date passes)'}
          </p>
          {rows.map((r) => (
            <label key={r.enrolmentId} className="flex items-center gap-2" data-testid="non-submitter">
              <input type="checkbox" checked={selected.has(r.enrolmentId)} disabled={!pastDue} onChange={() => toggle(r.enrolmentId)} />
              <span>
                {r.name} · GR {r.grNumber} · {r.guardianPhone ?? 'no guardian phone'}
              </span>
              {r.onLeave && <Badge variant="outline">On leave</Badge>}
              {r.notifiedToday && <Badge variant="success">Notified today</Badge>}
            </label>
          ))}
          <Button size="sm" disabled={pending || !pastDue || selected.size === 0} onClick={notify} data-testid="notify-non-submitters">
            Notify parents ({selected.size})
          </Button>
        </div>
      )}
    </div>
  );
}
